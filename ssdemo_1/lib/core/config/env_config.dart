import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Typed access to environment variables loaded from .env at startup.
class EnvConfig {
  EnvConfig._();
  static const bool _forceSkipAuthForNow = false;

  static late final EnvConfig instance;

  static Future<void> load() async {
    await dotenv.load(fileName: '.env');
    final supabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
    final supabaseKey = dotenv.env['SUPABASE_KEY'] ?? '';
    final backendApiKey = dotenv.env['BACKEND_API_KEY'] ?? '';
    final demoUserId = dotenv.env['DEMO_USER_ID'] ?? '';
    final autoLoginEmail = dotenv.env['AUTO_LOGIN_EMAIL'] ?? '';
    final autoLoginPassword = dotenv.env['AUTO_LOGIN_PASSWORD'] ?? '';
    final devUnscopedReads =
        (dotenv.env['DEV_UNSCOPED_READS'] ?? 'false').toLowerCase() == 'true';
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
      .._backendUrl = dotenv.env['BACKEND_URL'] ?? 'http://127.0.0.1:8000'
      .._skipAuth = (dotenv.env['SKIP_AUTH'] ?? 'false').toLowerCase() == 'true'
      .._demoUserId = demoUserId
      .._autoLoginEmail = autoLoginEmail.trim()
      .._autoLoginPassword = autoLoginPassword
      .._devUnscopedReads = devUnscopedReads;
  }

  late final String _supabaseUrl;
  late final String _supabaseKey;
  late final String _backendApiKey;
  late final String _backendUrl;
  late final bool _skipAuth;
  late final String _demoUserId;
  late final String _autoLoginEmail;
  late final String _autoLoginPassword;
  late final bool _devUnscopedReads;

  String get supabaseUrl => _supabaseUrl;
  String get supabaseKey => _supabaseKey;
  String get backendApiKey => _backendApiKey;
  String get backendUrl => _backendUrl;
  bool get skipAuth => _forceSkipAuthForNow || _skipAuth;
  String get demoUserId => _demoUserId;
  String get autoLoginEmail => _autoLoginEmail;
  String get autoLoginPassword => _autoLoginPassword;
  bool get hasAutoLoginCredentials =>
      _autoLoginEmail.isNotEmpty && _autoLoginPassword.isNotEmpty;
  bool get devUnscopedReads => _devUnscopedReads;
}
