import '../core/config/supabase_client.dart';

/// A finished month that ended over a budget limit (table budget_alerts,
/// written by the backend after each sync, python/user_model.py).
class BudgetOverrun {
  const BudgetOverrun({
    required this.month,
    required this.category,
    required this.spent,
    required this.limit,
  });

  /// 'YYYY-MM'.
  final String month;
  final String category;
  final double spent;
  final double limit;

  double get overBy => spent - limit;

  static BudgetOverrun? fromRow(Map<String, dynamic> row) {
    final month = (row['month'] as String?) ?? '';
    final category = (row['category'] as String?) ?? '';
    final spent = double.tryParse('${row['spent']}');
    final limit = double.tryParse('${row['limit_amount']}');
    if (month.isEmpty || category.isEmpty || spent == null || limit == null) {
      return null;
    }
    return BudgetOverrun(
      month: month,
      category: category,
      spent: spent,
      limit: limit,
    );
  }
}

class BudgetAlertService {
  const BudgetAlertService._();
  static const instance = BudgetAlertService._();

  /// Month-end overruns for the finished months from [fromMonth] up to, not
  /// including, [beforeMonth] ('YYYY-MM'), newest first. Empty on any error.
  Future<List<BudgetOverrun>> history(
    String userId, {
    required String fromMonth,
    required String beforeMonth,
  }) async {
    try {
      final rows = await AppSupabase.client
          .from('budget_alerts')
          .select('month,category,spent,limit_amount')
          .eq('user_id', userId)
          .eq('kind', 'over_budget')
          .isFilter('resolved_at', null)
          .gte('month', fromMonth)
          .lt('month', beforeMonth)
          .order('month', ascending: false)
          .order('category');
      return (rows as List)
          .whereType<Map<String, dynamic>>()
          .map(BudgetOverrun.fromRow)
          .whereType<BudgetOverrun>()
          .toList();
    } catch (_) {
      return const <BudgetOverrun>[];
    }
  }
}
