import 'app_models.dart';

/// One day on the monthly cumulative-spend curve.
class BudgetPacePoint {
  const BudgetPacePoint({
    required this.day,
    required this.cumulativeSpent,
  });

  /// 1-based day of the focus month.
  final int day;
  final double cumulativeSpent;
}

/// Monthly budget-remaining + burn-pace snapshot for the Copilot-style chart.
class BudgetPaceSnapshot {
  const BudgetPaceSnapshot({
    required this.totalBudgeted,
    required this.spentToDate,
    required this.daysElapsed,
    required this.daysInMonth,
    required this.cumulativePoints,
    required this.projectedEom,
  });

  final double totalBudgeted;
  final double spentToDate;
  final int daysElapsed;
  final int daysInMonth;
  final List<BudgetPacePoint> cumulativePoints;
  final double projectedEom;

  bool get hasBudget => totalBudgeted > 0 && totalBudgeted.isFinite;

  /// Remaining budget; negative means overspent.
  double get remaining => totalBudgeted - spentToDate;

  bool get isOverBudget => remaining < 0;

  /// Linear expected spend by [daysElapsed]: budget * day / daysInMonth.
  double get expectedByToday {
    if (!hasBudget || daysInMonth <= 0) return 0;
    final value = totalBudgeted * daysElapsed / daysInMonth;
    return value.isFinite ? value : 0;
  }

  /// Positive => under pace; negative => over pace.
  double get paceDelta => expectedByToday - spentToDate;

  bool get isUnderPace => paceDelta >= 0;

  /// Build from month budgets + expense transactions in [focusMonth].
  static BudgetPaceSnapshot build({
    required DateTime focusMonth,
    required List<BudgetCategoryProgress> budgets,
    required List<AppTransaction> transactions,
    DateTime? now,
  }) {
    final clock = now ?? DateTime.now();
    final year = focusMonth.year;
    final month = focusMonth.month;
    final dim = BudgetCategoryProgress.daysInMonth(year, month);

    final totalBudgeted = budgets.fold<double>(
      0,
      (sum, b) => sum + (b.limit.isFinite && b.limit > 0 ? b.limit : 0),
    );

    final elapsed = _daysElapsed(
      year: year,
      month: month,
      daysInMonth: dim,
      now: clock,
    );

    final daily = List<double>.filled(dim + 1, 0);
    for (final tx in transactions) {
      if (tx.date.year != year || tx.date.month != month) continue;
      if (!tx.isExpense) continue;
      final day = tx.date.day.clamp(1, dim);
      daily[day] += tx.expenseAmount;
    }

    final points = <BudgetPacePoint>[];
    var running = 0.0;
    for (var d = 1; d <= elapsed; d++) {
      running += daily[d];
      points.add(BudgetPacePoint(day: d, cumulativeSpent: running));
    }

    final spentToDate = points.isEmpty ? 0.0 : points.last.cumulativeSpent;
    final projectedEom = elapsed <= 0
        ? spentToDate
        : (spentToDate / elapsed) * dim;
    final safeProjected =
        projectedEom.isFinite ? projectedEom : spentToDate;

    return BudgetPaceSnapshot(
      totalBudgeted: totalBudgeted.isFinite ? totalBudgeted : 0,
      spentToDate: spentToDate.isFinite ? spentToDate : 0,
      daysElapsed: elapsed,
      daysInMonth: dim,
      cumulativePoints: points,
      projectedEom: safeProjected,
    );
  }

  static int _daysElapsed({
    required int year,
    required int month,
    required int daysInMonth,
    required DateTime now,
  }) {
    if (year < now.year || (year == now.year && month < now.month)) {
      return daysInMonth;
    }
    if (year == now.year && month == now.month) {
      return now.day.clamp(1, daysInMonth);
    }
    // Future month: no real spend yet; keep a single point at day 1.
    return 1;
  }
}
