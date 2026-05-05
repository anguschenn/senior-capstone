import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../utils/app_helpers.dart';

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
                  onViewModeChanged(value);
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
                    'flow-month-${focusMonth.year}-${focusMonth.month}-${focusMonth.day}',
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
        if (viewMode == FlowViewMode.year) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const Text('Year', style: TextStyle(color: Colors.black54)),
              const SizedBox(width: 12),
              Expanded(
                child: DropdownButtonFormField<int>(
                  initialValue: focusMonth.year,
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
                    onYearChanged(value);
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
