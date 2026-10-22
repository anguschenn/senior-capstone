import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../models/app_models.dart';
import '../../utils/app_helpers.dart';
import '../common/ui.dart';

/// "79% used · $789.33 of $1000.00" — shared by the alert list and the banner.
String budgetAlertUsageText(BudgetCategoryProgress item) {
  final used = '${(item.usedRatio * 100).toStringAsFixed(0)}% used';
  final amounts =
      '${formatMoney(item.spent, signed: false)} of ${formatMoney(item.limit, signed: false)}';
  return '$used · $amounts';
}

/// "Pace: ~$1287.85 by month end" — shared by the alert list and the banner.
/// Null for a month that is already over.
String? budgetAlertPaceText(BudgetCategoryProgress item) => item.paceApplies
    ? 'Pace: ~${formatMoney(item.projectedMonthEnd, signed: false)} by month end'
    : null;

/// Overspend alerts folded into a small pill beside the month ("● 2 over ›"):
/// always there while something is over, never covering the page. Tap it for
/// the list; tap a row to jump to that budget card.
class BudgetAlertPill extends StatelessWidget {
  const BudgetAlertPill({super.key, required this.items, required this.onTap});

  final List<BudgetCategoryProgress> items;
  final ValueChanged<BudgetCategoryProgress> onTap;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    final over = items.where((b) => b.isOverBudget).length;
    final label = over == items.length
        ? '${items.length} over budget'
        : over == 0
        ? '${items.length} heading over'
        : '${items.length} budget alerts';
    return Pressable(
      child: Material(
        key: const ValueKey('budget-alert-pill'),
        color: c.bad.withValues(alpha: 0.16),
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: () => showBudgetAlertList(context, items, onTap),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 32),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 6, 0),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.error_outline_rounded, size: 16, color: c.bad),
                  const SizedBox(width: 5),
                  Text(
                    label,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: c.bad,
                    ),
                  ),
                  Icon(Icons.chevron_right_rounded, size: 18, color: c.bad),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The overspend alerts as a floating list; tapping one calls [onTap].
Future<void> showBudgetAlertList(
  BuildContext context,
  List<BudgetCategoryProgress> items,
  ValueChanged<BudgetCategoryProgress> onTap,
) async {
  final picked = await showModalBottomSheet<BudgetCategoryProgress>(
    context: context,
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    elevation: 0,
    builder: (context) {
      final c = context.colors;
      return SafeArea(
        minimum: const EdgeInsets.only(bottom: 8),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          child: Material(
            color: c.card,
            borderRadius: BorderRadius.circular(24),
            clipBehavior: Clip.antiAlias,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Padding(
                  padding: EdgeInsets.fromLTRB(20, 18, 20, 6),
                  child: Text(
                    'Budget alerts',
                    style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
                  ),
                ),
                for (final item in items)
                  InkWell(
                    onTap: () => Navigator.of(context).pop(item),
                    child: Padding(
                      padding: const EdgeInsets.fromLTRB(20, 10, 16, 10),
                      child: Row(
                        children: [
                          CategoryDot(
                            color: colorForDetailedCategory(item.title),
                            icon: iconForBudgetCategory(item.title),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  item.isOverBudget
                                      ? '${item.title} is over budget'
                                      : '${item.title} on track to overspend',
                                  style: const TextStyle(
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                Text(
                                  budgetAlertUsageText(item),
                                  style: TextStyle(
                                    fontSize: 12.5,
                                    color: c.muted,
                                  ),
                                ),
                                if (budgetAlertPaceText(item) case final pace?)
                                  Text(
                                    pace,
                                    style: TextStyle(
                                      fontSize: 12.5,
                                      color: c.muted,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Icon(Icons.chevron_right_rounded, color: c.muted),
                        ],
                      ),
                    ),
                  ),
                const SizedBox(height: 10),
              ],
            ),
          ),
        ),
      );
    },
  );
  if (picked != null) onTap(picked);
}
