import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/widgets/common/ui.dart';

double _scale(WidgetTester tester) =>
    tester.widget<AnimatedScale>(find.byType(AnimatedScale)).scale;

Widget _app(Widget child) => MaterialApp(
  home: Scaffold(body: Center(child: child)),
);

void main() {
  testWidgets('grows on hover, shrinks while pressed, and still taps', (
    tester,
  ) async {
    var taps = 0;
    await tester.pumpWidget(
      _app(
        Pressable(
          child: GestureDetector(
            onTap: () => taps++,
            child: const SizedBox(width: 80, height: 40, child: Text('Go')),
          ),
        ),
      ),
    );
    expect(_scale(tester), 1.0);

    final mouse = await tester.createGesture(kind: PointerDeviceKind.mouse);
    await mouse.addPointer(location: Offset.zero);
    addTearDown(mouse.removePointer);
    await mouse.moveTo(tester.getCenter(find.text('Go')));
    await tester.pump();
    expect(_scale(tester), 1.04);

    await mouse.down(tester.getCenter(find.text('Go')));
    await tester.pump();
    expect(_scale(tester), 0.95);

    await mouse.up();
    await tester.pumpAndSettle();
    expect(_scale(tester), 1.04);
    expect(taps, 1);
  });

  testWidgets('a disabled control gets no feedback', (tester) async {
    await tester.pumpWidget(
      _app(const Pressable(enabled: false, child: Text('Off'))),
    );
    expect(find.byType(AnimatedScale), findsNothing);
  });
}
