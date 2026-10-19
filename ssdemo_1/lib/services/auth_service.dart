import 'package:supabase_flutter/supabase_flutter.dart';

import '../core/config/supabase_client.dart';
import 'chat_history_store.dart';
import 'sync_cache.dart';

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
  }

  Future<SignUpResult> signUp({
    required String email,
    required String password,
  }) async {
    final response = await _auth.signUp(
      email: email.trim(),
      password: password,
    );

    return SignUpResult(requiresEmailConfirmation: response.session == null);
  }

  Future<void> signOut() async {
    // Saved sync data and chats are financial data; don't leave them on the device.
    await SyncCache.instance.clear();
    await ChatHistoryStore.instance.clear();
    await _auth.signOut();
  }

  Future<void> resetPasswordForEmail(String email) async {
    await _auth.resetPasswordForEmail(email.trim());
  }
}
