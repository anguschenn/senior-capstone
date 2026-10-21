import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import '../widgets/common/ui.dart';
import 'home_page.dart' show TransactionRow;

class TransactionsPage extends StatefulWidget {
  const TransactionsPage({
    super.key,
    required this.transactions,
    required this.accountOptions,
    required this.selectedMonth,
    required this.monthOptions,
    required this.onMonthChanged,
    required this.reviewedCategoryByTxId,
    required this.onTransactionCategorySelected,
    this.aiCategorySuggestUri,
    this.apiKey,
    this.accessToken,
  });

  final List<AppTransaction> transactions;
  final List<AccountOption> accountOptions;
  final DateTime selectedMonth;
  final List<DateTime> monthOptions;
  final ValueChanged<DateTime> onMonthChanged;
  final Map<String, String> reviewedCategoryByTxId;
  final void Function(AppTransaction tx, String category)
  onTransactionCategorySelected;
  final Uri? aiCategorySuggestUri;
  final String? apiKey;
  final String? accessToken;

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  String query = '';
  ActivityViewMode viewMode = ActivityViewMode.month;

  /// Category filter; empty means all categories.
  String categoryFilter = '';

  /// Default: newest first, the order the list has always had.
  ActivitySortKey sortKey = ActivitySortKey.date;
  bool sortDescending = true;

  /// Sorted by [sortKey] in the chosen direction. Ties keep their incoming
  /// order (newest first), which a plain List.sort doesn't promise.
  List<AppTransaction> _sorted(List<AppTransaction> txs) {
    final indexed = txs.indexed.toList();
    indexed.sort((a, b) {
      final byKey = sortKey == ActivitySortKey.date
          ? a.$2.date.compareTo(b.$2.date)
          : a.$2.displayAmount.compareTo(b.$2.displayAmount);
      if (byKey != 0) return sortDescending ? -byKey : byKey;
      return a.$1.compareTo(b.$1);
    });
    return [for (final entry in indexed) entry.$2];
  }

  DateTimeRange? customRange;

  List<int> get _yearOptions {
    final years = <int>{DateTime.now().year, widget.selectedMonth.year};
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

  /// The label on a transaction's category tag; the category filter uses the
  /// same label, so what the filter matches is exactly what the list shows.
  String _categoryLabel(AppTransaction tx) => tx.isIncome
      ? tx.inflowLabel
      : (widget.reviewedCategoryByTxId[tx.id] ??
            budgetCategoryFromPfc(
              pfcDetailed: tx.category,
              pfcPrimary: tx.primaryCategory,
            ));

  @override
  Widget build(BuildContext context) {
    // First filter by time range, then by category and the text query.
    final selectedMonth = normalizedMonthOption(widget.selectedMonth);
    final monthSelectionValue = _monthOnlyOptions.any((m) => m == selectedMonth)
        ? selectedMonth
        : (_monthOnlyOptions.isNotEmpty
              ? _monthOnlyOptions.first
              : DateTime(selectedMonth.year, selectedMonth.month, 1));
    final periodTransactions = widget.transactions.where((tx) {
      if (viewMode == ActivityViewMode.month) {
        return tx.date.year == selectedMonth.year &&
            tx.date.month == selectedMonth.month;
      }
      if (viewMode == ActivityViewMode.year) {
        return tx.date.year == selectedMonth.year;
      }
      if (viewMode == ActivityViewMode.all && customRange != null) {
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

    // Categories in the selected range, with counts, for the filter menu. A
    // chosen category stays listed (at 0) after a range change empties it.
    final categoryCounts = <String, int>{};
    for (final tx in periodTransactions) {
      final label = _categoryLabel(tx);
      categoryCounts[label] = (categoryCounts[label] ?? 0) + 1;
    }
    if (categoryFilter.isNotEmpty) {
      categoryCounts.putIfAbsent(categoryFilter, () => 0);
    }
    final categoryNames = categoryCounts.keys.toList()
      ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));

    final filtered = _sorted(
      periodTransactions.where((tx) {
        if (categoryFilter.isNotEmpty && _categoryLabel(tx) != categoryFilter) {
          return false;
        }
        if (query.trim().isEmpty) return true;
        final q = query.toLowerCase();
        return tx.name.toLowerCase().contains(q) ||
            tx.category.toLowerCase().contains(q) ||
            tx.primaryCategory.toLowerCase().contains(q) ||
            (widget.reviewedCategoryByTxId[tx.id]?.toLowerCase().contains(q) ??
                false);
      }).toList(),
    );

    final c = context.colors;
    final countLabel =
        '${filtered.length} transaction${filtered.length == 1 ? '' : 's'}';

    // Newest/oldest first with a header per day; by amount it's one list.
    final rows = <Widget>[];
    DateTime? lastDay;
    for (final tx in filtered) {
      final day = DateTime(tx.date.year, tx.date.month, tx.date.day);
      if (sortKey == ActivitySortKey.date && day != lastDay) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
            child: Text(
              _dayLabel(day),
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.muted,
              ),
            ),
          ),
        );
        lastDay = day;
      }
      rows.add(
        Container(
          margin: const EdgeInsets.only(bottom: 1),
          padding: const EdgeInsets.symmetric(horizontal: 14),
          decoration: BoxDecoration(
            color: c.card,
            borderRadius: BorderRadius.circular(12),
          ),
          child: TransactionRow(
            tx: tx,
            accountOptions: widget.accountOptions,
            reviewedCategoryByTxId: widget.reviewedCategoryByTxId,
            onTransactionCategorySelected: widget.onTransactionCategorySelected,
            aiCategorySuggestUri: widget.aiCategorySuggestUri,
            apiKey: widget.apiKey,
            accessToken: widget.accessToken,
            showDate: sortKey != ActivitySortKey.date,
          ),
        ),
      );
    }

    Widget chip({
      Key? key,
      required String label,
      required bool selected,
      required VoidCallback onTap,
      Color? dot,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Material(
          key: key,
          color: selected ? (dot ?? c.button) : c.raised,
          borderRadius: BorderRadius.circular(99),
          child: InkWell(
            borderRadius: BorderRadius.circular(99),
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (dot != null && !selected) ...[
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: dot,
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? (dot != null ? AppPalette.ink : c.onButton)
                          : c.text,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return SafeArea(
      bottom: false,
      child: Column(
        children: [
          LargeTitle(
            'Activity',
            trailing: [
              Material(
                key: const ValueKey('tx-sort-key'),
                color: c.raised,
                borderRadius: BorderRadius.circular(99),
                child: InkWell(
                  borderRadius: BorderRadius.circular(99),
                  onTap: () async {
                    final picked = await showOptionSheet<ActivitySortKey>(
                      context: context,
                      title: 'Sort',
                      values: ActivitySortKey.values,
                      labelOf: (k) =>
                          k == ActivitySortKey.date ? 'Date' : 'Amount',
                      selected: sortKey,
                    );
                    if (picked != null) setState(() => sortKey = picked);
                  },
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    child: Text(
                      sortKey == ActivitySortKey.date ? 'By date' : 'By amount',
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                ),
              ),
              CircleIconButton(
                key: const ValueKey('tx-sort-direction'),
                tooltip: sortDescending ? 'Decreasing' : 'Increasing',
                onPressed: () =>
                    setState(() => sortDescending = !sortDescending),
                icon: sortDescending
                    ? Icons.arrow_downward_rounded
                    : Icons.arrow_upward_rounded,
              ),
            ],
          ),
          Expanded(
            // Filters scroll away with the list so more rows fit on screen.
            child: CustomScrollView(
              slivers: [
                SliverToBoxAdapter(
                  child: Column(
                    children: [
                      // Header filters let the user narrow the full activity list without re-querying.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 6, 16, 0),
                        child: TextField(
                          onChanged: (value) => setState(() => query = value),
                          decoration: InputDecoration(
                            hintText: 'Search',
                            prefixIcon: Icon(
                              Icons.search_rounded,
                              color: c.muted,
                            ),
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 9,
                            ),
                            border: OutlineInputBorder(
                              borderRadius: BorderRadius.circular(10),
                              borderSide: BorderSide.none,
                            ),
                          ),
                        ),
                      ),
                      SegmentedTabs<ActivityViewMode>(
                        margin: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                        value: viewMode,
                        segments: const {
                          ActivityViewMode.month: 'Month',
                          ActivityViewMode.year: 'Year',
                          ActivityViewMode.all: 'All Time',
                        },
                        onChanged: (value) => setState(() => viewMode = value),
                      ),
                      switch (viewMode) {
                        ActivityViewMode.month => ScopeLine(
                          key: ValueKey(
                            'tx-month-${selectedMonth.year}-${selectedMonth.month}-${selectedMonth.day}',
                          ),
                          label: monthOptionLabel(monthSelectionValue),
                          trailing: countLabel,
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                          onTap: () async {
                            final picked = await showOptionSheet<DateTime>(
                              context: context,
                              title: 'Month',
                              values: _monthOnlyOptions,
                              labelOf: monthOptionLabel,
                              selected: monthSelectionValue,
                            );
                            if (picked != null) widget.onMonthChanged(picked);
                          },
                        ),
                        ActivityViewMode.year => ScopeLine(
                          label: '${selectedMonth.year}',
                          trailing: countLabel,
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                          onTap: () async {
                            final picked = await showOptionSheet<int>(
                              context: context,
                              title: 'Year',
                              values: _yearOptions,
                              labelOf: (y) => '$y',
                              selected: selectedMonth.year,
                            );
                            if (picked != null) {
                              widget.onMonthChanged(DateTime(picked, 1, 2));
                            }
                          },
                        ),
                        ActivityViewMode.all => Padding(
                          padding: const EdgeInsets.fromLTRB(20, 4, 8, 0),
                          child: Row(
                            children: [
                              Expanded(
                                child: InkWell(
                                  onTap: () async {
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
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      vertical: 8,
                                    ),
                                    child: Text(
                                      customRange == null
                                          ? 'All time · pick a date range'
                                          : '${shortDate(customRange!.start, alwaysShowYear: true)} - ${shortDate(customRange!.end, alwaysShowYear: true)}',
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: FontWeight.w500,
                                        color: c.muted,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                              if (customRange != null)
                                IconButton(
                                  tooltip: 'Clear custom range',
                                  onPressed: () =>
                                      setState(() => customRange = null),
                                  icon: Icon(
                                    Icons.close_rounded,
                                    size: 18,
                                    color: c.muted,
                                  ),
                                ),
                              Padding(
                                padding: const EdgeInsets.only(right: 12),
                                child: Text(
                                  countLabel,
                                  style: TextStyle(
                                    color: c.muted,
                                    fontSize: 13,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      },
                      SizedBox(
                        height: 40,
                        child: ListView(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.fromLTRB(16, 4, 8, 2),
                          children: [
                            chip(
                              key: const ValueKey('tx-category-filter'),
                              label: categoryFilter.isEmpty
                                  ? 'All categories (${periodTransactions.length})'
                                  : 'All categories',
                              selected: categoryFilter.isEmpty,
                              onTap: () async {
                                final picked = await showOptionSheet<String>(
                                  context: context,
                                  title: 'Category',
                                  values: ['', ...categoryNames],
                                  labelOf: (name) => name.isEmpty
                                      ? 'All categories (${periodTransactions.length})'
                                      : '$name (${categoryCounts[name]})',
                                  selected: categoryFilter,
                                );
                                if (picked != null) {
                                  setState(() => categoryFilter = picked);
                                }
                              },
                            ),
                            for (final name in categoryNames)
                              chip(
                                label: name,
                                dot: colorForDetailedCategory(name),
                                selected: categoryFilter == name,
                                onTap: () => setState(
                                  () => categoryFilter = categoryFilter == name
                                      ? ''
                                      : name,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (filtered.isEmpty)
                  SliverFillRemaining(
                    hasScrollBody: false,
                    child: Center(
                      child: Text(
                        'No transactions found',
                        style: TextStyle(color: c.muted),
                      ),
                    ),
                  )
                else
                  // Main activity list with inline re-categorization for spending rows.
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
                    sliver: SliverList.list(children: rows),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _dayLabel(DateTime day) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final diff = today.difference(day).inDays;
    if (diff == 0) return 'Today';
    if (diff == 1) return 'Yesterday';
    return shortDate(day, alwaysShowYear: day.year != now.year);
  }
}

/// What the Activity list is ordered by; the direction is a separate toggle.
enum ActivitySortKey { date, amount }
