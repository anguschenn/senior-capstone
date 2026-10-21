import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../models/app_models.dart';
import '../../utils/app_helpers.dart';
import '../common/ui.dart';

class BudgetProgressCard extends StatelessWidget {
  const BudgetProgressCard({
    super.key,
    required this.item,
    required this.index,
    required this.onEdit,
    this.highlighted = false,
    this.transactions = const [],
    this.expanded = true,
    this.reorderable = false,
    this.onTap,
    this.onAskWhy,
  });

  final BudgetCategoryProgress item;
  final int index;
  final ValueChanged<BudgetCategoryProgress> onEdit;
  final bool highlighted;

  /// Spending behind this card, largest first; shown in a dropdown.
  final List<AppTransaction> transactions;

  /// Collapsed cards show only the title row and progress (the stack on
  /// the Budget page); expanded ones show the details.
  final bool expanded;

  /// Shows a drag handle (the Budget page's Edit mode).
  final bool reorderable;
  final VoidCallback? onTap;

  /// ✦ "Why is Food high?" chip.
  final VoidCallback? onAskWhy;

  static const _ink = AppPalette.ink;
  static const _overInk = Color(0xFF8A2E22);

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final icon = iconForBudgetCategory(item.title);
    final tone = colorForDetailedCategory(item.title);
    final amount = expanded
        ? '${formatMoney(item.spent, signed: false)} / ${formatMoney(item.limit, signed: false)}'
        : '${dollars(item.spent, decimals: 0)} / ${dollars(item.limit, decimals: 0)}';
    final progress = item.ratio;
    final isWarning = item.isWarning;
    final limit = item.limit;
    final spent = item.spent;
    final remaining = (limit - spent).clamp(-999999, 999999);
    final alarming = item.isBurnRateHigh || item.isOverBudget;
    final muted = _ink.withValues(alpha: 0.62);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      decoration: BoxDecoration(
        color: tone,
        borderRadius: BorderRadius.circular(16),
        border: highlighted ? Border.all(color: c.text, width: 2) : null,
        boxShadow: [
          BoxShadow(
            color: c.cardShadow,
            blurRadius: 12,
            offset: const Offset(0, -4),
          ),
        ],
      ),
      child: Material(
        type: MaterialType.transparency,
        child: InkWell(
          borderRadius: BorderRadius.circular(16),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 10, 14),
            child: DefaultTextStyle.merge(
              style: const TextStyle(color: _ink),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        width: 34,
                        height: 34,
                        decoration: BoxDecoration(
                          color: Colors.white.withValues(alpha: 0.35),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(icon, size: 18, color: _ink),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Text(
                          item.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          softWrap: false,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      if (!expanded && isWarning) ...[
                        _Badge(label: _shortStatus(item), alarming: alarming),
                        const SizedBox(width: 8),
                      ],
                      Text(
                        amount,
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (expanded)
                        IconButton(
                          tooltip: 'Set budget',
                          visualDensity: VisualDensity.compact,
                          onPressed: () => onEdit(item),
                          icon: const Icon(Icons.tune, size: 20, color: _ink),
                        ),
                      if (reorderable)
                        ReorderableDragStartListener(
                          index: index,
                          child: const Padding(
                            padding: EdgeInsets.only(left: 6),
                            child: Icon(
                              Icons.drag_handle_rounded,
                              size: 22,
                              color: _ink,
                            ),
                          ),
                        ),
                      if (!expanded && !reorderable) const SizedBox(width: 4),
                    ],
                  ),
                  const SizedBox(height: 12),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(99),
                    child: LinearProgressIndicator(
                      value: progress.isFinite ? progress.clamp(0, 1) : 0,
                      minHeight: 7,
                      color: alarming ? _overInk : _ink,
                      backgroundColor: Colors.white.withValues(alpha: 0.35),
                    ),
                  ),
                  if (expanded) ...[
                    const SizedBox(height: 10),
                    Row(
                      children: [
                        _Badge(
                          label: _statusLabel(item),
                          alarming: alarming,
                          calm: !isWarning,
                        ),
                        const Spacer(),
                        if (item.limit > 0) ...[
                          Text(
                            '${(item.usedRatio * 100).toStringAsFixed(0)}% used',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: item.isOverBudget ? _overInk : _ink,
                            ),
                          ),
                          const SizedBox(width: 10),
                        ],
                        if (item.hasLimit)
                          Text(
                            remaining >= 0
                                ? '${dollars(remaining.toDouble())} left'
                                : '${dollars(remaining.toDouble())} over',
                            style: TextStyle(
                              fontSize: 12.5,
                              color: remaining >= 0 ? muted : _overInk,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        const SizedBox(width: 4),
                      ],
                    ),
                    if (item.paceApplies &&
                        item.limit > 0 &&
                        item.spent > 0) ...[
                      const SizedBox(height: 8),
                      Text(
                        _burnRateLine(item),
                        style: TextStyle(
                          fontSize: 12,
                          color: item.isBurnRateHigh ? _overInk : muted,
                        ),
                      ),
                    ],
                    if (transactions.isNotEmpty)
                      _TransactionBreakdown(transactions: transactions),
                    if (onAskWhy != null && item.spent > 0)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: _InkAskChip(
                          label: 'Why is ${item.title} high?',
                          onTap: onAskWhy!,
                        ),
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

  /// Fits beside the title on a closed card.
  String _shortStatus(BudgetCategoryProgress item) {
    if (item.isOverBudget) return 'Over';
    if (item.isBurnRateHigh) return 'Over pace';
    return 'High usage';
  }

  String _statusLabel(BudgetCategoryProgress item) {
    // Without a limit there is nothing to be healthy against.
    if (!item.hasLimit) return 'No budget set';
    if (!item.paceApplies && item.isOverBudget) return 'Over budget';
    if (item.isBurnRateHigh) return 'On track to overspend';
    if (item.isBurnRateApproaching) return 'Burn rate high';
    if (item.isWarning) return 'High usage';
    return 'Healthy';
  }

  String _burnRateLine(BudgetCategoryProgress item) {
    final projected = item.projectedMonthEnd;
    if (item.isBurnRateHigh) {
      return 'Burn rate: ~${dollars(item.burnRateDaily, decimals: 0)}/day → '
          '~${dollars(projected, decimals: 0)} by month end '
          '(+${dollars(item.projectedOverrun, decimals: 0)} over)';
    }
    return 'Burn rate: ~${dollars(item.burnRateDaily, decimals: 0)}/day → '
        '~${dollars(projected, decimals: 0)} projected month end';
  }
}

/// Collapsible list of the transactions behind a budget card.
class _TransactionBreakdown extends StatelessWidget {
  const _TransactionBreakdown({required this.transactions});

  static const _initialRows = 10;

  final List<AppTransaction> transactions;

  @override
  Widget build(BuildContext context) {
    const tone = AppPalette.ink;
    final muted = tone.withValues(alpha: 0.62);
    final count = transactions.length;
    final hidden = count - _initialRows;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      childrenPadding: const EdgeInsets.only(bottom: 4),
      dense: true,
      visualDensity: VisualDensity.compact,
      shape: const Border(),
      collapsedShape: const Border(),
      iconColor: tone,
      collapsedIconColor: tone,
      title: Text(
        '$count transaction${count == 1 ? '' : 's'}',
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: tone,
        ),
      ),
      children: [
        for (final tx in transactions.take(_initialRows))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: [
                SizedBox(
                  width: 52,
                  child: Text(
                    shortDate(tx.date),
                    style: TextStyle(fontSize: 11, color: muted),
                  ),
                ),
                Expanded(
                  child: Text(
                    tx.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: tone),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  formatMoney(tx.expenseAmount, signed: false),
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: tone,
                  ),
                ),
              ],
            ),
          ),
        if (hidden > 0)
          Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '+ $hidden smaller transaction${hidden == 1 ? '' : 's'}',
                style: TextStyle(fontSize: 11, color: muted),
              ),
            ),
          ),
      ],
    );
  }
}

/// Status pill on a category card, e.g. "High usage".
class _Badge extends StatelessWidget {
  const _Badge({
    required this.label,
    required this.alarming,
    this.calm = false,
  });

  final String label;
  final bool alarming;
  final bool calm;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: alarming
            ? BudgetProgressCard._overInk
            : Colors.white.withValues(alpha: calm ? 0.35 : 0.6),
        borderRadius: BorderRadius.circular(99),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: alarming ? const Color(0xFFFBF8F2) : AppPalette.ink,
        ),
      ),
    );
  }
}

/// ✦ chip drawn for the coloured card (ink on a light wash).
class _InkAskChip extends StatelessWidget {
  const _InkAskChip({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final chip = Material(
      color: Colors.white.withValues(alpha: 0.45),
      borderRadius: BorderRadius.circular(99),
      child: InkWell(
        borderRadius: BorderRadius.circular(99),
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.auto_awesome, size: 13, color: AppPalette.ink),
              const SizedBox(width: 5),
              Text(
                label,
                style: const TextStyle(
                  fontSize: 12.5,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.ink,
                ),
              ),
            ],
          ),
        ),
      ),
    );
    return TapTarget(onTap: onTap, minWidth: 0, child: chip);
  }
}
