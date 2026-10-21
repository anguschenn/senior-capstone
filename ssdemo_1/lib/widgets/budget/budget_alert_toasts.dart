import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../models/app_models.dart';
import '../../utils/app_helpers.dart';
import '../common/ui.dart';

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

/// Overspend alert shown like an iPhone notification: one banner at the top
/// in the category's own colour, with any other alerts stacked behind it
/// (like the wallet cards). Tap it to jump to the budget card; × shows the
/// next one.
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

  static const double _peek = 7;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    final front = items.first;
    final behind = (items.length - 1).clamp(0, 2);
    return Stack(
      children: [
        // Edges of the waiting alerts peek out under the front banner.
        for (var i = behind; i >= 1; i--)
          Positioned(
            left: 10.0 * i,
            right: 10.0 * i,
            top: 24,
            bottom: (behind - i) * _peek,
            child: Container(
              decoration: BoxDecoration(
                color: i == 1 ? c.raised : c.line,
                borderRadius: BorderRadius.circular(18),
                boxShadow: [
                  BoxShadow(
                    color: c.cardShadow,
                    blurRadius: 10,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
            ),
          ),
        Padding(
          padding: EdgeInsets.only(bottom: behind * _peek),
          child: _BudgetAlertBanner(
            key: ValueKey(front.budgetId),
            item: front,
            more: items.length - 1,
            onTap: () => onTap(front),
            onDismiss: () => onDismiss(front),
          ),
        ),
      ],
    );
  }
}

class _BudgetAlertBanner extends StatelessWidget {
  const _BudgetAlertBanner({
    super.key,
    required this.item,
    required this.more,
    required this.onTap,
    required this.onDismiss,
  });

  final BudgetCategoryProgress item;
  final int more;
  final VoidCallback onTap;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final over = item.isOverBudget;
    final title = over
        ? '${item.title} is over budget'
        : '${item.title} on track to overspend';
    final usage = budgetAlertUsageText(item);
    final pace = budgetAlertPaceText(item);

    // Slides down from the top and fades in, like a notification.
    return TweenAnimationBuilder<double>(
      tween: Tween(begin: 0, end: 1),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOutCubic,
      builder: (context, t, child) => Opacity(
        opacity: t,
        child: Transform.translate(
          offset: Offset(0, (t - 1) * 28),
          child: child,
        ),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(18),
          boxShadow: [
            BoxShadow(
              color: c.cardShadow,
              blurRadius: 18,
              offset: const Offset(0, 6),
            ),
          ],
        ),
        child: Material(
          color: c.card,
          borderRadius: BorderRadius.circular(18),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 4, 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  CategoryDot(
                    color: colorForDetailedCategory(item.title),
                    icon: iconForBudgetCategory(item.title),
                    size: 38,
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          style: TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            color: c.text,
                          ),
                        ),
                        const SizedBox(height: 3),
                        Text(
                          usage,
                          style: TextStyle(fontSize: 12.5, color: c.muted),
                        ),
                        if (pace != null)
                          Text(
                            pace,
                            style: TextStyle(fontSize: 12.5, color: c.muted),
                          ),
                        if (more > 0)
                          Padding(
                            padding: const EdgeInsets.only(top: 4),
                            child: Text(
                              '+$more more',
                              style: TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                                color: c.text,
                              ),
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
                    icon: Icon(Icons.close, color: c.muted),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
