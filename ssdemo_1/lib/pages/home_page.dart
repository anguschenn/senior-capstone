import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import '../widgets/common/transaction_category_tag.dart';
import '../widgets/dashboard_sections.dart';

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.transactions,
    required this.lowConfidenceTransactions,
    required this.subscriptions,
    required this.monthlySubscriptionTotal,
    required this.stats,
    required this.syncing,
    required this.syncStatus,
    required this.onConnectBank,
    required this.onRefreshLiveData,
    required this.onClearLiveData,
    required this.accountOptions,
    required this.selectedAccountId,
    required this.selectedMonth,
    required this.monthOptions,
    required this.onMonthChanged,
    required this.reviewedCategoryByTxId,
    required this.manualReviewedTxIds,
    required this.confirmedReviewTxIds,
    required this.lowConfidenceReviewTxIds,
    required this.onAccountChanged,
    required this.onTransactionCategorySelected,
    required this.onReviewConfirm,
  });

  final List<AppTransaction> transactions;
  final List<AppTransaction> lowConfidenceTransactions;
  final List<DetectedSubscription> subscriptions;
  final double monthlySubscriptionTotal;
  final DashboardStats stats;
  final bool syncing;
  final String syncStatus;
  final VoidCallback onConnectBank;
  final VoidCallback onRefreshLiveData;
  final VoidCallback onClearLiveData;
  final List<AccountOption> accountOptions;
  final String selectedAccountId;
  final DateTime selectedMonth;
  final List<DateTime> monthOptions;
  final ValueChanged<DateTime> onMonthChanged;
  final Map<String, String> reviewedCategoryByTxId;
  final Set<String> manualReviewedTxIds;
  final Set<String> confirmedReviewTxIds;
  final Set<String> lowConfidenceReviewTxIds;
  final ValueChanged<String> onAccountChanged;
  final void Function(AppTransaction tx, String category)
  onTransactionCategorySelected;
  final Future<void> Function(String txId) onReviewConfirm;

  Future<void> _showMonthPicker(BuildContext context) async {
    final normalizedSelected = normalizedMonthOption(selectedMonth);
    final selected = await showModalBottomSheet<DateTime>(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: 8),
              Container(
                width: 44,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.black26,
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              const SizedBox(height: 12),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    Text(
                      'Select Month',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.fromLTRB(12, 0, 12, 16),
                  itemCount: monthOptions.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 2),
                  itemBuilder: (context, index) {
                    final raw = monthOptions[index];
                    final option = normalizedMonthOption(raw);
                    final isSelected = option == normalizedSelected;
                    return ListTile(
                      dense: true,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      tileColor: isSelected
                          ? Theme.of(context).colorScheme.primary.withOpacity(0.10)
                          : null,
                      title: Text(
                        monthOptionLabel(raw),
                        style: TextStyle(
                          fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                        ),
                      ),
                      trailing: isSelected
                          ? Icon(
                              Icons.check_rounded,
                              color: Theme.of(context).colorScheme.primary,
                            )
                          : null,
                      onTap: () => Navigator.of(context).pop(option),
                    );
                  },
                ),
              ),
            ],
          ),
        );
      },
    );
    if (selected != null) {
      onMonthChanged(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    double displayIncome = 0;
    double displayExpenses = 0;
    for (final tx in transactions) {
      if (!transactionInSelectedPeriod(tx, selectedMonth)) continue;
      displayIncome += tx.incomeAmount;
      displayExpenses += tx.expenseAmount;
    }
    final displayNet = displayIncome - displayExpenses;
    final periodLabel = periodLabelForSelection(selectedMonth);

    final incomeTitle = 'Income ($periodLabel)';
    final expensesTitle = 'Expenses ($periodLabel)';
    final cashFlowLabel = 'Cash Flow ($periodLabel)';
    final selectorDecoration = InputDecoration(
      isDense: true,
      filled: true,
      fillColor: Colors.grey.shade50,
      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.black.withOpacity(0.08)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: Colors.black.withOpacity(0.08)),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(12),
        borderSide: BorderSide(color: theme.colorScheme.primary, width: 1.4),
      ),
    );
    final selectorValueStyle = theme.textTheme.titleMedium?.copyWith(
      fontWeight: FontWeight.w500,
      color: Colors.black87,
    );
    final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
    final recentTransactions = transactions
        .where((tx) => tx.date.isAfter(sevenDaysAgo))
        .toList();

    // Review queue shows low-confidence transactions (income + expense).
    final pendingReviewTransactions = lowConfidenceTransactions.where((tx) {
      if (confirmedReviewTxIds.contains(tx.id)) {
        return false;
      }
      if (manualReviewedTxIds.contains(tx.id)) {
        return true;
      }
      return lowConfidenceReviewTxIds.contains(tx.id);
    }).toList();
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Page header and global data actions.
          // Top action row controls data sync/refresh for the whole app.
          const Text(
            'SmartSpend',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: syncing ? null : onConnectBank,
                icon: syncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_link),
                label: Text(syncing
                    ? 'Syncing'
                    : accountOptions.isEmpty
                        ? 'Connect Bank'
                        : 'Add Account'),
              ),
              OutlinedButton(
                onPressed: syncing ? null : onRefreshLiveData,
                child: const Text('Refresh'),
              ),
              TextButton(
                onPressed: syncing ? null : onClearLiveData,
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(syncStatus, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text(
                  'Account',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  style: selectorValueStyle,
                  icon: const Icon(Icons.keyboard_arrow_down_rounded),
                  value: selectedAccountId,
                  decoration: selectorDecoration,
                  items: [
                    DropdownMenuItem<String>(
                      value: kAllAccountsId,
                      child: Text('All Accounts', style: selectorValueStyle),
                    ),
                    ...accountOptions.map(
                      (account) => DropdownMenuItem<String>(
                        value: account.accountId,
                        child: Text(
                          '${account.label} (${account.txCount})',
                          style: selectorValueStyle,
                        ),
                      ),
                    ),
                  ],
                  onChanged: syncing
                      ? null
                      : (value) {
                          if (value == null) return;
                          onAccountChanged(value);
                        },
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              SizedBox(
                width: 76,
                child: Text(
                  'Month',
                  style: theme.textTheme.bodyMedium?.copyWith(
                    fontWeight: FontWeight.w600,
                    color: Colors.black87,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: InkWell(
                  borderRadius: BorderRadius.circular(12),
                  onTap: () => _showMonthPicker(context),
                  child: InputDecorator(
                  decoration: selectorDecoration,
                    child: Row(
                      children: [
                        Expanded(
                          child: Text(
                            monthOptionLabel(selectedMonth),
                            style: selectorValueStyle,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Icon(Icons.keyboard_arrow_down_rounded),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text('Net Worth'),
          Text(
            '${stats.totalBalance < 0 ? '- ' : ''}\$${stats.totalBalance.abs().toStringAsFixed(2)}',
            style: TextStyle(
              fontSize: 32,
              fontWeight: FontWeight.bold,
              color: stats.totalBalance < 0 ? Colors.red : Colors.black,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '$cashFlowLabel: ${displayNet >= 0 ? '+ ' : '- '}\$${displayNet.abs().toStringAsFixed(2)}',
            style: TextStyle(
              color: displayNet >= 0 ? Colors.green : Colors.red,
            ),
          ),
          const SizedBox(height: 20),
          // High-level financial summary for the selected account scope.
          // Compact dashboard cards for current balances and monthly totals.
          Row(
            children: [
              Expanded(
                child: SummaryCard(
                  title: incomeTitle,
                  value: formatMoney(displayIncome, signed: false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SummaryCard(
                  title: expensesTitle,
                  value: formatMoney(displayExpenses, signed: false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          // Most recent transaction preview shown on the dashboard.
          // Recent transactions show the latest few rows from the active account filter.
          const Text(
            'Recent Transactions (Last 7 Days)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          if (recentTransactions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No transactions in the last 7 days.'),
            ),
          ...recentTransactions.map((tx) {
            final effectiveCategory = tx.isIncome
                ? 'Income'
                : (reviewedCategoryByTxId[tx.id] ??
                      budgetCategoryFromPfc(
                        pfcDetailed: tx.category,
                        pfcPrimary: tx.primaryCategory,
                      ));
            final colorKey = reviewedCategoryByTxId[tx.id] ?? effectiveCategory;
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
                              onSelected: (category) =>
                                  onTransactionCategorySelected(tx, category),
                            );
                          },
                    child: TransactionCategoryTag(
                      label: effectiveCategory,
                      colorKey: colorKey,
                    ),
                  ),
                  Text(
                    'Acct ••••${accountEndingForId(tx.accountId, accountOptions)}',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
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
          }),
          const SizedBox(height: 16),
          // Manual review queue for uncertain spending categories.
          // Review queue surfaces low-confidence spending classifications for manual correction.
          const Text(
            'Review Transactions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (pendingReviewTransactions.isEmpty)
            const Text(
              'No low-confidence transactions to review.',
              style: TextStyle(color: Colors.black54),
            ),
          ...pendingReviewTransactions.map((tx) {
            final selected =
                reviewedCategoryByTxId[tx.id] ??
                (tx.isIncome
                    ? 'Income'
                    : budgetCategoryFromPfc(
                        pfcDetailed: tx.category,
                        pfcPrimary: tx.primaryCategory,
                      ));
            return Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.03),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    tx.name,
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(
                              shortDate(tx.date, alwaysShowYear: true),
                              style: const TextStyle(
                                color: Colors.black54,
                                fontSize: 12,
                              ),
                            ),
                            InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: () {
                                showTransactionCategoryPicker(
                                  context: context,
                                  tx: tx,
                                  selectedCategory: selected,
                                  onSelected: (category) =>
                                      onTransactionCategorySelected(
                                        tx,
                                        category,
                                      ),
                                );
                              },
                              child: TransactionCategoryTag(
                                label: selected,
                                colorKey: selected,
                              ),
                            ),
                            Text(
                              'Acct ••••${accountEndingForId(tx.accountId, accountOptions)}',
                              style: const TextStyle(
                                color: Colors.black54,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      FilledButton(
                        onPressed: () async => onReviewConfirm(tx.id),
                        style: FilledButton.styleFrom(
                          minimumSize: const Size(52, 30),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 0,
                          ),
                          visualDensity: VisualDensity.compact,
                        ),
                        child: const Text(
                          'Confirm',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    formatTransactionMoney(
                      amount: tx.displayAmount,
                      isIncome: tx.isIncome,
                    ),
                    style: const TextStyle(fontWeight: FontWeight.w600),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Tap category tag to adjust, then confirm to mark reviewed.',
                    style: const TextStyle(color: Colors.black54, fontSize: 12),
                  ),
                ],
              ),
            );
          }),
          const SizedBox(height: 20),
          // Short subscription preview to surface upcoming recurring charges.
          // Subscription preview shows only the nearest few detected recurring charges.
          const Text(
            'Upcoming Subscriptions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          Text(
            'Monthly total: ${formatMoney(monthlySubscriptionTotal, signed: false)}',
            style: const TextStyle(color: Colors.black54),
          ),
          if (subscriptions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No recurring subscriptions detected yet.'),
            ),
          ...subscriptions.map(
            (sub) => ListTile(
              leading: const Icon(Icons.subscriptions_outlined),
              title: Text(sub.merchant),
              subtitle: Text('Renews ${shortDate(sub.nextChargeDate)}'),
              trailing: Text(formatMoney(sub.amount, signed: false)),
            ),
          ),
        ],
      ),
    );
  }
}
