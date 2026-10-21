import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/models/app_models.dart';

DetectedSubscription _sub(DateTime next, String frequency) =>
    DetectedSubscription(
      id: 's',
      merchant: 'Spotify',
      amount: 21.99,
      nextChargeDate: next,
      frequency: frequency,
    );

void main() {
  test('a past monthly renewal rolls forward on the same day', () {
    final sub = _sub(DateTime(2026, 9, 18), 'monthly');
    expect(
      sub.nextChargeDateAfter(DateTime(2026, 10, 21)),
      DateTime(2026, 11, 18),
    );
  });

  test('a renewal due today stays today', () {
    final sub = _sub(DateTime(2026, 10, 21), 'monthly');
    expect(
      sub.nextChargeDateAfter(DateTime(2026, 10, 21, 15)),
      DateTime(2026, 10, 21),
    );
  });

  test('day 31 clamps to a short month and comes back', () {
    final sub = _sub(DateTime(2027, 1, 31), 'monthly');
    expect(
      sub.nextChargeDateAfter(DateTime(2027, 2, 1)),
      DateTime(2027, 2, 28),
    );
    expect(
      sub.nextChargeDateAfter(DateTime(2027, 3, 1)),
      DateTime(2027, 3, 31),
    );
  });

  test('weekly and annual roll forward', () {
    expect(
      _sub(
        DateTime(2026, 10, 1),
        'weekly',
      ).nextChargeDateAfter(DateTime(2026, 10, 21)),
      DateTime(2026, 10, 22),
    );
    expect(
      _sub(
        DateTime(2025, 10, 18),
        'annual',
      ).nextChargeDateAfter(DateTime(2026, 10, 21)),
      DateTime(2027, 10, 18),
    );
  });
}
