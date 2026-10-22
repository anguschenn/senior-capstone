import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/core/config/env_config.dart';

void main() {
  group('EnvConfig.rejectSecretsInBundledEnv', () {
    test('accepts the public values the app has to ship', () {
      EnvConfig.rejectSecretsInBundledEnv({
        'SUPABASE_URL': 'https://example.supabase.co',
        'SUPABASE_KEY': 'anon-key',
        'BACKEND_URL': 'http://127.0.0.1:8002',
        'BACKEND_API_KEY': 'api-key',
        // Left empty, as in older .env files: nothing to leak.
        'AUTO_LOGIN_EMAIL': '',
        'AUTO_LOGIN_PASSWORD': '  ',
      });
    });

    test('rejects a test password left in .env', () {
      expect(
        () => EnvConfig.rejectSecretsInBundledEnv({
          'AUTO_LOGIN_EMAIL': 'me@example.com',
          'AUTO_LOGIN_PASSWORD': 'hunter2',
        }),
        throwsA(
          isA<StateError>().having(
            (e) => e.message,
            'message',
            allOf(
              contains('AUTO_LOGIN_EMAIL, AUTO_LOGIN_PASSWORD'),
              contains('--dart-define'),
            ),
          ),
        ),
      );
    });
  });
}
