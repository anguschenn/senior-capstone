import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../models/app_models.dart';
import '../../utils/app_helpers.dart';

/// "79% used · $789.33 of $1000.00" — shared by the alerts and the banner.
String budgetAlertUsageText(BudgetCategoryProgress item) {
  final used = '${(item.usedRatio * 100).toStringAsFixed(0)}% used';
  final amounts =
      '${formatMoney(item.spent, signed: false)} of ${formatMoney(item.limit, signed: false)}';
  return '$used · $amounts';
}

/// "Pace: ~$1287.85 by month end" — shared by the alerts and the banner.
/// Null for a month that is already over.
String? budgetAlertPaceText(BudgetCategoryProgress item) => item.paceApplies
    ? 'Pace: ~${formatMoney(item.projectedMonthEnd, signed: false)} by month end'
    : null;

/// Stack of small light-red alerts, one per category whose burn rate projects
/// an overspend. Floats in the page corner; tap one to jump to its budget card,
/// or dismiss it with the close button.
class BudgetAlertToasts extends StatelessWidget {
  const BudgetAlertToasts({
    super.key,
    required this.items,
    required this.onTap,
    required this.onDismiss,
  });

  final List<BudgetCategoryProgress> items;
  final ValueChanged<BudgetCategoryProgress> onTap;
  final ValueChanged<BudgetCategoryProgress> onDismiss;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final item in items)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: _BudgetAlertToast(
                key: ValueKey(item.budgetId),
                item: item,
                onTap: () => onTap(item),
                onDismiss: () => onDismiss(item),
              ),
            ),
        ],
      ),
    );
  }
}

class _BudgetAlertToast extends StatelessWidget {
  const _BudgetAlertToast({
    super.key,
    required this.item,
    required this.onTap,
    required this.onDismiss,
  });

  final BudgetCategoryProgress item;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final over = item.isOverBudget;
    final tint = over ? c.bad : c.warn;
    final title = over
        ? '${item.title} is over budget'
        : '${item.title} on track to overspend';
    final usage = budgetAlertUsageText(item);
    final pace = budgetAlertPaceText(item);

    // Slides in from the right and fades up the first time it appears.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOut,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset((1 - t) * 24, 0),
          child: child,
        ),
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.fromLTRB(12, 10, 4, 10),
            decoration: BoxDecoration(
              color: c.card,
              borderRadius: BorderRadius.circular(12),
              border: Border(left: BorderSide(color: tint, width: 4)),
              boxShadow: [
                BoxShadow(
                  color: c.cardShadow,
                  blurRadius: 14,
                  offset: const Offset(0, 5),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  over ? Icons.error_outline : Icons.trending_up,
                  size: 20,
                  color: tint,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w700,
                          color: c.text,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        usage,
                        style: TextStyle(fontSize: 12, color: c.muted),
                      ),
                      if (pace != null)
                        Text(
                          pace,
                          style: TextStyle(fontSize: 12, color: c.muted),
                        ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: onDismiss,
                  icon: Icon(Icons.close, color: c.muted),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
