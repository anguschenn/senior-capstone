import 'package:flutter/material.dart';

import '../../models/budget/budget_view_mode.dart';
import '../../utils/app_helpers.dart';

class BudgetScopeSelector extends StatelessWidget {
  const BudgetScopeSelector({
    super.key,
    required this.viewMode,
    required this.onViewModeChanged,
    required this.selectedMonth,
    required this.monthOptions,
    required this.yearOptions,
    required this.onMonthChanged,
  });

  final BudgetViewMode viewMode;
  final ValueChanged<BudgetViewMode> onViewModeChanged;
  final DateTime selectedMonth;
  final List<DateTime> monthOptions;
  final List<int> yearOptions;
  final ValueChanged<DateTime> onMonthChanged;

  @override
  Widget build(BuildContext context) {
    final normalizedSelectedMonth = normalizedMonthOption(selectedMonth);
    final monthSelectionValue =
        monthOptions.any((m) => m == normalizedSelectedMonth)
        ? normalizedSelectedMonth
        : (monthOptions.isNotEmpty
              ? monthOptions.first
              : DateTime(
                  normalizedSelectedMonth.year,
                  normalizedSelectedMonth.month,
                  1,
                ));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedButton<BudgetViewMode>(
          segments: const [
            ButtonSegment<BudgetViewMode>(
              value: BudgetViewMode.month,
              label: Text('By Month'),
            ),
            ButtonSegment<BudgetViewMode>(
              value: BudgetViewMode.year,
              label: Text('By Year'),
            ),
            ButtonSegment<BudgetViewMode>(
              value: BudgetViewMode.all,
              label: Text('All Time'),
            ),
          ],
          selected: {viewMode},
          onSelectionChanged: (selection) {
            if (selection.isEmpty) return;
            onViewModeChanged(selection.first);
          },
        ),
        if (viewMode == BudgetViewMode.month) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Month', style: TextStyle(color: Colors.black54)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<DateTime>(
                  key: ValueKey(
                    'budget-month-${selectedMonth.year}-${selectedMonth.month}-${selectedMonth.day}',
                  ),
                  initialValue: monthSelectionValue,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: monthOptions
                      .map(
                        (m) => DropdownMenuItem<DateTime>(
                          value: normalizedMonthOption(m),
                          child: Text(monthOptionLabel(m)),
                        ),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    onMonthChanged(value);
                  },
                ),
              ),
            ],
          ),
        ],
        if (viewMode == BudgetViewMode.year) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Year', style: TextStyle(color: Colors.black54)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: selectedMonth.year,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: yearOptions
                      .map(
                        (y) =>
                            DropdownMenuItem<int>(value: y, child: Text('$y')),
                      )
                      .toList(),
                  onChanged: (value) {
                    if (value == null) return;
                    onMonthChanged(DateTime(value, 1, 2));
                  },
                ),
              ),
            ],
          ),
        ],
      ],
    );
  }
}
