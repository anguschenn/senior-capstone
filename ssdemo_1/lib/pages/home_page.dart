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
  if (tx.kind == TxKind.internal) return kInternalTransfer;
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
    this.onReconnect,
    this.onRefresh,
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
    this.onLinkPayback,
    this.onTransactionTap,
    this.budgetProgress = const [],
    this.bankSyncBusy = false,
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
  final VoidCallback onAddBank;
  final VoidCallback? onReconnect;
  final VoidCallback? onRefresh;
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

  /// Lets the user link money from a friend to the purchase it pays back;
  /// true when it was linked.
  final Future<bool> Function(BuildContext context, AppTransaction tx)?
  onLinkPayback;
  final void Function(BuildContext context, AppTransaction tx)?
  onTransactionTap;
  final VoidCallback? onOpenFlow;
  final VoidCallback? onOpenSettings;
  final VoidCallback? onSeeAllActivity;
  final VoidCallback? onOpenSubscriptions;
  final Uri? aiCategorySuggestUri;
  final String? apiKey;
  final String? accessToken;

  Future<void> _showMonthPicker(BuildContext context) async {
    final selected = await showMonthGridPicker(
      context: context,
      options: monthOptions.map(normalizedMonthOption).toList(),
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
        onLinkPayback: onLinkPayback,
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
        // Clears the floating tab bar.
        padding: EdgeInsets.only(bottom: 24 + tabBarClearance(context)),
        children: [
          LargeTitle(
            'Wallet',
            trailing: [
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
            padding: const EdgeInsets.fromLTRB(20, 0, 14, 4),
            // Bank shortcuts, also in Settings.
            actions: [
              _Shortcut(
                key: const ValueKey('wallet-add-bank'),
                icon: Icons.add_rounded,
                label: 'Add',
                onPressed: busy ? null : onAddBank,
              ),
              if (accountOptions.isNotEmpty && onReconnect != null)
                _Shortcut(
                  key: const ValueKey('wallet-reconnect'),
                  icon: Icons.link_rounded,
                  label: 'Reconnect',
                  onPressed: busy ? null : onReconnect,
                ),
              if (onRefresh != null)
                _Shortcut(
                  key: const ValueKey('wallet-refresh'),
                  icon: Icons.refresh_rounded,
                  label: 'Refresh',
                  onPressed: busy ? null : onRefresh,
                ),
            ],
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
            // Rows pad themselves, so their tap highlight spans the card.
            padding: const EdgeInsets.symmetric(vertical: 4),
            child: recentTransactions.isEmpty
                ? Padding(
                    padding: const EdgeInsets.all(14),
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
                          accountOptions: accountOptions,
                          reviewedCategoryByTxId: reviewedCategoryByTxId,
                          onTransactionCategorySelected:
                              onTransactionCategorySelected,
                          aiCategorySuggestUri: aiCategorySuggestUri,
                          apiKey: apiKey,
                          accessToken: accessToken,
                          onTap: onTransactionTap == null
                              ? null
                              : () => onTransactionTap!(context, tx),
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

/// Small round button with a word under it, so it reads on a phone where
/// there is no hover tooltip.
class _Shortcut extends StatelessWidget {
  const _Shortcut({
    super.key,
    required this.icon,
    required this.label,
    required this.onPressed,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    // Quiet on purpose: the month and the cards are the point of the page.
    return Semantics(
      button: true,
      label: label,
      child: Pressable(
        enabled: onPressed != null,
        child: InkWell(
          onTap: onPressed,
          customBorder: const CircleBorder(),
          child: SizedBox(
            width: 32,
            height: 32,
            child: Icon(
              icon,
              size: 19,
              color: c.muted.withValues(alpha: onPressed == null ? 0.4 : 0.85),
            ),
          ),
        ),
      ),
    );
  }
}

/// The All Accounts card colour: the account cards' colours mixed evenly,
/// so it reads as all of them together. No accounts: the old green.
Color _blend(List<Color> colors) {
  if (colors.isEmpty) return AppPalette.walletAll;
  double r = 0, g = 0, b = 0;
  for (final c in colors) {
    r += c.r;
    g += c.g;
    b += c.b;
  }
  final n = colors.length;
  return Color.from(alpha: 1, red: r / n, green: g / n, blue: b / n);
}

class _ColorCoins extends StatelessWidget {
  const _ColorCoins({required this.colors, required this.ring});

  final List<Color> colors;
  final Color ring;

  static const _size = 16.0;
  static const _step = 10.0;

  @override
  Widget build(BuildContext context) {
    final shown = colors.take(5).toList();
    return SizedBox(
      width: _size + _step * (shown.length - 1),
      height: _size,
      child: Stack(
        children: [
          for (final (i, color) in shown.indexed)
            Positioned(
              left: _step * i,
              child: Container(
                width: _size,
                height: _size,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(color: ring, width: 2),
                ),
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
    final accountColors = [
      for (var i = 0; i < accountOptions.length; i++)
        AppPalette.walletCards[i % AppPalette.walletCards.length],
    ];
    // Many accounts would make a very tall stack: show a few, and put the
    // rest behind a "More accounts" strip that opens a list.
    final overflow = others.length > _maxBehind;
    final behind = overflow ? others.take(_maxBehind - 1).toList() : others;
    final strips = behind.length + (overflow ? 1 : 0);

    Color colorFor(String id) {
      if (id == kAllAccountsId) return _blend(accountColors);
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
          // All Accounts: the account colours flow into each other.
          gradient: id == kAllAccountsId && accountColors.length > 1
              ? LinearGradient(
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                  colors: accountColors,
                )
              : null,
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
                  // All Accounts shows what it is made of: each account's
                  // colour as overlapping coins.
                  if (id == kAllAccountsId && accountColors.length > 1) ...[
                    _ColorCoins(colors: accountColors, ring: colorFor(id)),
                    const SizedBox(width: 8),
                  ],
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
        child: Pressable(
          enabled: enabled && !front,
          hoverScale: 1.01,
          pressScale: 0.98,
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
        ),
      );
    }

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
                      child: Pressable(
                        enabled: enabled,
                        hoverScale: 1.01,
                        pressScale: 0.98,
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
                    ),
                  card(selected, front: true, top: strips * _peek),
                ],
              ),
            ),
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

  bool get _monthFinished {
    if (isAllYearOption(selectedMonth)) return false;
    final now = DateTime.now();
    return DateTime(
      selectedMonth.year,
      selectedMonth.month + 1,
    ).isBefore(DateTime(now.year, now.month, 1).add(const Duration(days: 1)));
  }

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
                ConstrainedBox(
                  // Numbers take what they need; the chart gets the rest.
                  constraints: const BoxConstraints(maxWidth: 170),
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
                      // A finished month has no pace left to be on.
                      if (!_monthFinished) ...[
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
                    ],
                  ),
                ),
                // The chart takes the right half and matches the height of
                // the numbers beside it, on a phone or a wider window.
                const SizedBox(width: 12),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, box) => BudgetPaceMiniChart(
                      snapshot: snapshot,
                      width: box.maxWidth,
                      height: 96,
                    ),
                  ),
                ),
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
    this.onTap,
    this.horizontalInset = 0,
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

  /// Opens what the user can do with this transaction (split a purchase,
  /// link a friend's payment to one).
  final VoidCallback? onTap;

  /// Side padding inside the row, so its tap highlight reaches the edges of
  /// the card it sits in.
  final double horizontalInset;

  /// "\$40 to get back" on a split purchase, "Pays back Olive Garden" on a
  /// linked payment; empty otherwise.
  static String sharedNote(AppTransaction tx) {
    if (tx.kind == TxKind.payback) {
      final purchase = AppTransaction.purchaseByPaybackId[tx.id];
      return purchase == null
          ? 'Paid back'
          : 'Pays back ${purchase.name} · ${shortDate(purchase.date)}';
    }
    if (tx.sharedAmount > 0) {
      return tx.toGetBack > 0
          ? '${dollars(tx.toGetBack)} to get back'
          : 'Paid back in full';
    }
    if (tx.paidBack > 0) return '${dollars(tx.paidBack)} paid back';
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final category = effectiveCategoryFor(tx, reviewedCategoryByTxId);
    final tone = colorForDetailedCategory(category);
    final note = sharedNote(tx);
    final row = Padding(
      padding: EdgeInsets.symmetric(vertical: 9, horizontal: horizontalInset),
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
                      onTap: () => showTransactionCategoryPicker(
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
                if (note.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    note,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: c.muted, fontSize: 12),
                  ),
                ],
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
              color: tx.kind == TxKind.internal || tx.kind == TxKind.payback
                  ? c.muted
                  : (tx.isIncome ? c.good : c.text),
            ),
          ),
        ],
      ),
    );
    if (onTap == null) return row;
    return InkWell(onTap: onTap, child: row);
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
    this.onLinkPayback,
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
  final Future<bool> Function(BuildContext context, AppTransaction tx)?
  onLinkPayback;
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
            'Tap the category to change it, then confirm. Money from a '
            'friend: link it to the purchase it pays back, or pick its '
            'category.',
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
              decoration: cardDecoration(context),
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
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
                    children: [
                      if (tx.isPeerToPeerInflow && widget.onLinkPayback != null)
                        Padding(
                          padding: const EdgeInsets.only(right: 8),
                          child: OutlinedButton(
                            key: ValueKey('review-link-${tx.id}'),
                            onPressed: () async {
                              final linked = await widget.onLinkPayback!(
                                context,
                                tx,
                              );
                              if (linked && mounted) {
                                setState(() => _confirmed.add(tx.id));
                              }
                            },
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(80, 32),
                              visualDensity: VisualDensity.compact,
                            ),
                            child: const Text('Link to a purchase'),
                          ),
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
                ],
              ),
            ),
        ],
      ),
    );
  }
}
