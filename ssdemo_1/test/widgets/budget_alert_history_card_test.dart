import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/services/budget_alert_service.dart';
import 'package:ssdemo_1/widgets/budget/budget_alert_history_card.dart';

void main() {
  testWidgets('groups past overruns by month, newest first', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BudgetAlertHistoryCard(
            month: DateTime(2026, 10),
            userId: 'u1',
            loadHistory: (user, from, before) async {
              calls.add('$user $from $before');
              return [
                BudgetOverrun.fromRow({
                  'month': '2026-09',
                  'category': 'Food',
                  'spent': 1349.02,
                  'limit_amount': 810,
                })!,
                BudgetOverrun.fromRow({
                  'month': '2026-08',
                  'category': 'Food',
                  'spent': 1467.11,
                  'limit_amount': '1000.00',
                })!,
              ];
            },
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(calls, ['u1 2026-04 2026-10']);
    expect(find.text('Alert history'), findsOneWidget);
    expect(find.text('Sep 2026'), findsOneWidget);
    expect(
      find.text('Food: \$1349.02 of \$810.00 (over by \$539.02)'),
      findsOneWidget,
    );
    expect(find.text('Aug 2026'), findsOneWidget);
  });

  testWidgets('no history renders nothing', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: BudgetAlertHistoryCard(
            month: DateTime(2026, 10),
            userId: 'u1',
            loadHistory: (_, _, _) async => const [],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('Alert history'), findsNothing);
  });
}
