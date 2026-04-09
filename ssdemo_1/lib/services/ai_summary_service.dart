import '../constants/app_constants.dart';
import '../models/app_models.dart';

/// Builds the compact spending snapshot sent to the AI chat endpoint.
class AiSummaryService {
  const AiSummaryService._();
  static const instance = AiSummaryService._();

  Map<String, dynamic> build({
    required List<AppTransaction> transactions,
    required List<BudgetCategoryProgress> budgetProgress,
    required DashboardStats stats,
    required String selectedAccountId,
  }) {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 30));
    double income30d = 0;
    double expenses30d = 0;
    int txCount30d = 0;
    int expenseTxCount30d = 0;
    final categoryTotals = <String, double>{};
    final recent = <Map<String, dynamic>>[];

    for (final tx in transactions) {
      if (tx.date.isBefore(cutoff)) continue;
      txCount30d += 1;
      if (tx.amount < 0) {
        income30d += tx.amount.abs();
      } else {
        expenses30d += tx.amount;
        expenseTxCount30d += 1;
        categoryTotals[tx.category] =
            (categoryTotals[tx.category] ?? 0) + tx.amount;
      }
    }

    for (final tx in transactions.take(3)) {
      recent.add({
        'date': tx.date.toIso8601String().split('T').first,
        'name': tx.name,
        'amount': tx.amount,
        'category': tx.category,
      });
    }

    final topCategories = categoryTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topCategoryPayload = topCategories
        .take(5)
        .map((entry) => {'category': entry.key, 'amount': entry.value})
        .toList();

    final budgetAlerts = budgetProgress
        .where((b) => b.ratio >= 1)
        .take(3)
        .map((b) => {
              'category': b.title,
              'spent': b.spent,
              'limit': b.limit,
              'ratio': b.ratio,
            })
        .toList();

    final annualYear = now.year;
    double annualIncome = 0;
    double annualExpenses = 0;
    int annualExpenseTxCount = 0;
    final monthlyBreakdown = <String, Map<String, double>>{};
    final annualCategoryTotals = <String, double>{};
    final annualExpensesOnly = <AppTransaction>[];

    for (var m = 1; m <= 12; m++) {
      final key = '$annualYear-${m.toString().padLeft(2, '0')}';
      monthlyBreakdown[key] = {'income': 0, 'expenses': 0};
    }

    for (final tx in transactions) {
      if (tx.date.year != annualYear) continue;
      final monthKey = '${tx.date.year}-${tx.date.month.toString().padLeft(2, '0')}';
      final bucket = monthlyBreakdown[monthKey];
      if (tx.amount < 0) {
        final income = tx.amount.abs();
        annualIncome += income;
        if (bucket != null) {
          bucket['income'] = (bucket['income'] ?? 0) + income;
        }
      } else {
        annualExpenses += tx.amount;
        annualExpenseTxCount += 1;
        annualCategoryTotals[tx.category] =
            (annualCategoryTotals[tx.category] ?? 0) + tx.amount;
        annualExpensesOnly.add(tx);
        if (bucket != null) {
          bucket['expenses'] = (bucket['expenses'] ?? 0) + tx.amount;
        }
      }
    }

    final annualTopCategories = annualCategoryTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final anomalies = <Map<String, dynamic>>[];
    if (annualExpensesOnly.isNotEmpty) {
      final rankedExpenses = [...annualExpensesOnly]
        ..sort((a, b) => b.amount.compareTo(a.amount));
      for (final tx in rankedExpenses.take(5)) {
        anomalies.add({
          'date': tx.date.toIso8601String().split('T').first,
          'name': tx.name,
          'amount': tx.amount,
          'category': tx.category,
        });
      }
    }

    return {
      'version': 1,
      'generated_at': now.toIso8601String(),
      'scope': selectedAccountId == kAllAccountsId
          ? 'all_accounts'
          : 'single_account',
      'window_days': 30,
      'totals': {
        'income_30d': income30d,
        'expenses_30d': expenses30d,
        'net_30d': income30d - expenses30d,
        'tx_count_30d': txCount30d,
        'expense_tx_count_30d': expenseTxCount30d,
        'income_month': stats.monthlyIncome,
        'expenses_month': stats.monthlyExpenses,
        'net_month': stats.netThisMonth,
      },
      'top_expense_categories': topCategoryPayload,
      'recent_transactions': recent,
      'budget_alerts': budgetAlerts,
      'annual_summary': {
        'year': annualYear,
        'totals': {
          'income_year': annualIncome,
          'expenses_year': annualExpenses,
          'net_year': annualIncome - annualExpenses,
          'expense_tx_count_year': annualExpenseTxCount,
        },
        'monthly_breakdown': monthlyBreakdown.entries
            .map((entry) => {
                  'month': entry.key,
                  'income': entry.value['income'] ?? 0,
                  'expenses': entry.value['expenses'] ?? 0,
                })
            .toList(),
        'top_expense_categories_year': annualTopCategories
            .take(10)
            .map((entry) => {'category': entry.key, 'amount': entry.value})
            .toList(),
        'anomalies_top': anomalies,
      },
    };
  }
}
