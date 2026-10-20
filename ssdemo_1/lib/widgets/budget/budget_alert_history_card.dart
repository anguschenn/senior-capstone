import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../constants/app_constants.dart';
import '../../services/auth_service.dart';
import '../../services/budget_alert_service.dart';
import '../../services/budget_service.dart';
import '../../utils/app_helpers.dart' show colorForDetailedCategory;
import '../../utils/formatters.dart';

/// The last six finished months' budget overruns, newest first, so a pattern
/// ("Food over in 4 of 6 months") is visible next to this month's budgets.
class BudgetAlertHistoryCard extends StatefulWidget {
  const BudgetAlertHistoryCard({
    super.key,
    required this.month,
    this.loadHistory,
    this.userId,
  });

  /// The month being viewed; history covers the six months before it.
  final DateTime month;
  final Future<List<BudgetOverrun>> Function(
    String userId,
    String fromMonth,
    String beforeMonth,
  )?
  loadHistory;

  /// Defaults to the signed-in user.
  final String? userId;

  static const months = 6;

  @override
  State<BudgetAlertHistoryCard> createState() => _BudgetAlertHistoryCardState();
}

class _BudgetAlertHistoryCardState extends State<BudgetAlertHistoryCard> {
  List<BudgetOverrun> _items = const [];

  String get _monthKey =>
      '${widget.month.year}-${widget.month.month.toString().padLeft(2, '0')}';

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BudgetAlertHistoryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.month != widget.month) _load();
  }

  Future<void> _load() async {
    final userId = widget.userId ?? AuthService.instance.currentUser?.id;
    if (userId == null) return;
    final month = _monthKey;
    final from = BudgetService.previousMonths(
      month,
      BudgetAlertHistoryCard.months,
    ).first;
    final load =
        widget.loadHistory ??
        (String user, String fromMonth, String beforeMonth) =>
            BudgetAlertService.instance.history(
              user,
              fromMonth: fromMonth,
              beforeMonth: beforeMonth,
            );
    final items = await load(userId, from, month);
    if (!mounted || month != _monthKey) return;
    setState(() => _items = items);
  }

  String _monthLabel(String key) {
    final parts = key.split('-');
    final month = int.tryParse(parts.length > 1 ? parts[1] : '') ?? 1;
    return '${kMonthShortLabels[(month - 1).clamp(0, 11)]} ${parts[0]}';
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    final byMonth = <String, List<BudgetOverrun>>{};
    for (final item in _items) {
      byMonth.putIfAbsent(item.month, () => []).add(item);
    }
    return Container(
      margin: const EdgeInsets.only(top: 10),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Alert history',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'Months that ended over budget, last '
            '${BudgetAlertHistoryCard.months} months.',
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
          for (final entry in byMonth.entries) ...[
            const SizedBox(height: 10),
            Text(
              _monthLabel(entry.key),
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            for (final item in entry.value)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      decoration: BoxDecoration(
                        color: colorForDetailedCategory(item.category),
                        shape: BoxShape.circle,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        '${item.category}: ${formatMoney(item.spent, signed: false)}'
                        ' of ${formatMoney(item.limit, signed: false)}'
                        ' (over by ${formatMoney(item.overBy, signed: false)})',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }
}
