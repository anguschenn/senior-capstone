import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/services/sync_service.dart';

void main() {
  group('bankSyncFromResponse', () {
    test('one expired bank among synced ones still asks for a login', () {
      final bank = bankSyncFromResponse(
        200,
        '{"sync": {"added": 1}, "login_required_items": ["item-1"]}',
      );
      expect(bank.synced, isTrue);
      expect(bank.loginRequired, isTrue);
    });

    test('no expired bank', () {
      final bank = bankSyncFromResponse(200, '{"login_required_items": []}');
      expect(bank.synced, isTrue);
      expect(bank.loginRequired, isFalse);
    });

    test('a reply from an older backend without the list', () {
      final bank = bankSyncFromResponse(200, '{"sync": {}}');
      expect(bank.loginRequired, isFalse);
    });

    test('every bank expired throws', () {
      expect(
        () =>
            bankSyncFromResponse(400, '{"error_code": "ITEM_LOGIN_REQUIRED"}'),
        throwsA(isA<ItemLoginRequiredException>()),
      );
    });

    test('another Plaid error is just a failed sync', () {
      final bank = bankSyncFromResponse(400, '{"error_code": "PLAID_ERROR"}');
      expect(bank.synced, isFalse);
      expect(bank.loginRequired, isFalse);
    });
  });
}
