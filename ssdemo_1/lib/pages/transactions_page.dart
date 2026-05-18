import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import '../widgets/common/labeled_selector_field.dart';
import '../widgets/common/transaction_category_tag.dart';

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
  DateTimeRange? customRange;

  List<int> get _yearOptions {
    final years = <int>{DateTime.now().year, widget.selectedMonth.year};
    for (final tx in widget.transactions) {
      years.add(tx.date.year);
    }
    final sorted = years.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  String get _rangeLabel {
    final selectedMonth = normalizedMonthOption(widget.selectedMonth);
    if (viewMode == ActivityViewMode.month) {
      return monthOptionLabel(selectedMonth);
    }
    if (viewMode == ActivityViewMode.year) return '${selectedMonth.year}';
    if (customRange != null) {
      return '${shortDate(customRange!.start, alwaysShowYear: true)} - ${shortDate(customRange!.end, alwaysShowYear: true)}';
    }
    return 'all time';
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

  @override
  Widget build(BuildContext context) {
    // First filter by time range, then apply the text query.
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

    final filtered = periodTransactions.where((tx) {
      if (query.trim().isEmpty) return true;
      final q = query.toLowerCase();
      return tx.name.toLowerCase().contains(q) ||
          tx.category.toLowerCase().contains(q) ||
          tx.primaryCategory.toLowerCase().contains(q) ||
          (widget.reviewedCategoryByTxId[tx.id]?.toLowerCase().contains(q) ??
              false);
    }).toList();

    return SafeArea(
      child: Column(
        children: [
          // Header filters let the user narrow the full activity list without re-querying.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 8),
            child: Row(
              children: [
                Expanded(
                  child: LabeledSelectorField<ActivityViewMode>(
                    label: 'Range',
                    value: viewMode,
                    options: const [
                      SelectorOption(
                        value: ActivityViewMode.month,
                        label: 'By Month',
                      ),
                      SelectorOption(
                        value: ActivityViewMode.year,
                        label: 'By Year',
                      ),
                      SelectorOption(
                        value: ActivityViewMode.all,
                        label: 'All Time / Custom',
                      ),
                    ],
                    onChanged: (value) {
                      setState(() => viewMode = value);
                    },
                  ),
                ),
                if (viewMode == ActivityViewMode.month ||
                    viewMode == ActivityViewMode.year) ...[
                  const SizedBox(width: 10),
                  Expanded(
                    child: viewMode == ActivityViewMode.month
                        ? LabeledSelectorField<DateTime>(
                            key: ValueKey(
                              'tx-month-${selectedMonth.year}-${selectedMonth.month}-${selectedMonth.day}',
                            ),
                            label: 'Month',
                            value: monthSelectionValue,
                            options: _monthOnlyOptions
                                .map(
                                  (m) => SelectorOption<DateTime>(
                                    value: normalizedMonthOption(m),
                                    label: monthOptionLabel(m),
                                  ),
                                )
                                .toList(),
                            onChanged: widget.onMonthChanged,
                          )
                        : LabeledSelectorField<int>(
                            label: 'Year',
                            value: selectedMonth.year,
                            options: _yearOptions
                                .map(
                                  (y) => SelectorOption<int>(
                                    value: y,
                                    label: '$y',
                                  ),
                                )
                                .toList(),
                            onChanged: (value) {
                              widget.onMonthChanged(DateTime(value, 1, 2));
                            },
                          ),
                  ),
                ],
              ],
            ),
          ),
          if (viewMode == ActivityViewMode.all)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () async {
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
                      onPressed: () => setState(() => customRange = null),
                      icon: const Icon(Icons.clear),
                    ),
                  ],
                ],
              ),
            ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: InputDecoration(
                hintText: 'Search transactions',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.green.withValues(alpha: 0.06),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${filtered.length} transactions ($_rangeLabel)',
                style: const TextStyle(color: Colors.black54),
              ),
            ),
          ),
          Expanded(
            // Main activity list with inline re-categorization for spending rows.
            child: filtered.isEmpty
                ? const Center(child: Text('No transactions found'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final tx = filtered[i];
                      final effectiveCategory = tx.isIncome
                          ? 'Income'
                          : (widget.reviewedCategoryByTxId[tx.id] ??
                                budgetCategoryFromPfc(
                                  pfcDetailed: tx.category,
                                  pfcPrimary: tx.primaryCategory,
                                ));
                      final colorKey =
                          widget.reviewedCategoryByTxId[tx.id] ??
                          effectiveCategory;
                      return ListTile(
                        leading: Icon(iconForTransaction(tx.category, tx.name)),
                        title: Text(tx.name),
                        subtitle: Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(shortDate(tx.date, alwaysShowYear: true)),
                            InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: tx.isIncome
                                  ? null
                                  : () {
                                      showTransactionCategoryPicker(
                                        context: context,
                                        tx: tx,
                                        selectedCategory: effectiveCategory,
                                        onSelected: (category) => widget
                                            .onTransactionCategorySelected(
                                              tx,
                                              category,
                                            ),
                                        aiBackendUri:
                                            widget.aiCategorySuggestUri,
                                        apiKey: widget.apiKey,
                                        accessToken: widget.accessToken,
                                      );
                                    },
                              child: TransactionCategoryTag(
                                label: effectiveCategory,
                                colorKey: colorKey,
                              ),
                            ),
                            Text(
                              'Acct ••••${accountEndingForId(tx.accountId, widget.accountOptions)}',
                              style: const TextStyle(
                                color: Colors.black54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        trailing: Text(
                          formatTransactionMoney(
                            amount: tx.displayAmount,
                            isIncome: tx.isIncome,
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
