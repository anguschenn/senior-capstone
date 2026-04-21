import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import '../widgets/common/transaction_category_tag.dart';
import '../widgets/dashboard_widgets.dart';

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
    required this.onConnectPlaid,
    required this.onRefreshLiveData,
    required this.onClearLiveData,
    required this.accountOptions,
    required this.selectedAccountId,
    required this.selectedMonth,
    required this.monthOptions,
    required this.onMonthChanged,
    required this.reviewedCategoryByTxId,
    required this.confirmedReviewTxIds,
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
  final VoidCallback onConnectPlaid;
  final VoidCallback onRefreshLiveData;
  final VoidCallback onClearLiveData;
  final List<AccountOption> accountOptions;
  final String selectedAccountId;
  final DateTime selectedMonth;
  final List<DateTime> monthOptions;
  final ValueChanged<DateTime> onMonthChanged;
  final Map<String, String> reviewedCategoryByTxId;
  final Set<String> confirmedReviewTxIds;
  final ValueChanged<String> onAccountChanged;
  final void Function(AppTransaction tx, String category)
  onTransactionCategorySelected;
  final void Function(String txId) onReviewConfirm;

  @override
  Widget build(BuildContext context) {
    double displayIncome = 0;
    double displayExpenses = 0;
    for (final tx in transactions) {
      if (tx.date.year != selectedMonth.year ||
          tx.date.month != selectedMonth.month) {
        continue;
      }
      if (tx.amount < 0) {
        displayIncome += tx.amount.abs();
      } else {
        displayExpenses += tx.amount;
      }
    }
    final displayNet = displayIncome - displayExpenses;
    final periodLabel =
        '${kMonthShortLabels[selectedMonth.month - 1]} ${selectedMonth.year}';

    final incomeTitle = 'Income ($periodLabel)';
    final expensesTitle = 'Expenses ($periodLabel)';
    final netLabel = 'Net ($periodLabel)';

    // Review queue focuses on spending transactions with low confidence
    // or transactions the user manually changed but has not confirmed yet.
    final pendingReviewTransactions = lowConfidenceTransactions
        .where(
          (tx) =>
              !confirmedReviewTxIds.contains(tx.id) &&
              tx.amount > 0 &&
              (tx.confidence == 'low' ||
                  reviewedCategoryByTxId.containsKey(tx.id)),
        )
        .toList();
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
                onPressed: syncing ? null : onConnectPlaid,
                icon: syncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link),
                label: Text(syncing ? 'Syncing' : 'Connect'),
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
              const Text(
                'Account',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: selectedAccountId,
                      items: [
                        const DropdownMenuItem<String>(
                          value: kAllAccountsId,
                          child: Text('All Accounts'),
                        ),
                        ...accountOptions.map(
                          (account) => DropdownMenuItem<String>(
                            value: account.accountId,
                            child: Text(
                              '${account.label} (${account.txCount})',
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
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text(
                'Month',
                style: TextStyle(fontWeight: FontWeight.w600),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<DateTime>(
                      key: ValueKey(
                        'home-month-${selectedMonth.year}-${selectedMonth.month}',
                      ),
                      isExpanded: true,
                      value: DateTime(
                        selectedMonth.year,
                        selectedMonth.month,
                        1,
                      ),
                      items: monthOptions
                          .map(
                            (m) => DropdownMenuItem<DateTime>(
                              value: DateTime(m.year, m.month, 1),
                              child: Text(
                                '${kMonthShortLabels[m.month - 1]} ${m.year}',
                              ),
                            ),
                          )
                          .toList(),
                      onChanged: (value) {
                        if (value == null) return;
                        onMonthChanged(value);
                      },
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
            '$netLabel: ${displayNet >= 0 ? '+ ' : '- '}\$${displayNet.abs().toStringAsFixed(2)}',
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
            'Recent Transactions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          if (transactions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No transactions yet. Tap Connect or Refresh.'),
            ),
          ...transactions.take(3).map((tx) {
            final effectiveCategory = tx.amount < 0
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
                    onTap: tx.amount < 0
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
              trailing: Text(formatMoney(tx.amount)),
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
            final selected = tx.amount < 0
                ? 'Income'
                : (reviewedCategoryByTxId[tx.id] ??
                      budgetCategoryFromPfc(
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
                              onTap: tx.amount < 0
                                  ? null
                                  : () {
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
                        onPressed: () => onReviewConfirm(tx.id),
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
                    formatMoney(tx.amount),
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
