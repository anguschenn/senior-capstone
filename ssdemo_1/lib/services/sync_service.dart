import 'package:http/http.dart' as http;

import '../core/config/api_config.dart';
import '../core/config/env_config.dart';
import '../core/config/supabase_client.dart';
import '../models/app_models.dart';
import 'account_service.dart';
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
}

/// Orchestrates Plaid sync trigger and Supabase data loading.
class SyncService {
  const SyncService._();
  static const instance = SyncService._();

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  /// Triggers the backend Plaid sync endpoint (best-effort).
  Future<void> triggerPlaidSync() async {
    try {
      await http
          .get(
            ApiConfig.instance.transactionsUri,
            headers: {'x-api-key': EnvConfig.instance.backendApiKey},
          )
          .timeout(const Duration(seconds: 4));
    } catch (_) {}
  }

  /// Central load path: accounts, transactions, subscriptions, budgets.
  Future<SyncResult> refreshFromSupabase(
    Map<String, String> reviewedCategoryByTxId,
  ) async {
    final userId = EnvConfig.instance.demoUserId;
    final now = DateTime.now();
    final monthYear = _monthKey(now);

    final accountsRows = await AccountService.instance.fetchAccountRows(userId);
    final userCategories =
        await CategoryService.instance.ensureBaseCategories(userId);
    await BudgetService.instance
        .initializeBudgetsTo500(userCategories, monthYear, userId);

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
          'plaid_transaction_id,plaid_account_id,merchant_name,name,category,pfc_primary,pfc_detailed,pfc_confidence,date,amount,pending,user_id',
        )
        .eq('user_id', userId)
        .order('date', ascending: false)
        .limit(1000);

    // Parse and de-duplicate transactions.
    final txRows =
        (rows as List).whereType<Map<String, dynamic>>().toList();
    final parsed = txRows.map(AppTransaction.fromMap).toList();
    final deduped = <AppTransaction>[];
    final seen = <String>{};
    for (final tx in parsed) {
      if (seen.add(tx.dedupeKey)) deduped.add(tx);
    }

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
        if (tx.amount < 0) {
          monthlyIncome += tx.amount.abs();
        } else {
          monthlyExpenses += tx.amount;
        }
      }
    }
    final totalBalance =
        AccountService.instance.computeTotalBalance(accountsRows);

    // Account options.
    final txCountByAccount = <String, int>{};
    for (final tx in deduped) {
      if (tx.accountId.isEmpty) continue;
      txCountByAccount[tx.accountId] =
          (txCountByAccount[tx.accountId] ?? 0) + 1;
    }
    final accountOptions = AccountService.instance
        .buildAccountOptions(accountsRows, txCountByAccount);

    // Budget progress.
    final categoryMap = {for (final c in userCategories) c.id: c.name};
    final budgetRowsList =
        (budgetRows as List).whereType<Map<String, dynamic>>().toList();
    final budgetProgress = BudgetService.instance.buildProgressFromRows(
      budgetRows: budgetRowsList,
      categoryMap: categoryMap,
      txRows: txRows,
      now: now,
      yearly: false,
      reviewedCategoryByTxId: reviewedCategoryByTxId,
    );
    final budgetProgressYear = BudgetService.instance.buildProgressFromRows(
      budgetRows: budgetRowsList,
      categoryMap: categoryMap,
      txRows: txRows,
      now: now,
      yearly: true,
      reviewedCategoryByTxId: reviewedCategoryByTxId,
    );
    final effectiveBudgetProgress = budgetProgress.isNotEmpty
        ? budgetProgress
        : BudgetService.instance
              .presetBudgetProgress(deduped, now, false, reviewedCategoryByTxId);
    final effectiveBudgetProgressYear = budgetProgressYear.isNotEmpty
        ? budgetProgressYear
        : BudgetService.instance
              .presetBudgetProgress(deduped, now, true, reviewedCategoryByTxId);
    final effectiveBudgetProgressAll = BudgetService.instance
        .presetBudgetProgressAllTime(deduped, now, reviewedCategoryByTxId);

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
      hasData: deduped.isNotEmpty ||
          totalBalance > 0 ||
          effectiveBudgetProgress.isNotEmpty ||
          effectiveBudgetProgressYear.isNotEmpty ||
          dbSubscriptions.isNotEmpty,
    );
  }
}
