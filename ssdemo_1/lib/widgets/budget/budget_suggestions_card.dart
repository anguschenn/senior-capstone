import 'package:flutter/material.dart';

import '../../services/auth_service.dart';
import '../../services/budget_suggestion_service.dart';
import '../../utils/formatters.dart';

/// Suggested limits for this month, each to accept, edit or dismiss. A limit
/// never changes without the user's choice here (product rule).
class BudgetSuggestionsCard extends StatefulWidget {
  const BudgetSuggestionsCard({
    super.key,
    required this.month,
    required this.onUpdateBudgetLimit,
    this.service = BudgetSuggestionService.instance,
    this.userId,
  });

  final DateTime month;
  final Future<void> Function(String budgetId, double monthlyLimit)
  onUpdateBudgetLimit;
  final BudgetSuggestionService service;

  /// Defaults to the signed-in user.
  final String? userId;

  @override
  State<BudgetSuggestionsCard> createState() => _BudgetSuggestionsCardState();
}

class _BudgetSuggestionsCardState extends State<BudgetSuggestionsCard> {
  List<BudgetSuggestion> _items = const [];
  final Set<String> _busy = {};

  String get _monthKey =>
      '${widget.month.year}-${widget.month.month.toString().padLeft(2, '0')}';

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
    return Container(
      margin: const EdgeInsets.only(bottom: 18),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.blue.withValues(alpha: 0.06),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.blue.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.tune, size: 18, color: Colors.blue),
              SizedBox(width: 8),
              Text(
                'Suggested limits',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            'Based on your typical month, leaving out your highest and '
            'lowest. Nothing changes unless you accept.',
            style: TextStyle(
              fontSize: 12,
              color: Colors.black.withValues(alpha: 0.6),
            ),
          ),
          for (final item in _items) _row(item),
        ],
      ),
    );
  }

  Widget _row(BudgetSuggestion item) {
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
              'From ${item.months.length} months of spending',
              style: TextStyle(
                fontSize: 12,
                color: Colors.black.withValues(alpha: 0.55),
              ),
            ),
          Wrap(
            spacing: 8,
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
                child: const Text('Dismiss'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
