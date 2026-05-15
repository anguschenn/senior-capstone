import '../core/config/supabase_client.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';

/// Loads and builds account filter options from Supabase.
class AccountService {
  const AccountService._();
  static const instance = AccountService._();

  String _nameForRow(Map<String, dynamic> row) {
    final rawName = (row['name'] as String?)?.trim() ?? '';
    return rawName.isNotEmpty ? rawName : 'Account';
  }

  String _endingForRow(String accountId, Map<String, dynamic> row) {
    final mask =
        ((row['last_four'] as String?) ?? (row['mask'] as String?) ?? '')
            .trim();
    if (mask.isNotEmpty) return mask;
    if (accountId.length >= 4) {
      return accountId.substring(accountId.length - 4);
    }
    return accountId;
  }

  String _groupKeyForRow(String accountId, Map<String, dynamic> row) {
    final name = _nameForRow(row).toLowerCase();
    final ending = _endingForRow(accountId, row).toLowerCase();
    final accountType = ('${row['account_type'] ?? ''}').toLowerCase().trim();
    final subtype = ('${row['subtype'] ?? ''}').toLowerCase().trim();
    return '$name|$ending|$accountType|$subtype';
  }

  double _balanceContributionForRow(Map<String, dynamic> row) {
    final raw = row['ledger_balance'] ?? row['current_balance'];
    final accountType = '${row['account_type'] ?? ''}';
    final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
    return netWorthContribution(balance: parsed, accountType: accountType);
  }

  DateTime? _updatedAtForRow(Map<String, dynamic> row) {
    final raw = row['updated_at'];
    if (raw is String && raw.trim().isNotEmpty) {
      return DateTime.tryParse(raw.trim());
    }
    return null;
  }

  bool _isRowPreferred({
    required Map<String, dynamic> candidate,
    required Map<String, dynamic>? current,
  }) {
    if (current == null) return true;

    final candidateUpdatedAt = _updatedAtForRow(candidate);
    final currentUpdatedAt = _updatedAtForRow(current);
    if (candidateUpdatedAt != null && currentUpdatedAt != null) {
      if (candidateUpdatedAt.isAfter(currentUpdatedAt)) return true;
      if (candidateUpdatedAt.isBefore(currentUpdatedAt)) return false;
    } else if (candidateUpdatedAt != null && currentUpdatedAt == null) {
      return true;
    } else if (candidateUpdatedAt == null && currentUpdatedAt != null) {
      return false;
    }

    // Fallback when timestamps are tied/missing: keep the larger absolute balance.
    return _balanceContributionForRow(candidate).abs() >
        _balanceContributionForRow(current).abs();
  }

  Future<List<Map<String, dynamic>>> fetchAccountRows(
    String userId, {
    bool unscoped = false,
  }) async {
    final rows = unscoped
        ? await AppSupabase.client
              .from('accounts')
              .select(
                'current_balance,available_balance,account_type,subtype,user_id,plaid_account_id,name,mask,updated_at',
              )
        : await AppSupabase.client
              .from('accounts')
              .select(
                'current_balance,available_balance,account_type,subtype,user_id,plaid_account_id,name,mask,updated_at',
              )
              .eq('user_id', userId);
    return (rows as List).whereType<Map<String, dynamic>>().toList();
  }

  double computeTotalBalance(List<Map<String, dynamic>> accountsRows) {
    final preferredRowByGroup = <String, Map<String, dynamic>>{};
    double total = 0;
    for (final row in accountsRows) {
      final accountId = (row['plaid_account_id'] as String?)?.trim() ?? '';
      if (accountId.isEmpty) continue;
      final groupKey = _groupKeyForRow(accountId, row);
      final current = preferredRowByGroup[groupKey];
      if (_isRowPreferred(candidate: row, current: current)) {
        preferredRowByGroup[groupKey] = row;
      }
    }
    for (final row in preferredRowByGroup.values) {
      total += _balanceContributionForRow(row);
    }
    return total;
  }

  List<AccountOption> buildAccountOptions(
    List<Map<String, dynamic>> accountsRows,
    Map<String, int> txCountByAccount,
  ) {
    final accountIdsByGroup = <String, Set<String>>{};
    final labelsByGroup = <String, String>{};
    final endingsByGroup = <String, String>{};
    final preferredRowByGroup = <String, Map<String, dynamic>>{};
    final txCountByGroup = <String, int>{};

    for (final row in accountsRows) {
      final accountId = (row['plaid_account_id'] as String?)?.trim() ?? '';
      if (accountId.isEmpty) continue;

      final groupKey = _groupKeyForRow(accountId, row);
      final name = _nameForRow(row);
      final ending = _endingForRow(accountId, row);

      accountIdsByGroup.putIfAbsent(groupKey, () => <String>{}).add(accountId);
      labelsByGroup.putIfAbsent(groupKey, () => '$name ••••$ending');
      endingsByGroup.putIfAbsent(groupKey, () => ending);
      final current = preferredRowByGroup[groupKey];
      if (_isRowPreferred(candidate: row, current: current)) {
        preferredRowByGroup[groupKey] = row;
      }

      txCountByGroup[groupKey] =
          (txCountByGroup[groupKey] ?? 0) + (txCountByAccount[accountId] ?? 0);
    }

    final accountOptions = <AccountOption>[];
    for (final entry in accountIdsByGroup.entries) {
      final groupKey = entry.key;
      final linkedIds = entry.value.toList()..sort();
      final preferredRow = preferredRowByGroup[groupKey];
      final preferredId =
          (preferredRow?['plaid_account_id'] as String?)?.trim() ??
          linkedIds.first;
      accountOptions.add(
        AccountOption(
          accountId: preferredId,
          label: labelsByGroup[groupKey]!,
          ending: endingsByGroup[groupKey]!,
          balance: preferredRow != null
              ? _balanceContributionForRow(preferredRow)
              : 0,
          txCount: txCountByGroup[groupKey] ?? 0,
          linkedAccountIds: linkedIds,
        ),
      );
    }

    accountOptions.sort((a, b) => a.label.compareTo(b.label));
    return accountOptions;
  }
}
