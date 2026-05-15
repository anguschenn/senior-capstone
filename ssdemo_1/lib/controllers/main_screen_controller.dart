import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../services/auth_service.dart';
import '../services/budget_service.dart';
import '../services/category_service.dart';
import '../services/plaid_service.dart';
import '../services/sync_service.dart';
import '../utils/app_helpers.dart';

/// Owns all mutable state for the main screen and exposes actions for the UI.
class MainScreenController extends ChangeNotifier {
  bool _isDisposed = false;
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

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  // --- Actions ---

  void selectTab(int i) {
    tabIndex = i;
    _notifyListenersSafe();
  }

  void selectAccount(String accountId) {
    selectedAccountId = accountId;
    _notifyListenersSafe();
  }

  void selectMonth(DateTime month) {
    selectedMonth = normalizedMonthOption(month);
    _notifyListenersSafe();
  }

  Future<void> refreshLiveDataOnly() async {
    if (syncing) return;
    syncing = true;
    syncStatus = 'Syncing with bank...';
    _notifyListenersSafe();
    try {
      await SyncService.instance.triggerBankSync();
      syncStatus = 'Loading...';
      _notifyListenersSafe();
      final result = await SyncService.instance.refreshFromSupabase(
        reviewedCategoryByTxId,
        selectedMonth,
      );
      _applySyncResult(result);
      syncStatus = result.hasData ? 'Updated' : 'No data found';
    } catch (e) {
      syncStatus = 'Refresh failed: $e';
    } finally {
      syncing = false;
      _notifyListenersSafe();
    }
  }

  Future<void> connectBankAndPullData() async {
    if (syncing) return;
    syncing = true;
    syncStatus = 'Opening Plaid Link...';
    notifyListeners();

    try {
      final publicToken = await PlaidService.instance.openLink();

      if (publicToken == null) {
        // Web platform or user cancelled — fall back to syncing existing data.
        syncStatus = 'Refreshing...';
        notifyListeners();
        await SyncService.instance.triggerBankSync();
      } else {
        syncStatus = 'Connecting bank...';
        notifyListeners();
        await PlaidService.instance.exchangePublicToken(publicToken);
        syncStatus = 'Syncing transactions...';
        notifyListeners();
        await SyncService.instance.triggerBankSync();
      }

      final result = await SyncService.instance.refreshFromSupabase(
        reviewedCategoryByTxId,
        selectedMonth,
      );
      _applySyncResult(result);
      syncStatus = result.hasData ? 'Connected' : 'No data found';
    } catch (e) {
      syncStatus = 'Connection failed: $e';
    } finally {
      syncing = false;
      _notifyListenersSafe();
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
    _notifyListenersSafe();
  }

  void onTransactionCategorySelected(AppTransaction tx, String category) {
    final currentCategory =
        reviewedCategoryByTxId[tx.id] ??
        (tx.isIncome
            ? 'Income'
            : CategoryService.instance.budgetBucketFor(
                tx,
                const <String, String>{},
              ));
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
    _notifyListenersSafe();
  }

  Future<void> confirmReviewedCategory(String txId) async {
    if (syncing) return;
    syncing = true;
    syncStatus = 'Saving review...';
    _notifyListenersSafe();

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
      final ruleUserId = AuthService.instance.currentUserId;
      final ok = await CategoryService.instance.rememberRuleDecision(
        userId: ruleUserId,
        ruleKey: ruleKey,
        category: category,
      );
      if (ok) {
        try {
          final result = await SyncService.instance.refreshFromSupabase(
            reviewedCategoryByTxId,
            selectedMonth,
          );
          _applySyncResult(result);
          syncStatus = result.hasData
              ? 'Review saved. Data refreshed.'
              : 'Review saved. No DB data yet.';
        } catch (e) {
          syncStatus = 'Review saved, but refresh failed: $e';
        }
      } else {
        syncStatus = 'Review confirmed locally, but save failed.';
      }
    }
    syncing = false;
    _notifyListenersSafe();
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
    syncStatus = 'Saving budget...';
    _notifyListenersSafe();

    try {
      final monthYear = _monthKey(normalizedMonthOption(selectedMonth));
      await BudgetService.instance.upsertMonthlyBudgetByCategoryTitle(
        userId: AuthService.instance.currentUserId,
        categoryTitle: target.title,
        monthlyLimit: monthlyLimit,
        monthYear: monthYear,
      );
      syncStatus = 'Budget saved.';
    } catch (e) {
      // Keep optimistic UI state even when persistence fails.
      syncStatus = 'Saved locally, but DB update failed: $e';
    }
    _notifyListenersSafe();
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
    // Always trust the latest classifier output after refresh.
    // Keeping previous low-confidence ids causes stale review items to linger
    // even after a remembered rule now classifies them confidently.
    lowConfidenceReviewTxIds = {...result.autoLowConfidenceReviewTxIds};
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
    liveBudgetProgress = BudgetService.instance
        .buildZeroLimitProgressFromPresetCategories(
          liveTransactions,
          now,
          false,
          reviewedCategoryByTxId,
        );
    liveBudgetProgressYear = BudgetService.instance
        .buildZeroLimitProgressFromPresetCategories(
          liveTransactions,
          now,
          true,
          reviewedCategoryByTxId,
        );
    liveBudgetProgressAll = BudgetService.instance
        .buildZeroLimitProgressFromPresetCategoriesAllTime(
          liveTransactions,
          now,
          reviewedCategoryByTxId,
        );
  }

  void _notifyListenersSafe() {
    if (_isDisposed) return;
    notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
