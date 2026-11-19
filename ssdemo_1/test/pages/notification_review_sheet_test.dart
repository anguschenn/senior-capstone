import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/pages/home_page.dart';

void main() {
  testWidgets('review notification can open the transaction review sheet', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showReviewTransactionsSheet(
                context: context,
                transactions: const [],
                accountOptions: const [],
                reviewedCategoryByTxId: const {},
                onTransactionCategorySelected: (_, _) {},
                onReviewConfirm: (_) async {},
              ),
              child: const Text('Open review'),
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Open review'));
    await tester.pumpAndSettle();

    expect(find.text('Review Transactions'), findsOneWidget);
    expect(find.text('All caught up.'), findsOneWidget);
  });
}
