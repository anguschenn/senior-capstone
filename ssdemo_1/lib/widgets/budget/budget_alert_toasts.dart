import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../utils/app_helpers.dart';

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
    final over = item.isOverBudget;
    final title = over
        ? '${item.title} is over budget'
        : '${item.title} on track to overspend';
    final used = '${(item.usedRatio * 100).toStringAsFixed(0)}% used';
    final amounts =
        '${formatMoney(item.spent, signed: false)} of ${formatMoney(item.limit, signed: false)}';
    final pace =
        'Pace: ~${formatMoney(item.projectedMonthEnd, signed: false)} by month end';

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
              color: Colors.red.shade50.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.red.shade200),
              boxShadow: [
                BoxShadow(
                  color: Colors.red.withValues(alpha: 0.12),
                  blurRadius: 12,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(
                  over ? Icons.error_outline : Icons.trending_up,
                  size: 20,
                  color: Colors.red.shade700,
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
                          color: Colors.red.shade900,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '$used · $amounts',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.red.shade800,
                        ),
                      ),
                      Text(
                        pace,
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.red.shade800,
                        ),
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss',
                  visualDensity: VisualDensity.compact,
                  iconSize: 18,
                  onPressed: onDismiss,
                  icon: Icon(Icons.close, color: Colors.red.shade400),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
