import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/app/notification_destination.dart';

void main() {
  test('transaction review opens Wallet, where the review sheet is shown', () {
    expect(notificationTabIndexFor('transaction_review'), 0);
  });

  test('budget and subscription notifications open their matching tabs', () {
    expect(notificationTabIndexFor('budget'), 2);
    expect(notificationTabIndexFor('subscription_review'), 3);
  });

  test(
    'monthly reports and unknown notification kinds do not select a tab',
    () {
      expect(notificationTabIndexFor('monthly_report'), isNull);
      expect(notificationTabIndexFor('unknown'), isNull);
      expect(notificationTabIndexFor(null), isNull);
    },
  );
}
