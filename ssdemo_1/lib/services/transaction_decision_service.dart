import '../core/config/supabase_client.dart';
import '../models/app_models.dart';

/// Reads and writes the user's per-transaction choices
/// (transaction_decisions, migration 017): a category for one transaction,
/// the purchase a friend's payment pays back, and how much of a purchase
/// others will pay back.
class TransactionDecisionService {
  const TransactionDecisionService._();
  static const instance = TransactionDecisionService._();

  /// plaid_transaction_id -> row. Empty when the table isn't there yet.
  Future<Map<String, Map<String, dynamic>>> fetchRows(String userId) async {
    try {
      final rows = await AppSupabase.client
          .from('transaction_decisions')
          .select(
            'plaid_transaction_id,category,paid_back_purchase_id,shared_amount',
          )
          .eq('user_id', userId);
      final out = <String, Map<String, dynamic>>{};
      for (final row in (rows as List).whereType<Map<String, dynamic>>()) {
        final id = ((row['plaid_transaction_id'] as String?) ?? '').trim();
        if (id.isEmpty) continue;
        out[id] = {
          'category': row['category'],
          'paid_back_purchase_id': row['paid_back_purchase_id'],
          'shared_amount': row['shared_amount'],
        };
      }
      return out;
    } catch (_) {
      return const {};
    }
  }

  /// Saves [decision] for [txId]; an empty one removes the row. False when
  /// the write failed.
  Future<bool> save({
    required String userId,
    required String txId,
    required TxDecision decision,
  }) async {
    if (txId.trim().isEmpty) return false;
    try {
      if (decision.isEmpty) {
        await AppSupabase.client
            .from('transaction_decisions')
            .delete()
            .eq('user_id', userId)
            .eq('plaid_transaction_id', txId);
      } else {
        await AppSupabase.client.from('transaction_decisions').upsert({
          'user_id': userId,
          'plaid_transaction_id': txId,
          ...decision.toRow(),
          'updated_at': DateTime.now().toUtc().toIso8601String(),
        }, onConflict: 'user_id,plaid_transaction_id');
      }
      return true;
    } catch (_) {
      return false;
    }
  }
}
