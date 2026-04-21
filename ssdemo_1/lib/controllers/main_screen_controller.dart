import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../core/config/env_config.dart';
import '../models/app_models.dart';
import '../services/budget_service.dart';
import '../services/sync_service.dart';

/// Owns all mutable state for the main screen and exposes actions for the UI.
class MainScreenController extends ChangeNotifier {
  // Navigation
  int tabIndex = 0;

  // Sync
  bool syncing = false;
  String syncStatus = 'No data loaded yet';

  // Live data
  List<AppTransaction> liveTransactions = const [];
  List<DetectedSubscription> liveSubscriptions = const [];
  List<BudgetCategoryProgress> liveBudgetProgress = const [];
  List<BudgetCategoryProgress> liveBudgetProgressYear = const [];
  List<BudgetCategoryProgress> liveBudgetProgressAll = const [];
  List<CategoryOption> liveCategoryOptions = const [];
  List<AccountOption> liveAccountOptions = const [];
  Map<String, String> reviewedCategoryByTxId = const {};
  Set<String> confirmedReviewTxIds = const {};
  String selectedAccountId = kAllAccountsId;
  DateTime selectedMonth = DateTime(
    DateTime.now().year,
    DateTime.now().month,
    1,
  );
  DashboardStats liveStats = const DashboardStats(
    totalBalance: 0,
    monthlyIncome: 0,
    monthlyExpenses: 0,
    netThisMonth: 0,
  );

  // --- Actions ---

  void selectTab(int i) {
    tabIndex = i;
    notifyListeners();
  }

  void selectAccount(String accountId) {
    selectedAccountId = accountId;
    notifyListeners();
  }

  void selectMonth(DateTime month) {
    selectedMonth = DateTime(month.year, month.month, 1);
    notifyListeners();
  }

  Future<void> refreshLiveDataOnly() async {
    if (syncing) return;
    syncing = true;
    syncStatus = 'Refreshing from DB...';
    notifyListeners();
    try {
      final result = await SyncService.instance.refreshFromSupabase(
        reviewedCategoryByTxId,
      );
      _applySyncResult(result);
      syncStatus = result.hasData
          ? 'Connected: using database data'
          : 'No DB data yet';
    } catch (e) {
      syncStatus = 'Refresh failed: $e';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  Future<void> connectPlaidAndPullData() async {
    if (syncing) return;
    syncing = true;
    syncStatus = 'Syncing...';
    notifyListeners();

    await SyncService.instance.triggerPlaidSync();

    try {
      final result = await SyncService.instance.refreshFromSupabase(
        reviewedCategoryByTxId,
      );
      _applySyncResult(result);
      syncStatus = result.hasData
          ? 'Connected: using database data'
          : 'No DB data found';
    } catch (e) {
      syncStatus = 'Sync failed: $e';
    } finally {
      syncing = false;
      notifyListeners();
    }
  }

  void clearLiveData() {
    liveTransactions = const [];
    liveSubscriptions = const [];
    liveBudgetProgress = const [];
    liveBudgetProgressYear = const [];
    liveBudgetProgressAll = const [];
    liveCategoryOptions = const [];
    liveAccountOptions = const [];
    reviewedCategoryByTxId = const {};
    confirmedReviewTxIds = const {};
    selectedAccountId = kAllAccountsId;
    selectedMonth = DateTime(DateTime.now().year, DateTime.now().month, 1);
    liveStats = const DashboardStats(
      totalBalance: 0,
      monthlyIncome: 0,
      monthlyExpenses: 0,
      netThisMonth: 0,
    );
    syncStatus = 'Live data cleared';
    notifyListeners();
  }

  void onTransactionCategorySelected(AppTransaction tx, String category) {
    if (tx.amount < 0) return;
    final reviewedNext = Map<String, String>.from(reviewedCategoryByTxId);
    reviewedNext[tx.id] = category;
    final confirmedNext = Set<String>.from(confirmedReviewTxIds);
    confirmedNext.remove(tx.id);
    reviewedCategoryByTxId = reviewedNext;
    confirmedReviewTxIds = confirmedNext;
    _rebuildBudgetProgress();
    notifyListeners();
  }

  void confirmReviewedCategory(String txId) {
    confirmedReviewTxIds = Set<String>.from(confirmedReviewTxIds)..add(txId);
    notifyListeners();
  }

  Future<void> updateBudgetLimit(String budgetId, double monthlyLimit) async {
    if (monthlyLimit <= 0) return;
    if (budgetId.startsWith('preset_')) {
      liveBudgetProgress = liveBudgetProgress
          .map(
            (b) => b.budgetId == budgetId
                ? BudgetCategoryProgress(
                    budgetId: b.budgetId,
                    categoryId: b.categoryId,
                    title: b.title,
                    spent: b.spent,
                    limit: monthlyLimit,
                  )
                : b,
          )
          .toList();
      notifyListeners();
      return;
    }
    await BudgetService.instance.updateBudgetLimit(
      budgetId,
      monthlyLimit,
      EnvConfig.instance.demoUserId,
    );
    await refreshLiveDataOnly();
  }

  // --- Private helpers ---

  void _applySyncResult(SyncResult result) {
    final txIdSet = result.transactions.map((e) => e.id).toSet();
    liveTransactions = result.transactions;
    liveSubscriptions = result.subscriptions;
    liveBudgetProgress = result.budgetProgress;
    liveBudgetProgressYear = result.budgetProgressYear;
    liveBudgetProgressAll = result.budgetProgressAll;
    liveCategoryOptions = result.categoryOptions;
    liveAccountOptions = result.accountOptions;
    liveStats = result.stats;
    reviewedCategoryByTxId = {
      for (final entry in reviewedCategoryByTxId.entries)
        if (txIdSet.contains(entry.key)) entry.key: entry.value,
    };
    confirmedReviewTxIds = {
      for (final txId in confirmedReviewTxIds)
        if (txIdSet.contains(txId)) txId,
    };
    if (selectedAccountId != kAllAccountsId &&
        !result.accountOptions.any((a) => a.accountId == selectedAccountId)) {
      selectedAccountId = kAllAccountsId;
    }
  }

  void _rebuildBudgetProgress() {
    final now = DateTime.now();
    liveBudgetProgress = BudgetService.instance.presetBudgetProgress(
      liveTransactions,
      now,
      false,
      reviewedCategoryByTxId,
    );
    liveBudgetProgressYear = BudgetService.instance.presetBudgetProgress(
      liveTransactions,
      now,
      true,
      reviewedCategoryByTxId,
    );
    liveBudgetProgressAll = BudgetService.instance.presetBudgetProgressAllTime(
      liveTransactions,
      now,
      reviewedCategoryByTxId,
    );
  }
}
