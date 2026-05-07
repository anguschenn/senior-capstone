import 'package:flutter/material.dart';

import '../../models/budget/budget_view_mode.dart';
import '../../utils/app_helpers.dart';
import '../common/labeled_selector_field.dart';

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
        Row(
          children: [
            Expanded(
              child: LabeledSelectorField<BudgetViewMode>(
                label: 'Range',
                value: viewMode,
                options: const [
                  SelectorOption<BudgetViewMode>(
                    value: BudgetViewMode.month,
                    label: 'By Month',
                  ),
                  SelectorOption<BudgetViewMode>(
                    value: BudgetViewMode.year,
                    label: 'By Year',
                  ),
                  SelectorOption<BudgetViewMode>(
                    value: BudgetViewMode.all,
                    label: 'All Time',
                  ),
                ],
                onChanged: onViewModeChanged,
              ),
            ),
            if (viewMode == BudgetViewMode.month ||
                viewMode == BudgetViewMode.year) ...[
              const SizedBox(width: 10),
              Expanded(
                child: viewMode == BudgetViewMode.month
                    ? LabeledSelectorField<DateTime>(
                        key: ValueKey(
                          'budget-month-${selectedMonth.year}-${selectedMonth.month}-${selectedMonth.day}',
                        ),
                        label: 'Month',
                        value: monthSelectionValue,
                        options: monthOptions
                            .map(
                              (m) => SelectorOption<DateTime>(
                                value: normalizedMonthOption(m),
                                label: monthOptionLabel(m),
                              ),
                            )
                            .toList(),
                        onChanged: onMonthChanged,
                      )
                    : LabeledSelectorField<int>(
                        label: 'Year',
                        value: selectedMonth.year,
                        options: yearOptions
                            .map(
                              (y) => SelectorOption<int>(value: y, label: '$y'),
                            )
                            .toList(),
                        onChanged: (value) {
                          onMonthChanged(DateTime(value, 1, 2));
                        },
                      ),
              ),
            ],
          ],
        ),
      ],
    );
  }
}
