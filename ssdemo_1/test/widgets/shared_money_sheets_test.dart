import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/widgets/common/shared_money_sheets.dart';

AppTransaction _tx(
  String id,
  String name,
  double amount,
  DateTime date, {
  String pfcPrimary = 'FOOD_AND_DRINK',
}) => AppTransaction(
  dedupeKey: id,
  id: id,
  accountId: 'acc-card',
  accountName: 'Card',
  name: name,
  description: name,
  transactionType: pfcPrimary,
  category: pfcPrimary,
  primaryCategory: pfcPrimary,
  date: date,
  amount: amount,
  accountType: 'credit',
  accountSubtype: '',
  pending: false,
  confidence: 'high',
  userId: 'u1',
  rawMerchantName: name,
  rawPfcPrimary: pfcPrimary,
  rawPfcDetailed: pfcPrimary,
);

void main() {
  tearDown(() {
    AppTransaction.kindById = const {};
    AppTransaction.paidBackById = const {};
    AppTransaction.sharedAmountById = const {};
    AppTransaction.purchaseByPaybackId = const {};
  });

  final zelle = _tx(
    'z1',
    'Zelle payment from Amy',
    -40,
    DateTime(2026, 10, 2),
    pfcPrimary: 'TRANSFER_IN',
  );
  final dinner = _tx('p1', 'Olive Garden', 80, DateTime(2026, 9, 28));
  final lunch = _tx('p2', 'Chipotle', 12, DateTime(2026, 9, 30));
  final concert = _tx('p3', 'Ticketmaster', 150, DateTime(2026, 8, 1));
  final shared = _tx('p4', 'Airbnb', 300, DateTime(2026, 7, 1));
  final later = _tx('p5', 'Uber', 50, DateTime(2026, 10, 5));
  final all = [zelle, dinner, lunch, concert, shared, later];

  test('the user picks; split purchases first, then the week before', () {
    AppTransaction.sharedAmountById = {'p4': 200};
    final ids = linkablePurchases(zelle, all).map((t) => t.id).toList();
    // Too small (lunch) and after the payment (Uber) aren't offered.
    expect(ids, ['p4', 'p1', 'p3']);
  });

  test('a purchase already paid back in full is not offered again', () {
    AppTransaction.paidBackById = {'p1': 60};
    expect(linkablePurchases(zelle, all).map((t) => t.id), isNot(['p1']));
    expect(linkablePurchases(zelle, all).map((t) => t.id), ['p3', 'p4']);
  });

  test('splitting evenly leaves the others their part', () {
    expect(othersShareOf(80, 2), 40);
    expect(othersShareOf(100, 3), 66.67);
    expect(othersShareOf(80, 1), 0);
  });

  test('the split preview counts what friends already paid back', () {
    AppTransaction.paidBackById = {'p1': 30};
    expect(
      splitPreview(dinner, 40),
      r'Your share $40.00 · $10.00 to get back ($30.00 already paid back)',
    );
  });

  test('actions: purchases split, payments from people link', () {
    expect(actionsFor(dinner), [TransactionAction.split]);
    expect(actionsFor(zelle), [
      TransactionAction.linkPayback,
      TransactionAction.notPayback,
    ]);
    AppTransaction.kindById = {'z1': TxKind.payback};
    expect(actionsFor(zelle), [TransactionAction.unlinkPayback]);
  });

  testWidgets('split sheet: two people means half to get back', (tester) async {
    double? saved = -1;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              saved = await showSplitPurchaseSheet(
                context: context,
                purchase: dinner,
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(
      find.text(r'Your share $40.00 · $40.00 to get back'),
      findsOneWidget,
    );
    await tester.enterText(find.byKey(const ValueKey('split-input')), '4');
    await tester.pump();
    expect(
      find.text(r'Your share $20.00 · $60.00 to get back'),
      findsOneWidget,
    );
    // Both choices keep the same width (the capsule control, no tick).
    final evenWidth = tester.getSize(find.text('Split evenly')).width;
    await tester.tap(find.text('They owe'));
    await tester.pumpAndSettle();
    expect(tester.getSize(find.text('Split evenly')).width, evenWidth);
    await tester.enterText(find.byKey(const ValueKey('split-input')), '50');
    await tester.pump();
    expect(
      find.text(r'Your share $30.00 · $50.00 to get back'),
      findsOneWidget,
    );
    await tester.tap(find.text('They owe'));
    await tester.tap(find.text('Split evenly'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('split-input')), '4');
    await tester.pump();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(saved, 60);
  });
}
