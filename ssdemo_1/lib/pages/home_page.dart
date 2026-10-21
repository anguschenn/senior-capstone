import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../models/budget_pace.dart';
import '../utils/app_helpers.dart';
import '../widgets/budget/budget_pace_chart_card.dart';
import '../widgets/common/transaction_category_tag.dart';
import '../widgets/common/ui.dart';

/// Low-confidence transactions still waiting for the user to confirm.
List<AppTransaction> pendingReviewTransactions({
  required List<AppTransaction> transactions,
  required Set<String> manualReviewedTxIds,
  required Set<String> confirmedReviewTxIds,
  required Set<String> lowConfidenceReviewTxIds,
}) {
  return transactions.where((tx) {
    if (confirmedReviewTxIds.contains(tx.id)) return false;
    if (manualReviewedTxIds.contains(tx.id)) return true;
    return lowConfidenceReviewTxIds.contains(tx.id);
  }).toList();
}

/// Category shown for a transaction: the user's pick, else Plaid's.
String effectiveCategoryFor(
  AppTransaction tx,
  Map<String, String> reviewedCategoryByTxId,
) {
  if (tx.isIncome) return reviewedCategoryByTxId[tx.id] ?? tx.inflowLabel;
  return reviewedCategoryByTxId[tx.id] ??
      budgetCategoryFromPfc(
        pfcDetailed: tx.category,
        pfcPrimary: tx.primaryCategory,
      );
}

class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.transactions,
    required this.lowConfidenceTransactions,
    required this.subscriptions,
    required this.monthlySubscriptionTotal,
    required this.stats,
    required this.syncing,
    required this.onAddBank,
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
    this.budgetProgress = const [],
    this.bankSyncBusy = false,
    this.syncStatus = '',
    this.onOpenFlow,
    this.onOpenSettings,
    this.onSeeAllActivity,
    this.onOpenSubscriptions,
    this.aiCategorySuggestUri,
    this.apiKey,
    this.accessToken,
  });

  final List<AppTransaction> transactions;
  final List<AppTransaction> lowConfidenceTransactions;
  final List<DetectedSubscription> subscriptions;
  final double monthlySubscriptionTotal;
  final DashboardStats stats;
  final List<BudgetCategoryProgress> budgetProgress;
  final bool syncing;

  /// A background bank refresh is running: Add Bank waits, but the rest of
  /// the screen (e.g. switching wallet cards) stays usable.
  final bool bankSyncBusy;
  final String syncStatus;
  final VoidCallback onAddBank;
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
  final VoidCallback? onOpenFlow;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onSeeAllActivity;
  final VoidCallback? onOpenSubscriptions;
  final Uri? aiCategorySuggestUri;
  final String? apiKey;
  final String? accessToken;

  Future<void> _showMonthPicker(BuildContext context) async {
    final selected = await showOptionSheet<DateTime>(
      context: context,
      title: 'Select Month',
      values: monthOptions.map(normalizedMonthOption).toList(),
      labelOf: monthOptionLabel,
      selected: normalizedMonthOption(selectedMonth),
    );
    if (selected != null) onMonthChanged(selected);
  }

  void _openReview(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => ReviewTransactionsSheet(
        transactions: pendingReviewTransactions(
          transactions: lowConfidenceTransactions,
          manualReviewedTxIds: manualReviewedTxIds,
          confirmedReviewTxIds: confirmedReviewTxIds,
          lowConfidenceReviewTxIds: lowConfidenceReviewTxIds,
        ),
        accountOptions: accountOptions,
        reviewedCategoryByTxId: reviewedCategoryByTxId,
        onTransactionCategorySelected: onTransactionCategorySelected,
        onReviewConfirm: onReviewConfirm,
        aiCategorySuggestUri: aiCategorySuggestUri,
        apiKey: apiKey,
        accessToken: accessToken,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final busy = syncing || bankSyncBusy;
    final sevenDaysAgo = DateTime.now().subtract(const Duration(days: 7));
    final recentTransactions = transactions
        .where((tx) => tx.date.isAfter(sevenDaysAgo))
        .toList();
    final pending = pendingReviewTransactions(
      transactions: lowConfidenceTransactions,
      manualReviewedTxIds: manualReviewedTxIds,
      confirmedReviewTxIds: confirmedReviewTxIds,
      lowConfidenceReviewTxIds: lowConfidenceReviewTxIds,
    );

    return SafeArea(
      bottom: false,
      child: ListView(
        padding: const EdgeInsets.only(bottom: 24),
        children: [
          LargeTitle(
            'Wallet',
            trailing: [
              CircleIconButton(
                key: const ValueKey('wallet-add-bank'),
                icon: Icons.add_rounded,
                tooltip: 'Add Bank',
                onPressed: busy ? null : onAddBank,
              ),
              CircleIconButton(
                key: const ValueKey('wallet-settings'),
                icon: Icons.settings_outlined,
                tooltip: 'Settings',
                onPressed: onOpenSettings,
              ),
            ],
          ),
          ScopeLine(
            label: busy
                ? '${monthOptionLabel(selectedMonth)} · Syncing…'
                : monthOptionLabel(selectedMonth),
            onTap: () => _showMonthPicker(context),
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 4),
          ),
          WalletCardStack(
            accountOptions: accountOptions,
            selectedAccountId: selectedAccountId,
            selectedBalance: stats.totalBalance,
            enabled: !syncing,
            onAccountChanged: onAccountChanged,
          ),
          const SizedBox(height: 14),
          _FlowThumbnail(
            transactions: transactions,
            budgetProgress: budgetProgress,
            selectedMonth: selectedMonth,
            onTap: onOpenFlow,
          ),
          if (pending.isNotEmpty)
            Section(
              key: const ValueKey('wallet-review'),
              onTap: () => _openReview(context),
              child: InfoRow(
                leading: _RoundIcon(icon: Icons.help_outline, color: c.warn),
                title:
                    '${pending.length} transaction${pending.length == 1 ? '' : 's'} to review',
                subtitle: 'Check the category, then confirm',
              ),
            ),
          SectionHeader(
            'Last 7 days',
            action: 'See all',
            onAction: onSeeAllActivity,
          ),
          Section(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
            child: recentTransactions.isEmpty
                ? Padding(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    child: Text(
                      'No transactions in the last 7 days.',
                      style: TextStyle(color: c.muted),
                    ),
                  )
                : Column(
                    children: [
                      for (final (i, tx)
                          in recentTransactions.take(6).indexed) ...[
                        if (i > 0)
                          Divider(height: 0.5, thickness: 0.5, color: c.line),
                        TransactionRow(
                          tx: tx,
                          accountOptions: accountOptions,
                          reviewedCategoryByTxId: reviewedCategoryByTxId,
                          onTransactionCategorySelected:
                              onTransactionCategorySelected,
                          aiCategorySuggestUri: aiCategorySuggestUri,
                          apiKey: apiKey,
                          accessToken: accessToken,
                        ),
                      ],
                    ],
                  ),
          ),
          const SizedBox(height: 4),
          Section(
            key: const ValueKey('wallet-subscriptions'),
            onTap: onOpenSubscriptions,
            child: Column(
              children: [
                InfoRow(
                  leading: const _RoundIcon(
                    icon: Icons.autorenew_rounded,
                    color: AppPalette.subscriptions,
                  ),
                  title: 'Upcoming subscriptions',
                  subtitle: subscriptions.isEmpty
                      ? 'No recurring subscriptions detected yet'
                      : 'Monthly total: ${formatMoney(monthlySubscriptionTotal, signed: false)}',
                ),
                // The nearest few charges, as the old dashboard listed them.
                for (final sub in subscriptions) ...[
                  Divider(height: 16, thickness: 0.5, color: c.line),
                  Row(
                    children: [
                      const SizedBox(width: 44),
                      Expanded(
                        child: Text(
                          sub.merchant,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 14.5),
                        ),
                      ),
                      Text(
                        'Renews ${shortDate(sub.nextChargeDate)}',
                        style: TextStyle(fontSize: 12.5, color: c.muted),
                      ),
                      const SizedBox(width: 10),
                      Text(
                        formatMoney(sub.amount, signed: false),
                        style: const TextStyle(
                          fontSize: 14.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RoundIcon extends StatelessWidget {
  const _RoundIcon({required this.icon, required this.color});

  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: context.colors.raised,
        shape: BoxShape.circle,
      ),
      child: Icon(icon, size: 18, color: color),
    );
  }
}

/// Apple Wallet–style stack: the other accounts peek out above, the selected
/// one sits in front. Tap a card behind to bring it forward, or swipe the
/// front card left/right to move through the accounts.
class WalletCardStack extends StatelessWidget {
  const WalletCardStack({
    super.key,
    required this.accountOptions,
    required this.selectedAccountId,
    required this.selectedBalance,
    required this.onAccountChanged,
    this.enabled = true,
  });

  final List<AccountOption> accountOptions;
  final String selectedAccountId;

  /// Balance (net worth for All Accounts) of the selected scope.
  final double selectedBalance;
  final ValueChanged<String> onAccountChanged;
  final bool enabled;

  static const double _peek = 44;
  static const double _cardHeight = 172;
  static const int _maxBehind = 4;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final ids = [kAllAccountsId, for (final a in accountOptions) a.accountId];
    final selected = ids.contains(selectedAccountId)
        ? selectedAccountId
        : kAllAccountsId;
    final others = ids.where((id) => id != selected).toList();
    // Many accounts would make a very tall stack: show a few, and put the
    // rest behind a "More accounts" strip that opens a list.
    final overflow = others.length > _maxBehind;
    final behind = overflow ? others.take(_maxBehind - 1).toList() : others;
    final strips = behind.length + (overflow ? 1 : 0);

    Color colorFor(String id) {
      if (id == kAllAccountsId) return AppPalette.walletAll;
      final i = accountOptions.indexWhere((a) => a.accountId == id);
      return AppPalette.walletCards[i % AppPalette.walletCards.length];
    }

    AccountOption? optionFor(String id) {
      for (final a in accountOptions) {
        if (a.accountId == id) return a;
      }
      return null;
    }

    String titleFor(String id) {
      if (id == kAllAccountsId) return 'All Accounts';
      final label = optionFor(id)?.label ?? id;
      // Labels end with "••••1234"; the ending is shown on the right instead.
      return label.replaceAll(RegExp(r'\s*•+\s*\d+\s*$'), '');
    }

    String detailFor(String id) {
      if (id == kAllAccountsId) {
        final n = accountOptions.length;
        return '$n account${n == 1 ? '' : 's'}';
      }
      final ending = optionFor(id)?.ending ?? '';
      return ending.isEmpty ? '' : '••$ending';
    }

    void move(int step) {
      final i = ids.indexOf(selected);
      final next = (i + step) % ids.length;
      if (next != i) onAccountChanged(ids[next < 0 ? next + ids.length : next]);
    }

    Widget card(String id, {required bool front, required double top}) {
      const onCard = Color(0xFFFBF8F2);
      final body = Container(
        height: _cardHeight,
        padding: const EdgeInsets.fromLTRB(18, 13, 18, 16),
        decoration: BoxDecoration(
          color: colorFor(id),
          borderRadius: BorderRadius.circular(16),
          boxShadow: [
            BoxShadow(
              color: c.cardShadow,
              blurRadius: 16,
              offset: const Offset(0, -6),
            ),
          ],
        ),
        child: DefaultTextStyle(
          style: const TextStyle(color: onCard),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      titleFor(id),
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    detailFor(id),
                    style: TextStyle(
                      fontSize: 13,
                      color: onCard.withValues(alpha: 0.75),
                    ),
                  ),
                ],
              ),
              if (front) ...[
                const Spacer(),
                Text(
                  id == kAllAccountsId ? 'Net Worth' : 'Balance',
                  style: TextStyle(
                    fontSize: 13,
                    color: onCard.withValues(alpha: 0.75),
                  ),
                ),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(
                    selectedBalance < 0
                        ? dollars(selectedBalance, sign: true)
                        : dollars(selectedBalance),
                    style: const TextStyle(
                      fontSize: 32,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.6,
                    ),
                  ),
                ),
              ],
            ],
          ),
        ),
      );
      return Positioned(
        left: 0,
        right: 0,
        top: top,
        child: GestureDetector(
          key: ValueKey('wallet-card-$id'),
          behavior: HitTestBehavior.opaque,
          onTap: !enabled || front ? null : () => onAccountChanged(id),
          onHorizontalDragEnd: !enabled || !front
              ? null
              : (d) {
                  final v = d.primaryVelocity ?? 0;
                  if (v.abs() < 150) return;
                  move(v < 0 ? 1 : -1);
                },
          child: body,
        ),
      );
    }

    // Page dots under the stack: one per account, the selected one long, so
    // it's clear the front card can be swiped.
    final dots = ids.length < 2
        ? null
        : Padding(
            key: const ValueKey('wallet-dots'),
            padding: const EdgeInsets.only(top: 10),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                for (final id in ids)
                  AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    margin: const EdgeInsets.symmetric(horizontal: 3),
                    width: id == selected ? 16 : 6,
                    height: 6,
                    decoration: BoxDecoration(
                      color: id == selected
                          ? c.text
                          : c.muted.withValues(alpha: 0.45),
                      borderRadius: BorderRadius.circular(3),
                    ),
                  ),
              ],
            ),
          );

    return AnimatedSize(
      duration: const Duration(milliseconds: 200),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              height: strips * _peek + _cardHeight,
              child: Stack(
                children: [
                  for (final (i, id) in behind.indexed)
                    card(id, front: false, top: i * _peek),
                  if (overflow)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: behind.length * _peek,
                      child: GestureDetector(
                        key: const ValueKey('wallet-more-accounts'),
                        behavior: HitTestBehavior.opaque,
                        onTap: !enabled
                            ? null
                            : () async {
                                final picked = await showOptionSheet<String>(
                                  context: context,
                                  title: 'Accounts',
                                  values: ids,
                                  labelOf: (id) => id == kAllAccountsId
                                      ? 'All Accounts'
                                      : (optionFor(id)?.label ?? id),
                                  selected: selected,
                                );
                                if (picked != null) onAccountChanged(picked);
                              },
                        child: Container(
                          height: _cardHeight,
                          padding: const EdgeInsets.fromLTRB(18, 13, 18, 16),
                          alignment: Alignment.topLeft,
                          decoration: BoxDecoration(
                            color: c.raised,
                            borderRadius: BorderRadius.circular(16),
                            boxShadow: [
                              BoxShadow(
                                color: c.cardShadow,
                                blurRadius: 16,
                                offset: const Offset(0, -6),
                              ),
                            ],
                          ),
                          child: Text(
                            'More accounts (${others.length - behind.length})',
                            style: const TextStyle(
                              fontSize: 15.5,
                              fontWeight: FontWeight.w700,
                            ),
                          ),
                        ),
                      ),
                    ),
                  card(selected, front: true, top: strips * _peek),
                ],
              ),
            ),
            ?dots,
          ],
        ),
      ),
    );
  }
}

/// "Cash Flow · October ›" card: budget left, pace, and a mini pace chart.
/// Tapping it opens the full Cash Flow page.
class _FlowThumbnail extends StatelessWidget {
  const _FlowThumbnail({
    required this.transactions,
    required this.budgetProgress,
    required this.selectedMonth,
    required this.onTap,
  });

  final List<AppTransaction> transactions;
  final List<BudgetCategoryProgress> budgetProgress;
  final DateTime selectedMonth;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    double income = 0;
    double expenses = 0;
    for (final tx in transactions) {
      if (!transactionInSelectedPeriod(tx, selectedMonth)) continue;
      income += tx.incomeAmount;
      expenses += tx.expenseAmount;
    }
    final net = income - expenses;
    final monthView = !isAllYearOption(selectedMonth);
    final snapshot = monthView
        ? BudgetPaceSnapshot.build(
            focusMonth: normalizedMonthOption(selectedMonth),
            budgets: budgetProgress,
            transactions: transactions,
          )
        : null;
    final label = monthView
        ? kMonthShortLabels[selectedMonth.month - 1]
        : '${selectedMonth.year}';

    Widget stat(String title, String value, {Color? color}) => Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: 12, color: c.muted)),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: color ?? c.text,
            ),
          ),
        ],
      ),
    );

    return Section(
      key: const ValueKey('wallet-flow'),
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                'Cash Flow · $label',
                style: const TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              Icon(Icons.chevron_right_rounded, size: 18, color: c.muted),
            ],
          ),
          if (snapshot != null && snapshot.hasBudget) ...[
            const SizedBox(height: 8),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        dollars(snapshot.remaining, decimals: 0),
                        style: TextStyle(
                          fontSize: 28,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.6,
                          color: snapshot.isOverBudget ? c.bad : c.text,
                        ),
                      ),
                      Text(
                        snapshot.isOverBudget ? 'over budget' : 'budget left',
                        style: TextStyle(fontSize: 13, color: c.muted),
                      ),
                      const SizedBox(height: 8),
                      StatusPill(
                        label: snapshot.isUnderPace
                            ? '${dollars(snapshot.paceDelta, decimals: 0)} under pace'
                            : '${dollars(snapshot.paceDelta, decimals: 0)} over pace',
                        background: snapshot.isUnderPace
                            ? c.goodTint
                            : c.bad.withValues(alpha: 0.16),
                        foreground: snapshot.isUnderPace ? c.good : c.bad,
                      ),
                    ],
                  ),
                ),
                BudgetPaceMiniChart(snapshot: snapshot),
              ],
            ),
          ],
          const SizedBox(height: 12),
          Row(
            children: [
              stat('Income', formatMoney(income, signed: false)),
              stat('Expenses', formatMoney(expenses, signed: false)),
              stat(
                'Cash flow',
                dollars(net, sign: true),
                color: net >= 0 ? c.good : c.bad,
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// One transaction: category dot, merchant, date + category tag, amount.
/// Tapping the tag opens the category picker (spending only).
class TransactionRow extends StatelessWidget {
  const TransactionRow({
    super.key,
    required this.tx,
    required this.accountOptions,
    required this.reviewedCategoryByTxId,
    required this.onTransactionCategorySelected,
    this.aiCategorySuggestUri,
    this.apiKey,
    this.accessToken,
    this.showDate = true,
    this.alwaysPickable = false,
  });

  final AppTransaction tx;
  final List<AccountOption> accountOptions;
  final Map<String, String> reviewedCategoryByTxId;
  final void Function(AppTransaction tx, String category)
  onTransactionCategorySelected;
  final Uri? aiCategorySuggestUri;
  final String? apiKey;
  final String? accessToken;
  final bool showDate;

  /// Lets income be re-categorised too (the review sheet allows it).
  final bool alwaysPickable;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final category = effectiveCategoryFor(tx, reviewedCategoryByTxId);
    final tone = colorForDetailedCategory(category);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 9),
      child: Row(
        children: [
          CategoryDot(
            color: tone,
            icon: iconForCategoryLabel(category, tx.name),
            size: 34,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  tx.name,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 3),
                Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    if (showDate)
                      Text(
                        shortDate(tx.date, alwaysShowYear: true),
                        style: TextStyle(color: c.muted, fontSize: 12),
                      ),
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: tx.isIncome && !alwaysPickable
                          ? null
                          : () => showTransactionCategoryPicker(
                              context: context,
                              tx: tx,
                              selectedCategory: category,
                              onSelected: (picked) =>
                                  onTransactionCategorySelected(tx, picked),
                              aiBackendUri: aiCategorySuggestUri,
                              apiKey: apiKey,
                              accessToken: accessToken,
                            ),
                      child: TransactionCategoryTag(
                        label: category,
                        colorKey: category,
                      ),
                    ),
                    Text(
                      '••${accountEndingForId(tx.accountId, accountOptions)}',
                      style: TextStyle(color: c.muted, fontSize: 12),
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          Text(
            formatTransactionMoney(
              amount: tx.displayAmount,
              isIncome: tx.isIncome,
            ),
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w600,
              color: tx.isIncome ? c.good : c.text,
            ),
          ),
        ],
      ),
    );
  }
}

/// Sheet listing transactions whose category needs a quick check.
class ReviewTransactionsSheet extends StatefulWidget {
  const ReviewTransactionsSheet({
    super.key,
    required this.transactions,
    required this.accountOptions,
    required this.reviewedCategoryByTxId,
    required this.onTransactionCategorySelected,
    required this.onReviewConfirm,
    this.aiCategorySuggestUri,
    this.apiKey,
    this.accessToken,
  });

  final List<AppTransaction> transactions;
  final List<AccountOption> accountOptions;
  final Map<String, String> reviewedCategoryByTxId;
  final void Function(AppTransaction tx, String category)
  onTransactionCategorySelected;
  final Future<void> Function(String txId) onReviewConfirm;
  final Uri? aiCategorySuggestUri;
  final String? apiKey;
  final String? accessToken;

  @override
  State<ReviewTransactionsSheet> createState() =>
      _ReviewTransactionsSheetState();
}

class _ReviewTransactionsSheetState extends State<ReviewTransactionsSheet> {
  // The sheet was built from a snapshot of the page, so picks and confirms
  // made here are mirrored locally until the sheet closes.
  final _picked = <String, String>{};
  final _confirmed = <String>{};

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final items = widget.transactions
        .where((tx) => !_confirmed.contains(tx.id))
        .toList();
    final categories = {...widget.reviewedCategoryByTxId, ..._picked};
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, scroll) => ListView(
        controller: scroll,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          Center(
            child: Container(
              width: 36,
              height: 5,
              decoration: BoxDecoration(
                color: c.line,
                borderRadius: BorderRadius.circular(99),
              ),
            ),
          ),
          const SizedBox(height: 12),
          const Text(
            'Review Transactions',
            style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Tap the category to change it, then confirm.',
            style: TextStyle(color: c.muted, fontSize: 13),
          ),
          const SizedBox(height: 12),
          if (items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 24),
              child: Center(
                child: Text('All caught up.', style: TextStyle(color: c.muted)),
              ),
            ),
          for (final tx in items)
            Container(
              margin: const EdgeInsets.only(bottom: 10),
              padding: const EdgeInsets.fromLTRB(14, 4, 10, 8),
              decoration: BoxDecoration(
                color: c.card,
                borderRadius: BorderRadius.circular(14),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  TransactionRow(
                    tx: tx,
                    accountOptions: widget.accountOptions,
                    reviewedCategoryByTxId: categories,
                    alwaysPickable: true,
                    onTransactionCategorySelected: (tx, category) {
                      setState(() => _picked[tx.id] = category);
                      widget.onTransactionCategorySelected(tx, category);
                    },
                    aiCategorySuggestUri: widget.aiCategorySuggestUri,
                    apiKey: widget.apiKey,
                    accessToken: widget.accessToken,
                  ),
                  FilledButton(
                    onPressed: () async {
                      setState(() => _confirmed.add(tx.id));
                      await widget.onReviewConfirm(tx.id);
                    },
                    style: FilledButton.styleFrom(
                      minimumSize: const Size(80, 32),
                      visualDensity: VisualDensity.compact,
                    ),
                    child: const Text('Confirm'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
