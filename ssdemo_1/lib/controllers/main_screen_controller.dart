import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../services/auth_service.dart';
import '../services/budget_service.dart';
import '../services/category_service.dart';
import '../services/sync_service.dart';
import '../utils/app_helpers.dart';

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
  Set<String> manualReviewedTxIds = const {};
  Set<String> confirmedReviewTxIds = const {};
  Set<String> lowConfidenceReviewTxIds = const {};
  final Map<String, double> _manualMonthlyLimitByCategoryKey = {};
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
    selectedMonth = normalizedMonthOption(month);
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
        selectedMonth,
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

  Future<void> connectBankAndPullData() async {
    if (syncing) return;
    syncing = true;
    syncStatus = 'Syncing...';
    notifyListeners();

    await SyncService.instance.triggerBankSync();

    try {
      final result = await SyncService.instance.refreshFromSupabase(
        reviewedCategoryByTxId,
        selectedMonth,
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
    manualReviewedTxIds = const {};
    confirmedReviewTxIds = const {};
    lowConfidenceReviewTxIds = const {};
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
    if (!tx.isExpense) return;
    final currentCategory =
        reviewedCategoryByTxId[tx.id] ??
        CategoryService.instance.budgetBucketFor(tx, const <String, String>{});
    if (currentCategory.trim() == category.trim()) {
      return;
    }
    final reviewedNext = Map<String, String>.from(reviewedCategoryByTxId);
    reviewedNext[tx.id] = category;
    final manualNext = Set<String>.from(manualReviewedTxIds)..add(tx.id);
    final confirmedNext = Set<String>.from(confirmedReviewTxIds);
    confirmedNext.remove(tx.id);
    reviewedCategoryByTxId = reviewedNext;
    manualReviewedTxIds = manualNext;
    confirmedReviewTxIds = confirmedNext;
    _rebuildBudgetProgress();
    notifyListeners();
  }

  Future<void> confirmReviewedCategory(String txId) async {
    confirmedReviewTxIds = Set<String>.from(confirmedReviewTxIds)..add(txId);
    AppTransaction? tx;
    for (final item in liveTransactions) {
      if (item.id == txId) {
        tx = item;
        break;
      }
    }
    if (tx != null) {
      final category =
          reviewedCategoryByTxId[txId] ??
          CategoryService.instance.budgetBucketFor(tx, reviewedCategoryByTxId);
      final ruleKey = CategoryService.instance.ruleKeyForTransaction(tx);
      final ok = await CategoryService.instance.rememberRuleDecision(
        userId: AuthService.instance.currentUserId,
        ruleKey: ruleKey,
        category: category,
      );
      syncStatus = ok
          ? 'Review confirmed and saved.'
          : 'Review confirmed locally, but save failed.';
    }
    notifyListeners();
  }

  Future<void> updateBudgetLimit(String budgetId, double monthlyLimit) async {
    if (monthlyLimit < 0) return;
    final all = [
      ...liveBudgetProgress,
      ...liveBudgetProgressYear,
      ...liveBudgetProgressAll,
    ];
    BudgetCategoryProgress? target;
    for (final item in all) {
      if (item.budgetId == budgetId) {
        target = item;
        break;
      }
    }
    if (target == null) return;
    final key = normalizeCategoryKey(target.title);
    _manualMonthlyLimitByCategoryKey[key] = monthlyLimit;
    _applyManualLimitOverrides();
    notifyListeners();
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
      ...result.autoReviewedCategoryByTxId,
      for (final entry in reviewedCategoryByTxId.entries)
        if (txIdSet.contains(entry.key)) entry.key: entry.value,
    };
    manualReviewedTxIds = {
      for (final txId in manualReviewedTxIds)
        if (txIdSet.contains(txId)) txId,
    };
    confirmedReviewTxIds = {
      for (final txId in confirmedReviewTxIds)
        if (txIdSet.contains(txId)) txId,
    };
    lowConfidenceReviewTxIds = {
      ...result.autoLowConfidenceReviewTxIds,
      for (final txId in lowConfidenceReviewTxIds)
        if (txIdSet.contains(txId)) txId,
    };
    _applyManualLimitOverrides();
    if (selectedAccountId != kAllAccountsId &&
        !result.accountOptions.any((a) => a.accountId == selectedAccountId)) {
      selectedAccountId = kAllAccountsId;
    }
  }

  void _applyManualLimitOverrides() {
    if (_manualMonthlyLimitByCategoryKey.isEmpty) return;
    liveBudgetProgress = _withManualLimits(
      liveBudgetProgress,
      yearly: false,
      allTime: false,
    );
    liveBudgetProgressYear = _withManualLimits(
      liveBudgetProgressYear,
      yearly: true,
      allTime: false,
    );
    liveBudgetProgressAll = _withManualLimits(
      liveBudgetProgressAll,
      yearly: false,
      allTime: true,
    );
  }

  List<BudgetCategoryProgress> _withManualLimits(
    List<BudgetCategoryProgress> source, {
    required bool yearly,
    required bool allTime,
  }) {
    return source.map((item) {
      final key = normalizeCategoryKey(item.title);
      final monthly = _manualMonthlyLimitByCategoryKey[key];
      if (monthly == null) return item;
      final limit = allTime ? monthly : (yearly ? monthly * 12 : monthly);
      return BudgetCategoryProgress(
        budgetId: item.budgetId,
        categoryId: item.categoryId,
        title: item.title,
        spent: item.spent,
        limit: limit,
      );
    }).toList();
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
