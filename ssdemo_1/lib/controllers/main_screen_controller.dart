import 'dart:async';

import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../services/auth_service.dart';
import '../services/budget_service.dart';
import '../services/category_service.dart';
import '../services/hidden_accounts_store.dart';
import '../services/plaid_service.dart';
import '../services/transaction_decision_service.dart';
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

  /// When the banks were last synced: by this session, or by the backend
  /// (webhook or an earlier launch) as recorded in sync_status.
  DateTime? lastBankSyncAt;

  /// Launch skips the bank sync when the backend synced more recently than
  /// this; Plaid webhooks keep Supabase current in between. Refresh always syncs.
  static const launchSyncMaxAge = Duration(hours: 3);

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

  /// The loaded year's limits per month ("2026-09" → category id → limit).
  Map<String, Map<String, double>> liveBudgetLimitsByMonth = const {};

  /// Current-month budget progress from GET /api/budget_progress (all
  /// accounts, no per-account filter -- see SyncService.fetchServerBudgetProgress).
  /// Null when unavailable (error, no budget rows yet, or stale for the
  /// now-selected month); FinancialSnapshotService then falls back to the
  /// Dart computation from [liveBudgetProgress].
  List<BudgetCategoryProgress>? serverBudgetProgress;
  DateTime? serverBudgetProgressMonth;
  List<CategoryOption> liveCategoryOptions = const [];
  List<AccountOption> liveAccountOptions = const [];
  Map<String, String> reviewedCategoryByTxId = const {};
  Set<String> manualReviewedTxIds = const {};
  Set<String> confirmedReviewTxIds = const {};
  Set<String> lowConfidenceReviewTxIds = const {};

  /// The user's per-transaction choices (transaction_decisions): one-off
  /// categories, paybacks linked to purchases, split purchases.
  Map<String, TxDecision> decisions = const {};
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
    unawaited(_refreshServerBudgetProgress());
    _notifyListenersSafe();
  }

  bool _budgetProgressRunning = false;
  bool _budgetProgressAgain = false;

  /// Fetches server-computed budget progress for the now-selected month.
  /// Calls made while one is in flight (a launch applies up to three sync
  /// results) are folded into a single follow-up fetch once it returns, so
  /// the newest data is still read without a request per call.
  Future<void> _refreshServerBudgetProgress() async {
    if (_budgetProgressRunning) {
      _budgetProgressAgain = true;
      return;
    }
    _budgetProgressRunning = true;
    try {
      do {
        _budgetProgressAgain = false;
        await _fetchServerBudgetProgressOnce();
      } while (_budgetProgressAgain && !_isDisposed);
    } finally {
      _budgetProgressRunning = false;
    }
  }

  /// Applies only if [selectedMonth] is still the same month when the
  /// response arrives, so a slow response can't clobber progress for
  /// whatever month the user has since switched to.
  Future<void> _fetchServerBudgetProgressOnce() async {
    final month = normalizedMonthOption(selectedMonth);
    if (isAllYearOption(month)) {
      // The endpoint computes one calendar month; nothing to fetch for
      // an "All Year" selection.
      if (serverBudgetProgress != null) {
        serverBudgetProgress = null;
        serverBudgetProgressMonth = null;
        _notifyListenersSafe();
      }
      return;
    }
    final result = await _sync.fetchServerBudgetProgress(month);
    if (_isDisposed) return;
    if (normalizedMonthOption(selectedMonth) != month) return;
    serverBudgetProgress = result;
    serverBudgetProgressMonth = result == null ? null : month;
    _notifyListenersSafe();
  }

  Future<void> refreshLiveDataOnly() async {
    if (syncing || refreshingInBackground) return;
    syncing = true;
    syncStatus = 'Syncing with bank...';
    _notifyListenersSafe();
    try {
      final synced = await _sync.triggerBankSync(full: true);
      loginRequired = false;
      syncStatus = 'Loading...';
      _notifyListenersSafe();
      final result = await _sync.refreshFromSupabase(
        reviewedCategoryByTxId,
        selectedMonth,
      );
      _applySyncResult(result);
      insightsVersion++;
      syncStatus = result.hasData ? _updatedStatus(synced) : 'No data found';
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
    unawaited(_loadHiddenAccounts());
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

      // Webhooks keep Supabase current, so when the last sync is recent the
      // data just read is already up to date: skip the bank round trip (and a
      // possible cold start of the backend).
      final serverSyncedAt = await _sync.fetchLastSyncedAt();
      if (_isDisposed) return;
      if (serverSyncedAt != null) lastBankSyncAt = serverSyncedAt;
      if (fresh != null &&
          serverSyncedAt != null &&
          DateTime.now().difference(serverSyncedAt) < launchSyncMaxAge) {
        syncStatus = fresh.hasData
            ? 'Up to date · bank synced ${_clockLabel(serverSyncedAt)}'
            : 'No data found';
        return;
      }
      if (fresh != null) {
        syncStatus = 'Syncing with bank...';
        _notifyListenersSafe();
      }

      final bankSynced = await _sync.triggerBankSync();
      if (_isDisposed) return;
      loginRequired = false;
      final synced = await _fetchAndApply();
      if (synced != null) {
        syncStatus = synced.hasData
            ? _updatedStatus(bankSynced)
            : 'No data found';
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

  /// "Updated · bank synced 3:42 PM" when the backend confirmed the sync;
  /// otherwise says plainly that the data shown may be behind the bank.
  String _updatedStatus(bool bankSynced) {
    if (bankSynced) {
      lastBankSyncAt = DateTime.now();
      return 'Updated · bank synced ${_clockLabel(lastBankSyncAt!)}';
    }
    final last = lastBankSyncAt;
    return last == null
        ? "Showing saved data · couldn't reach bank sync"
        : 'Showing saved data · last bank sync ${_clockLabel(last)}';
  }

  /// "3:42 PM" today, "Sep 26, 3:42 PM" on another day.
  static String _clockLabel(DateTime time, {DateTime? now}) {
    final clock = now ?? DateTime.now();
    final hour = time.hour % 12 == 0 ? 12 : time.hour % 12;
    final minute = time.minute.toString().padLeft(2, '0');
    final label = '$hour:$minute ${time.hour < 12 ? 'AM' : 'PM'}';
    final sameDay =
        time.year == clock.year &&
        time.month == clock.month &&
        time.day == clock.day;
    return sameDay ? label : '${shortDate(time)}, $label';
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
        final synced = await _sync.triggerBankSync();
        final result = await _sync.refreshFromSupabase(
          reviewedCategoryByTxId,
          selectedMonth,
        );
        _applySyncResult(result);
        syncStatus = result.hasData ? _updatedStatus(synced) : 'No data found';
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
    liveBudgetLimitsByMonth = const {};
    liveCategoryOptions = const [];
    liveAccountOptions = const [];
    serverBudgetProgress = null;
    serverBudgetProgressMonth = null;
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
            ? tx.inflowLabel
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
    _reclassify();
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
      final ruleUserId = AuthService.instance.currentUserId;
      // Money from a person is decided one payment at a time: the same
      // friend may pay back a meal now and a ride next time, so no rule.
      final ok = tx.isPeerToPeerInflow
          ? await TransactionDecisionService.instance.save(
              userId: ruleUserId,
              txId: txId,
              decision: TxDecision(category: category),
            )
          : await CategoryService.instance.rememberRuleDecision(
              userId: ruleUserId,
              ruleKey: CategoryService.instance.ruleKeyForTransaction(tx),
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
          unawaited(_refreshInsights());
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

  // --- Money shared with friends ---

  /// Links money from a friend to the purchase it pays back: it then lowers
  /// that purchase, in the purchase's month and category.
  Future<bool> linkPayback(AppTransaction inflow, AppTransaction purchase) =>
      _saveDecision(
        inflow.id,
        TxDecision(paidBackPurchaseId: purchase.id),
        status: 'Payback linked.',
      );

  /// Links friends' [payments] to the [purchase] they pay back, from the
  /// purchase's side.
  Future<bool> linkPaybacks(
    List<AppTransaction> payments,
    AppTransaction purchase,
  ) => _saveDecisions({
    for (final p in payments) p.id: TxDecision(paidBackPurchaseId: purchase.id),
  }, status: payments.length == 1 ? 'Payback linked.' : 'Paybacks linked.');

  /// Payments from a person the user said aren't paybacks.
  Set<String> get notPaybackIds => {
    for (final e in decisions.entries)
      if (e.value.category.isNotEmpty) e.key,
  };

  /// Undoes [linkPayback]; the money goes back to Review.
  Future<bool> unlinkPayback(AppTransaction inflow) =>
      _saveDecision(inflow.id, const TxDecision(), status: 'Payback unlinked.');

  /// Money from a friend that isn't a payback: counts in [category] in the
  /// month it arrived.
  Future<bool> setInflowCategory(AppTransaction inflow, String category) =>
      _saveDecision(
        inflow.id,
        TxDecision(category: category),
        status: 'Category saved.',
      );

  /// Marks a purchase as split: others will pay back [amount]. It still
  /// counts in full until they do. Zero removes the split.
  Future<bool> setSharedAmount(AppTransaction purchase, double amount) {
    final current = decisions[purchase.id] ?? const TxDecision();
    return _saveDecision(
      purchase.id,
      TxDecision(
        category: current.category,
        paidBackPurchaseId: current.paidBackPurchaseId,
        sharedAmount: amount > 0 ? (amount * 100).roundToDouble() / 100 : 0,
      ),
      status: amount > 0 ? 'Split saved.' : 'Split removed.',
    );
  }

  Future<bool> _saveDecision(
    String txId,
    TxDecision decision, {
    required String status,
  }) => _saveDecisions({txId: decision}, status: status);

  /// Saves several choices, then refreshes once.
  Future<bool> _saveDecisions(
    Map<String, TxDecision> changes, {
    required String status,
  }) async {
    if (syncing || changes.isEmpty) return false;
    syncing = true;
    syncStatus = 'Saving...';
    _notifyListenersSafe();
    var ok = true;
    final confirmed = Set<String>.from(confirmedReviewTxIds);
    for (final e in changes.entries) {
      final saved = await TransactionDecisionService.instance.save(
        userId: AuthService.instance.currentUserId,
        txId: e.key,
        decision: e.value,
      );
      if (!saved) {
        ok = false;
        continue;
      }
      // Undoing a decision sends money from a friend back to Review.
      e.value.isEmpty ? confirmed.remove(e.key) : confirmed.add(e.key);
    }
    confirmedReviewTxIds = confirmed;
    try {
      _refreshGen++;
      final result = await _sync.refreshFromSupabase(
        reviewedCategoryByTxId,
        selectedMonth,
      );
      _applySyncResult(result);
      syncStatus = ok ? status : 'Some changes could not be saved. Try again.';
      unawaited(_refreshInsights());
    } catch (e) {
      syncStatus = '$status Refresh failed: $e';
    }
    syncing = false;
    _notifyListenersSafe();
    return ok;
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

    final monthYear = monthKeyOf(normalizedMonthOption(selectedMonth));
    liveBudgetLimitsByMonth = {
      ...liveBudgetLimitsByMonth,
      monthYear: {
        ...?liveBudgetLimitsByMonth[monthYear],
        target.categoryId: monthlyLimit,
      },
    };
    try {
      await BudgetService.instance.upsertMonthlyBudgetByCategoryTitle(
        userId: AuthService.instance.currentUserId,
        categoryTitle: target.title,
        monthlyLimit: monthlyLimit,
        monthYear: monthYear,
      );
      syncStatus = 'Budget saved.';
      // A month that had no rows has one now: pick up the server's view.
      unawaited(_refreshServerBudgetProgress());
      unawaited(_refreshInsights());
    } catch (e) {
      // Keep optimistic UI state even when persistence fails.
      syncStatus = 'Saved locally, but DB update failed: $e';
    }
    _notifyListenersSafe();
  }

  /// Bumped when the server's subscriptions, alerts and suggestions were
  /// recomputed, so cards that load them on their own reload.
  int insightsVersion = 0;

  /// After a budget, rule or hidden-account change: the server recomputes
  /// subscriptions, alerts and suggestions (a bank sync only does that when
  /// the bank sent something new), then the app reads them again.
  Future<void> _refreshInsights() async {
    final ok = await _sync.refreshInsights();
    if (!ok || _isDisposed) return;
    await _fetchAndApply();
    if (_isDisposed) return;
    insightsVersion++;
    _notifyListenersSafe();
  }

  // --- Private helpers ---

  Map<String, String> _ruleCategoryByTxId = const {};

  /// Re-decides what counts as spending, income, a refund or a transfer
  /// between own accounts, with the categories the user picked this session.
  /// A hidden account is left out like one that was never linked, so paying
  /// a hidden card from checking is spending (its purchases no longer count).
  void _reclassify() {
    useClassification(
      classifyTransactions(liveTransactions, {
        ..._ruleCategoryByTxId,
        for (final txId in manualReviewedTxIds)
          if (reviewedCategoryByTxId[txId] != null)
            txId: reviewedCategoryByTxId[txId]!,
      }, paidBackPurchaseById: paidBackPurchaseIds(decisions)),
      liveTransactions,
      decisions,
    );
  }

  // --- Hidden accounts ---

  /// Accounts hidden in Settings, by Plaid account id: left out of every
  /// page and total until shown again. Nothing is deleted.
  Set<String> hiddenAccountIds = const {};

  bool isAccountHidden(AccountOption a) =>
      hiddenAccountIds.contains(a.accountId) ||
      a.linkedAccountIds.any(hiddenAccountIds.contains);

  List<AppTransaction> _allTransactions = const [];
  List<AccountOption> _allAccountOptions = const [];
  DashboardStats _allStats = liveStatsEmpty;

  static const liveStatsEmpty = DashboardStats(
    totalBalance: 0,
    monthlyIncome: 0,
    monthlyExpenses: 0,
    netThisMonth: 0,
  );

  /// Every connected account, hidden ones included (for Settings).
  List<AccountOption> get allAccountOptions => _allAccountOptions;

  Future<void> _loadHiddenAccounts() async {
    final Set<String> ids;
    try {
      final userId = AuthService.instance.currentUserId;
      // The database is what the backend reads. This device's copy covers a
      // failed read, and anything hidden here before the column existed is
      // written back so the backend skips it too.
      final store = HiddenAccountsStore.instance;
      final local = await store.load(userId);
      final remote = await store.loadFromServer(userId);
      if (remote != null && !remote.containsAll(local)) {
        await store.saveToServer(userId, local.difference(remote), true);
      }
      ids = {...local, ...?remote};
    } catch (_) {
      return; // signed out or no session yet: nothing hidden
    }
    if (_isDisposed || ids.isEmpty) return;
    hiddenAccountIds = ids;
    _applyHiddenAccounts();
    _reclassify();
    _rebuildBudgetProgress();
    _notifyListenersSafe();
  }

  Future<void> setAccountHidden(String accountId, bool hidden) async {
    final ids = {
      accountId,
      for (final a in _allAccountOptions)
        if (a.accountId == accountId) ...a.linkedAccountIds,
    };
    final next = Set<String>.from(hiddenAccountIds);
    hidden ? next.addAll(ids) : next.removeAll(ids);
    hiddenAccountIds = next;
    _applyHiddenAccounts();
    _reclassify();
    _rebuildBudgetProgress();
    _notifyListenersSafe();
    final userId = AuthService.instance.currentUserId;
    await HiddenAccountsStore.instance.save(userId, next);
    await HiddenAccountsStore.instance.saveToServer(userId, ids, hidden);
    unawaited(_refreshInsights());
  }

  /// Every Plaid account id behind the hidden accounts.
  Set<String> get hiddenTransactionAccountIds => {
    ...hiddenAccountIds,
    for (final a in _allAccountOptions)
      if (isAccountHidden(a)) ...{a.accountId, ...a.linkedAccountIds},
  };

  void _applyHiddenAccounts() {
    final hiddenIds = hiddenTransactionAccountIds;
    if (!_allAccountOptions.any(isAccountHidden)) {
      liveTransactions = _allTransactions;
      liveAccountOptions = _allAccountOptions;
      liveStats = _allStats;
      return;
    }
    liveTransactions = _allTransactions
        .where((tx) => !hiddenIds.contains(tx.accountId))
        .toList();
    liveAccountOptions = _allAccountOptions
        .where((a) => !isAccountHidden(a))
        .toList();
    liveStats = DashboardStats(
      totalBalance: liveAccountOptions.fold(0.0, (sum, a) => sum + a.balance),
      monthlyIncome: _allStats.monthlyIncome,
      monthlyExpenses: _allStats.monthlyExpenses,
      netThisMonth: _allStats.netThisMonth,
    );
    if (hiddenIds.contains(selectedAccountId)) {
      selectedAccountId = kAllAccountsId;
    }
  }

  void _applySyncResult(SyncResult result) {
    final txIdSet = result.transactions.map((e) => e.id).toSet();
    _allTransactions = result.transactions;
    _allAccountOptions = result.accountOptions;
    _allStats = result.stats;
    liveTransactions = result.transactions;
    liveSubscriptions = result.subscriptions;
    liveBudgetProgress = result.budgetProgress;
    liveBudgetProgressYear = result.budgetProgressYear;
    liveBudgetProgressAll = result.budgetProgressAll;
    liveBudgetLimitsByMonth = result.budgetLimitsByMonth;
    liveCategoryOptions = result.categoryOptions;
    liveAccountOptions = result.accountOptions;
    liveStats = result.stats;
    // Only the user's own picks carry over; everything else is the fresh
    // result, so a linked payback shows its purchase's category, not the
    // Income it read before.
    reviewedCategoryByTxId = {
      ...result.autoReviewedCategoryByTxId,
      for (final entry in reviewedCategoryByTxId.entries)
        if (txIdSet.contains(entry.key) &&
            manualReviewedTxIds.contains(entry.key))
          entry.key: entry.value,
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
    _ruleCategoryByTxId = result.ruleCategoryByTxId;
    decisions = result.decisions;
    _applyHiddenAccounts();
    _reclassify();
    _applyManualLimitOverrides();
    if (selectedAccountId != kAllAccountsId &&
        !result.accountOptions.any((a) => a.accountId == selectedAccountId)) {
      selectedAccountId = kAllAccountsId;
    }
    unawaited(_refreshServerBudgetProgress());
  }

  void _applyManualLimitOverrides() {
    if (_manualMonthlyLimitByCategoryKey.isEmpty) return;
    final monthBefore = {
      for (final item in liveBudgetProgress)
        normalizeCategoryKey(item.title): item.limit,
    };
    liveBudgetProgress = _withManualLimits(
      liveBudgetProgress,
      yearly: false,
      allTime: false,
    );
    liveBudgetProgressYear = _withManualLimits(
      liveBudgetProgressYear,
      yearly: true,
      allTime: false,
      monthBefore: monthBefore,
    );
    liveBudgetProgressAll = _withManualLimits(
      liveBudgetProgressAll,
      yearly: false,
      allTime: true,
    );
    // A just-edited limit must show immediately even when the Budget page is
    // currently reading serverBudgetProgress, not the Dart-computed list this
    // overlay normally touches -- otherwise the edit would appear to do
    // nothing until the next server refresh completes.
    final server = serverBudgetProgress;
    if (server != null) {
      serverBudgetProgress = _withManualLimits(
        server,
        yearly: false,
        allTime: false,
      );
    }
  }

  List<BudgetCategoryProgress> _withManualLimits(
    List<BudgetCategoryProgress> source, {
    required bool yearly,
    required bool allTime,
    Map<String, double> monthBefore = const {},
  }) {
    return source.map((item) {
      final key = normalizeCategoryKey(item.title);
      final monthly = _manualMonthlyLimitByCategoryKey[key];
      if (monthly == null) return item;
      // The year is the sum of its months: swap in this month's new limit.
      final limit = allTime
          ? monthly
          : (yearly ? item.limit - (monthBefore[key] ?? 0) + monthly : monthly);
      return BudgetCategoryProgress(
        budgetId: item.budgetId,
        categoryId: item.categoryId,
        title: item.title,
        spent: item.spent,
        limit: limit,
        budgetedMonths: item.budgetedMonths,
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
