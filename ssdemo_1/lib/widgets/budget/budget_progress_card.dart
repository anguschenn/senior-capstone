import 'package:flutter/material.dart';

import '../../models/app_models.dart';
import '../../utils/app_helpers.dart';

class BudgetProgressCard extends StatelessWidget {
  const BudgetProgressCard({
    super.key,
    required this.item,
    required this.index,
    required this.onEdit,
    this.highlighted = false,
  });

  final BudgetCategoryProgress item;
  final int index;
  final ValueChanged<BudgetCategoryProgress> onEdit;
  final bool highlighted;

  @override
  Widget build(BuildContext context) {
    final icon = iconForBudgetCategory(item.title);
    final tone = colorForDetailedCategory(item.title);
    final amount =
        '${formatMoney(item.spent, signed: false)} / ${formatMoney(item.limit, signed: false)}';
    final progress = item.ratio;
    final isWarning = item.isWarning;
    final limit = item.limit;
    final spent = item.spent;
    final remaining = (limit - spent).clamp(-999999, 999999);

    return AnimatedContainer(
      duration: const Duration(milliseconds: 250),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [tone.withValues(alpha: 0.14), tone.withValues(alpha: 0.05)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: highlighted ? Colors.orange : tone.withValues(alpha: 0.25),
          width: highlighted ? 2 : 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: tone),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Set budget',
                onPressed: () => onEdit(item),
                icon: Icon(Icons.tune, size: 20, color: tone),
              ),
              ReorderableDragStartListener(
                index: index,
                child: Icon(Icons.drag_indicator, size: 20, color: tone),
              ),
              const SizedBox(width: 12),
              Text(amount, style: const TextStyle(fontWeight: FontWeight.w600)),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: progress.isFinite ? progress.clamp(0, 1) : 0,
            minHeight: 8,
            color: item.isBurnRateHigh
                ? Colors.redAccent
                : (isWarning ? Colors.orange : tone),
            backgroundColor: Colors.black12,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                _statusLabel(item),
                style: TextStyle(
                  color: isWarning
                      ? (item.isBurnRateHigh ? Colors.redAccent : Colors.orange)
                      : tone,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              Text(
                'Remaining: ${remaining >= 0 ? '' : '-'}\$${remaining.abs().toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 12,
                  color: remaining >= 0 ? Colors.black54 : Colors.redAccent,
                ),
              ),
            ],
          ),
          if (item.limit > 0 && item.spent > 0) ...[
            const SizedBox(height: 6),
            Text(
              _burnRateLine(item),
              style: TextStyle(
                fontSize: 11,
                color: item.isBurnRateHigh
                    ? Colors.redAccent
                    : (item.isBurnRateApproaching ? Colors.orange : Colors.black54),
              ),
            ),
          ],
        ],
      ),
    );
  }

  String _statusLabel(BudgetCategoryProgress item) {
    if (item.isBurnRateHigh) return 'On track to overspend';
    if (item.isBurnRateApproaching) return 'Burn rate high';
    if (item.isWarning) return 'High usage';
    return 'Healthy';
  }

  String _burnRateLine(BudgetCategoryProgress item) {
    final projected = item.projectedMonthEnd;
    if (item.isBurnRateHigh) {
      return 'Burn rate: ~\$${item.burnRateDaily.toStringAsFixed(0)}/day → '
          '~\$${projected.toStringAsFixed(0)} by month end '
          '(+\$${item.projectedOverrun.toStringAsFixed(0)} over)';
    }
    return 'Burn rate: ~\$${item.burnRateDaily.toStringAsFixed(0)}/day → '
        '~\$${projected.toStringAsFixed(0)} projected month end';
  }
}
