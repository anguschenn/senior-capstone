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

  test('money sent to a person is not offered as a purchase', () {
    final sent = _tx(
      'p6',
      'Zelle payment to Austin Chin',
      71,
      DateTime(2026, 10, 2),
      pfcPrimary: 'TRANSFER_OUT',
    );
    final ids = linkablePurchases(zelle, [...all, sent]).map((t) => t.id);
    expect(ids, isNot(contains('p6')));
    expect(ids, contains('p1'));
  });

  test('money sent to a person offers no split or payback', () {
    final sent = _tx(
      'p6',
      'Zelle payment to Austin Chin',
      71,
      DateTime(2026, 10, 2),
      pfcPrimary: 'TRANSFER_OUT',
    );
    expect(sent.kind, TxKind.spend);
    expect(actionsFor(sent), isEmpty);
    expect(actionsFor(dinner), [
      TransactionAction.split,
      TransactionAction.addPayback,
    ]);
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

  test(
    'from a purchase: unlinked payments since it, that fit, closest first',
    () {
      final early = _tx(
        'z0',
        'Venmo from Bob',
        -20,
        DateTime(2026, 9, 20),
        pfcPrimary: 'TRANSFER_IN',
      );
      final big = _tx(
        'z2',
        'Zelle payment from Cat',
        -90,
        DateTime(2026, 10, 1),
        pfcPrimary: 'TRANSFER_IN',
      );
      final linked = _tx(
        'z3',
        'Zelle payment from Dan',
        -10,
        DateTime(2026, 9, 29),
        pfcPrimary: 'TRANSFER_IN',
      );
      AppTransaction.kindById = {'z3': TxKind.payback};
      AppTransaction.purchaseByPaybackId = {'z3': dinner};
      final txs = [...all, early, big, linked];
      // Bob paid before the dinner, Cat's is more than the dinner, Dan's is
      // already linked: only Amy's is offered.
      expect(linkablePayments(dinner, txs).map((t) => t.id), ['z1']);
      expect(paybacksOf(dinner, txs).map((t) => t.id), ['z3']);
      // One the user said isn't a payback isn't offered either.
      expect(linkablePayments(dinner, txs, notPaybackIds: {'z1'}), isEmpty);
    },
  );

  test('two weeks after the purchase first, closest first; then newest', () {
    AppTransaction.kindById = const {};
    final trip = _tx('t1', 'Airbnb', 600, DateTime(2026, 6, 1));
    AppTransaction p(String id, int month, int day) => _tx(
      id,
      'Venmo from $id',
      -20,
      DateTime(2026, month, day),
      pfcPrimary: 'TRANSFER_IN',
    );
    final txs = [trip, p('a', 6, 10), p('b', 6, 3), p('c', 7, 1), p('d', 8, 1)];
    expect(linkablePayments(trip, txs).map((t) => t.id), ['b', 'a', 'd', 'c']);
  });

  testWidgets('add paybacks: tick two and link both; too much greys it', (
    tester,
  ) async {
    final amy = _tx(
      'za',
      'Zelle payment from Amy',
      -40,
      DateTime(2026, 9, 29),
      pfcPrimary: 'TRANSFER_IN',
    );
    final bob = _tx(
      'zb',
      'Venmo from Bob',
      -30,
      DateTime(2026, 9, 30),
      pfcPrimary: 'TRANSFER_IN',
    );
    List<AppTransaction>? linked;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              linked = await showLinkPaymentSheet(
                context: context,
                purchase: dinner,
                transactions: [dinner, amy, bob],
              );
            },
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('payment-za')));
    await tester.tap(find.byKey(const ValueKey('payment-zb')));
    await tester.pump();
    // $70 fits in the $80 dinner.
    expect(find.text('Link 2'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('link-payments')));
    await tester.pumpAndSettle();
    expect(linked?.map((t) => t.id), ['za', 'zb']);

    AppTransaction.paidBackById = {'p1': 20};
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('payment-za')));
    await tester.tap(find.byKey(const ValueKey('payment-zb')));
    await tester.pump();
    expect(find.text(r'More than the $60.00 left'), findsOneWidget);
    final button = tester.widget<FilledButton>(
      find.byKey(const ValueKey('link-payments')),
    );
    expect(button.onPressed, isNull);
  });

  test('the split preview counts what friends already paid back', () {
    AppTransaction.paidBackById = {'p1': 30};
    expect(
      splitPreview(dinner, 40),
      r'Your share $40.00 · $10.00 to get back ($30.00 already paid back)',
    );
  });

  test('actions: purchases split, payments from people link', () {
    expect(actionsFor(dinner), [
      TransactionAction.split,
      TransactionAction.addPayback,
    ]);
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
