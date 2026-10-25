import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../constants/app_constants.dart';
import '../controllers/main_screen_controller.dart';
import '../core/config/api_config.dart';
import '../core/config/env_config.dart';
import '../models/app_models.dart';
import '../pages/budget_page.dart';
import '../pages/cash_flow_page.dart';
import '../pages/home_page.dart';
import '../pages/settings_page.dart';
import '../pages/subscriptions_page.dart';
import '../pages/transactions_page.dart';
import '../services/auth_service.dart';
import '../services/financial_snapshot_service.dart';
import '../utils/app_helpers.dart';
import '../widgets/ai_assistant/ai_assistant_panel.dart';
import '../widgets/common/shared_money_sheets.dart';
import '../widgets/common/ui.dart';

/// Opens the AI panel, optionally with a question filled in and a note on
/// where it was opened from (the ✦ chips on Budget and Cash Flow).
typedef AskCallback = void Function({String? prompt, String? contextLabel});

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _ctrl = MainScreenController();

  List<DateTime> _monthOptions(List<AppTransaction> txs) {
    final monthsWithData = <DateTime>{};
    for (final tx in txs) {
      monthsWithData.add(DateTime(tx.date.year, tx.date.month, 1));
    }
    final sortedMonths = monthsWithData.toList()
      ..sort((a, b) => b.compareTo(a));
    final yearsWithData = sortedMonths.map((m) => m.year).toSet().toList()
      ..sort((a, b) => b.compareTo(a));
    return [
      for (final year in yearsWithData) allYearOptionFor(year),
      ...sortedMonths,
    ];
  }

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onControllerChange);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _ctrl.loadCachedThenRefresh();
    });
  }

  @override
  void dispose() {
    _ctrl.removeListener(_onControllerChange);
    _ctrl.dispose();
    super.dispose();
  }

  void _onControllerChange() {
    if (mounted) setState(() {});
  }

  double _monthlySubscriptionTotal(List<DetectedSubscription> subs) =>
      subs.fold<double>(0, (sum, item) => sum + item.monthlyEquivalent);

  void _openAsk({String? prompt, String? contextLabel}) {
    final c = _ctrl;
    final summariesByAccount = <String, Map<String, dynamic>>{
      kAllAccountsId: FinancialSnapshotService.instance
          .buildForAccount(
            c,
            kAllAccountsId,
            targetMonth: c.selectedMonth,
            useLinkedAccounts: true,
          )
          .spendingSummary,
    };
    for (final option in c.liveAccountOptions) {
      summariesByAccount[option.accountId] = FinancialSnapshotService.instance
          .buildForAccount(
            c,
            option.accountId,
            targetMonth: c.selectedMonth,
            useLinkedAccounts: true,
          )
          .spendingSummary;
    }
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      backgroundColor: Colors.transparent,
      builder: (context) => AIAssistantPanel(
        chatApiUri: ApiConfig.instance.aiChatUri,
        apiKey: EnvConfig.instance.backendApiKey,
        accountOptions: c.liveAccountOptions,
        initialAccountId: c.selectedAccountId,
        spendingSummaryByAccount: summariesByAccount,
        selectedMonth: c.selectedMonth,
        initialPrompt: prompt,
        contextLabel: contextLabel,
        hiddenAccountIds: c.hiddenTransactionAccountIds.toList()..sort(),
      ),
    );
  }

  /// Pushes a page that rebuilds whenever the controller changes, so a
  /// refresh or a month change shows up on it straight away.
  void _push(Widget Function() build) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) =>
            AnimatedBuilder(animation: _ctrl, builder: (_, _) => build()),
      ),
    );
  }

  /// Lets the user pick the purchase a friend's payment pays back.
  Future<bool> _linkPayback(BuildContext context, AppTransaction inflow) async {
    final purchase = await showLinkPurchaseSheet(
      context: context,
      inflow: inflow,
      transactions: _ctrl.liveTransactions,
    );
    if (purchase == null) return false;
    return _ctrl.linkPayback(inflow, purchase);
  }

  /// Split a purchase with others, or decide what a friend's payment is.
  Future<void> _openTransactionActions(
    BuildContext context,
    AppTransaction tx,
  ) async {
    // Money sent to a person has no actions, but paybacks linked to it
    // earlier can still be unlinked.
    if (actionsFor(tx).isEmpty &&
        paybacksOf(tx, _ctrl.liveTransactions).isEmpty) {
      return;
    }
    final choice = await showTransactionActionsSheet(
      context: context,
      tx: tx,
      transactions: _ctrl.liveTransactions,
    );
    if (choice == null || !context.mounted) return;
    switch (choice.action) {
      case TransactionAction.split:
        final amount = await showSplitPurchaseSheet(
          context: context,
          purchase: tx,
        );
        if (amount != null) await _ctrl.setSharedAmount(tx, amount);
      case TransactionAction.addPayback:
        final payments = await showLinkPaymentSheet(
          context: context,
          purchase: tx,
          transactions: _ctrl.liveTransactions,
          notPaybackIds: _ctrl.notPaybackIds,
        );
        if (payments != null && payments.isNotEmpty) {
          await _ctrl.linkPaybacks(payments, tx);
        }
      case TransactionAction.linkPayback:
        await _linkPayback(context, tx);
      case TransactionAction.unlinkPayback:
        await _ctrl.unlinkPayback(choice.other ?? tx);
      case TransactionAction.notPayback:
        await showTransactionCategoryPicker(
          context: context,
          tx: tx,
          selectedCategory: effectiveCategoryFor(
            tx,
            _ctrl.reviewedCategoryByTxId,
          ),
          onSelected: (category) => _ctrl.setInflowCategory(tx, category),
        );
    }
  }

  void _openFlow() {
    _push(() {
      final c = _ctrl;
      final snapshot = FinancialSnapshotService.instance.build(
        c,
        targetMonth: c.selectedMonth,
      );
      return Scaffold(
        body: CashFlowPage(
          transactions: snapshot.transactions,
          budgetProgress: snapshot.budgetProgress,
          selectedMonth: c.selectedMonth,
          monthOptions: _monthOptions(c.liveTransactions),
          onMonthChanged: c.selectMonth,
          onAsk: _openAsk,
        ),
      );
    });
  }

  void _openSettings() {
    _push(() {
      final c = _ctrl;
      // Read directly: a full snapshot here only to get subscriptions
      // recomputed every budget on each notify.
      final subs = c.liveSubscriptions;
      return SettingsPage(
        email: AuthService.instance.currentUser?.email,
        accountOptions: c.liveAccountOptions,
        hiddenAccounts: [
          for (final a in c.allAccountOptions)
            if (c.isAccountHidden(a)) a,
        ],
        onHideAccount: (a) => c.setAccountHidden(a.accountId, true),
        onShowAccount: (a) => c.setAccountHidden(a.accountId, false),
        loginRequired: c.loginRequired,
        syncing: c.syncing,
        bankSyncBusy: c.refreshingInBackground,
        syncStatus: c.syncStatus,
        subscriptionCount: subs.where((s) => !s.needsConfirmation).length,
        onReconnect: c.reauthenticateBank,
        onAddBank: c.connectBankAndPullData,
        onRefresh: c.refreshLiveDataOnly,
        onClear: c.clearLiveData,
        onOpenSubscriptions: () {
          Navigator.of(context).popUntil((route) => route.isFirst);
          c.selectTab(3);
        },
        onSignOut: () async {
          Navigator.of(context).popUntil((route) => route.isFirst);
          await AuthService.instance.signOut();
        },
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    final colors = context.colors;
    final snapshot = FinancialSnapshotService.instance.build(
      c,
      targetMonth: c.selectedMonth,
    );
    final visibleTransactions = snapshot.transactions;
    // Budgets are for every account together, whichever one is selected.
    final oneAccount = c.selectedAccountId != kAllAccountsId;
    final household = oneAccount
        ? FinancialSnapshotService.instance.buildForAccount(
            c,
            kAllAccountsId,
            targetMonth: c.selectedMonth,
          )
        : snapshot;
    final visibleSubscriptions = snapshot.subscriptions;
    // Unconfirmed ("needs review") subscriptions belong in the Subscriptions
    // tab's review queue, not in the dashboard preview or the monthly total —
    // they haven't been confirmed as real subscriptions yet.
    final confirmedSubscriptions = visibleSubscriptions
        .where((s) => !s.needsConfirmation)
        .toList();
    final monthOptions = _monthOptions(c.liveTransactions);

    // All four tabs are built every time (not just the active one) and kept
    // alive in an IndexedStack, so switching tabs never destroys a page's
    // State — scroll position, the Budget tab's AI suggestion, and its
    // manual category order all survive a switch instead of resetting.
    final pages = <Widget>[
      HomePage(
        transactions: visibleTransactions,
        lowConfidenceTransactions: visibleTransactions,
        subscriptions: confirmedSubscriptions.take(3).toList(),
        monthlySubscriptionTotal: _monthlySubscriptionTotal(
          confirmedSubscriptions,
        ),
        stats: snapshot.stats,
        budgetProgress: snapshot.budgetProgress,
        syncing: c.syncing,
        bankSyncBusy: c.refreshingInBackground,
        loadingFirstData: c.loadingFirstData,
        onAddBank: c.connectBankAndPullData,
        onReconnect: c.reauthenticateBank,
        onRefresh: c.refreshLiveDataOnly,
        accountOptions: c.liveAccountOptions,
        selectedAccountId: c.selectedAccountId,
        reviewedCategoryByTxId: c.reviewedCategoryByTxId,
        manualReviewedTxIds: c.manualReviewedTxIds,
        confirmedReviewTxIds: c.confirmedReviewTxIds,
        lowConfidenceReviewTxIds: c.lowConfidenceReviewTxIds,
        onAccountChanged: c.selectAccount,
        selectedMonth: c.selectedMonth,
        monthOptions: monthOptions,
        onMonthChanged: c.selectMonth,
        onTransactionCategorySelected: c.onTransactionCategorySelected,
        onReviewConfirm: c.confirmReviewedCategory,
        onLinkPayback: _linkPayback,
        onTransactionTap: _openTransactionActions,
        onOpenFlow: _openFlow,
        onOpenSettings: _openSettings,
        onSeeAllActivity: () => c.selectTab(1),
        onOpenSubscriptions: () => c.selectTab(3),
        aiCategorySuggestUri: ApiConfig.instance.aiCategorySuggestUri,
        apiKey: EnvConfig.instance.backendApiKey,
        accessToken: AuthService.instance.currentAccessToken,
      ),
      TransactionsPage(
        transactions: visibleTransactions,
        accountOptions: c.liveAccountOptions,
        selectedMonth: c.selectedMonth,
        monthOptions: monthOptions,
        onMonthChanged: c.selectMonth,
        reviewedCategoryByTxId: c.reviewedCategoryByTxId,
        onTransactionCategorySelected: c.onTransactionCategorySelected,
        onTransactionTap: _openTransactionActions,
        loading: c.loadingFirstData,
        aiCategorySuggestUri: ApiConfig.instance.aiCategorySuggestUri,
        apiKey: EnvConfig.instance.backendApiKey,
        accessToken: AuthService.instance.currentAccessToken,
      ),
      BudgetPage(
        insightsVersion: c.insightsVersion,
        stats: household.stats,
        budgetProgress: snapshot.budgetProgress,
        budgetProgressYear: snapshot.budgetProgressYear,
        budgetProgressAll: snapshot.budgetProgressAll,
        onUpdateBudgetLimit: c.updateBudgetLimit,
        aiBudgetSuggestApiUri: ApiConfig.instance.aiBudgetSuggestUri,
        apiKey: EnvConfig.instance.backendApiKey,
        accessToken: AuthService.instance.currentAccessToken,
        spendingSummary: snapshot.spendingSummary,
        selectedMonth: c.selectedMonth,
        monthOptions: monthOptions,
        onMonthChanged: c.selectMonth,
        scopeNote: oneAccount ? 'Budgets cover all accounts' : null,
        transactions: household.transactions,
        reviewedCategoryByTxId: c.reviewedCategoryByTxId,
        onAsk: _openAsk,
      ),
      SubscriptionsPage(
        subscriptions: visibleSubscriptions,
        monthlyTotal: _monthlySubscriptionTotal(confirmedSubscriptions),
        onConfirm: c.confirmSubscription,
        onDismiss: c.dismissSubscription,
      ),
    ];

    return Scaffold(
      // Pages scroll under the floating glass tab bar.
      extendBody: true,
      body: Column(
        children: [
          if (c.loginRequired)
            Material(
              color: colors.card,
              child: SafeArea(
                bottom: false,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
                  child: Row(
                    children: [
                      Icon(Icons.error_outline, color: colors.bad, size: 20),
                      const SizedBox(width: 10),
                      const Expanded(
                        child: Text(
                          'Bank connection expired — tap to re-authenticate',
                        ),
                      ),
                      TextButton(
                        onPressed: c.syncing ? null : _ctrl.reauthenticateBank,
                        child: Text(
                          'Fix',
                          style: TextStyle(
                            color: colors.bad,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          Expanded(
            child: MediaQuery.removePadding(
              context: context,
              removeTop: c.loginRequired,
              child: IndexedStack(index: c.tabIndex, children: pages),
            ),
          ),
        ],
      ),
      bottomNavigationBar: _TabBar(
        index: c.tabIndex,
        onSelect: c.selectTab,
        onAsk: () => _openAsk(),
      ),
    );
  }
}

/// Wallet / Activity / Ask / Budget / Subs, as a floating glass capsule
/// over the page (blurred, translucent), like iOS 26 tab bars. The chosen
/// tab sits in a lighter capsule that slides between tabs. Ask is a round
/// button in the middle that opens the AI panel instead of switching tabs.
class _TabBar extends StatelessWidget {
  const _TabBar({
    required this.index,
    required this.onSelect,
    required this.onAsk,
  });

  final int index;
  final ValueChanged<int> onSelect;
  final VoidCallback onAsk;

  static const _items = [
    (Icons.account_balance_wallet_outlined, 'Wallet'),
    (Icons.receipt_long_outlined, 'Activity'),
    (Icons.pie_chart_outline, 'Budget'),
    (Icons.autorenew_rounded, 'Subs'),
  ];

  /// Tabs 0-1 sit left of Ask, 2-3 right of it.
  static int _slotOf(int tab) => tab < 2 ? tab : tab + 1;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final dark = Theme.of(context).brightness == Brightness.dark;
    Widget item(int i) {
      final (icon, label) = _items[i];
      final selected = i == index;
      final color = selected ? c.text : c.muted;
      return Expanded(
        child: Pressable(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => onSelect(i),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: color, size: 23),
                const SizedBox(height: 2),
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 10.5,
                    fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                    color: color,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    return SafeArea(
      top: false,
      minimum: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: DecoratedBox(
          decoration: ShapeDecoration(
            shape: const StadiumBorder(),
            shadows: [
              BoxShadow(
                color: c.cardShadow,
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: ClipPath(
            clipper: const ShapeBorderClipper(shape: StadiumBorder()),
            child: BackdropFilter(
              filter: ImageFilter.blur(sigmaX: 18, sigmaY: 18),
              child: Container(
                height: 62,
                padding: const EdgeInsets.all(4),
                decoration: ShapeDecoration(
                  color: c.card.withValues(alpha: dark ? 0.62 : 0.70),
                  // A faint light rim, like glass catching light.
                  shape: StadiumBorder(
                    side: BorderSide(
                      color: dark
                          ? const Color(0x24FFFFFF)
                          : const Color(0x99FFFFFF),
                      width: 0.8,
                    ),
                  ),
                ),
                child: LayoutBuilder(
                  builder: (context, box) {
                    final slot = box.maxWidth / 5;
                    return Stack(
                      children: [
                        AnimatedPositioned(
                          duration: const Duration(milliseconds: 360),
                          // Springy between tabs, no overshoot at the ends.
                          curve: index == 0 || index == _items.length - 1
                              ? Curves.easeOutCubic
                              : Curves.easeOutBack,
                          left: slot * _slotOf(index),
                          top: 0,
                          bottom: 0,
                          width: slot,
                          child: DecoratedBox(
                            decoration: ShapeDecoration(
                              color: dark
                                  ? const Color(0x1FFFFFFF)
                                  : const Color(0x14000000),
                              shape: const StadiumBorder(),
                            ),
                          ),
                        ),
                        Row(
                          children: [
                            item(0),
                            item(1),
                            Expanded(
                              child: Center(
                                child: Pressable(
                                  child: Material(
                                    key: const ValueKey('tab-ask'),
                                    color: c.button,
                                    shape: const CircleBorder(),
                                    child: InkWell(
                                      customBorder: const CircleBorder(),
                                      onTap: onAsk,
                                      child: SizedBox.square(
                                        dimension: 46,
                                        child: Center(
                                          child: AskMark(
                                            size: 22,
                                            color: c.onButton,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                            item(2),
                            item(3),
                          ],
                        ),
                      ],
                    );
                  },
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
