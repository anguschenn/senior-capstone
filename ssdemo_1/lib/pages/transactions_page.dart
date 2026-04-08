import 'package:flutter/material.dart';

import '../models/app_models.dart';
import '../utils/app_helpers.dart';

class TransactionsPage extends StatefulWidget {
  const TransactionsPage({
    super.key,
    required this.transactions,
    required this.accountOptions,
    required this.reviewedCategoryByTxId,
    required this.onTransactionCategorySelected,
  });

  final List<AppTransaction> transactions;
  final List<AccountOption> accountOptions;
  final Map<String, String> reviewedCategoryByTxId;
  final void Function(AppTransaction tx, String category) onTransactionCategorySelected;

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  String query = '';
  ActivityViewMode viewMode = ActivityViewMode.month;

  @override
  Widget build(BuildContext context) {
    // First filter by time range, then apply the text query.
    final now = DateTime.now();
    final periodTransactions = widget.transactions.where((tx) {
      if (viewMode == ActivityViewMode.month) {
        return tx.date.year == now.year && tx.date.month == now.month;
      }
      if (viewMode == ActivityViewMode.year) {
        return tx.date.year == now.year;
      }
      return true;
    }).toList();

    final filtered = periodTransactions.where((tx) {
      if (query.trim().isEmpty) return true;
      final q = query.toLowerCase();
      return tx.name.toLowerCase().contains(q) ||
          tx.category.toLowerCase().contains(q) ||
          tx.primaryCategory.toLowerCase().contains(q) ||
          (widget.reviewedCategoryByTxId[tx.id]?.toLowerCase().contains(q) ?? false);
    }).toList();

    return SafeArea(
      child: Column(
        children: [
          // Header filters let the user narrow the full activity list without re-querying.
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: SegmentedButton<ActivityViewMode>(
              segments: const [
                ButtonSegment<ActivityViewMode>(
                  value: ActivityViewMode.month,
                  label: Text('This Month'),
                ),
                ButtonSegment<ActivityViewMode>(
                  value: ActivityViewMode.year,
                  label: Text('This Year'),
                ),
                ButtonSegment<ActivityViewMode>(
                  value: ActivityViewMode.all,
                  label: Text('All Time'),
                ),
              ],
              selected: {viewMode},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                setState(() => viewMode = selection.first);
              },
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
                '${filtered.length} transactions (${viewMode == ActivityViewMode.month ? 'this month' : (viewMode == ActivityViewMode.year ? 'this year' : 'all time')})',
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
                      final effectiveCategory = tx.amount < 0
                          ? 'Income'
                          : (widget.reviewedCategoryByTxId[tx.id] ??
                                budgetCategoryFromPfc(
                                  pfcDetailed: tx.category,
                                  pfcPrimary: tx.primaryCategory,
                                ));
                      final colorKey =
                          widget.reviewedCategoryByTxId[tx.id] ?? effectiveCategory;
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
                              onTap: tx.amount < 0
                                  ? null
                                  : () {
                                showTransactionCategoryPicker(
                                  context: context,
                                  tx: tx,
                                  selectedCategory: effectiveCategory,
                                  onSelected: (category) =>
                                      widget.onTransactionCategorySelected(tx, category),
                                );
                              },
                              child: TransactionCategoryTag(
                                label: effectiveCategory,
                                colorKey: colorKey,
                              ),
                            ),
                            Text(
                              'Acct ••••${accountEndingForId(tx.accountId, widget.accountOptions)}',
                              style: const TextStyle(color: Colors.black54, fontSize: 12),
                            ),
                          ],
                        ),
                        trailing: Text(formatMoney(tx.amount)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

