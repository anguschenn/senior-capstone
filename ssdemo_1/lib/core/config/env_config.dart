import 'package:flutter/foundation.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Typed access to environment variables loaded from .env at startup.
///
/// .env is bundled as an asset, so on the web anyone can download it from
/// assets/.env. It may only hold values the app has to ship anyway (the
/// Supabase URL and anon key, the backend URL and API key). Passwords go
/// elsewhere: see [autoLoginEmail].
class EnvConfig {
  EnvConfig._();

  static late final EnvConfig instance;

  /// Keys that must never be in .env, because .env ships in the web build.
  static const forbiddenBundledKeys = [
    'AUTO_LOGIN_EMAIL',
    'AUTO_LOGIN_PASSWORD',
  ];

  // Test sign-in for local debugging. Passed at launch, e.g.
  // flutter run --dart-define=AUTO_LOGIN_EMAIL=... --dart-define=AUTO_LOGIN_PASSWORD=...
  // Release builds compile these to '' so a password is never in the bundle.
  static const _autoLoginEmail = kDebugMode
      ? String.fromEnvironment('AUTO_LOGIN_EMAIL')
      : '';
  static const _autoLoginPassword = kDebugMode
      ? String.fromEnvironment('AUTO_LOGIN_PASSWORD')
      : '';

  static Future<void> load() async {
    await dotenv.load(fileName: '.env');
    rejectSecretsInBundledEnv(dotenv.env);
    final supabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
    final supabaseKey = dotenv.env['SUPABASE_KEY'] ?? '';
    final backendApiKey = dotenv.env['BACKEND_API_KEY'] ?? '';
    if (supabaseUrl.isEmpty || supabaseKey.isEmpty) {
      throw StateError(
        'Missing SUPABASE_URL or SUPABASE_KEY. Set them in ssdemo_1/.env.',
      );
    }
    if (backendApiKey.isEmpty) {
      throw StateError('Missing BACKEND_API_KEY. Set it in ssdemo_1/.env.');
    }
    instance = EnvConfig._()
      .._supabaseUrl = supabaseUrl
      .._supabaseKey = supabaseKey
      .._backendApiKey = backendApiKey
      .._backendUrl = dotenv.env['BACKEND_URL'] ?? 'http://127.0.0.1:8000';
  }

  /// Fails fast when .env holds a value that must not ship in the web build,
  /// so a filled-in test password is caught on the first run, not published.
  @visibleForTesting
  static void rejectSecretsInBundledEnv(Map<String, String> env) {
    final found = [
      for (final key in forbiddenBundledKeys)
        if ((env[key] ?? '').trim().isNotEmpty) key,
    ];
    if (found.isEmpty) return;
    throw StateError(
      '${found.join(', ')} must not be in ssdemo_1/.env: it ships inside the '
      'web build where anyone can download it. Remove it and pass it at '
      'launch instead, e.g. flutter run --dart-define=${found.first}=...',
    );
  }

  late final String _supabaseUrl;
  late final String _supabaseKey;
  late final String _backendApiKey;
  late final String _backendUrl;

  String get supabaseUrl => _supabaseUrl;
  String get supabaseKey => _supabaseKey;
  String get backendApiKey => _backendApiKey;
  String get backendUrl => _backendUrl;

  /// Test account signed in on launch, debug builds only (see above).
  String get autoLoginEmail => _autoLoginEmail.trim();
  String get autoLoginPassword => _autoLoginPassword;
  bool get hasAutoLoginCredentials =>
      autoLoginEmail.isNotEmpty && autoLoginPassword.isNotEmpty;
}
