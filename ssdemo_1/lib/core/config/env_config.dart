import 'package:flutter_dotenv/flutter_dotenv.dart';

/// Typed access to environment variables loaded from .env at startup.
class EnvConfig {
  EnvConfig._();

  static late final EnvConfig instance;

  static Future<void> load() async {
    await dotenv.load(fileName: '.env');
    final supabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
    final supabaseKey = dotenv.env['SUPABASE_KEY'] ?? '';
    final backendApiKey = dotenv.env['BACKEND_API_KEY'] ?? '';
    final autoLoginEmail = dotenv.env['AUTO_LOGIN_EMAIL'] ?? '';
    final autoLoginPassword = dotenv.env['AUTO_LOGIN_PASSWORD'] ?? '';
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
      .._autoLoginEmail = autoLoginEmail.trim()
      .._autoLoginPassword = autoLoginPassword;
  }

  late final String _supabaseUrl;
  late final String _supabaseKey;
  late final String _backendApiKey;
  late final String _backendUrl;
  late final String _autoLoginEmail;
  late final String _autoLoginPassword;

  String get supabaseUrl => _supabaseUrl;
  String get supabaseKey => _supabaseKey;
  String get backendApiKey => _backendApiKey;
  String get backendUrl => _backendUrl;
  String get autoLoginEmail => _autoLoginEmail;
  String get autoLoginPassword => _autoLoginPassword;
  bool get hasAutoLoginCredentials =>
      _autoLoginEmail.isNotEmpty && _autoLoginPassword.isNotEmpty;
}
