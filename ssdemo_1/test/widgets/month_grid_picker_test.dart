import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/widgets/common/ui.dart';

// Returns the picker's result future boxed, so awaiting the open doesn't
// also wait for the pick.
Future<List<Future<DateTime?>>> _open(
  WidgetTester tester,
  List<DateTime> options,
  DateTime selected,
) async {
  late BuildContext ctx;
  {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) {
              ctx = context;
              return const SizedBox.expand();
            },
          ),
        ),
      ),
    );
    final result = showMonthGridPicker(
      context: ctx,
      options: options,
      selected: selected,
    );
    await tester.pumpAndSettle();
    return [result];
  }
}

void main() {
  final options = [
    DateTime(2026, 1, 2), // whole year
    for (var m = 2; m <= 10; m++) DateTime(2026, m, 1),
  ];

  testWidgets('one tap on a month picks it and closes', (tester) async {
    final [result] = await _open(tester, options, DateTime(2026, 10, 1));
    expect(find.text('OK'), findsNothing);
    expect(find.text('Cancel'), findsNothing);
    await tester.tap(find.text('Mar'));
    await tester.pumpAndSettle();
    expect(await result, DateTime(2026, 3, 1));
    expect(find.text('Mar'), findsNothing);
  });

  testWidgets('Whole year is one tap too', (tester) async {
    final [result] = await _open(tester, options, DateTime(2026, 10, 1));
    await tester.tap(find.text('Whole year'));
    await tester.pumpAndSettle();
    expect(await result, DateTime(2026, 1, 2));
  });

  testWidgets('a month without transactions cannot be picked', (tester) async {
    final [result] = await _open(tester, options, DateTime(2026, 10, 1));
    expect(find.text('Grey months have no transactions.'), findsOneWidget);
    await tester.tap(find.text('Jan'));
    await tester.pumpAndSettle();
    expect(find.text('Jan'), findsOneWidget); // still open
    await tester.tap(find.text('Feb'));
    await tester.pumpAndSettle();
    expect(await result, DateTime(2026, 2, 1));
  });
}
