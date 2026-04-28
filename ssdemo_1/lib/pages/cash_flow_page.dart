import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import '../widgets/dashboard_widgets.dart';

class CashFlowPage extends StatefulWidget {
  const CashFlowPage({
    super.key,
    required this.transactions,
    required this.selectedMonth,
    required this.monthOptions,
    required this.onMonthChanged,
  });

  final List<AppTransaction> transactions;
  final DateTime selectedMonth;
  final List<DateTime> monthOptions;
  final ValueChanged<DateTime> onMonthChanged;

  @override
  State<CashFlowPage> createState() => _CashFlowPageState();
}

class _CashFlowPageState extends State<CashFlowPage> {
  // Controls which time range feeds the chart and summary calculations.
  FlowViewMode viewMode = FlowViewMode.month;
  DateTimeRange? customRange;

  List<int> get _yearOptions {
    final years = <int>{DateTime.now().year, _focusMonth.year};
    for (final tx in widget.transactions) {
      years.add(tx.date.year);
    }
    final sorted = years.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  List<DateTime> get _monthOnlyOptions {
    final seen = <String>{};
    final out = <DateTime>[];
    for (final m in widget.monthOptions) {
      if (isAllYearOption(m)) continue;
      final n = normalizedMonthOption(m);
      final key = '${n.year}-${n.month}';
      if (seen.add(key)) out.add(n);
    }
    return out;
  }

  DateTime get _focusMonth => normalizedMonthOption(widget.selectedMonth);
  String get _rangeLabel {
    if (viewMode == FlowViewMode.month) {
      return periodLabelForSelection(_focusMonth);
    }
    if (viewMode == FlowViewMode.year) return '${_focusMonth.year}';
    if (customRange != null) {
      return '${shortDate(customRange!.start, alwaysShowYear: true)} - ${shortDate(customRange!.end, alwaysShowYear: true)}';
    }
    return 'All time';
  }

  List<AppTransaction> get _periodTransactions {
    final focus = _focusMonth;
    return widget.transactions.where((tx) {
      if (viewMode == FlowViewMode.month) {
        return transactionInSelectedPeriod(tx, focus);
      }
      if (viewMode == FlowViewMode.year) {
        return tx.date.year == focus.year;
      }
      if (customRange != null) {
        final start = DateTime(
          customRange!.start.year,
          customRange!.start.month,
          customRange!.start.day,
        );
        final end = DateTime(
          customRange!.end.year,
          customRange!.end.month,
          customRange!.end.day,
          23,
          59,
          59,
        );
        return !tx.date.isBefore(start) && !tx.date.isAfter(end);
      }
      return true;
    }).toList();
  }

  double get _periodIncome {
    double total = 0;
    for (final tx in _periodTransactions) {
      total += tx.incomeAmount;
    }
    return total;
  }

  double get _periodExpenses {
    double total = 0;
    for (final tx in _periodTransactions) {
      total += tx.expenseAmount;
    }
    return total;
  }

  double get _periodNet => _periodIncome - _periodExpenses;

  List<MonthlyFlowPoint> get _activeSeries {
    final focus = _focusMonth;
    if (viewMode == FlowViewMode.month) {
      return _buildCurrentMonthWeeklySeries(focus);
    }
    if (viewMode == FlowViewMode.year) {
      return _buildCurrentYearSeries(focus);
    }
    if (customRange != null) {
      return _buildSeriesFromTransactions(_periodTransactions);
    }
    return _buildRecentAllTimeSeries(focus, 12);
  }

  List<MonthlyFlowPoint> _buildSeriesFromTransactions(
    List<AppTransaction> txs,
  ) {
    final monthly = <String, MonthlyFlowPoint>{};
    for (final tx in txs) {
      final anchor = DateTime(tx.date.year, tx.date.month, 1);
      final key = '${anchor.year}-${anchor.month.toString().padLeft(2, '0')}';
      final existing = monthly[key];
      final nextIncome = (existing?.income ?? 0) + tx.incomeAmount;
      final nextExpenses = (existing?.expenses ?? 0) + tx.expenseAmount;
      monthly[key] = MonthlyFlowPoint(
        label: '${kMonthShortLabels[anchor.month - 1]} ${anchor.year}',
        income: nextIncome,
        expenses: nextExpenses,
      );
    }
    final keys = monthly.keys.toList()..sort();
    return keys.map((k) => monthly[k]!).toList();
  }

  // -------------------------------------------------------------------------
  // Cash-flow chart data builders
  // -------------------------------------------------------------------------

  // Month view uses weekly buckets to make one-month behavior easier to scan.
  List<MonthlyFlowPoint> _buildCurrentMonthWeeklySeries(DateTime now) {
    final incomes = List<double>.filled(5, 0);
    final expenses = List<double>.filled(5, 0);

    for (final tx in widget.transactions) {
      if (tx.date.year != now.year || tx.date.month != now.month) continue;
      final weekIndex = ((tx.date.day - 1) ~/ 7).clamp(0, 4);
      incomes[weekIndex] += tx.incomeAmount;
      expenses[weekIndex] += tx.expenseAmount;
    }

    return List<MonthlyFlowPoint>.generate(
      5,
      (i) => MonthlyFlowPoint(
        label: 'W${i + 1}',
        income: incomes[i],
        expenses: expenses[i],
      ),
    );
  }

  // All-time view compresses recent history into monthly buckets.
  List<MonthlyFlowPoint> _buildRecentAllTimeSeries(DateTime now, int count) {
    final series = <MonthlyFlowPoint>[];
    for (int offset = count - 1; offset >= 0; offset--) {
      final anchor = DateTime(now.year, now.month - offset, 1);
      double income = 0;
      double expenses = 0;
      for (final tx in widget.transactions) {
        if (tx.date.year == anchor.year && tx.date.month == anchor.month) {
          income += tx.incomeAmount;
          expenses += tx.expenseAmount;
        }
      }
      series.add(
        MonthlyFlowPoint(
          label: kMonthShortLabels[anchor.month - 1],
          income: income,
          expenses: expenses,
        ),
      );
    }
    return series;
  }

  // Year view renders one point per month.
  List<MonthlyFlowPoint> _buildCurrentYearSeries(DateTime now) {
    final series = <MonthlyFlowPoint>[];
    for (int month = 1; month <= 12; month++) {
      double income = 0;
      double expenses = 0;
      for (final tx in widget.transactions) {
        if (tx.date.year == now.year && tx.date.month == month) {
          income += tx.incomeAmount;
          expenses += tx.expenseAmount;
        }
      }
      series.add(
        MonthlyFlowPoint(
          label: kMonthShortLabels[month - 1],
          income: income,
          expenses: expenses,
        ),
      );
    }
    return series;
  }

  @override
  Widget build(BuildContext context) {
    // This page is a read-only analytics view over the currently visible transactions.
    final monthSelectionValue = _monthOnlyOptions.any((m) => m == _focusMonth)
        ? _focusMonth
        : (_monthOnlyOptions.isNotEmpty
              ? _monthOnlyOptions.first
              : DateTime(_focusMonth.year, _focusMonth.month, 1));
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Time-range controls and summary cards share the same filtered transaction set.
          const Text(
            'Cash Flow',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Text('Track money in and out'),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Range', style: TextStyle(color: Colors.black54)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<FlowViewMode>(
                  initialValue: viewMode,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                      value: FlowViewMode.month,
                      child: Text('By Month'),
                    ),
                    DropdownMenuItem(
                      value: FlowViewMode.year,
                      child: Text('By Year'),
                    ),
                    DropdownMenuItem(
                      value: FlowViewMode.all,
                      child: Text('All Time / Custom'),
                    ),
                  ],
                  onChanged: (value) {
                    if (value == null) return;
                    setState(() => viewMode = value);
                  },
                ),
              ),
            ],
          ),
          if (viewMode == FlowViewMode.month) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Text('Month', style: TextStyle(color: Colors.black54)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<DateTime>(
                    key: ValueKey(
                      'flow-month-${_focusMonth.year}-${_focusMonth.month}-${_focusMonth.day}',
                    ),
                    initialValue: monthSelectionValue,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _monthOnlyOptions
                        .map(
                          (m) => DropdownMenuItem<DateTime>(
                            value: normalizedMonthOption(m),
                            child: Text(monthOptionLabel(m)),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      widget.onMonthChanged(value);
                    },
                  ),
                ),
              ],
            ),
          ],
          if (viewMode == FlowViewMode.year) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Text('Year', style: TextStyle(color: Colors.black54)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<int>(
                    initialValue: _focusMonth.year,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: _yearOptions
                        .map(
                          (y) => DropdownMenuItem<int>(
                            value: y,
                            child: Text('$y'),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      widget.onMonthChanged(DateTime(value, 1, 2));
                    },
                  ),
                ),
              ],
            ),
          ],
          if (viewMode == FlowViewMode.all) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: () async {
                      final now = DateTime.now();
                      final picked = await showDateRangePicker(
                        context: context,
                        firstDate: DateTime(now.year - 10, 1, 1),
                        lastDate: DateTime(now.year + 1, 12, 31),
                        initialDateRange: customRange,
                      );
                      if (picked == null) return;
                      setState(() => customRange = picked);
                    },
                    icon: const Icon(Icons.date_range),
                    label: Text(
                      customRange == null
                          ? 'Pick Custom Date Range (Optional)'
                          : '${shortDate(customRange!.start, alwaysShowYear: true)} - ${shortDate(customRange!.end, alwaysShowYear: true)}',
                    ),
                  ),
                ),
                if (customRange != null) ...[
                  const SizedBox(width: 8),
                  IconButton(
                    tooltip: 'Clear custom range',
                    onPressed: () => setState(() => customRange = null),
                    icon: const Icon(Icons.clear),
                  ),
                ],
              ],
            ),
          ],
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Income',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(formatMoney(_periodIncome, signed: false)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Expenses',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(formatMoney(_periodExpenses, signed: false)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Net',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    Text(
                      '${_periodNet >= 0 ? '+' : '-'} \$${_periodNet.abs().toStringAsFixed(2)}',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          // Simple bar chart showing expense magnitude for the active range.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: _buildBars(),
            ),
          ),
          const SizedBox(height: 20),
          // Lightweight text summary that turns the chart data into a sentence.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.trending_up, color: Colors.green),
                    SizedBox(width: 8),
                    Text(
                      'Trend Summary',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(_monthCompareText()),
                const SizedBox(height: 6),
                Text(
                  '• $_rangeLabel income: ${formatMoney(_periodIncome, signed: false)}',
                ),
                const SizedBox(height: 6),
                Text(
                  '• $_rangeLabel expenses: ${formatMoney(_periodExpenses, signed: false)}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBars() {
    final series = _activeSeries;
    if (series.isEmpty) {
      return const [
        ChartBar(label: '-', height: 40, value: 0),
        ChartBar(label: '-', height: 40, value: 0),
        ChartBar(label: '-', height: 40, value: 0),
        ChartBar(label: '-', height: 40, value: 0),
        ChartBar(label: '-', height: 40, value: 0),
      ];
    }
    final maxExpense = series.map((e) => e.expenses).fold<double>(0, math.max);
    final safeMax = maxExpense <= 0 ? 1 : maxExpense;
    return series
        .map(
          (e) => ChartBar(
            label: e.label,
            height: 40 + (e.expenses / safeMax) * 80,
            value: e.expenses,
          ),
        )
        .toList();
  }

  // Produces the short trend summary sentence shown below the chart.
  String _monthCompareText() {
    final series = _activeSeries;
    if (series.length < 2) {
      return '• Not enough history to compare trend yet';
    }
    final current = series.last.expenses;
    final previous = series[series.length - 2].expenses;
    if (previous <= 0 && current <= 0) {
      if (viewMode == FlowViewMode.month && !isAllYearOption(_focusMonth)) {
        return '• No expense activity in the latest 2 months';
      }
      if (viewMode == FlowViewMode.year) {
        return '• No expense activity in the latest 2 periods';
      }
      return '• No expense activity in the latest 2 months';
    }
    if (previous <= 0) {
      if (viewMode == FlowViewMode.month && !isAllYearOption(_focusMonth)) {
        return '• Spending started this week';
      }
      if (viewMode == FlowViewMode.year) {
        return '• Spending started in the latest period';
      }
      return '• Spending started in the latest month';
    }
    final pct = ((current - previous) / previous) * 100;
    final direction = pct >= 0 ? 'increased' : 'decreased';
    if (viewMode == FlowViewMode.month) {
      return '• Spending $direction ${pct.abs().toStringAsFixed(1)}% vs last week';
    }
    if (viewMode == FlowViewMode.year) {
      return '• Spending $direction ${pct.abs().toStringAsFixed(1)}% vs previous period';
    }
    return '• Spending $direction ${pct.abs().toStringAsFixed(1)}% vs previous month';
  }
}

// ---------------------------------------------------------------------------
// Small reusable UI widgets used across multiple pages
// ---------------------------------------------------------------------------
