import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/models/budget_pace.dart';
import 'package:ssdemo_1/widgets/budget/budget_pace_chart_card.dart';

void main() {
  test('day labels every 5 days, ending on the real last day', () {
    expect(BudgetPaceChartCard.axisDays(30), [1, 5, 10, 15, 20, 25, 30]);
    expect(BudgetPaceChartCard.axisDays(31), [1, 5, 10, 15, 20, 25, 31]);
    expect(BudgetPaceChartCard.axisDays(28), [1, 5, 10, 15, 20, 25, 28]);
    expect(BudgetPaceChartCard.axisDays(29), [1, 5, 10, 15, 20, 25, 29]);
  });

  test('line colour: green well under, yellow/orange near, red over', () {
    Color c(double gap) => BudgetPaceChartCard.paceColor(gap);
    expect(c(-0.30), const Color(0xFF2E7D32));
    expect(c(-0.10), const Color(0xFF2E7D32));
    expect(c(-0.04), const Color(0xFFF9A825));
    expect(c(0.00), const Color(0xFFEF6C00));
    expect(c(0.08), const Color(0xFFE53935));
    expect(c(0.50), const Color(0xFFE53935));
    // Between stops it blends: less green (redder) the further past the line.
    expect(c(0.04).g, lessThan(c(0.0).g));
    expect(c(0.04).g, greaterThan(c(0.08).g));
  });

  testWidgets('chart renders at the taller height', (tester) async {
    final snapshot = BudgetPaceSnapshot.build(
      focusMonth: DateTime(2026, 9),
      now: DateTime(2026, 9, 27),
      budgets: const [
        BudgetCategoryProgress(
          budgetId: 'b',
          categoryId: 'c',
          title: 'Food',
          spent: 0,
          limit: 810,
        ),
      ],
      transactions: [
        for (var d = 1; d <= 27; d += 2)
          AppTransaction.fromMap({
            'plaid_transaction_id': 'tx-$d',
            'name': 'Lunch',
            'amount': 80.0,
            'date': '2026-09-${d.toString().padLeft(2, '0')}',
          }),
      ],
    );
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: BudgetPaceChartCard(snapshot: snapshot),
          ),
        ),
      ),
    );
    final chart = find.descendant(
      of: find.byType(BudgetPaceChartCard),
      matching: find.byType(CustomPaint),
    );
    expect(tester.getSize(chart.last).height, 200);
    expect(find.textContaining('over pace'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
