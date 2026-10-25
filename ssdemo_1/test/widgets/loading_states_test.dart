import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/models/ai/ai_models.dart';
import 'package:ssdemo_1/widgets/budget/budget_ai_analysis_card.dart';
import 'package:ssdemo_1/widgets/common/ui.dart';

Widget _app(Widget child, {bool still = false}) => MaterialApp(
  home: Builder(
    builder: (context) => MediaQuery(
      data: MediaQuery.of(context).copyWith(disableAnimations: still),
      child: Scaffold(body: SingleChildScrollView(child: child)),
    ),
  ),
);

BudgetAiAnalysisCard _card({
  required bool loading,
  AiBudgetSuggestionResponse? suggestion,
}) => BudgetAiAnalysisCard(
  loading: loading,
  error: '',
  suggestion: suggestion,
  contextSource: '',
  highestCategoryText: 'Food (80%)',
  expensesLabel: 'Total monthly expenses',
  expensesValue: 420,
  canGenerate: true,
  onGenerate: () {},
);

const _answer = AiBudgetSuggestionResponse(
  copy: 'Food is running ahead of last month.',
  alerts: [],
  actions: [
    AiBudgetAction(
      category: 'Food',
      type: 'reduce',
      target: '',
      why: 'Cook at home twice more a week.',
    ),
  ],
  confidence: 'high',
  contextSource: '',
);

/// The TextButton around [label]; TextButton.icon builds a subclass.
Finder _button(String label) => find.ancestor(
  of: find.text(label),
  matching: find.byWidgetPredicate((w) => w is TextButton),
);

void main() {
  testWidgets('skeleton stays hidden for a quick load', (tester) async {
    await tester.pumpWidget(
      _app(
        const DelayedSkeleton(
          loading: true,
          skeleton: Text('skeleton'),
          child: Text('content'),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.text('skeleton'), findsNothing);
    expect(find.text('content'), findsOneWidget);

    await tester.pump(const Duration(milliseconds: 150));
    expect(find.text('skeleton'), findsOneWidget);

    // Done loading: the content takes the skeleton's place.
    await tester.pumpWidget(
      _app(
        const DelayedSkeleton(
          loading: false,
          skeleton: Text('skeleton'),
          child: Text('content'),
        ),
      ),
    );
    expect(find.text('skeleton'), findsNothing);
    expect(find.text('content'), findsOneWidget);
  });

  testWidgets('shimmer holds still when animations are off', (tester) async {
    await tester.pumpWidget(
      _app(const SkeletonShimmer(child: SkeletonBox(height: 12)), still: true),
    );
    // A running shimmer would never settle.
    await tester.pumpAndSettle();
    expect(tester.hasRunningAnimations, isFalse);
  });

  testWidgets('analysis card: Analyzing button, skeleton, then the answer', (
    tester,
  ) async {
    await tester.pumpWidget(_app(_card(loading: true)));

    final button = _button('Analyzing...');
    expect(button, findsOneWidget);
    expect(tester.widget<TextButton>(button).onPressed, isNull);
    expect(find.byType(SkeletonShimmer), findsNothing);

    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(SkeletonShimmer), findsOneWidget);

    await tester.pumpWidget(_app(_card(loading: false, suggestion: _answer)));
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(SkeletonShimmer), findsNothing);
    expect(find.text('Food is running ahead of last month.'), findsOneWidget);
    expect(_button('Generate again'), findsOneWidget);
  });
}
