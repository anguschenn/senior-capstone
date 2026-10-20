import '../core/config/supabase_client.dart';

/// A suggested monthly limit the backend wrote after a sync
/// (python/user_model.py, table budget_suggestions in migration 014).
class BudgetSuggestion {
  const BudgetSuggestion({
    required this.id,
    required this.budgetId,
    required this.category,
    required this.currentLimit,
    required this.suggestedLimit,
    required this.months,
    this.monthsOver = 0,
  });

  final String id;
  final String budgetId;
  final String category;
  final double currentLimit;
  final double suggestedLimit;

  /// The months ('YYYY-MM') the suggestion was averaged over.
  final List<String> months;

  /// How many of [months] ended over that month's limit.
  final int monthsOver;

  static BudgetSuggestion? fromRow(Map<String, dynamic> row) {
    final id = (row['id'] as String?) ?? '';
    final budgetId = (row['budget_id'] as String?) ?? '';
    final suggested = double.tryParse('${row['suggested_limit']}');
    if (id.isEmpty || budgetId.isEmpty || suggested == null) return null;
    final basis = row['basis'];
    final months = basis is Map && basis['months'] is List
        ? (basis['months'] as List).map((m) => '$m').toList()
        : const <String>[];
    final monthsOver = basis is Map ? basis['months_over'] : null;
    return BudgetSuggestion(
      id: id,
      budgetId: budgetId,
      category: (row['category'] as String?) ?? 'Budget',
      currentLimit: double.tryParse('${row['current_limit']}') ?? 0,
      suggestedLimit: suggested,
      months: months,
      monthsOver: monthsOver is num ? monthsOver.toInt() : 0,
    );
  }
}

/// Reads pending suggestions and records the user's decision. Changing the
/// budget itself stays with the caller (onUpdateBudgetLimit), so the limit
/// only ever changes through the existing budget path.
class BudgetSuggestionService {
  const BudgetSuggestionService._();
  static const instance = BudgetSuggestionService._();

  static const _table = 'budget_suggestions';

  /// Pending suggestions for [month] ('YYYY-MM'). Empty on any error, e.g.
  /// before migration 014 is applied.
  Future<List<BudgetSuggestion>> pending(String userId, String month) async {
    try {
      final rows = await AppSupabase.client
          .from(_table)
          .select(
            'id,budget_id,category,current_limit,suggested_limit,basis,status',
          )
          .eq('user_id', userId)
          .eq('month', month)
          .eq('status', 'pending')
          .order('category');
      return (rows as List)
          .whereType<Map<String, dynamic>>()
          .map(BudgetSuggestion.fromRow)
          .whereType<BudgetSuggestion>()
          .toList();
    } catch (_) {
      return const <BudgetSuggestion>[];
    }
  }

  /// [status] is accepted, edited or dismissed.
  Future<void> decide(String id, String status, {double? decidedLimit}) async {
    await AppSupabase.client
        .from(_table)
        .update({
          'status': status,
          'decided_limit': decidedLimit,
          'decided_at': DateTime.now().toUtc().toIso8601String(),
        })
        .eq('id', id);
  }
}
