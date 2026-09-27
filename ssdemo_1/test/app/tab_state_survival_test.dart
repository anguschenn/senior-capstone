import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// A page with its own local State, standing in for e.g. BudgetPage's
/// `_aiSuggestion` / `_manualBudgetOrder`, or a page's scroll position.
///
/// Two distinct classes (below), not one class reused with a different
/// label: that matters. main_screen.dart's tabs are distinct widget types
/// (HomePage, CashFlowPage, ...), so Flutter's reconciliation (canUpdate:
/// same runtimeType + key) never treats switching between them as updating
/// one element in place — it is always a real dispose-and-rebuild under the
/// old switch expression. Reusing one class for both tabs here would let
/// Flutter update the existing element instead, masking the exact bug this
/// test exists to catch.
abstract class _CounterPageState<T extends StatefulWidget> extends State<T> {
  int _count = 0;
  String get label;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Text('$label: $_count'),
        ElevatedButton(
          onPressed: () => setState(() => _count++),
          child: Text('bump $label'),
        ),
      ],
    );
  }
}

class _CounterPageA extends StatefulWidget {
  const _CounterPageA();
  @override
  State<_CounterPageA> createState() => _CounterPageAState();
}

class _CounterPageAState extends _CounterPageState<_CounterPageA> {
  @override
  String get label => 'A';
}

class _CounterPageB extends StatefulWidget {
  const _CounterPageB();
  @override
  State<_CounterPageB> createState() => _CounterPageBState();
}

class _CounterPageBState extends _CounterPageState<_CounterPageB> {
  @override
  String get label => 'B';
}

/// The OLD pattern main_screen.dart used: a switch expression builds only the
/// active tab's widget. Switching away destroys it; switching back builds a
/// brand new one, so any local State is gone.
class _SwitchTabHost extends StatefulWidget {
  const _SwitchTabHost();
  @override
  State<_SwitchTabHost> createState() => _SwitchTabHostState();
}

class _SwitchTabHostState extends State<_SwitchTabHost> {
  int index = 0;
  @override
  Widget build(BuildContext context) {
    final body = switch (index) {
      0 => const _CounterPageA(),
      _ => const _CounterPageB(),
    };
    return Scaffold(
      body: body,
      bottomNavigationBar: Row(
        children: [
          TextButton(
            onPressed: () => setState(() => index = 0),
            child: const Text('tab A'),
          ),
          TextButton(
            onPressed: () => setState(() => index = 1),
            child: const Text('tab B'),
          ),
        ],
      ),
    );
  }
}

/// The NEW pattern: all tabs are built up front and kept alive in an
/// IndexedStack; only which one is visible changes. This is the exact change
/// made to main_screen.dart.
class _IndexedStackTabHost extends StatefulWidget {
  const _IndexedStackTabHost();
  @override
  State<_IndexedStackTabHost> createState() => _IndexedStackTabHostState();
}

class _IndexedStackTabHostState extends State<_IndexedStackTabHost> {
  int index = 0;
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: const [_CounterPageA(), _CounterPageB()],
      ),
      bottomNavigationBar: Row(
        children: [
          TextButton(
            onPressed: () => setState(() => index = 0),
            child: const Text('tab A'),
          ),
          TextButton(
            onPressed: () => setState(() => index = 1),
            child: const Text('tab B'),
          ),
        ],
      ),
    );
  }
}

void main() {
  testWidgets(
    'OLD pattern (switch expression): switching tabs resets local state',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _SwitchTabHost()));

      await tester.tap(find.text('bump A'));
      await tester.pump();
      expect(find.text('A: 1'), findsOneWidget);

      await tester.tap(find.text('tab B'));
      await tester.pump();
      await tester.tap(find.text('tab A'));
      await tester.pump();

      // The old A instance was destroyed when we switched to B; this is a
      // brand new one, back at 0. This is the bug the milestone calls out.
      expect(find.text('A: 0'), findsOneWidget);
    },
  );

  testWidgets(
    'NEW pattern (IndexedStack): switching tabs preserves local state',
    (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _IndexedStackTabHost()));

      await tester.tap(find.text('bump A'));
      await tester.pump();
      expect(find.text('A: 1'), findsOneWidget);

      await tester.tap(find.text('tab B'));
      await tester.pump();
      // A never left the tree — it's merely not the visible child — so its
      // count is still 1, not reset. Bump B too, to show both survive
      // independently.
      await tester.tap(find.text('bump B'));
      await tester.pump();

      await tester.tap(find.text('tab A'));
      await tester.pump();
      expect(find.text('A: 1'), findsOneWidget);

      await tester.tap(find.text('tab B'));
      await tester.pump();
      expect(find.text('B: 1'), findsOneWidget);
    },
  );
}
