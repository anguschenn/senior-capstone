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
    // Budgets are set for the household, not per account: progress always
    // counts every account, whichever one is selected.
    final budgetTransactions = controller.liveTransactions;
    // The server's numbers are only correct on the exact month it was
    // computed for. Year/All-time view, or no server data yet, falls back to
    // the Dart computation.
    final serverMonth = controller.serverBudgetProgressMonth;
    // The server counts every account, so not when the user hid one.
    final serverForFocus =
        controller.hiddenAccountIds.isEmpty &&
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
    final useServerBudgetProgress = serverForFocus && !noBudgetsThisMonth;
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
      txs: budgetTransactions,
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
                : _monthTemplate(controller, focusMonth) ??
                      controller.liveBudgetProgress,
            txs: budgetTransactions,
            focusMonth: focusMonth,
            yearly: isAllYearOption(focusMonth),
            allTime: false,
            reviewedCategoryByTxId: controller.reviewedCategoryByTxId,
          );
    final visibleBudgetProgressYear = _rebaseProgressFromTemplate(
      template: controller.liveBudgetProgressYear,
      txs: budgetTransactions,
      focusMonth: focusMonth,
      yearly: true,
      allTime: false,
      reviewedCategoryByTxId: controller.reviewedCategoryByTxId,
    );
    final visibleBudgetProgressAll = _rebaseProgressFromTemplate(
      template: controller.liveBudgetProgressAll,
      txs: budgetTransactions,
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
      budgetTransactions: budgetTransactions,
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

  /// The focus month's own limits from the loaded year's budget rows, so a
  /// past month doesn't borrow this month's budget while the server's
  /// answer is pending or unavailable. Null when that year wasn't loaded.
  List<BudgetCategoryProgress>? _monthTemplate(
    MainScreenController controller,
    DateTime focusMonth,
  ) {
    if (isAllYearOption(focusMonth)) return null;
    final byMonth = controller.liveBudgetLimitsByMonth;
    final year = '${focusMonth.year}-';
    if (!byMonth.keys.any((k) => k.startsWith(year))) return null;
    final key = '$year${focusMonth.month.toString().padLeft(2, '0')}';
    final limits = byMonth[key] ?? const <String, double>{};
    final names = {
      for (final c in controller.liveCategoryOptions) c.id: c.name,
    };
    // The same category can exist under two ids (a shared default and the
    // user's own copy), so match by name too, or it shows up twice.
    final limitByName = <String, double>{
      for (final entry in limits.entries)
        if (names[entry.key] != null)
          normalizeCategoryKey(names[entry.key]!): entry.value,
    };
    final knownNames = controller.liveBudgetProgress
        .map((b) => normalizeCategoryKey(b.title))
        .toSet();
    return [
      for (final b in controller.liveBudgetProgress)
        BudgetCategoryProgress(
          budgetId: b.budgetId,
          categoryId: b.categoryId,
          title: b.title,
          spent: 0,
          limit:
              limits[b.categoryId] ??
              limitByName[normalizeCategoryKey(b.title)] ??
              0,
        ),
      // Categories budgeted that month but not in the loaded month.
      for (final entry in limits.entries)
        if (names[entry.key] != null &&
            !knownNames.contains(normalizeCategoryKey(names[entry.key]!)))
          BudgetCategoryProgress(
            budgetId: 'month-${entry.key}',
            categoryId: entry.key,
            title: names[entry.key]!,
            spent: 0,
            limit: entry.value,
          ),
    ];
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
