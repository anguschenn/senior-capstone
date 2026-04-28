import '../constants/app_constants.dart';
import '../controllers/main_screen_controller.dart';
import '../models/app_models.dart';
import '../models/finance/financial_snapshot.dart';
import '../utils/app_helpers.dart';
import 'ai_summary_service.dart';
import 'budget_service.dart';

class FinancialSnapshotService {
  const FinancialSnapshotService._();

  static const instance = FinancialSnapshotService._();

  FinancialSnapshot build(
    MainScreenController controller, {
    DateTime? targetMonth,
    Map<String, dynamic>? precomputedSummary,
  }) {
    return buildForAccount(
      controller,
      controller.selectedAccountId,
      targetMonth: targetMonth ?? controller.selectedMonth,
      precomputedSummary: precomputedSummary,
    );
  }

  FinancialSnapshot buildForAccount(
    MainScreenController controller,
    String targetAccountId, {
    DateTime? targetMonth,
    Map<String, dynamic>? precomputedSummary,
    bool useLinkedAccounts = true,
  }) {
    final focusMonth = normalizedMonthOption(
      targetMonth ?? controller.selectedMonth,
    );
    AccountOption? selectedOption;
    for (final option in controller.liveAccountOptions) {
      if (option.accountId == targetAccountId) {
        selectedOption = option;
        break;
      }
    }
    final selectedAccountIds = selectedOption != null && useLinkedAccounts
        ? selectedOption.linkedAccountIds.toSet()
        : <String>{targetAccountId};

    final visibleTransactions = targetAccountId == kAllAccountsId
        ? controller.liveTransactions
        : controller.liveTransactions
              .where((tx) => selectedAccountIds.contains(tx.accountId))
              .toList();
    final visibleSubscriptions = controller.liveSubscriptions;
    final visibleBudgetProgress = _rebaseProgressFromTemplate(
      template: controller.liveBudgetProgress,
      txs: visibleTransactions,
      focusMonth: focusMonth,
      yearly: isAllYearOption(focusMonth),
      allTime: false,
      reviewedCategoryByTxId: controller.reviewedCategoryByTxId,
    );
    final visibleBudgetProgressYear = _rebaseProgressFromTemplate(
      template: controller.liveBudgetProgressYear,
      txs: visibleTransactions,
      focusMonth: focusMonth,
      yearly: true,
      allTime: false,
      reviewedCategoryByTxId: controller.reviewedCategoryByTxId,
    );
    final visibleBudgetProgressAll = _rebaseProgressFromTemplate(
      template: controller.liveBudgetProgressAll,
      txs: visibleTransactions,
      focusMonth: focusMonth,
      yearly: false,
      allTime: true,
      reviewedCategoryByTxId: controller.reviewedCategoryByTxId,
    );

    double visibleIncome = 0;
    double visibleExpenses = 0;
    for (final tx in visibleTransactions) {
      if (transactionInSelectedPeriod(tx, focusMonth)) {
        visibleIncome += tx.incomeAmount;
        visibleExpenses += tx.expenseAmount;
      }
    }

    final selectedBalance = targetAccountId == kAllAccountsId
        ? controller.liveStats.totalBalance
        : (selectedOption?.balance ?? 0.0);

    final stats = DashboardStats(
      totalBalance: selectedBalance,
      monthlyIncome: visibleIncome,
      monthlyExpenses: visibleExpenses,
      netThisMonth: visibleIncome - visibleExpenses,
    );

    final spendingSummary = AiSummaryService.instance.build(
      transactions: visibleTransactions,
      budgetProgress: visibleBudgetProgress,
      stats: stats,
      selectedAccountId: targetAccountId,
      precomputedSummary: precomputedSummary,
      reviewedCategoryByTxId: controller.reviewedCategoryByTxId,
      scopeLabel: targetAccountId == kAllAccountsId
          ? 'Overall (All Accounts)'
          : (useLinkedAccounts
                ? (selectedOption?.label ??
                      'Account ${_endingForId(targetAccountId)}')
                : 'Account ••••${_endingForId(targetAccountId)}'),
      focusMonth: focusMonth,
    );

    return FinancialSnapshot(
      transactions: visibleTransactions,
      subscriptions: visibleSubscriptions,
      budgetProgress: visibleBudgetProgress,
      budgetProgressYear: visibleBudgetProgressYear,
      budgetProgressAll: visibleBudgetProgressAll,
      stats: stats,
      spendingSummary: spendingSummary,
    );
  }

  List<BudgetCategoryProgress> _rebaseProgressFromTemplate({
    required List<BudgetCategoryProgress> template,
    required List<AppTransaction> txs,
    required DateTime focusMonth,
    required bool yearly,
    required bool allTime,
    required Map<String, String> reviewedCategoryByTxId,
  }) {
    if (template.isNotEmpty) {
      return BudgetService.instance.rebasedProgressFromTemplate(
        template: template,
        txs: txs,
        focusMonth: focusMonth,
        yearly: yearly,
        allTime: allTime,
        reviewedCategoryByTxId: reviewedCategoryByTxId,
      );
    }
    if (allTime) {
      return BudgetService.instance.presetBudgetProgressAllTime(
        txs,
        focusMonth,
        reviewedCategoryByTxId,
      );
    }
    return BudgetService.instance.presetBudgetProgress(
      txs,
      focusMonth,
      yearly,
      reviewedCategoryByTxId,
    );
  }

  String _endingForId(String accountId) {
    if (accountId.length >= 4) return accountId.substring(accountId.length - 4);
    return accountId;
  }
}
