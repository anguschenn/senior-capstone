// Proves FinancialSnapshotService's choice between the server-computed and
// Dart-computed budget progress: server values only for "All Accounts" on
// the exact month they were fetched for; the existing Dart recomputation
// (unchanged) everywhere else. python/budget_progress.py has no per-account
// filter, so using it for a specific account would silently ignore the
// account filter the Budget page shows the user.
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/constants/app_constants.dart';
import 'package:ssdemo_1/controllers/main_screen_controller.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/models/finance/financial_snapshot.dart';
import 'package:ssdemo_1/services/financial_snapshot_service.dart';
import 'package:ssdemo_1/utils/app_helpers.dart';

const _acctA = 'acctA';

AppTransaction _foodExpense(
  String id,
  double amount, {
  String date = '2026-09-10',
}) {
  return AppTransaction.fromMap({
    'plaid_transaction_id': id,
    'plaid_account_id': _acctA,
    'merchant_name': 'Test Merchant',
    'name': 'Test Merchant',
    'date': date,
    'amount': amount,
    'account_type': 'depository',
  });
}

MainScreenController _controllerWith({
  required String selectedAccountId,
  required DateTime selectedMonth,
  List<BudgetCategoryProgress>? serverBudgetProgress,
  DateTime? serverBudgetProgressMonth,
}) {
  final tx = _foodExpense('t1', 42);
  final controller = MainScreenController()
    ..selectedAccountId = selectedAccountId
    ..selectedMonth = selectedMonth
    ..liveTransactions = [tx]
    ..reviewedCategoryByTxId = {tx.id: 'Food'}
    ..liveAccountOptions = const [
      AccountOption(
        accountId: _acctA,
        label: 'Checking ••••1234',
        ending: '1234',
        balance: 100,
        txCount: 1,
        linkedAccountIds: [_acctA],
      ),
    ]
    ..liveBudgetProgress = const [
      // Dart template: limit is real, spent is recomputed from
      // liveTransactions by rebasedProgressFromTemplate, so its value here
      // is irrelevant -- only the recomputed amount (42) should show up.
      BudgetCategoryProgress(
        budgetId: 'b1',
        categoryId: 'c1',
        title: 'Food',
        spent: 0,
        limit: 300,
      ),
    ]
    ..serverBudgetProgress = serverBudgetProgress
    ..serverBudgetProgressMonth = serverBudgetProgressMonth;
  addTearDown(controller.dispose);
  return controller;
}

BudgetCategoryProgress _food(FinancialSnapshot snapshot) =>
    snapshot.budgetProgress.firstWhere((b) => b.title == 'Food');

void main() {
  final focusMonth = DateTime(2026, 9, 1);
  final serverProgress = const [
    BudgetCategoryProgress(
      budgetId: 'b1',
      categoryId: 'c1',
      title: 'Food',
      spent: 999, // a value only the server would produce
      limit: 300,
    ),
  ];

  test(
    'All Accounts, server data for the exact focus month: uses the server value',
    () {
      final controller = _controllerWith(
        selectedAccountId: kAllAccountsId,
        selectedMonth: focusMonth,
        serverBudgetProgress: serverProgress,
        serverBudgetProgressMonth: focusMonth,
      );
      final snapshot = FinancialSnapshotService.instance.build(controller);
      expect(_food(snapshot).spent, 999);
    },
  );

  test(
    'a specific account selected: ignores server data, uses the Dart recomputation',
    () {
      final controller = _controllerWith(
        selectedAccountId: _acctA,
        selectedMonth: focusMonth,
        serverBudgetProgress: serverProgress,
        serverBudgetProgressMonth: focusMonth,
      );
      final snapshot = FinancialSnapshotService.instance.build(controller);
      expect(_food(snapshot).spent, 42);
    },
  );

  test(
    'server data is for a different month than the one being viewed: falls back',
    () {
      final controller = _controllerWith(
        selectedAccountId: kAllAccountsId,
        selectedMonth: focusMonth,
        serverBudgetProgress: serverProgress,
        serverBudgetProgressMonth: DateTime(
          2026,
          8,
          1,
        ), // stale -- a prior month
      );
      final snapshot = FinancialSnapshotService.instance.build(controller);
      expect(_food(snapshot).spent, 42);
    },
  );

  test('no server data yet: falls back to the Dart recomputation', () {
    final controller = _controllerWith(
      selectedAccountId: kAllAccountsId,
      selectedMonth: focusMonth,
      serverBudgetProgress: null,
      serverBudgetProgressMonth: null,
    );
    final snapshot = FinancialSnapshotService.instance.build(controller);
    expect(_food(snapshot).spent, 42);
  });

  test(
    'All Year selected: never uses server data, even if present for this month',
    () {
      final controller = _controllerWith(
        selectedAccountId: kAllAccountsId,
        selectedMonth: allYearOptionFor(2026),
        serverBudgetProgress: serverProgress,
        serverBudgetProgressMonth: focusMonth,
      );
      final snapshot = FinancialSnapshotService.instance.build(controller);
      // Year view recomputes from liveBudgetProgressYear (empty here), so Food
      // isn't present at all -- the point is just that it never equals 999.
      expect(snapshot.budgetProgress.where((b) => b.spent == 999), isEmpty);
    },
  );

  for (final account in [kAllAccountsId, _acctA]) {
    test('the server found no budget rows for the month ($account): '
        'spending shows with no limit, not another month\'s', () {
      final controller = _controllerWith(
        selectedAccountId: account,
        selectedMonth: focusMonth,
        serverBudgetProgress: const [],
        serverBudgetProgressMonth: focusMonth,
      );
      final snapshot = FinancialSnapshotService.instance.build(controller);
      expect(_food(snapshot).spent, 42);
      expect(_food(snapshot).limit, 0);
    });
  }

  test('server rows for only some categories: the rest still show their '
      'spending', () {
    final controller = _controllerWith(
      selectedAccountId: kAllAccountsId,
      selectedMonth: focusMonth,
      serverBudgetProgress: const [
        BudgetCategoryProgress(
          budgetId: 'b2',
          categoryId: 'c2',
          title: 'Shopping',
          spent: 10,
          limit: 50,
        ),
      ],
      serverBudgetProgressMonth: focusMonth,
    );
    final snapshot = FinancialSnapshotService.instance.build(controller);
    expect(snapshot.budgetProgress.map((b) => b.title), contains('Shopping'));
    expect(_food(snapshot).spent, 42);
    expect(_food(snapshot).limit, 0);
  });

  test('no server answer for a past month: uses that month\'s own limits', () {
    final controller =
        _controllerWith(
            selectedAccountId: kAllAccountsId,
            selectedMonth: focusMonth,
          )
          ..liveCategoryOptions = const [
            CategoryOption(id: 'c1', name: 'Food'),
            CategoryOption(id: 'c2', name: 'Travel'),
          ]
          ..liveBudgetLimitsByMonth = const {
            '2026-09': {'c1': 500, 'c2': 200},
            '2026-10': {'c1': 300},
          };
    final snapshot = FinancialSnapshotService.instance.build(controller);
    expect(_food(snapshot).limit, 500);
    expect(
      snapshot.budgetProgress.firstWhere((b) => b.title == 'Travel').limit,
      200,
    );

    // A month of the loaded year with no rows has no limits.
    controller.selectedMonth = DateTime(2026, 7, 1);
    final july = FinancialSnapshotService.instance.build(controller);
    expect(_food(july).limit, 0);
  });
}
