import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/pages/transactions_page.dart';

AppTransaction _tx(
  String id,
  String name,
  double amount,
  String pfc, {
  int day = 5,
}) {
  return AppTransaction(
    dedupeKey: id,
    id: id,
    accountId: 'acc-1',
    accountName: 'Card',
    name: name,
    description: name,
    transactionType: pfc,
    category: pfc,
    primaryCategory: pfc,
    date: DateTime(2026, 10, day),
    amount: amount,
    accountType: 'credit',
    accountSubtype: 'credit card',
    pending: false,
    confidence: 'high',
    userId: 'u1',
    rawMerchantName: name,
    rawPfcPrimary: pfc,
    rawPfcDetailed: pfc,
  );
}

Future<void> _pump(WidgetTester tester) async {
  // Tall enough that every row is on screen under the Activity header.
  tester.view.physicalSize = const Size(800, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: TransactionsPage(
          transactions: [
            // Newest first, as the app loads them.
            _tx('1', 'Chipotle', 12, 'FOOD_AND_DRINK', day: 9),
            _tx('2', 'Panera', 9, 'FOOD_AND_DRINK', day: 7),
            _tx('3', 'Amazon', 40, 'GENERAL_MERCHANDISE', day: 3),
            _tx('4', 'Payroll', -2000, 'INCOME', day: 1),
          ],
          accountOptions: const [],
          selectedMonth: DateTime(2026, 10),
          monthOptions: [DateTime(2026, 10)],
          onMonthChanged: (_) {},
          // Shopping picked by hand for Amazon: the filter follows the tag.
          reviewedCategoryByTxId: const {'3': 'Shopping'},
          onTransactionCategorySelected: (_, _) {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Future<void> _pick(
  WidgetTester tester,
  String option, {
  String field = 'tx-category-filter',
}) async {
  await tester.tap(find.byKey(ValueKey(field)));
  await tester.pumpAndSettle();
  await tester.tap(find.text(option).last);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('filters the list to one category', (tester) async {
    await _pump(tester);
    expect(find.text('4 transactions (Oct 2026)'), findsOneWidget);
    expect(find.text('All categories (4)'), findsOneWidget);

    await _pick(tester, 'Food (2)');
    expect(find.text('2 transactions (Oct 2026)'), findsOneWidget);
    expect(find.text('Amazon'), findsNothing);

    await _pick(tester, 'Shopping (1)');
    expect(find.text('Amazon'), findsOneWidget);
    expect(find.text('Chipotle'), findsNothing);

    await _pick(tester, 'All categories (4)');
    expect(find.text('4 transactions (Oct 2026)'), findsOneWidget);
  });

  testWidgets('combines with search', (tester) async {
    await _pump(tester);
    await _pick(tester, 'Food (2)');
    await tester.enterText(find.byType(TextField), 'pan');
    await tester.pumpAndSettle();
    expect(find.text('1 transactions (Oct 2026)'), findsOneWidget);
    expect(find.text('Panera'), findsOneWidget);
  });

  testWidgets('sorts by date or amount, either direction', (tester) async {
    await _pump(tester);
    List<String> order() {
      final names = ['Chipotle', 'Panera', 'Amazon', 'Payroll'];
      return names..sort(
        (a, b) => tester
            .getTopLeft(find.text(a))
            .dy
            .compareTo(tester.getTopLeft(find.text(b)).dy),
      );
    }

    expect(order(), ['Chipotle', 'Panera', 'Amazon', 'Payroll']);

    await tester.tap(find.byKey(const ValueKey('tx-sort-direction')));
    await tester.pumpAndSettle();
    expect(order(), ['Payroll', 'Amazon', 'Panera', 'Chipotle']);

    await _pick(tester, 'Amount', field: 'tx-sort-key');
    expect(order(), ['Panera', 'Chipotle', 'Amazon', 'Payroll']);

    await tester.tap(find.byKey(const ValueKey('tx-sort-direction')));
    await tester.pumpAndSettle();
    expect(order(), ['Payroll', 'Amazon', 'Chipotle', 'Panera']);
  });
}
