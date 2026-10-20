import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../models/app_models.dart';
import '../../utils/app_helpers.dart';
import '../common/ui.dart';

/// Month / Year / All segmented control with the period line under it.
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
    final c = context.colors;
    final focusMonth = normalizedMonthOption(selectedMonth);
    final monthSelectionValue = monthOptions.any((m) => m == focusMonth)
        ? focusMonth
        : (monthOptions.isNotEmpty
              ? monthOptions.first
              : DateTime(focusMonth.year, focusMonth.month, 1));

    final Widget scope = switch (viewMode) {
      FlowViewMode.month => ScopeLine(
        key: ValueKey(
          'flow-month-${focusMonth.year}-${focusMonth.month}-${focusMonth.day}',
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
      FlowViewMode.year => ScopeLine(
        label: '${focusMonth.year}',
        onTap: () async {
          final picked = await showOptionSheet<int>(
            context: context,
            title: 'Year',
            values: yearOptions,
            labelOf: (y) => '$y',
            selected: focusMonth.year,
          );
          if (picked != null) onYearChanged(picked);
        },
      ),
      FlowViewMode.all => Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 12, 6),
        child: Row(
          children: [
            Expanded(
              child: InkWell(
                onTap: onPickCustomRange,
                child: Row(
                  children: [
                    Icon(Icons.date_range_rounded, size: 17, color: c.muted),
                    const SizedBox(width: 6),
                    Flexible(
                      child: Text(
                        customRange == null
                            ? 'All time · pick a date range'
                            : '${shortDate(customRange!.start, alwaysShowYear: true)} - ${shortDate(customRange!.end, alwaysShowYear: true)}',
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w500,
                          color: c.muted,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (customRange != null)
              IconButton(
                tooltip: 'Clear custom range',
                onPressed: onClearCustomRange,
                icon: Icon(Icons.close_rounded, size: 18, color: c.muted),
              ),
          ],
        ),
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SegmentedTabs<FlowViewMode>(
          value: viewMode,
          segments: const {
            FlowViewMode.month: 'Month',
            FlowViewMode.year: 'Year',
            FlowViewMode.all: 'All Time',
          },
          onChanged: onViewModeChanged,
        ),
        scope,
      ],
    );
  }
}
