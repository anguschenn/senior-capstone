import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import '../widgets/common/ui.dart';
import 'home_page.dart'
    show TransactionListSkeleton, TransactionRow, effectiveCategoryFor;

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
    this.onTransactionTap,
    this.loading = false,
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

  /// Opens what the user can do with a transaction (split a purchase, link
  /// a friend's payment to one).
  final void Function(BuildContext context, AppTransaction tx)?
  onTransactionTap;

  /// The first read of the user's data is still on its way: placeholder
  /// rows, not "No transactions found".
  final bool loading;
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
  // Same label as the row's pill, so the filter and the pill always agree.
  String _categoryLabel(AppTransaction tx) =>
      effectiveCategoryFor(tx, widget.reviewedCategoryByTxId);

  @override
  Widget build(BuildContext context) {
    // First filter by time range, then by category and the text query.
    final selectedMonth = normalizedMonthOption(widget.selectedMonth);
    final monthSelectionValue = _monthOnlyOptions.any((m) => m == selectedMonth)
        ? selectedMonth
        : (_monthOnlyOptions.isNotEmpty
              ? _monthOnlyOptions.first
              : DateTime(selectedMonth.year, selectedMonth.month, 1));
    // Oldest to newest, so ‹ goes back in time and › forward.
    final months = _monthOnlyOptions.toSet().toList()..sort();
    final monthIndex = months.indexOf(monthSelectionValue);
    VoidCallback? monthStep(int step) {
      final i = monthIndex + step;
      if (monthIndex < 0 || i < 0 || i >= months.length) return null;
      return () => widget.onMonthChanged(months[i]);
    }

    final years = [..._yearOptions]..sort();
    final yearIndex = years.indexOf(selectedMonth.year);
    VoidCallback? yearStep(int step) {
      final i = yearIndex + step;
      if (yearIndex < 0 || i < 0 || i >= years.length) return null;
      return () => widget.onMonthChanged(allYearOptionFor(years[i]));
    }

    final periodTransactions = widget.transactions.where((tx) {
      if (viewMode == ActivityViewMode.month) {
        // "All Year" picked from the month picker covers the whole year.
        return transactionInSelectedPeriod(tx, selectedMonth);
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

    final q = query.trim().toLowerCase();
    final searched = q.isEmpty
        ? periodTransactions
        : periodTransactions.where((tx) {
            return tx.name.toLowerCase().contains(q) ||
                tx.category.toLowerCase().contains(q) ||
                tx.primaryCategory.toLowerCase().contains(q) ||
                (widget.reviewedCategoryByTxId[tx.id]?.toLowerCase().contains(
                      q,
                    ) ??
                    false);
          }).toList();

    // Categories in the selected range that match the search, with counts,
    // for the filter menu. A chosen category stays listed (at 0) after a
    // range change or search empties it.
    final categoryCounts = <String, int>{};
    for (final tx in searched) {
      final label = _categoryLabel(tx);
      categoryCounts[label] = (categoryCounts[label] ?? 0) + 1;
    }
    if (categoryFilter.isNotEmpty) {
      categoryCounts.putIfAbsent(categoryFilter, () => 0);
    }
    // Busiest categories first, so the common ones don't sit below the fold.
    final categoryNames = categoryCounts.keys.toList()
      ..sort((a, b) {
        final byCount = categoryCounts[b]!.compareTo(categoryCounts[a]!);
        if (byCount != 0) return byCount;
        return a.toLowerCase().compareTo(b.toLowerCase());
      });

    final filtered = _sorted(
      searched
          .where(
            (tx) =>
                categoryFilter.isEmpty || _categoryLabel(tx) == categoryFilter,
          )
          .toList(),
    );

    final c = context.colors;
    final countLabel =
        '${filtered.length} transaction${filtered.length == 1 ? '' : 's'}';

    // Newest/oldest first with a header per day; by amount it's one list.
    // Each group is one rounded card with dividers, like Wallet's list.
    final groups = <(String?, List<AppTransaction>)>[];
    DateTime? lastDay;
    for (final tx in filtered) {
      final day = DateTime(tx.date.year, tx.date.month, tx.date.day);
      if (groups.isEmpty ||
          (sortKey == ActivitySortKey.date && day != lastDay)) {
        groups.add((
          sortKey == ActivitySortKey.date ? _dayLabel(day) : null,
          <AppTransaction>[],
        ));
        lastDay = day;
      }
      groups.last.$2.add(tx);
    }
    final rows = <Widget>[];
    for (final (label, txs) in groups) {
      if (label != null) {
        rows.add(
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 14, 4, 4),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.muted,
              ),
            ),
          ),
        );
      } else {
        rows.add(const SizedBox(height: 8));
      }
      rows.add(
        // A Material card, clipped to its corners, so a row's tap highlight
        // fills the card's width; rows pad themselves.
        Material(
          color: c.card,
          shape: cardShape(context),
          clipBehavior: Clip.antiAlias,
          child: Column(
            children: [
              for (final (i, tx) in txs.indexed) ...[
                if (i > 0)
                  Divider(
                    height: 0.5,
                    thickness: 0.5,
                    indent: 14,
                    endIndent: 14,
                    color: c.line,
                  ),
                TransactionRow(
                  tx: tx,
                  horizontalInset: 14,
                  accountOptions: widget.accountOptions,
                  reviewedCategoryByTxId: widget.reviewedCategoryByTxId,
                  onTransactionCategorySelected:
                      widget.onTransactionCategorySelected,
                  aiCategorySuggestUri: widget.aiCategorySuggestUri,
                  apiKey: widget.apiKey,
                  accessToken: widget.accessToken,
                  showDate: sortKey != ActivitySortKey.date,
                  onTap: widget.onTransactionTap == null
                      ? null
                      : () => widget.onTransactionTap!(context, tx),
                ),
              ],
            ],
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
      IconData? trailingIcon,
    }) {
      return Padding(
        padding: const EdgeInsets.only(right: 8),
        child: Pressable(
          child: Material(
            key: key,
            color: selected ? (dot ?? c.button) : c.raised,
            borderRadius: BorderRadius.circular(99),
            child: InkWell(
              borderRadius: BorderRadius.circular(99),
              onTap: onTap,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 7,
                ),
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
                    Flexible(
                      child: Text(
                        label,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: selected
                              ? (dot != null ? AppPalette.ink : c.onButton)
                              : c.text,
                        ),
                      ),
                    ),
                    if (trailingIcon != null) ...[
                      const SizedBox(width: 4),
                      Icon(
                        trailingIcon,
                        size: 16,
                        color: selected
                            ? (dot != null ? AppPalette.ink : c.onButton)
                            : c.text,
                      ),
                    ],
                  ],
                ),
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
              Pressable(
                child: Material(
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
                        sortKey == ActivitySortKey.date
                            ? 'By date'
                            : 'By amount',
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
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
                        steps: {
                          ActivityViewMode.month: (
                            previous: monthStep(-1),
                            next: monthStep(1),
                          ),
                          ActivityViewMode.year: (
                            previous: yearStep(-1),
                            next: yearStep(1),
                          ),
                        },
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
                            final picked = await showMonthGridPicker(
                              context: context,
                              options: _monthOnlyOptions,
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
                            final picked = await showYearGridPicker(
                              context: context,
                              years: _yearOptions,
                              selected: selectedMonth.year,
                            );
                            if (picked != null) {
                              widget.onMonthChanged(allYearOptionFor(picked));
                            }
                          },
                        ),
                        // Same line as Month and Year, so switching doesn't
                        // shift the page.
                        ActivityViewMode.all => ScopeLine(
                          label: customRange == null
                              ? 'All time · pick a date range'
                              : '${shortDate(customRange!.start, alwaysShowYear: true)} - ${shortDate(customRange!.end, alwaysShowYear: true)}',
                          trailing: countLabel,
                          padding: const EdgeInsets.fromLTRB(20, 4, 20, 0),
                          onTap: () async {
                            final picked = await showRangeCalendar(
                              context: context,
                              initial: customRange,
                            );
                            if (picked == null) return;
                            setState(() => customRange = picked);
                          },
                          actions: [
                            if (customRange != null)
                              IconButton(
                                tooltip: 'Clear custom range',
                                visualDensity: VisualDensity.compact,
                                onPressed: () =>
                                    setState(() => customRange = null),
                                icon: Icon(
                                  Icons.close_rounded,
                                  size: 18,
                                  color: c.muted,
                                ),
                              ),
                          ],
                        ),
                      },
                      // One filter button opens the full category list with
                      // counts; a chosen category shows next to it with an ×.
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 4, 8, 2),
                        child: Row(
                          children: [
                            chip(
                              key: const ValueKey('tx-category-filter'),
                              label: categoryFilter.isEmpty
                                  ? 'All categories (${searched.length})'
                                  : 'Category',
                              selected: categoryFilter.isEmpty,
                              trailingIcon: Icons.keyboard_arrow_down_rounded,
                              onTap: () async {
                                final picked = await showOptionSheet<String>(
                                  context: context,
                                  title: 'Category',
                                  values: ['', ...categoryNames],
                                  labelOf: (name) => name.isEmpty
                                      ? 'All categories (${searched.length})'
                                      : '$name (${categoryCounts[name]})',
                                  selected: categoryFilter,
                                );
                                if (picked != null) {
                                  setState(() => categoryFilter = picked);
                                }
                              },
                            ),
                            if (categoryFilter.isNotEmpty)
                              Flexible(
                                child: chip(
                                  key: const ValueKey('tx-category-clear'),
                                  label: categoryFilter,
                                  dot: colorForDetailedCategory(categoryFilter),
                                  selected: true,
                                  trailingIcon: Icons.close_rounded,
                                  onTap: () =>
                                      setState(() => categoryFilter = ''),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                if (filtered.isEmpty && widget.loading)
                  SliverPadding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    sliver: SliverToBoxAdapter(
                      child: Material(
                        color: c.card,
                        shape: cardShape(context),
                        child: const TransactionListSkeleton(rows: 6),
                      ),
                    ),
                  )
                else if (filtered.isEmpty)
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
                    // Clears the floating tab bar.
                    padding: EdgeInsets.fromLTRB(
                      16,
                      0,
                      16,
                      24 + tabBarClearance(context),
                    ),
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
