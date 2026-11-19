import 'dart:ui' show PointerDeviceKind;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/widgets/cash_flow/cash_flow_category_chart.dart';

void main() {
  testWidgets('shows category legend and slice value on hover', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: CashFlowCategoryChart(
              spendingByCategory: const {'Food': 75, 'Shopping': 25},
            ),
          ),
        ),
      ),
    );

    expect(find.text('Spending by category'), findsOneWidget);
    expect(find.text('Food'), findsOneWidget);
    expect(find.text('Shopping'), findsOneWidget);

    final chart = find.byType(MouseRegion).last;
    final rect = tester.getRect(chart);
    final hoverPosition = rect.centerRight - const Offset(12, 0);
    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: hoverPosition);
    await mouse.moveTo(hoverPosition);
    await tester.pump();

    expect(find.text('Food - \$75.00'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('shows an empty state without painting a pie', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: CashFlowCategoryChart(spendingByCategory: {})),
      ),
    );

    expect(find.text('No spending in this period'), findsOneWidget);
  });
}
