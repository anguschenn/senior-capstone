import 'package:shared_preferences/shared_preferences.dart';

import '../core/config/supabase_client.dart';

/// Accounts the user hid (swipe in Settings), by Plaid account id. Kept in
/// accounts.hidden so the backend leaves them out too, with a copy on this
/// device. Hiding only removes an account from view and totals; nothing is
/// deleted.
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

  /// Null when the read fails (offline, or the column isn't there yet).
  Future<Set<String>?> loadFromServer(String userId) async {
    try {
      final rows = await AppSupabase.client
          .from('accounts')
          .select('plaid_account_id')
          .eq('user_id', userId)
          .eq('hidden', true);
      return {
        for (final row in (rows as List).whereType<Map<String, dynamic>>())
          if ((row['plaid_account_id'] as String?)?.trim().isNotEmpty ?? false)
            (row['plaid_account_id'] as String).trim(),
      };
    } catch (_) {
      return null;
    }
  }

  Future<void> saveToServer(
    String userId,
    Set<String> plaidAccountIds,
    bool hidden,
  ) async {
    if (plaidAccountIds.isEmpty) return;
    try {
      await AppSupabase.client
          .from('accounts')
          .update({'hidden': hidden})
          .eq('user_id', userId)
          .inFilter('plaid_account_id', plaidAccountIds.toList());
    } catch (_) {
      // Best effort: the app still hides it; the backend catches up next time.
    }
  }
}
