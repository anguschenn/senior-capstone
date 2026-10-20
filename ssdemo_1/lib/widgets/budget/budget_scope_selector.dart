import 'package:flutter/material.dart';

import '../../models/budget/budget_view_mode.dart';
import '../../utils/app_helpers.dart';
import '../common/ui.dart';

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
    final Widget scope = switch (viewMode) {
      BudgetViewMode.month => ScopeLine(
        key: ValueKey(
          'budget-month-${selectedMonth.year}-${selectedMonth.month}-${selectedMonth.day}',
        ),
        label: monthOptionLabel(monthSelectionValue),
        onTap: () async {
          final picked = await showOptionSheet<DateTime>(
            context: context,
            title: 'Month',
            values: monthOptions.map(normalizedMonthOption).toList(),
            labelOf: monthOptionLabel,
            selected: monthSelectionValue,
          );
          if (picked != null) onMonthChanged(picked);
        },
      ),
      BudgetViewMode.year => ScopeLine(
        label: '${selectedMonth.year}',
        onTap: () async {
          final picked = await showOptionSheet<int>(
            context: context,
            title: 'Year',
            values: yearOptions,
            labelOf: (y) => '$y',
            selected: selectedMonth.year,
          );
          if (picked != null) onMonthChanged(DateTime(picked, 1, 2));
        },
      ),
      BudgetViewMode.all => const ScopeLine(label: 'All time'),
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedTabs<BudgetViewMode>(
          value: viewMode,
          segments: const {
            BudgetViewMode.month: 'Month',
            BudgetViewMode.year: 'Year',
            BudgetViewMode.all: 'All Time',
          },
          onChanged: onViewModeChanged,
        ),
        scope,
      ],
    );
  }
}
