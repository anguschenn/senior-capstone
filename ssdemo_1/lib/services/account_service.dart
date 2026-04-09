import '../core/config/supabase_client.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';

/// Loads and builds account filter options from Supabase.
class AccountService {
  const AccountService._();
  static const instance = AccountService._();

  Future<List<Map<String, dynamic>>> fetchAccountRows(String userId) async {
    final rows = await AppSupabase.client
        .from('accounts')
        .select(
          'current_balance,account_type,subtype,user_id,plaid_account_id,name,mask',
        )
        .eq('user_id', userId);
    return (rows as List).whereType<Map<String, dynamic>>().toList();
  }

  double computeTotalBalance(List<Map<String, dynamic>> accountsRows) {
    double total = 0;
    for (final row in accountsRows) {
      final raw = row['current_balance'];
      final accountType = '${row['account_type'] ?? ''}';
      final parsed =
          raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
      total += netWorthContribution(balance: parsed, accountType: accountType);
    }
    return total;
  }

  List<AccountOption> buildAccountOptions(
    List<Map<String, dynamic>> accountsRows,
    Map<String, int> txCountByAccount,
  ) {
    final accountOptions = <AccountOption>[];
    final seenAccountIds = <String>{};
    for (final row in accountsRows) {
      final plaidAccountId =
          (row['plaid_account_id'] as String?)?.trim() ?? '';
      if (plaidAccountId.isEmpty || !seenAccountIds.add(plaidAccountId)) {
        continue;
      }
      final name =
          ((row['name'] as String?)?.trim().isNotEmpty ?? false)
              ? (row['name'] as String).trim()
              : 'Account';
      final mask = (row['mask'] as String?)?.trim() ?? '';
      final ending = mask.isNotEmpty
          ? mask
          : (plaidAccountId.length >= 4
                ? plaidAccountId.substring(plaidAccountId.length - 4)
                : plaidAccountId);
      accountOptions.add(
        AccountOption(
          accountId: plaidAccountId,
          label: '$name ••••$ending',
          ending: ending,
          balance: (() {
            final raw = row['current_balance'];
            final accountType = '${row['account_type'] ?? ''}';
            final parsed =
                raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
            return netWorthContribution(
              balance: parsed,
              accountType: accountType,
            );
          })(),
          txCount: txCountByAccount[plaidAccountId] ?? 0,
        ),
      );
    }
    final optionsWithTx =
        accountOptions.where((a) => a.txCount > 0).toList();
    final effective =
        optionsWithTx.isNotEmpty ? optionsWithTx : accountOptions;
    effective.sort((a, b) => a.label.compareTo(b.label));
    return effective;
  }
}
