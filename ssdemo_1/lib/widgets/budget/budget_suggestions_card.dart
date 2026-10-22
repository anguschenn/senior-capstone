import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../services/auth_service.dart';
import '../../services/budget_suggestion_service.dart';
import '../../utils/formatters.dart';
import '../common/ui.dart';

/// Suggested limits for this month, each to accept, edit or dismiss. A limit
/// never changes without the user's choice here (product rule).
class BudgetSuggestionsCard extends StatefulWidget {
  const BudgetSuggestionsCard({
    super.key,
    required this.month,
    required this.onUpdateBudgetLimit,
    this.service = BudgetSuggestionService.instance,
    this.userId,
    this.onAskWhy,
  });

  final DateTime month;
  final Future<void> Function(String budgetId, double monthlyLimit)
  onUpdateBudgetLimit;
  final BudgetSuggestionService service;

  /// Defaults to the signed-in user.
  final String? userId;

  /// ✦ "Why?" next to a suggestion; gets the category name.
  final ValueChanged<String>? onAskWhy;

  @override
  State<BudgetSuggestionsCard> createState() => _BudgetSuggestionsCardState();
}

class _BudgetSuggestionsCardState extends State<BudgetSuggestionsCard> {
  List<BudgetSuggestion> _items = const [];
  final Set<String> _busy = {};

  String get _monthKey => monthKeyOf(widget.month);

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(BudgetSuggestionsCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.month != widget.month) _load();
  }

  Future<void> _load() async {
    final userId = widget.userId ?? AuthService.instance.currentUser?.id;
    if (userId == null) return;
    final month = _monthKey;
    final items = await widget.service.pending(userId, month);
    if (!mounted || month != _monthKey) return;
    setState(() => _items = items);
  }

  Future<void> _decide(
    BudgetSuggestion item,
    String status, {
    double? limit,
  }) async {
    setState(() => _busy.add(item.id));
    try {
      // Change the budget first: a recorded "accepted" with no new limit
      // would be worse than asking again.
      if (limit != null) await widget.onUpdateBudgetLimit(item.budgetId, limit);
      await widget.service.decide(item.id, status, decidedLimit: limit);
      if (mounted) {
        setState(() => _items = [..._items]..remove(item));
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not save. Try again.')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy.remove(item.id));
    }
  }

  Future<void> _edit(BudgetSuggestion item) async {
    final controller = TextEditingController(
      text: item.suggestedLimit.toStringAsFixed(0),
    );
    final value = await showDialog<double>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('${item.category} limit'),
        content: TextField(
          controller: controller,
          autofocus: true,
          keyboardType: const TextInputType.numberWithOptions(decimal: true),
          decoration: const InputDecoration(
            prefixText: '\$',
            labelText: 'Monthly limit',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final parsed = double.tryParse(controller.text.trim());
              if (parsed == null || !parsed.isFinite || parsed < 0) return;
              Navigator.of(dialogContext).pop(parsed);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
    // Not disposed here: the dialog's closing animation still reads it.
    if (value != null) await _decide(item, 'edited', limit: value);
  }

  @override
  Widget build(BuildContext context) {
    if (_items.isEmpty) return const SizedBox.shrink();
    final c = context.colors;
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Suggested limits',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(
            'This limit is below what you usually spend. Your usual month '
            'leaves out your highest and lowest. Nothing changes unless you '
            'accept.',
            style: TextStyle(fontSize: 12, color: c.muted),
          ),
          for (final item in _items) _row(item),
        ],
      ),
    );
  }

  Widget _row(BudgetSuggestion item) {
    final c = context.colors;
    final busy = _busy.contains(item.id);
    final current = item.currentLimit > 0
        ? formatMoney(item.currentLimit, signed: false)
        : 'no limit';
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${item.category}: $current → '
            '${formatMoney(item.suggestedLimit, signed: false)}',
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          if (item.months.isNotEmpty)
            Text(
              item.monthsOver > 0
                  ? 'Your usual month. Over budget in ${item.monthsOver} of '
                        'the last ${item.months.length} months'
                  : 'Your usual month, from ${item.months.length} months '
                        'of spending',
              style: TextStyle(fontSize: 12, color: c.muted),
            ),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              TextButton(
                onPressed: busy
                    ? null
                    : () =>
                          _decide(item, 'accepted', limit: item.suggestedLimit),
                child: const Text('Accept'),
              ),
              TextButton(
                onPressed: busy ? null : () => _edit(item),
                child: const Text('Edit'),
              ),
              TextButton(
                onPressed: busy ? null : () => _decide(item, 'dismissed'),
                child: Text('Dismiss', style: TextStyle(color: c.muted)),
              ),
              if (widget.onAskWhy != null)
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: AskChip(
                    label: 'Why?',
                    onTap: () => widget.onAskWhy!(item.category),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
