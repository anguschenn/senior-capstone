import 'package:shared_preferences/shared_preferences.dart';

/// Accounts the user hid (swipe in Settings), kept on this device per user.
/// Hiding only removes an account from view and totals; nothing is deleted.
class HiddenAccountsStore {
  const HiddenAccountsStore._();
  static const instance = HiddenAccountsStore._();

  String _key(String userId) => 'hidden_accounts_v1_$userId';

  Future<Set<String>> load(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      return (prefs.getStringList(_key(userId)) ?? const <String>[]).toSet();
    } catch (_) {
      return <String>{};
    }
  }

  Future<void> save(String userId, Set<String> accountIds) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList(_key(userId), accountIds.toList()..sort());
    } catch (_) {
      // Best effort: the account stays hidden for this session.
    }
  }
}
