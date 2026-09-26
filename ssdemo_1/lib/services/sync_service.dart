import 'dart:async';
import 'dart:convert';

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
import 'sync_cache.dart';

/// Thrown when Plaid reports ITEM_LOGIN_REQUIRED for a linked bank.
class ItemLoginRequiredException implements Exception {
  const ItemLoginRequiredException();
  @override
  String toString() => 'Bank re-authentication required';
}

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

/// A [SyncResult] rebuilt from the on-device copy, and when that copy was saved.
class CachedSyncResult {
  const CachedSyncResult({required this.result, required this.savedAt});

  final SyncResult result;
  final DateTime savedAt;
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

  /// Triggers the backend bank sync endpoint.
  /// Throws [ItemLoginRequiredException] if re-authentication is needed.
  Future<void> triggerBankSync() async {
    try {
      final response = await http
          .get(ApiConfig.instance.transactionsUri, headers: _backendHeaders())
          .timeout(const Duration(seconds: 30));
      if (response.statusCode == 400 && _isLoginRequired(response.body)) {
        throw const ItemLoginRequiredException();
      }
    } on ItemLoginRequiredException {
      rethrow;
    } catch (_) {
      // Other network/server errors are best-effort — don't block the UI.
    }
  }

  /// True only when the backend explicitly reports ITEM_LOGIN_REQUIRED.
  /// Plaid API errors also surface as 400, so the status alone is not enough.
  bool _isLoginRequired(String body) {
    try {
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['error_code'] == 'ITEM_LOGIN_REQUIRED';
    } catch (_) {
      return false;
    }
  }

  /// Central load path: accounts, transactions, subscriptions, budgets.
  /// Also saves the raw rows on-device so the next launch can paint from them.
  Future<SyncResult> refreshFromSupabase(
    Map<String, String> reviewedCategoryByTxId,
    DateTime selectedMonth,
  ) async {
    final raw = await fetchRaw(
      AuthService.instance.currentUserId,
      selectedMonth,
    );
    unawaited(SyncCache.instance.save(raw));
    return buildResult(raw, reviewedCategoryByTxId);
  }

  /// The last successful load saved on this device, rebuilt into a result, or
  /// null when there is none. Never throws: the saved copy is an optimization.
  Future<CachedSyncResult?> loadCachedResult(
    Map<String, String> reviewedCategoryByTxId,
    DateTime selectedMonth,
  ) async {
    try {
      final raw = await SyncCache.instance.load(
        AuthService.instance.currentUserId,
      );
      if (raw == null) return null;
      final monthYear = _monthKey(normalizedMonthOption(selectedMonth));
      // Budget limits are stored per month; don't show another month's limits.
      final usable = raw.monthYear == monthYear ? raw : raw.withoutBudgets();
      return CachedSyncResult(
        result: buildResult(usable, reviewedCategoryByTxId),
        savedAt: raw.savedAt,
      );
    } catch (_) {
      return null;
    }
  }

  /// Forgets the on-device copy (sign-out, "Clear").
  Future<void> clearSavedData() => SyncCache.instance.clear();

  /// Fetches everything a refresh needs from Supabase, unparsed.
  Future<RawSyncData> fetchRaw(String userId, DateTime selectedMonth) async {
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
        .select(
          'id,merchant_name,amount,next_charge_date,frequency,needs_confirmation',
        )
        .eq('user_id', userId)
        .eq('is_active', true)
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
    final rememberedRules = await CategoryService.instance
        .fetchRememberedRuleDecisions(userId);

    return RawSyncData(
      userId: userId,
      monthYear: monthYear,
      savedAt: DateTime.now(),
      accountsRows: accountsRows,
      categories: userCategories,
      budgetRows: (budgetRows as List)
          .whereType<Map<String, dynamic>>()
          .toList(),
      subscriptionRows: (subscriptionRows as List)
          .whereType<Map<String, dynamic>>()
          .toList(),
      txRows: txRows,
      rememberedRules: {
        for (final e in rememberedRules.entries)
          e.key: {
            'category': e.value.category,
            'confidence': e.value.confidence,
          },
      },
    );
  }

  /// Turns raw rows (fresh from Supabase or from the on-device copy) into the
  /// parsed result the UI renders. Pure: no network, no storage.
  SyncResult buildResult(
    RawSyncData raw,
    Map<String, String> reviewedCategoryByTxId, {
    DateTime? asOf,
  }) {
    final now = asOf ?? DateTime.now();
    final txRows = raw.txRows;
    final accountsRows = raw.accountsRows;
    final userCategories = raw.categories;
    final rememberedRules = {
      for (final e in raw.rememberedRules.entries)
        e.key: CategoryDecision(
          category: e.value['category'] ?? '',
          confidence: e.value['confidence'] ?? 'high',
        ),
    };

    // Parse and de-duplicate transactions.
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
    for (final row in raw.subscriptionRows) {
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
          id: (row['id'] as String?) ?? '',
          merchant: merchant,
          amount: amount.abs(),
          nextChargeDate: nextDate,
          frequency: frequency,
          needsConfirmation: row['needs_confirmation'] == true,
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
    final budgetRowsList = raw.budgetRows;
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
