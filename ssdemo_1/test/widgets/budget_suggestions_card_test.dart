import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/services/budget_suggestion_service.dart';
import 'package:ssdemo_1/widgets/budget/budget_suggestions_card.dart';

class _FakeService implements BudgetSuggestionService {
  _FakeService(this.items);

  final List<BudgetSuggestion> items;
  final decisions = <String>[];

  @override
  Future<List<BudgetSuggestion>> pending(String userId, String month) async =>
      items;

  @override
  Future<void> decide(String id, String status, {double? decidedLimit}) async {
    decisions.add('$id:$status:$decidedLimit');
  }
}

BudgetSuggestion _food() => BudgetSuggestion.fromRow({
  'id': 's1',
  'budget_id': 'b-food',
  'category': 'Food',
  'current_limit': 300,
  'suggested_limit': '240.00',
  'basis': {
    'months': ['2026-04', '2026-05', '2026-06'],
  },
})!;

Future<List<String>> _pump(WidgetTester tester, _FakeService service) async {
  final updates = <String>[];
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: BudgetSuggestionsCard(
          month: DateTime(2026, 10),
          userId: 'u1',
          service: service,
          onUpdateBudgetLimit: (budgetId, limit) async =>
              updates.add('$budgetId:$limit'),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return updates;
}

void main() {
  testWidgets('accept changes the budget, then records the decision', (
    tester,
  ) async {
    final service = _FakeService([_food()]);
    final updates = await _pump(tester, service);
    expect(find.text('Food: \$300.00 → \$240.00'), findsOneWidget);
    expect(find.text('From 3 months of spending'), findsOneWidget);

    await tester.tap(find.text('Accept'));
    await tester.pumpAndSettle();
    expect(updates, ['b-food:240.0']);
    expect(service.decisions, ['s1:accepted:240.0']);
    expect(find.text('Suggested limits'), findsNothing);
  });

  testWidgets('dismiss leaves the budget alone', (tester) async {
    final service = _FakeService([_food()]);
    final updates = await _pump(tester, service);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(updates, isEmpty);
    expect(service.decisions, ['s1:dismissed:null']);
  });

  testWidgets('edit saves the typed limit', (tester) async {
    final service = _FakeService([_food()]);
    final updates = await _pump(tester, service);
    await tester.tap(find.text('Edit'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '260');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(updates, ['b-food:260.0']);
    expect(service.decisions, ['s1:edited:260.0']);
  });

  testWidgets('nothing pending renders nothing', (tester) async {
    await _pump(tester, _FakeService(const []));
    expect(find.text('Suggested limits'), findsNothing);
  });

  test('malformed rows are skipped', () {
    expect(BudgetSuggestion.fromRow({'id': 's1'}), isNull);
  });
}
