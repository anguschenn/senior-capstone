import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/constants/app_constants.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/pages/home_page.dart';

Widget _home({bool syncing = false, bool bankSyncBusy = false}) {
  return MaterialApp(
    home: Scaffold(
      body: HomePage(
        transactions: const [],
        lowConfidenceTransactions: const [],
        subscriptions: const [],
        monthlySubscriptionTotal: 0,
        stats: const DashboardStats(
          totalBalance: 0,
          monthlyIncome: 0,
          monthlyExpenses: 0,
          netThisMonth: 0,
        ),
        syncing: syncing,
        bankSyncBusy: bankSyncBusy,
        syncStatus: 'status',
        onConnectBank: () {},
        onAddBank: () {},
        onRefreshLiveData: () {},
        onClearLiveData: () {},
        accountOptions: const [
          AccountOption(
            accountId: 'a1',
            label: 'Checking ••••1234',
            ending: '1234',
            balance: 1,
            txCount: 1,
            linkedAccountIds: ['a1'],
          ),
        ],
        selectedAccountId: kAllAccountsId,
        selectedMonth: DateTime(2026, 9, 1),
        monthOptions: [DateTime(2026, 9, 1)],
        onMonthChanged: (_) {},
        reviewedCategoryByTxId: const {},
        manualReviewedTxIds: const {},
        confirmedReviewTxIds: const {},
        lowConfidenceReviewTxIds: const {},
        onAccountChanged: (_) {},
        onTransactionCategorySelected: (tx, category) {},
        onReviewConfirm: (txId) async {},
      ),
    ),
  );
}

VoidCallback? _onPressed(WidgetTester tester, Finder button) {
  final widget = tester.widget(button);
  if (widget is ButtonStyleButton) return widget.onPressed;
  throw StateError('not a button: $widget');
}

bool _accountDropdownEnabled(WidgetTester tester) {
  final dropdown = tester.widget<DropdownButtonFormField<String>>(
    find.byType(DropdownButtonFormField<String>),
  );
  return dropdown.onChanged != null;
}

void main() {
  Finder button(String label) => find.ancestor(
    of: find.text(label),
    matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
  );

  testWidgets('idle: bank buttons and account filter are all usable', (
    tester,
  ) async {
    await tester.pumpWidget(_home());
    expect(find.text('Add Bank'), findsOneWidget);
    expect(_onPressed(tester, button('Add Bank')), isNotNull);
    expect(_onPressed(tester, button('Refresh')), isNotNull);
    expect(_onPressed(tester, button('Clear')), isNotNull);
    expect(_accountDropdownEnabled(tester), isTrue);
  });

  testWidgets('background bank refresh: buttons wait, account filter works', (
    tester,
  ) async {
    await tester.pumpWidget(_home(bankSyncBusy: true));
    expect(find.text('Syncing'), findsOneWidget);
    expect(_onPressed(tester, button('Syncing')), isNull);
    expect(_onPressed(tester, button('Reconnect')), isNull);
    expect(_onPressed(tester, button('Refresh')), isNull);
    expect(_onPressed(tester, button('Clear')), isNull);
    expect(_accountDropdownEnabled(tester), isTrue);
  });

  testWidgets('a blocking sync still locks everything, as before', (
    tester,
  ) async {
    await tester.pumpWidget(_home(syncing: true));
    expect(_onPressed(tester, button('Refresh')), isNull);
    expect(_accountDropdownEnabled(tester), isFalse);
  });
}
