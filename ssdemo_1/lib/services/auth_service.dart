import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/supabase_client.dart';

class SignUpResult {
  const SignUpResult({required this.requiresEmailConfirmation});

  final bool requiresEmailConfirmation;
}

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
      throw StateError('No authenticated Supabase user.');
    }
    return id;
  }

  Future<void> signIn({required String email, required String password}) async {
    await _auth.signInWithPassword(email: email.trim(), password: password);
    await ensurePublicUserRecord();
  }

  Future<SignUpResult> signUp({
    required String email,
    required String password,
  }) async {
    final response = await _auth.signUp(
      email: email.trim(),
      password: password,
    );
    await ensurePublicUserRecord();
    return SignUpResult(requiresEmailConfirmation: response.session == null);
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
