import 'package:http/http.dart' as http;

import '../core/config/api_config.dart';
import '../core/config/env_config.dart';
import '../core/config/supabase_client.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import 'account_service.dart';
import 'auth_service.dart';
import 'budget_service.dart';
import 'category_service.dart';

/// Result payload returned by a full sync or refresh.
class SyncResult {
  const SyncResult({
    required this.transactions,
    required this.subscriptions,
    required this.budgetProgress,
    required this.budgetProgressYear,
    required this.budgetProgressAll,
    required this.categoryOptions,
    required this.accountOptions,
    required this.stats,
    required this.hasData,
    required this.autoReviewedCategoryByTxId,
    required this.autoLowConfidenceReviewTxIds,
  });

  final List<AppTransaction> transactions;
  final List<DetectedSubscription> subscriptions;
  final List<BudgetCategoryProgress> budgetProgress;
  final List<BudgetCategoryProgress> budgetProgressYear;
  final List<BudgetCategoryProgress> budgetProgressAll;
  final List<CategoryOption> categoryOptions;
  final List<AccountOption> accountOptions;
  final DashboardStats stats;
  final bool hasData;
  final Map<String, String> autoReviewedCategoryByTxId;
  final Set<String> autoLowConfidenceReviewTxIds;
}

/// Orchestrates bank sync trigger and Supabase data loading.
class SyncService {
  const SyncService._();
  static const instance = SyncService._();

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  Map<String, String> _backendHeaders() {
    final headers = <String, String>{
      'x-api-key': EnvConfig.instance.backendApiKey,
    };
    final accessToken = AuthService.instance.currentAccessToken;
    if (accessToken != null && accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    return headers;
  }

  /// Triggers the backend bank sync endpoint (best-effort).
  Future<void> triggerBankSync() async {
    try {
      await http
          .get(ApiConfig.instance.transactionsUri, headers: _backendHeaders())
          .timeout(const Duration(seconds: 30));
    } catch (_) {}
  }

  /// Central load path: accounts, transactions, subscriptions, budgets.
  Future<SyncResult> refreshFromSupabase(
    Map<String, String> reviewedCategoryByTxId,
    DateTime selectedMonth,
  ) async {
    final userId = AuthService.instance.currentUserId;
    final now = DateTime.now();
    final focused = normalizedMonthOption(selectedMonth);
    final monthYear = _monthKey(focused);

    final accountsRows = await AccountService.instance.fetchAccountRows(
      userId,
      unscoped: false,
    );
    final accountMetaById = {
      for (final row in accountsRows)
        ((row['plaid_account_id'] as String?) ?? '').trim(): {
          'account_name': ((row['name'] as String?) ?? '').trim(),
          'account_type': ((row['account_type'] as String?) ?? '').trim(),
          'subtype': ((row['subtype'] as String?) ?? '').trim(),
        },
    }..remove('');
    final userCategories = await CategoryService.instance.ensureBaseCategories(
      userId,
    );
    await BudgetService.instance.ensureMonthlyBudgetRows(
      userCategories,
      monthYear,
      userId,
    );

    final budgetRows = await AppSupabase.client
        .from('budgets')
        .select('id,category_id,monthly_limit,month_year')
        .eq('user_id', userId)
        .eq('month_year', monthYear);

    final subscriptionRows = await AppSupabase.client
        .from('subscriptions')
        .select('id,merchant_name,amount,next_charge_date,frequency')
        .eq('user_id', userId)
        .order('next_charge_date', ascending: true)
        .limit(500);

    final rows = await AppSupabase.client
        .from('transactions')
        .select(
          'plaid_transaction_id,plaid_account_id,merchant_name,name,category,pfc_primary,pfc_detailed,pfc_confidence,pending,date,amount,user_id',
        )
        .eq('user_id', userId)
        .order('date', ascending: false)
        .limit(1000);

    // Parse and de-duplicate transactions.
    final txRows = (rows as List).whereType<Map<String, dynamic>>().map((row) {
      final accountId = ((row['plaid_account_id'] as String?) ?? '').trim();
      final meta = accountMetaById[accountId] ?? const <String, String>{};
      return {
        ...row,
        'account_name': meta['account_name'] ?? '',
        'account_type': meta['account_type'] ?? '',
        'subtype': meta['subtype'] ?? '',
      };
    }).toList();
    final rememberedRulesUserId = userId;
    final rememberedRules = await CategoryService.instance
        .fetchRememberedRuleDecisions(rememberedRulesUserId);
    final parsed = txRows.map(AppTransaction.fromMap).toList();
    final deduped = <AppTransaction>[];
    final seen = <String>{};
    for (final tx in parsed) {
      if (seen.add(tx.dedupeKey)) deduped.add(tx);
    }

    final effectiveReviewedCategoryByTxId = <String, String>{
      ...reviewedCategoryByTxId,
    };
    final autoReviewedCategoryByTxId = <String, String>{};
    final autoLowConfidenceReviewTxIds = <String>{};

    for (int i = 0; i < txRows.length && i < parsed.length; i++) {
      final tx = parsed[i];
      final key = CategoryService.instance.ruleKeyForRawTransaction(txRows[i]);
      if (key.isEmpty) continue;
      final remembered = rememberedRules[key];
      if (remembered != null && remembered.category.isNotEmpty) {
        autoReviewedCategoryByTxId[tx.id] = remembered.category;
        continue;
      }
      final decision = CategoryService.instance.classifyByPfcSignals(
        pfcPrimary: ((txRows[i]['pfc_primary'] as String?) ?? '').trim(),
        pfcDetailed:
            ((txRows[i]['pfc_detailed'] as String?) ??
                    (txRows[i]['category'] as String?) ??
                    '')
                .trim(),
        merchantName:
            ((txRows[i]['name'] as String?) ??
                    (txRows[i]['merchant_name'] as String?) ??
                    '')
                .trim(),
        transactionName: ((txRows[i]['name'] as String?) ?? '').trim(),
      );
      autoReviewedCategoryByTxId[tx.id] = decision.category;
      if (decision.confidence == 'low') {
        autoLowConfidenceReviewTxIds.add(tx.id);
      }
    }
    effectiveReviewedCategoryByTxId.addAll(autoReviewedCategoryByTxId);

    // Build subscriptions.
    final dbSubscriptions = <DetectedSubscription>[];
    final subSeen = <String>{};
    for (final row
        in (subscriptionRows as List).whereType<Map<String, dynamic>>()) {
      final merchant = (row['merchant_name'] as String?)?.trim();
      if (merchant == null || merchant.isEmpty) continue;
      final rawAmount = row['amount'];
      final amount = rawAmount is num
          ? rawAmount.toDouble()
          : double.tryParse('$rawAmount') ?? 0;
      final rawDate = (row['next_charge_date'] as String?) ?? '';
      final nextDate = DateTime.tryParse(rawDate);
      if (nextDate == null) continue;
      final frequency =
          ((row['frequency'] as String?)?.trim().isNotEmpty ?? false)
          ? (row['frequency'] as String).trim()
          : 'monthly';
      final dedupeKey =
          '${merchant.toLowerCase()}|${amount.toStringAsFixed(2)}|${nextDate.toIso8601String().split("T").first}';
      if (!subSeen.add(dedupeKey)) continue;
      dbSubscriptions.add(
        DetectedSubscription(
          merchant: merchant,
          amount: amount.abs(),
          nextChargeDate: nextDate,
          frequency: frequency,
        ),
      );
    }

    // Dashboard stats.
    double monthlyIncome = 0;
    double monthlyExpenses = 0;
    for (final tx in deduped) {
      if (tx.date.year == now.year && tx.date.month == now.month) {
        monthlyIncome += tx.incomeAmount;
        monthlyExpenses += tx.expenseAmount;
      }
    }
    final totalBalance = AccountService.instance.computeTotalBalance(
      accountsRows,
    );

    // Account options.
    final txCountByAccount = <String, int>{};
    for (final tx in deduped) {
      if (tx.accountId.isEmpty) continue;
      txCountByAccount[tx.accountId] =
          (txCountByAccount[tx.accountId] ?? 0) + 1;
    }
    final accountOptions = AccountService.instance.buildAccountOptions(
      accountsRows,
      txCountByAccount,
    );

    // Budget progress.
    final categoryMap = {for (final c in userCategories) c.id: c.name};
    final budgetRowsList = (budgetRows as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    final budgetProgress = BudgetService.instance.buildProgressFromRows(
      budgetRows: budgetRowsList,
      categoryMap: categoryMap,
      txRows: txRows,
      now: now,
      yearly: false,
      reviewedCategoryByTxId: effectiveReviewedCategoryByTxId,
    );
    final budgetProgressYear = BudgetService.instance.buildProgressFromRows(
      budgetRows: budgetRowsList,
      categoryMap: categoryMap,
      txRows: txRows,
      now: now,
      yearly: true,
      reviewedCategoryByTxId: effectiveReviewedCategoryByTxId,
    );
    final effectiveBudgetProgress = budgetProgress.isNotEmpty
        ? budgetProgress
        : BudgetService.instance.buildZeroLimitProgressFromPresetCategories(
            deduped,
            now,
            false,
            effectiveReviewedCategoryByTxId,
          );
    final effectiveBudgetProgressYear = budgetProgressYear.isNotEmpty
        ? budgetProgressYear
        : BudgetService.instance.buildZeroLimitProgressFromPresetCategories(
            deduped,
            now,
            true,
            effectiveReviewedCategoryByTxId,
          );
    final effectiveBudgetProgressAll = BudgetService.instance
        .buildZeroLimitProgressFromPresetCategoriesAllTime(
          deduped,
          now,
          effectiveReviewedCategoryByTxId,
        );

    return SyncResult(
      transactions: deduped,
      subscriptions: dbSubscriptions,
      budgetProgress: effectiveBudgetProgress,
      budgetProgressYear: effectiveBudgetProgressYear,
      budgetProgressAll: effectiveBudgetProgressAll,
      categoryOptions: userCategories,
      accountOptions: accountOptions,
      stats: DashboardStats(
        totalBalance: totalBalance,
        monthlyIncome: monthlyIncome,
        monthlyExpenses: monthlyExpenses,
        netThisMonth: monthlyIncome - monthlyExpenses,
      ),
      hasData:
          deduped.isNotEmpty ||
          totalBalance > 0 ||
          effectiveBudgetProgress.isNotEmpty ||
          effectiveBudgetProgressYear.isNotEmpty ||
          dbSubscriptions.isNotEmpty,
      autoReviewedCategoryByTxId: autoReviewedCategoryByTxId,
      autoLowConfidenceReviewTxIds: autoLowConfidenceReviewTxIds,
    );
  }
}
