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

  DateTime get _focusMonth =>
      DateTime(widget.selectedMonth.year, widget.selectedMonth.month, 1);

  List<AppTransaction> get _periodTransactions {
    final focus = _focusMonth;
    return widget.transactions.where((tx) {
      if (viewMode == FlowViewMode.month) {
        return tx.date.year == focus.year && tx.date.month == focus.month;
      }
      if (viewMode == FlowViewMode.year) {
        return tx.date.year == focus.year;
      }
      return true;
    }).toList();
  }

  double get _periodIncome {
    double total = 0;
    for (final tx in _periodTransactions) {
      if (tx.amount < 0) total += tx.amount.abs();
    }
    return total;
  }

  double get _periodExpenses {
    double total = 0;
    for (final tx in _periodTransactions) {
      if (tx.amount > 0) total += tx.amount;
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
    return _buildRecentAllTimeSeries(focus, 12);
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
      if (tx.amount < 0) {
        incomes[weekIndex] += tx.amount.abs();
      } else {
        expenses[weekIndex] += tx.amount;
      }
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
          if (tx.amount < 0) {
            income += tx.amount.abs();
          } else {
            expenses += tx.amount;
          }
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
          if (tx.amount < 0) {
            income += tx.amount.abs();
          } else {
            expenses += tx.amount;
          }
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
          SegmentedButton<FlowViewMode>(
            segments: const [
              ButtonSegment<FlowViewMode>(
                value: FlowViewMode.month,
                label: Text('By Month'),
              ),
              ButtonSegment<FlowViewMode>(
                value: FlowViewMode.year,
                label: Text('By Year'),
              ),
              ButtonSegment<FlowViewMode>(
                value: FlowViewMode.all,
                label: Text('All Time'),
              ),
            ],
            selected: {viewMode},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) return;
              setState(() => viewMode = selection.first);
            },
          ),
          if (viewMode != FlowViewMode.all) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Text('Month', style: TextStyle(color: Colors.black54)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<DateTime>(
                    key: ValueKey(
                      'flow-month-${_focusMonth.year}-${_focusMonth.month}',
                    ),
                    initialValue: _focusMonth,
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: widget.monthOptions
                        .map(
                          (m) => DropdownMenuItem<DateTime>(
                            value: DateTime(m.year, m.month, 1),
                            child: Text(
                              '${kMonthShortLabels[m.month - 1]} ${m.year}',
                            ),
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
                  '• ${viewMode == FlowViewMode.month ? '${kMonthShortLabels[_focusMonth.month - 1]} ${_focusMonth.year}' : (viewMode == FlowViewMode.year ? '${_focusMonth.year}' : 'All time')} income: ${formatMoney(_periodIncome, signed: false)}',
                ),
                const SizedBox(height: 6),
                Text(
                  '• ${viewMode == FlowViewMode.month ? '${kMonthShortLabels[_focusMonth.month - 1]} ${_focusMonth.year}' : (viewMode == FlowViewMode.year ? '${_focusMonth.year}' : 'All time')} expenses: ${formatMoney(_periodExpenses, signed: false)}',
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
      if (viewMode == FlowViewMode.month) {
        return '• No expense activity in the latest 2 months';
      }
      if (viewMode == FlowViewMode.year) {
        return '• No expense activity in the latest 2 periods';
      }
      return '• No expense activity in the latest 2 months';
    }
    if (previous <= 0) {
      if (viewMode == FlowViewMode.month) {
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
