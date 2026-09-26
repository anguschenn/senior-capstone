import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../services/auth_service.dart';
import '../services/budget_service.dart';
import '../services/category_service.dart';
import '../services/plaid_service.dart';
import '../services/subscription_service.dart';
import '../services/sync_service.dart';
import '../utils/app_helpers.dart';

export '../services/sync_service.dart' show ItemLoginRequiredException;

/// Owns all mutable state for the main screen and exposes actions for the UI.
class MainScreenController extends ChangeNotifier {
  MainScreenController({SyncService? sync})
    : _sync = sync ?? SyncService.instance;

  final SyncService _sync;
  bool _isDisposed = false;
  // Navigation
  int tabIndex = 0;

  // Sync
  bool syncing = false;

  /// True while the launch refresh runs. Unlike [syncing] it does not lock the
  /// whole screen: saved or Supabase data is already showing and stays usable;
  /// only the bank-sync buttons wait, so two bank syncs never overlap.
  bool refreshingInBackground = false;
  bool loginRequired = false;
  String syncStatus = 'No data loaded yet';

  // Bumped whenever a refresh starts or data is cleared. A fetched result is
  // applied only if nothing newer started meanwhile, so a slow older fetch can
  // never overwrite fresher data.
  int _refreshGen = 0;

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

  Future<void> confirmSubscription(String id) async {
    await SubscriptionService.instance.confirm(id);
    liveSubscriptions = liveSubscriptions
        .map(
          (s) => s.id == id
              ? DetectedSubscription(
                  id: s.id,
                  merchant: s.merchant,
                  amount: s.amount,
                  nextChargeDate: s.nextChargeDate,
                  frequency: s.frequency,
                  needsConfirmation: false,
                )
              : s,
        )
        .toList();
    _notifyListenersSafe();
  }

  Future<void> dismissSubscription(String id) async {
    await SubscriptionService.instance.dismiss(id);
    liveSubscriptions = liveSubscriptions.where((s) => s.id != id).toList();
    _notifyListenersSafe();
  }

  void selectMonth(DateTime month) {
    selectedMonth = normalizedMonthOption(month);
    _notifyListenersSafe();
  }

  Future<void> refreshLiveDataOnly() async {
    if (syncing || refreshingInBackground) return;
    syncing = true;
    syncStatus = 'Syncing with bank...';
    _notifyListenersSafe();
    try {
      await _sync.triggerBankSync();
      loginRequired = false;
      syncStatus = 'Loading...';
      _notifyListenersSafe();
      final result = await _sync.refreshFromSupabase(
        reviewedCategoryByTxId,
        selectedMonth,
      );
      _applySyncResult(result);
      syncStatus = result.hasData ? 'Updated' : 'No data found';
    } on ItemLoginRequiredException {
      loginRequired = true;
      syncStatus = 'Bank login expired — tap to re-authenticate';
    } catch (e) {
      syncStatus = 'Refresh failed: $e';
    } finally {
      syncing = false;
      _notifyListenersSafe();
    }
  }

  /// Reads Supabase and applies the result, unless a newer refresh has started.
  Future<SyncResult?> _fetchAndApply() async {
    final gen = ++_refreshGen;
    final result = await _sync.refreshFromSupabase(
      reviewedCategoryByTxId,
      selectedMonth,
    );
    if (gen != _refreshGen || _isDisposed) return null;
    _applySyncResult(result);
    return result;
  }

  /// Launch path. Paints the on-device copy of the last sync immediately, then
  /// reads Supabase (which already holds the last synced data) without waiting
  /// on the bank, and only then pulls new bank data in the background and reads
  /// again. The screen never waits on the (possibly cold) backend.
  Future<void> loadCachedThenRefresh() async {
    if (syncing || refreshingInBackground) return;
    refreshingInBackground = true;
    try {
      final cached = await _sync.loadCachedResult(
        reviewedCategoryByTxId,
        selectedMonth,
      );
      if (_isDisposed) return;
      if (cached != null) {
        _applySyncResult(cached.result);
        syncStatus =
            'Showing saved data (${_ago(cached.savedAt)}) · refreshing...';
      } else {
        syncStatus = 'Loading...';
      }
      _notifyListenersSafe();

      final fresh = await _fetchAndApply();
      if (_isDisposed) return;
      if (fresh != null) {
        syncStatus = 'Syncing with bank...';
        _notifyListenersSafe();
      }

      await _sync.triggerBankSync();
      if (_isDisposed) return;
      loginRequired = false;
      final synced = await _fetchAndApply();
      if (synced != null) {
        syncStatus = synced.hasData ? 'Updated' : 'No data found';
      }
    } on ItemLoginRequiredException {
      loginRequired = true;
      syncStatus = 'Bank login expired — tap to re-authenticate';
    } catch (e) {
      syncStatus = 'Refresh failed: $e';
    } finally {
      refreshingInBackground = false;
      _notifyListenersSafe();
    }
  }

  String _ago(DateTime time) {
    final age = DateTime.now().difference(time);
    if (age.inMinutes < 1) return 'just now';
    if (age.inHours < 1) return '${age.inMinutes}m ago';
    if (age.inDays < 1) return '${age.inHours}h ago';
    return '${age.inDays}d ago';
  }

  Future<void> reauthenticateBank() async {
    if (syncing || refreshingInBackground) return;
    syncing = true;
    syncStatus = 'Opening bank login...';
    _notifyListenersSafe();
    try {
      final publicToken = await PlaidService.instance.openLinkUpdateMode();
      if (publicToken != null) {
        await PlaidService.instance.exchangePublicToken(publicToken);
        loginRequired = false;
        syncStatus = 'Syncing transactions...';
        _notifyListenersSafe();
        await _sync.triggerBankSync();
        final result = await _sync.refreshFromSupabase(
          reviewedCategoryByTxId,
          selectedMonth,
        );
        _applySyncResult(result);
        syncStatus = result.hasData ? 'Updated' : 'No data found';
      } else {
        syncStatus = 'Re-authentication cancelled';
      }
    } catch (e) {
      syncStatus = 'Re-authentication failed: $e';
    } finally {
      syncing = false;
      _notifyListenersSafe();
    }
  }

  Future<void> connectBankAndPullData() async {
    if (syncing || refreshingInBackground) return;
    syncing = true;
    syncStatus = 'Opening Plaid Link...';
    notifyListeners();

    try {
      final publicToken = await PlaidService.instance.openLink();

      if (publicToken == null) {
        // Web platform or user cancelled — fall back to syncing existing data.
        syncStatus = 'Refreshing...';
        notifyListeners();
        await _sync.triggerBankSync();
      } else {
        syncStatus = 'Connecting bank...';
        notifyListeners();
        await PlaidService.instance.exchangePublicToken(publicToken);
        syncStatus = 'Syncing transactions...';
        notifyListeners();
        await _sync.triggerBankSync();
      }

      final result = await _sync.refreshFromSupabase(
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
    // Drop any refresh still in flight and forget the on-device copy too, so
    // cleared data doesn't reappear on the next launch.
    _refreshGen++;
    unawaited(_sync.clearSavedData());
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
          // An older refresh still in flight predates the rule just saved.
          _refreshGen++;
          final result = await _sync.refreshFromSupabase(
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
