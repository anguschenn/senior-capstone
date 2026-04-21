import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../controllers/main_screen_controller.dart';
import '../core/config/api_config.dart';
import '../core/config/env_config.dart';
import '../models/app_models.dart';
import '../pages/budget_page.dart';
import '../pages/cash_flow_page.dart';
import '../pages/home_page.dart';
import '../pages/subscriptions_page.dart';
import '../pages/transactions_page.dart';
import '../services/financial_snapshot_service.dart';
import '../widgets/ai_assistant/ai_assistant_button.dart';
import '../widgets/ai_assistant/ai_assistant_panel.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _ctrl = MainScreenController();

  List<DateTime> _monthOptions(List<AppTransaction> txs) {
    final monthSet = <DateTime>{};
    for (final tx in txs) {
      monthSet.add(DateTime(tx.date.year, tx.date.month, 1));
    }
    monthSet.add(
      DateTime(_ctrl.selectedMonth.year, _ctrl.selectedMonth.month, 1),
    );
    final sorted = monthSet.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  @override
  void initState() {
    super.initState();
    _ctrl.addListener(_onControllerChange);
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

  @override
  Widget build(BuildContext context) {
    final c = _ctrl;
    final snapshot = FinancialSnapshotService.instance.build(
      c,
      targetMonth: c.selectedMonth,
    );
    final visibleTransactions = snapshot.transactions;
    final visibleSubscriptions = snapshot.subscriptions;
    final visibleBudgetProgress = snapshot.budgetProgress;
    final visibleBudgetProgressYear = snapshot.budgetProgressYear;
    final visibleBudgetProgressAll = snapshot.budgetProgressAll;
    final visibleStats = snapshot.stats;
    final spendingSummary = snapshot.spendingSummary;
    final monthOptions = _monthOptions(visibleTransactions);

    final body = switch (c.tabIndex) {
      0 => HomePage(
        transactions: visibleTransactions,
        lowConfidenceTransactions: visibleTransactions,
        subscriptions: visibleSubscriptions.take(3).toList(),
        monthlySubscriptionTotal: visibleSubscriptions.fold<double>(
          0,
          (sum, item) => sum + item.amount,
        ),
        stats: visibleStats,
        syncing: c.syncing,
        syncStatus: c.syncStatus,
        onConnectPlaid: c.connectPlaidAndPullData,
        onRefreshLiveData: c.refreshLiveDataOnly,
        onClearLiveData: c.clearLiveData,
        accountOptions: c.liveAccountOptions,
        selectedAccountId: c.selectedAccountId,
        reviewedCategoryByTxId: c.reviewedCategoryByTxId,
        confirmedReviewTxIds: c.confirmedReviewTxIds,
        onAccountChanged: c.selectAccount,
        selectedMonth: c.selectedMonth,
        monthOptions: monthOptions,
        onMonthChanged: c.selectMonth,
        onTransactionCategorySelected: c.onTransactionCategorySelected,
        onReviewConfirm: c.confirmReviewedCategory,
      ),
      1 => CashFlowPage(
        transactions: visibleTransactions,
        selectedMonth: c.selectedMonth,
        monthOptions: monthOptions,
        onMonthChanged: c.selectMonth,
      ),
      2 => TransactionsPage(
        transactions: visibleTransactions,
        accountOptions: c.liveAccountOptions,
        selectedMonth: c.selectedMonth,
        monthOptions: monthOptions,
        onMonthChanged: c.selectMonth,
        reviewedCategoryByTxId: c.reviewedCategoryByTxId,
        onTransactionCategorySelected: c.onTransactionCategorySelected,
      ),
      3 => BudgetPage(
        stats: visibleStats,
        budgetProgress: visibleBudgetProgress,
        budgetProgressYear: visibleBudgetProgressYear,
        budgetProgressAll: visibleBudgetProgressAll,
        onUpdateBudgetLimit: c.updateBudgetLimit,
        aiBudgetSuggestApiUri: ApiConfig.instance.aiBudgetSuggestUri,
        apiKey: EnvConfig.instance.backendApiKey,
        spendingSummary: spendingSummary,
        selectedMonth: c.selectedMonth,
        monthOptions: monthOptions,
        onMonthChanged: c.selectMonth,
      ),
      _ => SubscriptionsPage(subscriptions: visibleSubscriptions),
    };

    return Stack(
      children: [
        Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: c.tabIndex,
            onDestinationSelected: c.selectTab,
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.home_outlined),
                label: 'Home',
              ),
              NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Flow'),
              NavigationDestination(
                icon: Icon(Icons.receipt_long),
                label: 'Activity',
              ),
              NavigationDestination(
                icon: Icon(Icons.pie_chart_outline),
                label: 'Budget',
              ),
              NavigationDestination(
                icon: Icon(Icons.subscriptions_outlined),
                label: 'Subs',
              ),
            ],
          ),
        ),
        Positioned(
          right: 18,
          bottom: 96,
          child: AIAssistantButton(
            onTap: () {
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
                summariesByAccount[option.accountId] = FinancialSnapshotService
                    .instance
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
                backgroundColor: Colors.transparent,
                builder: (context) => AIAssistantPanel(
                  chatApiUri: ApiConfig.instance.aiChatUri,
                  apiKey: EnvConfig.instance.backendApiKey,
                  accountOptions: c.liveAccountOptions,
                  initialAccountId: c.selectedAccountId,
                  spendingSummaryByAccount: summariesByAccount,
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
