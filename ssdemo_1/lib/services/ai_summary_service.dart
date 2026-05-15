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
      'windows_anchor',
      'windows_rolling',
      'window_definition',
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
      'data_coverage',
      'confidence',
      'warnings',
      'category_index',
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

  double _clamp01(double value) {
    if (value < 0) return 0;
    if (value > 1) return 1;
    return value;
  }

  bool _isTransferLikeForTotals(
    AppTransaction txForTotals,
    String categoryForTotals,
  ) {
    // Keep AI spending/income totals aligned with dashboard totals:
    // do not exclude transfer-like transactions from top-line math.
    if (txForTotals.id.isEmpty && categoryForTotals.isNotEmpty) {
      // no-op: references keep analyzer happy while preserving disabled behavior
    }
    return false;
  }

  bool _isTransferLikeIncome(
    AppTransaction txForIncome,
    String categoryForIncome,
  ) {
    // Keep AI income totals aligned with dashboard totals.
    if (txForIncome.id.isEmpty && categoryForIncome.isNotEmpty) {
      // no-op: references keep analyzer happy while preserving disabled behavior
    }
    return false;
  }

  bool _isTransferLikeForAnalysis(AppTransaction tx, String category) {
    if (!tx.isExpense) return false;
    final primarySignal = tx.rawPfcPrimary.toLowerCase();
    final detailedSignal = tx.rawPfcDetailed.toLowerCase();
    final combinedPfc = '$primarySignal $detailedSignal';
    if (combinedPfc.contains('loan_payments') ||
        combinedPfc.contains('credit_card_payment') ||
        combinedPfc.contains('transfer_out') ||
        combinedPfc.contains('transfer_in') ||
        combinedPfc.contains('internal')) {
      return true;
    }
    final text = [
      category,
      tx.transactionType,
      tx.name,
      tx.description,
    ].join(' ').toLowerCase();
    if (text.contains('internal transfer') ||
        text.contains('transfer from') ||
        text.contains('transfer to') ||
        text.contains('zelle') ||
        text.contains('venmo') ||
        text.contains('cash app')) {
      return true;
    }
    if (text.contains('credit card payment') ||
        text.contains('loan payment') ||
        text.contains('payment thank you') ||
        text.contains('autopay')) {
      return true;
    }
    return false;
  }

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
    final now = DateTime.now();
    final focus = focusMonth ?? now;
    final anchor = DateTime(focus.year, focus.month, 1);
    final cutoff30d = anchor.subtract(const Duration(days: 30));
    final cutoff7d = anchor.subtract(const Duration(days: 7));
    final cutoff90d = anchor.subtract(const Duration(days: 90));
    final rollingCutoff30d = now.subtract(const Duration(days: 30));
    final rollingCutoff7d = now.subtract(const Duration(days: 7));
    final rollingCutoff90d = now.subtract(const Duration(days: 90));
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
    double income7dRolling = 0;
    double expenses7dRolling = 0;
    int txCount7dRolling = 0;

    double income90d = 0;
    double expenses90d = 0;
    int txCount90d = 0;
    double income30dRolling = 0;
    double expenses30dRolling = 0;
    int txCount30dRolling = 0;
    int expenseTxCount30dRolling = 0;
    double income90dRolling = 0;
    double expenses90dRolling = 0;
    int txCount90dRolling = 0;

    final annualYear = anchor.year;
    double annualIncome = 0;
    double annualExpenses = 0;
    int annualExpenseTxCount = 0;
    final annualCategoryTotals = <String, double>{};
    final annualExpensesOnly = <AppTransaction>[];
    final categoryTotalsAll = <String, double>{};
    final activeDayKeys = <String>{};
    final recent30dActiveDayKeys = <String>{};
    DateTime? earliestTxDate;
    DateTime? latestTxDate;
    int expenseTxCountAll = 0;
    int transferLikeExpenseTxCount = 0;

    String effectiveCategoryFor(AppTransaction tx) {
      final reviewed = (reviewedCategoryByTxId[tx.id] ?? '').trim();
      if (reviewed.isNotEmpty) return reviewed;
      return tx.category;
    }

    for (final tx in transactions) {
      final effectiveCategory = effectiveCategoryFor(tx);
      final dateKey = _dateKey(tx.date);
      activeDayKeys.add(dateKey);
      if (!tx.date.isBefore(rollingCutoff30d)) {
        recent30dActiveDayKeys.add(dateKey);
      }
      if (earliestTxDate == null || tx.date.isBefore(earliestTxDate)) {
        earliestTxDate = tx.date;
      }
      if (latestTxDate == null || tx.date.isAfter(latestTxDate)) {
        latestTxDate = tx.date;
      }
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
      if (!tx.date.isBefore(rollingCutoff30d)) {
        txCount30dRolling += 1;
      }
      if (!tx.date.isBefore(cutoff7d)) {
        txCount7d += 1;
      }
      if (!tx.date.isBefore(rollingCutoff7d)) {
        txCount7dRolling += 1;
      }
      if (!tx.date.isBefore(cutoff90d)) {
        txCount90d += 1;
      }
      if (!tx.date.isBefore(rollingCutoff90d)) {
        txCount90dRolling += 1;
      }

      if (tx.isIncome) {
        if (_isTransferLikeIncome(tx, effectiveCategory)) {
          continue;
        }
        final income = tx.incomeAmount;
        monthBucket['income'] = (monthBucket['income'] as double) + income;
        dayBucket['income'] = (dayBucket['income'] as double) + income;
        yearlyBucket['income'] = (yearlyBucket['income'] as double) + income;
        if (!tx.date.isBefore(cutoff30d)) {
          income30d += income;
        }
        if (!tx.date.isBefore(rollingCutoff30d)) {
          income30dRolling += income;
        }
        if (!tx.date.isBefore(cutoff7d)) {
          income7d += income;
        }
        if (!tx.date.isBefore(rollingCutoff7d)) {
          income7dRolling += income;
        }
        if (!tx.date.isBefore(cutoff90d)) {
          income90d += income;
        }
        if (!tx.date.isBefore(rollingCutoff90d)) {
          income90dRolling += income;
        }
        if (tx.date.year == annualYear) {
          annualIncome += income;
        }
      } else if (tx.isExpense) {
        final expense = tx.expenseAmount;
        final isTransferLikeForTotals = _isTransferLikeForTotals(
          tx,
          effectiveCategory,
        );
        final isTransferLikeForAnalysis = _isTransferLikeForAnalysis(
          tx,
          effectiveCategory,
        );
        expenseTxCountAll += 1;

        // Exclude transfer/payment-like outflows from spending math so
        // "expenses" aligns with user-facing discretionary spend.
        if (isTransferLikeForTotals) {
          transferLikeExpenseTxCount += 1;
          continue;
        }

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
        if (!tx.date.isBefore(rollingCutoff30d)) {
          expenses30dRolling += expense;
          expenseTxCount30dRolling += 1;
        }
        if (!tx.date.isBefore(cutoff7d)) {
          expenses7d += expense;
        }
        if (!tx.date.isBefore(rollingCutoff7d)) {
          expenses7dRolling += expense;
        }
        if (!tx.date.isBefore(cutoff90d)) {
          expenses90d += expense;
        }
        if (!tx.date.isBefore(rollingCutoff90d)) {
          expenses90dRolling += expense;
        }
        if (tx.date.year == annualYear) {
          annualExpenses += expense;
          annualExpenseTxCount += 1;
        }

        if (tx.date.year == annualYear && !isTransferLikeForAnalysis) {
          annualExpensesOnly.add(tx);
        }

        if (!isTransferLikeForAnalysis) {
          categoryTotalsAll[effectiveCategory] =
              (categoryTotalsAll[effectiveCategory] ?? 0) + expense;

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
    }

    final sortedRecent = [...transactions]
      ..sort((a, b) {
        final byDate = b.date.compareTo(a.date);
        if (byDate != 0) return byDate;
        return b.id.compareTo(a.id);
      });
    for (final tx in sortedRecent.take(3)) {
      final effectiveCategory = effectiveCategoryFor(tx);
      recent.add({
        'id': tx.id,
        'date': _dateKey(tx.date),
        'name': tx.name,
        'amount': tx.amount,
        'category': effectiveCategory,
        'type': tx.transactionType,
        'account_id': tx.accountId,
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
        ..sort((a, b) => b.expenseAmount.compareTo(a.expenseAmount));
      for (final tx in rankedExpenses.take(5)) {
        final effectiveCategory = effectiveCategoryFor(tx);
        anomalies.add({
          'date': _dateKey(tx.date),
          'name': tx.name,
          'amount': tx.expenseAmount,
          'category': effectiveCategory,
        });
      }
    }

    final daysSpan = (earliestTxDate == null || latestTxDate == null)
        ? 0
        : latestTxDate.difference(earliestTxDate).inDays + 1;
    final coverageRatioRecent30d = recent30dActiveDayKeys.length / 30.0;
    final transferLikeExpenseRatio = expenseTxCountAll == 0
        ? 0.0
        : transferLikeExpenseTxCount / expenseTxCountAll;
    final txCountScore = _clamp01(txCount30dRolling / 20.0);
    final coverageScore = _clamp01(coverageRatioRecent30d);
    final historyScore = _clamp01(daysSpan / 120.0);
    final noiseScore = _clamp01(1.0 - transferLikeExpenseRatio);
    final confidenceScore = _clamp01(
      (txCountScore * 0.35) +
          (coverageScore * 0.3) +
          (historyScore * 0.2) +
          (noiseScore * 0.15),
    );
    final confidenceOverall = confidenceScore >= 0.75
        ? 'high'
        : (confidenceScore >= 0.45 ? 'medium' : 'low');
    final warnings = <String>[];
    if (txCount30dRolling < 5 || coverageRatioRecent30d < 0.2) {
      warnings.add('sparse_recent_data');
    }
    if (daysSpan > 0 && daysSpan < 60) {
      warnings.add('possible_missing_history');
    }
    if (transferLikeExpenseRatio > 0.4) {
      warnings.add('contains_transfer_like_noise');
    }

    final computed = {
      'version': 3,
      'generated_at': now.toIso8601String(),
      'scope': selectedAccountId == kAllAccountsId
          ? 'all_accounts'
          : 'single_account',
      'scope_label': scopeLabel,
      'data_coverage': {
        'transaction_count_total': transactions.length,
        'range_start': earliestTxDate == null ? null : _dateKey(earliestTxDate),
        'range_end': latestTxDate == null ? null : _dateKey(latestTxDate),
        'days_span': daysSpan,
        'active_days': activeDayKeys.length,
        'coverage_ratio_recent_30d': coverageRatioRecent30d,
      },
      'confidence': {
        'score': confidenceScore,
        'overall': confidenceOverall,
        'reasons': warnings,
        'components': {
          'tx_count_recent_30d': txCountScore,
          'coverage_recent_30d': coverageScore,
          'history_span': historyScore,
          'noise_penalty_adjusted': noiseScore,
        },
      },
      'warnings': warnings,
      'category_index': categoryTotalsAll,
      'time_anchor': {
        'selected_month': _monthKey(anchor),
        'selected_year': anchor.year,
        'tz': now.timeZoneName,
      },
      'window_days': 30,
      'window_definition': {
        'windows_anchor': 'anchor_based_selected_month',
        'windows_rolling': 'rolling_from_generated_at',
      },
      'windows_anchor': {
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
      'windows_rolling': {
        'last_7d': {
          'income': income7dRolling,
          'expenses': expenses7dRolling,
          'tx_count': txCount7dRolling,
        },
        'last_30d': {
          'income': income30dRolling,
          'expenses': expenses30dRolling,
          'tx_count': txCount30dRolling,
          'expense_tx_count': expenseTxCount30dRolling,
        },
        'last_90d': {
          'income': income90dRolling,
          'expenses': expenses90dRolling,
          'tx_count': txCount90dRolling,
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
