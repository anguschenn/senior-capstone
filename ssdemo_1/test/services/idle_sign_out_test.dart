import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssdemo_1/services/idle_sign_out.dart';

void main() {
  final start = DateTime(2026, 11, 17, 9);

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('no record, or an hour unused, is idle', () {
    expect(isIdleTooLong(null, start), isTrue);
    expect(
      isIdleTooLong(start, start.add(const Duration(minutes: 59))),
      isFalse,
    );
    expect(
      isIdleTooLong(start, start.add(const Duration(minutes: 60))),
      isTrue,
    );
  });

  group('IdleSignOutGuard', () {
    late DateTime now;
    late int signOuts;

    Future<void> pumpGuard(WidgetTester tester) async {
      now = start;
      signOuts = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: IdleSignOutGuard(
            now: () => now,
            onIdle: () => signOuts++,
            child: const Scaffold(body: Center(child: Text('app'))),
          ),
        ),
      );
    }

    Future<void> wait(WidgetTester tester, int minutes) async {
      now = now.add(Duration(minutes: minutes));
      await tester.pump(Duration(minutes: minutes));
      await tester.pump();
    }

    testWidgets('signs out once after an hour without use', (tester) async {
      await pumpGuard(tester);
      await wait(tester, 59);
      expect(signOuts, 0);
      await wait(tester, 1);
      expect(signOuts, 1);
      await wait(tester, 5);
      expect(signOuts, 1);
    });

    testWidgets('taps keep the session going', (tester) async {
      await pumpGuard(tester);
      for (var i = 0; i < 3; i++) {
        await wait(tester, 40);
        await tester.tap(find.text('app'));
      }
      await wait(tester, 40);
      expect(signOuts, 0);
      await wait(tester, 20);
      expect(signOuts, 1);
    });

    testWidgets('a tap after the limit signs out instead of reviving', (
      tester,
    ) async {
      await pumpGuard(tester);
      // As in a background tab, where the minute timer may not have run.
      now = now.add(const Duration(minutes: 75));
      await tester.tap(find.text('app'));
      await tester.pump();
      expect(signOuts, 1);
    });

    testWidgets('use in another tab counts', (tester) async {
      await pumpGuard(tester);
      await wait(tester, 50);
      await IdleActivityStore.instance.save(now);
      await wait(tester, 20);
      expect(signOuts, 0);
      await wait(tester, 45);
      expect(signOuts, 1);
    });
  });
}
