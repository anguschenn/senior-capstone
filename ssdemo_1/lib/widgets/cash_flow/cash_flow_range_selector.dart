import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../utils/app_helpers.dart';
import '../common/labeled_selector_field.dart';

class CashFlowRangeSelector extends StatelessWidget {
  const CashFlowRangeSelector({
    super.key,
    required this.viewMode,
    required this.selectedMonth,
    required this.monthOptions,
    required this.yearOptions,
    required this.customRange,
    required this.onViewModeChanged,
    required this.onMonthChanged,
    required this.onYearChanged,
    required this.onPickCustomRange,
    required this.onClearCustomRange,
  });

  final FlowViewMode viewMode;
  final DateTime selectedMonth;
  final List<DateTime> monthOptions;
  final List<int> yearOptions;
  final DateTimeRange? customRange;
  final ValueChanged<FlowViewMode> onViewModeChanged;
  final ValueChanged<DateTime> onMonthChanged;
  final ValueChanged<int> onYearChanged;
  final Future<void> Function() onPickCustomRange;
  final VoidCallback onClearCustomRange;

  @override
  Widget build(BuildContext context) {
    final focusMonth = normalizedMonthOption(selectedMonth);
    final monthSelectionValue = monthOptions.any((m) => m == focusMonth)
        ? focusMonth
        : (monthOptions.isNotEmpty
              ? monthOptions.first
              : DateTime(focusMonth.year, focusMonth.month, 1));

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: LabeledSelectorField<FlowViewMode>(
                label: 'Range',
                value: viewMode,
                options: const [
                  SelectorOption(value: FlowViewMode.month, label: 'By Month'),
                  SelectorOption(value: FlowViewMode.year, label: 'By Year'),
                  SelectorOption(
                    value: FlowViewMode.all,
                    label: 'All Time / Custom',
                  ),
                ],
                onChanged: onViewModeChanged,
              ),
            ),
            if (viewMode == FlowViewMode.month ||
                viewMode == FlowViewMode.year) ...[
              const SizedBox(width: 10),
              Expanded(
                child: viewMode == FlowViewMode.month
                    ? LabeledSelectorField<DateTime>(
                        key: ValueKey(
                          'flow-month-${focusMonth.year}-${focusMonth.month}-${focusMonth.day}',
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
                        value: focusMonth.year,
                        options: yearOptions
                            .map(
                              (y) => SelectorOption<int>(value: y, label: '$y'),
                            )
                            .toList(),
                        onChanged: onYearChanged,
                      ),
              ),
            ],
          ],
        ),
        if (viewMode == FlowViewMode.all) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: onPickCustomRange,
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
                  onPressed: onClearCustomRange,
                  icon: const Icon(Icons.clear),
                ),
              ],
            ],
          ),
        ],
      ],
    );
  }
}
