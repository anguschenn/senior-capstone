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
    // The server has no per-account filter (python/budget_progress.py sums
    // every transaction), so its numbers are only correct for "All Accounts"
    // on the exact month it was computed for. Everything else -- a specific
    // account, Year/All-time view, or no server data yet -- falls back to
    // the existing Dart computation, unchanged.
    final serverMonth = controller.serverBudgetProgressMonth;
    final serverForFocus =
        !isAllYearOption(focusMonth) &&
        controller.serverBudgetProgress != null &&
        serverMonth != null &&
        serverMonth.year == focusMonth.year &&
        serverMonth.month == focusMonth.month;
    // The server found no budget rows for this month (e.g. a month before
    // budgets were set): show its spending with no limits, for any account,
    // rather than this month's limits applied to it.
    final noBudgetsThisMonth =
        serverForFocus && controller.serverBudgetProgress!.isEmpty;
    final useServerBudgetProgress =
        targetAccountId == kAllAccountsId &&
        serverForFocus &&
        !noBudgetsThisMonth;
    // Every category card, with this month's spending and no limit: fills in
    // categories the month has no budget row for.
    List<BudgetCategoryProgress> spendOnly() => _rebaseProgressFromTemplate(
      template: [
        for (final b in controller.liveBudgetProgress)
          BudgetCategoryProgress(
            budgetId: b.budgetId,
            categoryId: b.categoryId,
            title: b.title,
            spent: 0,
            limit: 0,
          ),
      ],
      txs: visibleTransactions,
      focusMonth: focusMonth,
      yearly: false,
      allTime: false,
      reviewedCategoryByTxId: controller.reviewedCategoryByTxId,
    );
    final visibleBudgetProgress = useServerBudgetProgress
        ? [
            ...controller.serverBudgetProgress!,
            // A month with rows for only some categories (e.g. just Food)
            // still shows the others' spending.
            for (final b in spendOnly())
              if (!controller.serverBudgetProgress!.any(
                (s) =>
                    normalizeCategoryKey(s.title) ==
                    normalizeCategoryKey(b.title),
              ))
                b,
          ]
        : _rebaseProgressFromTemplate(
            template: noBudgetsThisMonth
                ? [
                    for (final b in controller.liveBudgetProgress)
                      BudgetCategoryProgress(
                        budgetId: b.budgetId,
                        categoryId: b.categoryId,
                        title: b.title,
                        spent: 0,
                        limit: 0,
                      ),
                  ]
                : controller.liveBudgetProgress,
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

    final accountTypes = targetAccountId == kAllAccountsId
        ? const <String>{}
        : visibleTransactions
              .map((tx) => tx.accountType.toLowerCase().trim())
              .where((type) => type.isNotEmpty)
              .toSet();

    final spendingSummary = AiSummaryService.instance.build(
      transactions: visibleTransactions,
      budgetProgress: visibleBudgetProgress,
      stats: stats,
      selectedAccountId: targetAccountId,
      accountType: accountTypes.length == 1 ? accountTypes.first : '',
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
      return BudgetService.instance
          .buildZeroLimitProgressFromPresetCategoriesAllTime(
            txs,
            focusMonth,
            reviewedCategoryByTxId,
          );
    }
    return BudgetService.instance.buildZeroLimitProgressFromPresetCategories(
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
