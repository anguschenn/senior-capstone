import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/env_config.dart';
import '../core/config/supabase_client.dart';

class AuthService {
  const AuthService._();
  static const instance = AuthService._();

  GoTrueClient get _auth => AppSupabase.client.auth;

  Stream<AuthState> get authStateChanges => _auth.onAuthStateChange;

  User? get currentUser => _auth.currentUser;

  String? get currentAccessToken => _auth.currentSession?.accessToken;

  String get currentUserId {
    final id = currentUser?.id;
    if (id == null || id.isEmpty) {
      if (EnvConfig.instance.skipAuth &&
          EnvConfig.instance.demoUserId.trim().isNotEmpty) {
        return EnvConfig.instance.demoUserId.trim();
      }
      throw StateError('No authenticated Supabase user.');
    }
    return id;
  }

  Future<void> signIn({required String email, required String password}) async {
    await _auth.signInWithPassword(email: email.trim(), password: password);
    await ensurePublicUserRecord();
  }

  Future<void> signUp({required String email, required String password}) async {
    await _auth.signUp(email: email.trim(), password: password);
    await ensurePublicUserRecord();
  }

  Future<void> signOut() => _auth.signOut();

  Future<void> ensurePublicUserRecord() async {
    final user = currentUser;
    if (user == null) return;
    final email = user.email?.trim();
    try {
      await AppSupabase.client.from('users').upsert({
        'id': user.id,
        'email': email,
        'name': email,
      }, onConflict: 'id');
    } catch (_) {}
  }
}
