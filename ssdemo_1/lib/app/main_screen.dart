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
import '../services/ai_summary_service.dart';
import '../services/budget_service.dart';
import '../widgets/ai_assistant/ai_assistant_button.dart';
import '../widgets/ai_assistant/ai_assistant_panel.dart';

class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  final _ctrl = MainScreenController();

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
    final visibleTransactions = c.selectedAccountId == kAllAccountsId
        ? c.liveTransactions
        : c.liveTransactions
              .where((tx) => tx.accountId == c.selectedAccountId)
              .toList();
    final visibleSubscriptions = c.liveSubscriptions;
    final now = DateTime.now();
    final visibleBudgetProgress = c.selectedAccountId == kAllAccountsId
        ? c.liveBudgetProgress
        : BudgetService.instance.presetBudgetProgress(
            visibleTransactions, now, false, c.reviewedCategoryByTxId);
    final visibleBudgetProgressYear = c.selectedAccountId == kAllAccountsId
        ? c.liveBudgetProgressYear
        : BudgetService.instance.presetBudgetProgress(
            visibleTransactions, now, true, c.reviewedCategoryByTxId);
    final visibleBudgetProgressAll = c.selectedAccountId == kAllAccountsId
        ? c.liveBudgetProgressAll
        : BudgetService.instance.presetBudgetProgressAllTime(
            visibleTransactions, now, c.reviewedCategoryByTxId);

    double visibleIncome = 0;
    double visibleExpenses = 0;
    for (final tx in visibleTransactions) {
      if (tx.date.year == now.year && tx.date.month == now.month) {
        if (tx.amount < 0) {
          visibleIncome += tx.amount.abs();
        } else {
          visibleExpenses += tx.amount;
        }
      }
    }
    final selectedBalance = c.selectedAccountId == kAllAccountsId
        ? c.liveStats.totalBalance
        : (() {
            for (final account in c.liveAccountOptions) {
              if (account.accountId == c.selectedAccountId) {
                return account.balance;
              }
            }
            return 0.0;
          })();
    final visibleStats = DashboardStats(
      totalBalance: selectedBalance,
      monthlyIncome: visibleIncome,
      monthlyExpenses: visibleExpenses,
      netThisMonth: visibleIncome - visibleExpenses,
    );

    final body = switch (c.tabIndex) {
      0 => HomePage(
          transactions: visibleTransactions.take(3).toList(),
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
          onTransactionCategorySelected: c.onTransactionCategorySelected,
          onReviewConfirm: c.confirmReviewedCategory,
        ),
      1 => CashFlowPage(transactions: visibleTransactions),
      2 => TransactionsPage(
          transactions: visibleTransactions,
          accountOptions: c.liveAccountOptions,
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
          spendingSummary: AiSummaryService.instance.build(
            transactions: visibleTransactions,
            budgetProgress: visibleBudgetProgress,
            stats: visibleStats,
            selectedAccountId: c.selectedAccountId,
          ),
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
                  icon: Icon(Icons.home_outlined), label: 'Home'),
              NavigationDestination(
                  icon: Icon(Icons.bar_chart), label: 'Flow'),
              NavigationDestination(
                  icon: Icon(Icons.receipt_long), label: 'Activity'),
              NavigationDestination(
                  icon: Icon(Icons.pie_chart_outline), label: 'Budget'),
              NavigationDestination(
                  icon: Icon(Icons.subscriptions_outlined), label: 'Subs'),
            ],
          ),
        ),
        Positioned(
          right: 18,
          bottom: 96,
          child: AIAssistantButton(
            onTap: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (context) => AIAssistantPanel(
                  chatApiUri: ApiConfig.instance.aiChatUri,
                  apiKey: EnvConfig.instance.backendApiKey,
                  spendingSummary: AiSummaryService.instance.build(
                    transactions: visibleTransactions,
                    budgetProgress: visibleBudgetProgress,
                    stats: visibleStats,
                    selectedAccountId: c.selectedAccountId,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
