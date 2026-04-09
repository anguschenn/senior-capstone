import '../core/config/supabase_client.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';

/// Manages category fetching, budget-bucket mapping, and review overrides.
class CategoryService {
  const CategoryService._();
  static const instance = CategoryService._();

  Future<List<CategoryOption>> ensureBaseCategories(String userId) async {
    try {
      final rows = await AppSupabase.client
          .from('categories')
          .select('id,name,user_id')
          .or('user_id.eq.$userId,user_id.is.null');
      return (rows as List)
          .whereType<Map<String, dynamic>>()
          .map((r) => CategoryOption(id: '${r['id']}', name: '${r['name']}'))
          .where((c) => c.id.isNotEmpty && c.name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Resolves a transaction into a budget bucket, preferring manual overrides.
  String budgetBucketFor(
    AppTransaction tx,
    Map<String, String> reviewedCategoryByTxId,
  ) {
    final reviewed = reviewedCategoryByTxId[tx.id];
    if (reviewed != null && reviewed.isNotEmpty) return reviewed;
    return budgetCategoryFromPfc(
      pfcDetailed: tx.category,
      pfcPrimary: tx.primaryCategory,
    );
  }

  /// Same mapping but for raw Supabase rows before model conversion.
  String budgetBucketForRawTransaction(
    Map<String, dynamic> row,
    Map<String, String> reviewedCategoryByTxId,
  ) {
    final txId = ((row['plaid_transaction_id'] as String?) ?? '').trim();
    final reviewed = reviewedCategoryByTxId[txId];
    if (reviewed != null && reviewed.isNotEmpty) return reviewed;
    return budgetCategoryFromPfc(
      pfcDetailed: ((row['pfc_detailed'] as String?) ?? '').trim(),
      pfcPrimary: ((row['pfc_primary'] as String?) ?? '').trim(),
    );
  }
}
