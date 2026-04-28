import '../constants/app_constants.dart';
import '../models/app_models.dart';

/// Builds the compact spending snapshot sent to the AI chat endpoint.
class AiSummaryService {
  const AiSummaryService._();
  static const instance = AiSummaryService._();

  T? _asTyped<T>(dynamic value) => value is T ? value : null;

  Map<String, dynamic> _mergeWithPrecomputed(
    Map<String, dynamic> computed,
    Map<String, dynamic>? precomputed,
  ) {
    if (precomputed == null || precomputed.isEmpty) return computed;
    final merged = Map<String, dynamic>.from(computed);

    // Prefer frontend pre-aggregated blocks when available.
    for (final key in [
      'totals',
      'windows',
      'year_index',
      'month_index',
      'day_index_recent',
      'month_day_index',
      'rankings',
      'top_expense_categories',
      'recent_transactions',
      'budget_alerts',
      'annual_summary',
      'time_anchor',
    ]) {
      final value = precomputed[key];
      if (value != null) {
        merged[key] = value;
      }
    }

    // Prefer metadata overrides if caller explicitly provides them.
    for (final key in [
      'version',
      'generated_at',
      'scope',
      'scope_label',
      'window_days',
    ]) {
      final value = precomputed[key];
      if (value != null) {
        merged[key] = value;
      }
    }

    return merged;
  }

  bool _isTransferLikeCategory(String category) {
    final text = category.toLowerCase();
    return text.contains('transfer') ||
        text.contains('internal') ||
        text.contains('payment');
  }

  Map<String, dynamic> _emptyMonthBucket() => {
    'income': 0.0,
    'expenses': 0.0,
    'tx_count': 0,
    'expense_tx_count': 0,
  };

  Map<String, dynamic> _emptyDayBucket() => {
    'income': 0.0,
    'expenses': 0.0,
    'tx_count': 0,
  };

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  String _dateKey(DateTime date) => date.toIso8601String().split('T').first;

  Map<String, dynamic> build({
    required List<AppTransaction> transactions,
    required List<BudgetCategoryProgress> budgetProgress,
    required DashboardStats stats,
    required String selectedAccountId,
    required String scopeLabel,
    Map<String, dynamic>? precomputedSummary,
    Map<String, String> reviewedCategoryByTxId = const <String, String>{},
    DateTime? focusMonth,
  }) {
    final anchor = DateTime(
      (focusMonth ?? DateTime.now()).year,
      (focusMonth ?? DateTime.now()).month,
      1,
    );
    final now = DateTime.now();
    final cutoff30d = anchor.subtract(const Duration(days: 30));
    final cutoff7d = anchor.subtract(const Duration(days: 7));
    final cutoff90d = anchor.subtract(const Duration(days: 90));
    final cutoffRecentDays = anchor.subtract(const Duration(days: 120));

    double income30d = 0;
    double expenses30d = 0;
    int txCount30d = 0;
    int expenseTxCount30d = 0;
    final categoryTotals30d = <String, double>{};
    final recent = <Map<String, dynamic>>[];

    final monthTotals = <String, Map<String, dynamic>>{};
    final monthCategoryTotals = <String, Map<String, double>>{};
    final dayTotals = <String, Map<String, dynamic>>{};
    final yearTotals = <int, Map<String, dynamic>>{};

    double income7d = 0;
    double expenses7d = 0;
    int txCount7d = 0;

    double income90d = 0;
    double expenses90d = 0;
    int txCount90d = 0;

    final annualYear = anchor.year;
    double annualIncome = 0;
    double annualExpenses = 0;
    int annualExpenseTxCount = 0;
    final annualCategoryTotals = <String, double>{};
    final annualExpensesOnly = <AppTransaction>[];

    String effectiveCategoryFor(AppTransaction tx) {
      final reviewed = (reviewedCategoryByTxId[tx.id] ?? '').trim();
      if (reviewed.isNotEmpty) return reviewed;
      return tx.category;
    }

    for (final tx in transactions) {
      final effectiveCategory = effectiveCategoryFor(tx);
      final dateKey = _dateKey(tx.date);
      final monthKey = _monthKey(tx.date);
      final monthBucket = monthTotals.putIfAbsent(
        monthKey,
        () => _emptyMonthBucket(),
      );
      final dayBucket = dayTotals.putIfAbsent(dateKey, () => _emptyDayBucket());
      final yearlyBucket = yearTotals.putIfAbsent(
        tx.date.year,
        () => {'income': 0.0, 'expenses': 0.0, 'tx_count': 0},
      );
      monthBucket['tx_count'] = (monthBucket['tx_count'] as int) + 1;
      dayBucket['tx_count'] = (dayBucket['tx_count'] as int) + 1;
      yearlyBucket['tx_count'] = (yearlyBucket['tx_count'] as int) + 1;

      if (!tx.date.isBefore(cutoff30d)) {
        txCount30d += 1;
      }
      if (!tx.date.isBefore(cutoff7d)) {
        txCount7d += 1;
      }
      if (!tx.date.isBefore(cutoff90d)) {
        txCount90d += 1;
      }

      if (tx.isIncome) {
        final income = tx.incomeAmount;
        monthBucket['income'] = (monthBucket['income'] as double) + income;
        dayBucket['income'] = (dayBucket['income'] as double) + income;
        yearlyBucket['income'] = (yearlyBucket['income'] as double) + income;
        if (!tx.date.isBefore(cutoff30d)) {
          income30d += income;
        }
        if (!tx.date.isBefore(cutoff7d)) {
          income7d += income;
        }
        if (!tx.date.isBefore(cutoff90d)) {
          income90d += income;
        }
        if (tx.date.year == annualYear) {
          annualIncome += income;
        }
      } else if (tx.isExpense) {
        final expense = tx.expenseAmount;
        monthBucket['expenses'] = (monthBucket['expenses'] as double) + expense;
        monthBucket['expense_tx_count'] =
            (monthBucket['expense_tx_count'] as int) + 1;
        dayBucket['expenses'] = (dayBucket['expenses'] as double) + expense;
        yearlyBucket['expenses'] =
            (yearlyBucket['expenses'] as double) + expense;

        if (!tx.date.isBefore(cutoff30d)) {
          expenses30d += expense;
          expenseTxCount30d += 1;
        }
        if (!tx.date.isBefore(cutoff7d)) {
          expenses7d += expense;
        }
        if (!tx.date.isBefore(cutoff90d)) {
          expenses90d += expense;
        }
        if (tx.date.year == annualYear) {
          annualExpenses += expense;
          annualExpenseTxCount += 1;
          annualExpensesOnly.add(tx);
        }

        if (_isTransferLikeCategory(effectiveCategory)) continue;

        final monthCategoryBucket = monthCategoryTotals.putIfAbsent(
          monthKey,
          () => <String, double>{},
        );
        monthCategoryBucket[effectiveCategory] =
            (monthCategoryBucket[effectiveCategory] ?? 0) + expense;

        if (!tx.date.isBefore(cutoff30d)) {
          categoryTotals30d[effectiveCategory] =
              (categoryTotals30d[effectiveCategory] ?? 0) + expense;
        }
        if (tx.date.year == annualYear) {
          annualCategoryTotals[effectiveCategory] =
              (annualCategoryTotals[effectiveCategory] ?? 0) + expense;
        }
      }
    }

    for (final tx in transactions.take(3)) {
      final effectiveCategory = effectiveCategoryFor(tx);
      recent.add({
        'date': _dateKey(tx.date),
        'name': tx.name,
        'amount': tx.amount,
        'category': effectiveCategory,
      });
    }

    final topCategories30d = categoryTotals30d.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topCategoryPayload = topCategories30d
        .take(5)
        .map((entry) => {'category': entry.key, 'amount': entry.value})
        .toList();

    final budgetAlerts = budgetProgress
        .where((b) => b.ratio >= 1)
        .take(3)
        .map(
          (b) => {
            'category': b.title,
            'spent': b.spent,
            'limit': b.limit,
            'ratio': b.ratio,
          },
        )
        .toList();

    final annualTopCategories = annualCategoryTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));

    final monthKeysSorted = monthTotals.keys.toList()..sort();
    final recentMonthKeys = monthKeysSorted.length > 36
        ? monthKeysSorted.sublist(monthKeysSorted.length - 36)
        : monthKeysSorted;

    final monthIndex = <String, Map<String, dynamic>>{};
    for (final month in recentMonthKeys) {
      final bucket = monthTotals[month] ?? _emptyMonthBucket();
      final catMap = monthCategoryTotals[month] ?? const <String, double>{};
      final ranked = catMap.entries.toList()
        ..sort((a, b) => b.value.compareTo(a.value));
      final top = ranked.isNotEmpty ? ranked.first : null;
      monthIndex[month] = {
        'income': bucket['income'],
        'expenses': bucket['expenses'],
        'tx_count': bucket['tx_count'],
        'expense_tx_count': bucket['expense_tx_count'],
        'top_category': top == null
            ? null
            : {'name': top.key, 'amount': top.value},
      };
    }

    final dayKeysSorted = dayTotals.keys.toList()..sort();
    final dayIndexRecent = <String, Map<String, dynamic>>{};
    for (final day in dayKeysSorted) {
      final parsed = DateTime.tryParse(day);
      if (parsed == null || parsed.isBefore(cutoffRecentDays)) continue;
      dayIndexRecent[day] = {
        'income': dayTotals[day]!['income'],
        'expenses': dayTotals[day]!['expenses'],
        'tx_count': dayTotals[day]!['tx_count'],
      };
    }

    final monthDayIndex = <String, List<Map<String, dynamic>>>{};
    for (final month in recentMonthKeys.reversed.take(6)) {
      final days = dayKeysSorted
          .where((d) => d.startsWith('$month-'))
          .map(
            (d) => {
              'date': d,
              'income': dayTotals[d]!['income'],
              'expenses': dayTotals[d]!['expenses'],
              'tx_count': dayTotals[d]!['tx_count'],
            },
          )
          .toList();
      monthDayIndex[month] = days;
    }

    final yearIndex = <String, Map<String, dynamic>>{};
    final years = yearTotals.keys.toList()..sort();
    for (final y in years) {
      final b = yearTotals[y]!;
      yearIndex['$y'] = {
        'income': b['income'],
        'expenses': b['expenses'],
        'tx_count': b['tx_count'],
      };
    }

    final highestSpendingMonths =
        monthIndex.entries
            .map(
              (e) => {
                'month': e.key,
                'expenses': ((e.value['expenses'] as num?) ?? 0).toDouble(),
              },
            )
            .toList()
          ..sort(
            (a, b) =>
                (b['expenses'] as double).compareTo(a['expenses'] as double),
          );

    final highestSpendingDaysRecent =
        dayIndexRecent.entries
            .map(
              (e) => {
                'date': e.key,
                'expenses': ((e.value['expenses'] as num?) ?? 0).toDouble(),
              },
            )
            .toList()
          ..sort(
            (a, b) =>
                (b['expenses'] as double).compareTo(a['expenses'] as double),
          );

    final monthlyExpenseRanking =
        monthIndex.entries
            .where((e) => e.key.startsWith('$annualYear-'))
            .map(
              (entry) => {
                'month': entry.key,
                'expenses': ((entry.value['expenses'] as num?) ?? 0).toDouble(),
              },
            )
            .toList()
          ..sort(
            (a, b) =>
                (b['expenses'] as double).compareTo(a['expenses'] as double),
          );

    final monthlyExpenseTrend = <Map<String, dynamic>>[];
    final monthlyRows =
        monthIndex.entries
            .where((e) => e.key.startsWith('$annualYear-'))
            .map(
              (entry) => {
                'month': entry.key,
                'expenses': ((entry.value['expenses'] as num?) ?? 0).toDouble(),
              },
            )
            .toList()
          ..sort(
            (a, b) => (a['month'] as String).compareTo(b['month'] as String),
          );
    double? prevMonthExpenses;
    for (final row in monthlyRows) {
      final currentExpenses = row['expenses'] as double;
      double? momChangePct;
      if (prevMonthExpenses != null && prevMonthExpenses > 0) {
        momChangePct =
            (currentExpenses - prevMonthExpenses) / prevMonthExpenses;
      }
      monthlyExpenseTrend.add({
        'month': row['month'],
        'expenses': currentExpenses,
        'mom_change_pct': momChangePct,
      });
      prevMonthExpenses = currentExpenses;
    }

    final monthlyTopCategories = monthIndex.entries
        .where((e) => e.key.startsWith('$annualYear-'))
        .map((entry) {
          final top = entry.value['top_category'];
          if (top is! Map) return null;
          return {
            'month': entry.key,
            'category': '${top['name'] ?? ''}',
            'amount': ((top['amount'] as num?) ?? 0).toDouble(),
          };
        })
        .whereType<Map<String, dynamic>>()
        .toList();

    final dailyExpensePayload = dayKeysSorted
        .where((d) => d.startsWith('$annualYear-'))
        .map((d) => {'date': d, 'amount': dayTotals[d]!['expenses']})
        .toList();

    final anomalies = <Map<String, dynamic>>[];
    if (annualExpensesOnly.isNotEmpty) {
      final rankedExpenses = [...annualExpensesOnly]
        ..sort((a, b) => b.amount.compareTo(a.amount));
      for (final tx in rankedExpenses.take(5)) {
        final effectiveCategory = effectiveCategoryFor(tx);
        anomalies.add({
          'date': _dateKey(tx.date),
          'name': tx.name,
          'amount': tx.amount,
          'category': effectiveCategory,
        });
      }
    }

    final computed = {
      'version': 2,
      'generated_at': now.toIso8601String(),
      'scope': selectedAccountId == kAllAccountsId
          ? 'all_accounts'
          : 'single_account',
      'scope_label': scopeLabel,
      'time_anchor': {
        'selected_month': _monthKey(anchor),
        'selected_year': anchor.year,
        // This is the exact month total already shown in frontend cards.
        'selected_month_expenses': stats.monthlyExpenses,
        'selected_month_income': stats.monthlyIncome,
        'tz': now.timeZoneName,
      },
      'window_days': 30,
      'windows': {
        'last_7d': {
          'income': income7d,
          'expenses': expenses7d,
          'tx_count': txCount7d,
        },
        'last_30d': {
          'income': income30d,
          'expenses': expenses30d,
          'tx_count': txCount30d,
          'expense_tx_count': expenseTxCount30d,
        },
        'last_90d': {
          'income': income90d,
          'expenses': expenses90d,
          'tx_count': txCount90d,
        },
      },
      'year_index': yearIndex,
      'month_index': monthIndex,
      'day_index_recent': dayIndexRecent,
      'month_day_index': monthDayIndex,
      'rankings': {
        'highest_spending_months': highestSpendingMonths.take(12).toList(),
        'highest_spending_days_recent': highestSpendingDaysRecent
            .take(10)
            .toList(),
      },

      // Backward-compatible fields used by existing backend logic.
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
        'monthly_breakdown': monthIndex.entries
            .where((e) => e.key.startsWith('$annualYear-'))
            .map(
              (entry) => {
                'month': entry.key,
                'income': ((entry.value['income'] as num?) ?? 0).toDouble(),
                'expenses': ((entry.value['expenses'] as num?) ?? 0).toDouble(),
              },
            )
            .toList(),
        'top_expense_categories_year': annualTopCategories
            .take(10)
            .map((entry) => {'category': entry.key, 'amount': entry.value})
            .toList(),
        'monthly_expense_ranking': monthlyExpenseRanking,
        'monthly_expense_trend': monthlyExpenseTrend,
        'monthly_top_categories': monthlyTopCategories,
        'daily_expense_totals': dailyExpensePayload,
        'anomalies_top': anomalies,
      },
    };
    return _mergeWithPrecomputed(
      computed,
      _asTyped<Map<String, dynamic>>(precomputedSummary),
    );
  }
}
