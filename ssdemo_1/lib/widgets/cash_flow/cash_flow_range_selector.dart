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

    // Oldest to newest, so ‹ goes back in time and › forward.
    final months = monthOptions.map(normalizedMonthOption).toSet().toList()
      ..sort();
    final monthIndex = months.indexOf(monthSelectionValue);
    VoidCallback? monthStep(int step) {
      final i = monthIndex + step;
      if (monthIndex < 0 || i < 0 || i >= months.length) return null;
      return () => onMonthChanged(months[i]);
    }

    final years = [...yearOptions]..sort();
    final yearIndex = years.indexOf(focusMonth.year);
    VoidCallback? yearStep(int step) {
      final i = yearIndex + step;
      if (yearIndex < 0 || i < 0 || i >= years.length) return null;
      return () => onYearChanged(years[i]);
    }

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
      // Same line as Month and Year, so switching doesn't shift the page.
      FlowViewMode.all => ScopeLine(
        label: customRange == null
            ? 'All time · pick a date range'
            : '${shortDate(customRange!.start, alwaysShowYear: true)} - ${shortDate(customRange!.end, alwaysShowYear: true)}',
        onTap: onPickCustomRange,
        actions: [
          if (customRange != null)
            IconButton(
              tooltip: 'Clear custom range',
              visualDensity: VisualDensity.compact,
              onPressed: onClearCustomRange,
              icon: Icon(Icons.close_rounded, size: 18, color: c.muted),
            ),
        ],
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
          steps: {
            FlowViewMode.month: (previous: monthStep(-1), next: monthStep(1)),
            FlowViewMode.year: (previous: yearStep(-1), next: yearStep(1)),
          },
        ),
        scope,
      ],
    );
  }
}
