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
      final subs = FinancialSnapshotService.instance
          .build(c, targetMonth: c.selectedMonth)
          .subscriptions;
      return SettingsPage(
        email: AuthService.instance.currentUser?.email,
        accountOptions: c.liveAccountOptions,
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
        syncStatus: c.syncStatus,
        onAddBank: c.connectBankAndPullData,
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
        aiCategorySuggestUri: ApiConfig.instance.aiCategorySuggestUri,
        apiKey: EnvConfig.instance.backendApiKey,
        accessToken: AuthService.instance.currentAccessToken,
      ),
      BudgetPage(
        stats: snapshot.stats,
        budgetProgress: snapshot.budgetProgress,
        budgetProgressYear: snapshot.budgetProgressYear,
        budgetProgressAll: snapshot.budgetProgressAll,
        onUpdateBudgetLimit: c.updateBudgetLimit,
        aiBudgetSuggestApiUri: ApiConfig.instance.aiBudgetSuggestUri,
        apiKey: EnvConfig.instance.backendApiKey,
        spendingSummary: snapshot.spendingSummary,
        selectedMonth: c.selectedMonth,
        monthOptions: monthOptions,
        onMonthChanged: c.selectMonth,
        transactions: visibleTransactions,
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

/// Wallet / Activity / Ask / Budget / Subs. Ask is a raised round button in
/// the middle that opens the AI panel instead of switching tabs.
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

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    Widget item(int i) {
      final (icon, label) = _items[i];
      final selected = i == index;
      final color = selected ? c.text : c.muted;
      return Expanded(
        child: InkWell(
          onTap: () => onSelect(i),
          child: Padding(
            padding: const EdgeInsets.only(top: 8, bottom: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(icon, color: color, size: 24),
                const SizedBox(height: 3),
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

    return DecoratedBox(
      decoration: BoxDecoration(
        color: c.background,
        border: Border(top: BorderSide(color: c.line, width: 0.5)),
      ),
      child: SafeArea(
        top: false,
        child: SizedBox(
          height: 58,
          child: Row(
            children: [
              item(0),
              item(1),
              // Raised Ask button with its own label, like the other tabs.
              Expanded(
                child: InkWell(
                  key: const ValueKey('tab-ask'),
                  onTap: onAsk,
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Material(
                        color: c.button,
                        shape: const CircleBorder(),
                        elevation: 3,
                        shadowColor: c.cardShadow,
                        child: SizedBox(
                          width: 40,
                          height: 40,
                          child: Icon(
                            Icons.auto_awesome,
                            color: c.onButton,
                            size: 19,
                          ),
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        'Ask',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                          color: c.text,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              item(2),
              item(3),
            ],
          ),
        ),
      ),
    );
  }
}
