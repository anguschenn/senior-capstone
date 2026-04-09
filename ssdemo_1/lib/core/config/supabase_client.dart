import 'package:supabase_flutter/supabase_flutter.dart';

import 'env_config.dart';

/// Initializes and exposes the shared Supabase client.
class AppSupabase {
  AppSupabase._();

  static Future<void> init() async {
    final env = EnvConfig.instance;
    await Supabase.initialize(
      url: env.supabaseUrl,
      anonKey: env.supabaseKey,
    );
  }

  static SupabaseClient get client => Supabase.instance.client;
}
