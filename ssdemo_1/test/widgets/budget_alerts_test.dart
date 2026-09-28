import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/widgets/budget/budget_alert_toasts.dart';
import 'package:ssdemo_1/widgets/budget/budget_insight_banner.dart';
import 'package:ssdemo_1/widgets/budget/budget_progress_card.dart';

BudgetCategoryProgress _budget(String title, double spent, double limit) =>
    BudgetCategoryProgress(
      budgetId: 'b-$title',
      categoryId: 'c-$title',
      title: title,
      spent: spent,
      limit: limit,
    );

Widget _host(Widget child) => MaterialApp(home: Scaffold(body: child));

void main() {
  test('usedRatio is not capped the way the progress-bar ratio is', () {
    final food = _budget('Food', 1620, 810);
    expect(food.usedRatio, 2.0);
    expect(food.ratio, 1.5);
    expect(food.isOverBudget, isTrue);
    expect(_budget('Health', 6.63, 30).isOverBudget, isFalse);
  });

  testWidgets('one alert per category, with used %, amounts and pace', (
    tester,
  ) async {
    final tapped = <String>[];
    final dismissed = <String>[];
    await tester.pumpWidget(
      _host(
        BudgetAlertToasts(
          items: [
            _budget('Food', 1113.69, 810),
            _budget('Transport', 147.5, 275),
          ],
          onTap: (c) => tapped.add(c.title),
          onDismiss: (c) => dismissed.add(c.title),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Food is over budget'), findsOneWidget);
    expect(find.text('137% used · \$1113.69 of \$810.00'), findsOneWidget);
    expect(find.text('Transport on track to overspend'), findsOneWidget);
    expect(find.textContaining('Pace: ~\$'), findsNWidgets(2));

    await tester.tap(find.text('Food is over budget'));
    await tester.tap(find.byTooltip('Dismiss').last);
    expect(tapped, ['Food']);
    expect(dismissed, ['Transport']);
  });

  testWidgets('no alerts renders nothing', (tester) async {
    await tester.pumpWidget(
      _host(
        BudgetAlertToasts(items: const [], onTap: (_) {}, onDismiss: (_) {}),
      ),
    );
    expect(find.byType(InkWell), findsNothing);
  });

  testWidgets('banner separates over-budget from on-track categories', (
    tester,
  ) async {
    final tapped = <String>[];
    await tester.pumpWidget(
      _host(
        BudgetInsightBanner(
          message: 'All good',
          overCategories: const ['Food', 'Entertainment'],
          atRiskCategories: const ['Transport'],
          onCategoryTap: tapped.add,
        ),
      ),
    );
    expect(find.text('Over budget:'), findsOneWidget);
    expect(find.text('On track to overspend:'), findsOneWidget);
    expect(find.byIcon(Icons.error_outline), findsOneWidget);
    await tester.tap(find.text('Entertainment'));
    expect(tapped, ['Entertainment']);
  });

  testWidgets('banner falls back to the message with nothing flagged', (
    tester,
  ) async {
    await tester.pumpWidget(
      _host(const BudgetInsightBanner(message: 'Spending looks healthy')),
    );
    expect(find.text('Spending looks healthy'), findsOneWidget);
    expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
  });

  testWidgets('card lists its transactions largest first in a dropdown', (
    tester,
  ) async {
    final txs = [
      for (var i = 1; i <= 12; i++)
        AppTransaction.fromMap({
          'plaid_transaction_id': 'tx-$i',
          'name': 'Merchant $i',
          'amount': i * 10.0,
          'date': '2026-09-${i.toString().padLeft(2, '0')}',
        }),
    ]..sort((a, b) => b.expenseAmount.compareTo(a.expenseAmount));
    await tester.pumpWidget(
      _host(
        SingleChildScrollView(
          child: BudgetProgressCard(
            item: _budget('Food', 780, 810),
            index: 0,
            onEdit: (_) {},
            transactions: txs,
          ),
        ),
      ),
    );

    expect(find.text('12 transactions'), findsOneWidget);
    expect(find.text('Merchant 12'), findsNothing);

    await tester.tap(find.text('12 transactions'));
    await tester.pumpAndSettle();

    expect(find.text('Merchant 12'), findsOneWidget);
    expect(find.text('\$120.00'), findsOneWidget);
    expect(
      tester.getTopLeft(find.text('Merchant 12')).dy,
      lessThan(tester.getTopLeft(find.text('Merchant 11')).dy),
    );
    expect(find.text('Merchant 2'), findsNothing);
    expect(find.text('+ 2 smaller transactions'), findsOneWidget);
  });

  test('card payments carry no spending, so they never reach a breakdown', () {
    final payment = AppTransaction.fromMap({
      'plaid_transaction_id': 'pay',
      'name': 'Payment to Chase card ending in 4191',
      'amount': 1000,
      'date': '2026-09-03',
      'pfc_primary': 'LOAN_PAYMENTS',
      'pfc_detailed': 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT',
    });
    expect(payment.isExpense, isTrue);
    expect(payment.expenseAmount, 0);
  });
}
