import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../models/app_models.dart';
import '../utils/app_helpers.dart';

enum BudgetViewMode { month, year, all }

class BudgetPage extends StatefulWidget {
  const BudgetPage({
    super.key,
    required this.stats,
    required this.budgetProgress,
    required this.budgetProgressYear,
    required this.budgetProgressAll,
    required this.onUpdateBudgetLimit,
    required this.aiBudgetSuggestApiUri,
    required this.apiKey,
    required this.spendingSummary,
  });

  final DashboardStats stats;
  final List<BudgetCategoryProgress> budgetProgress;
  final List<BudgetCategoryProgress> budgetProgressYear;
  final List<BudgetCategoryProgress> budgetProgressAll;
  final Future<void> Function(String budgetId, double monthlyLimit) onUpdateBudgetLimit;
  final Uri aiBudgetSuggestApiUri;
  final String apiKey;
  final Map<String, dynamic> spendingSummary;

  @override
  State<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends State<BudgetPage> {
  // Controls which budget aggregation window is visible.
  BudgetViewMode viewMode = BudgetViewMode.month;

  bool _loadingAi = false;
  String _aiError = '';
  Map<String, dynamic>? _aiSuggestions;
  String _aiContextSource = '';

  List<BudgetCategoryProgress> get activeBudgetProgress =>
      viewMode == BudgetViewMode.month
          ? widget.budgetProgress
          : (viewMode == BudgetViewMode.year
                ? widget.budgetProgressYear
                : widget.budgetProgressAll);

  Future<void> _generateAiBudgetSuggestions() async {
    if (_loadingAi) return;
    final totals = (widget.spendingSummary['totals'] is Map)
        ? (widget.spendingSummary['totals'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final annualSummary = (widget.spendingSummary['annual_summary'] is Map)
        ? (widget.spendingSummary['annual_summary'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final annualTotals = (annualSummary['totals'] is Map)
        ? (annualSummary['totals'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final expenses30d = ((totals['expenses_30d'] as num?) ?? 0).toDouble();
    final expenseTxCount30d = ((totals['expense_tx_count_30d'] as num?) ?? 0).toInt();
    final expensesYear = ((annualTotals['expenses_year'] as num?) ?? 0).toDouble();
    final expenseTxCountYear = ((annualTotals['expense_tx_count_year'] as num?) ?? 0).toInt();
    final hasEnoughData = viewMode == BudgetViewMode.month
        ? (expenses30d >= 50 && expenseTxCount30d >= 5)
        : (expensesYear >= 200 && expenseTxCountYear >= 20);
    if (!hasEnoughData) {
      setState(() {
        _aiError = '';
        _aiSuggestions = {
          'copy':
              'Not enough expense data in this selected time range to generate reliable AI suggestions yet. Connect and refresh transactions, then try again.',
          'alerts': [],
          'actions': [],
        };
        _aiContextSource = 'rule_fallback';
      });
      return;
    }

    setState(() {
      _loadingAi = true;
      _aiError = '';
    });

    final rankedProgress = [...activeBudgetProgress]
      ..sort((a, b) => b.ratio.compareTo(a.ratio));
    final budgetProgressPayload = rankedProgress
        .take(12)
        .map(
          (b) => {
            'category': b.title,
            'spent': b.spent,
            'limit': b.limit,
            'ratio': b.ratio,
          },
        )
        .toList();

    try {
      final response = await http
          .post(
            widget.aiBudgetSuggestApiUri,
            headers: {
              'Content-Type': 'application/json',
              'x-api-key': widget.apiKey,
            },
            body: jsonEncode({
              'spending_summary': widget.spendingSummary,
              'budget_progress': budgetProgressPayload,
              'view_mode': viewMode.name,
            }),
          )
          .timeout(const Duration(seconds: 30));

      final rawBody = utf8.decode(response.bodyBytes);
      final Map<String, dynamic> parsed;
      try {
        parsed = jsonDecode(rawBody) as Map<String, dynamic>;
      } catch (_) {
        final contentType = response.headers['content-type'] ?? 'unknown';
        final preview = rawBody.length > 180 ? '${rawBody.substring(0, 180)}…' : rawBody;
        throw FormatException(
          'Expected JSON but got $contentType (HTTP ${response.statusCode}). Body preview: $preview',
        );
      }

      if (response.statusCode >= 200 && response.statusCode < 300) {
        setState(() {
          _aiSuggestions =
              (parsed['suggestions'] as Map?)?.cast<String, dynamic>();
          _aiContextSource = (parsed['context_source'] ?? '').toString();
        });
      } else {
        setState(() {
          _aiError = (parsed['error'] ?? 'Request failed').toString();
        });
      }
    } catch (e) {
      setState(() {
        _aiError = 'Failed to reach AI service: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _loadingAi = false);
      }
    }
  }

  List<Map<String, dynamic>> _suggestionList(String key) {
    final raw = _aiSuggestions?[key];
    if (raw is List) {
      return raw.whereType<Map>().map((e) => e.cast<String, dynamic>()).toList();
    }
    return const [];
  }

  String _cleanSuggestionCopy() {
    var text = (_aiSuggestions?['copy'] ?? '').toString().trim();
    if (text.isEmpty) return text;
    if (text.startsWith('{')) {
      final copyKeyIndex = text.indexOf('"copy"');
      if (copyKeyIndex >= 0) {
        final colonIndex = text.indexOf(':', copyKeyIndex);
        if (colonIndex >= 0) {
          var tail = text.substring(colonIndex + 1).trimLeft();
          if (tail.startsWith('"')) {
            tail = tail.substring(1);
            final endQuote = tail.indexOf('"');
            text = endQuote >= 0 ? tail.substring(0, endQuote) : tail;
          } else {
            text = tail;
          }
        }
      }
    }
    return text
        .replaceAll(r'\n', '\n')
        .replaceAll(r'\t', '\t')
        .replaceAll(r'\"', '"')
        .trim();
  }

  String _selectedRangeExpensesLabel() {
    if (viewMode == BudgetViewMode.month) return 'Total monthly expenses';
    if (viewMode == BudgetViewMode.year) return 'Total yearly expenses';
    return 'Total all-time expenses';
  }

  double _selectedRangeExpensesValue() {
    return activeBudgetProgress.fold<double>(0, (sum, item) => sum + item.spent);
  }

  @override
  Widget build(BuildContext context) {
    // Budget page combines editable category limits with lightweight insight text.
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          // Top controls switch time scope and open budget editing flows.
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Budget',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _showBulkEditBudgetDialog(context),
                icon: const Icon(Icons.tune),
                label: const Text('Edit Budget'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _showCustomCategoryDialog(context),
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Add Custom Category'),
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<BudgetViewMode>(
            segments: const [
              ButtonSegment<BudgetViewMode>(
                value: BudgetViewMode.month,
                label: Text('This Month'),
              ),
              ButtonSegment<BudgetViewMode>(
                value: BudgetViewMode.year,
                label: Text('This Year'),
              ),
              ButtonSegment<BudgetViewMode>(
                value: BudgetViewMode.all,
                label: Text('All Time'),
              ),
            ],
            selected: {viewMode},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) return;
              setState(() => viewMode = selection.first);
            },
          ),
          const SizedBox(height: 8),
          Text('Current month net: ${widget.stats.netThisMonth >= 0 ? '+ ' : '- '}\$${widget.stats.netThisMonth.abs().toStringAsFixed(2)}'),
          const SizedBox(height: 20),
          // Insight card summarizes the highest-risk budget category at a glance.
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _budgetInsight(),
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          // Category budget cards show spent vs. limit for the current time scope.
          if (activeBudgetProgress.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                'No budgets configured for this view yet.',
              ),
            ),
          if (activeBudgetProgress.isNotEmpty)
            ..._budgetListWidgets(context),
          const SizedBox(height: 18),
          // Simple explanation block derived from the currently visible budget data.
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.smart_toy_outlined, color: Colors.green),
                    const SizedBox(width: 10),
                    const Text(
                      'AI Analysis',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                    const Spacer(),
                    TextButton.icon(
                      onPressed: _loadingAi ? null : _generateAiBudgetSuggestions,
                      icon: _loadingAi
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Icon(Icons.auto_awesome, size: 18),
                      label: const Text('Generate'),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text('• Highest category usage: ${_highestCategoryText()}'),
                const SizedBox(height: 6),
                Text(
                  '• ${_selectedRangeExpensesLabel()}: ${formatMoney(_selectedRangeExpensesValue(), signed: false)}',
                ),
                const SizedBox(height: 10),
                if (_aiError.isNotEmpty)
                  Text(
                    _aiError,
                    style: const TextStyle(
                      color: Colors.redAccent,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (_aiError.isEmpty && _aiSuggestions == null)
                  Text(
                    _budgetSuggestion(),
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                if (_aiSuggestions != null) ...[
                  Row(
                    children: [
                      if (_aiContextSource.isNotEmpty)
                        _metaBadge(_aiContextSource, Colors.black45),
                      if ((_aiSuggestions?['confidence'] ?? '').toString().isNotEmpty) ...[
                        const SizedBox(width: 6),
                        _metaBadge(
                          (_aiSuggestions!['confidence'] ?? 'medium').toString(),
                          _confidenceBadgeColor(
                            (_aiSuggestions!['confidence'] ?? 'medium').toString(),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 6),
                  if (_cleanSuggestionCopy().isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 10),
                      child: Text(
                        _cleanSuggestionCopy(),
                        style: const TextStyle(fontWeight: FontWeight.w500),
                      ),
                    ),
                  if (_suggestionList('alerts').isNotEmpty) ...[
                    const Text('Alerts', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    ..._suggestionList('alerts').take(3).map((a) {
                      final category = (a['category'] ?? 'Unknown').toString();
                      final severity = (a['severity'] ?? 'med').toString();
                      final reason = (a['reason'] ?? '').toString();
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('• [$severity] $category: $reason'),
                      );
                    }),
                    const SizedBox(height: 10),
                  ],
                  if (_suggestionList('actions').isNotEmpty) ...[
                    const Text('Actions', style: TextStyle(fontWeight: FontWeight.w700)),
                    const SizedBox(height: 6),
                    ..._suggestionList('actions').take(3).map((a) {
                      final category = (a['category'] ?? 'Unknown').toString();
                      final type = (a['type'] ?? 'monitor').toString();
                      final target = (a['target'] ?? '').toString();
                      final why = (a['why'] ?? '').toString();
                      final targetSuffix = target.trim().isEmpty ? '' : ' ($target)';
                      return Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text('• $category: $type$targetSuffix. $why'),
                      );
                    }),
                  ],
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _metaBadge(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }

  Color _confidenceBadgeColor(String confidence) {
    switch (confidence) {
      case 'high':
        return Colors.green;
      case 'medium':
        return Colors.orange;
      case 'low':
        return Colors.redAccent;
      default:
        return Colors.grey;
    }
  }

  // Builds the visible list of budget cards for the selected time scope.
  List<Widget> _budgetListWidgets(BuildContext context) {
    final widgets = <Widget>[];
    for (int i = 0; i < activeBudgetProgress.length; i++) {
      final item = activeBudgetProgress[i];
      widgets.add(
        _budgetItem(
          context,
          item,
        ),
      );
      if (i != activeBudgetProgress.length - 1) {
        widgets.add(const SizedBox(height: 14));
      }
    }
    return widgets;
  }

  // -------------------------------------------------------------------------
  // Budget insight text helpers
  // -------------------------------------------------------------------------

  String _highestCategoryText() {
    final lead = _topCategory();
    if (lead == null) return 'No budget categories yet';
    return '${lead.title} (${(lead.ratio * 100).toStringAsFixed(0)}%)';
  }

  // Short status sentence shown in the warning card near the top of the page.
  String _budgetInsight() {
    final lead = _topCategory();
    if (lead == null) return 'Budget Insight: no spending data yet.';
    if (lead.ratio >= 1) {
      return 'Budget Insight: ${lead.title} is over limit this month.';
    }
    if (lead.ratio >= 0.8) {
      return 'Budget Insight: ${lead.title} is close to limit this month.';
    }
    return 'Budget Insight: all categories are currently within limits.';
  }

  // Short recommendation string based on the most stressed budget category.
  String _budgetSuggestion() {
    final lead = _topCategory();
    if (lead == null) return 'Suggestion: connect data to see budget guidance.';
    if (lead.ratio >= 1) {
      return 'Suggestion: cut ${lead.title.toLowerCase()} spending this week to recover your budget.';
    }
    if (lead.ratio >= 0.8) {
      return 'Suggestion: reduce non-essential ${lead.title.toLowerCase()} spend for the rest of the month.';
    }
    return 'Suggestion: current pace is healthy; keep spending patterns stable.';
  }

  BudgetCategoryProgress? _topCategory() {
    if (activeBudgetProgress.isEmpty) return null;
    final sorted = [...activeBudgetProgress]..sort((a, b) => b.ratio.compareTo(a.ratio));
    return sorted.first;
  }

  // -------------------------------------------------------------------------
  // Budget editing dialogs
  // -------------------------------------------------------------------------

  // Inline editor for a single budget row.
  Future<void> _showEditBudgetDialog(
    BuildContext context,
    BudgetCategoryProgress item,
  ) async {
    final controller = TextEditingController(text: item.limit.toStringAsFixed(0));
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Set ${item.title} Budget'),
          content: TextField(
            controller: controller,
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
              onPressed: () async {
                final parsed = double.tryParse(controller.text.trim());
                if (parsed == null || parsed <= 0) return;
                await widget.onUpdateBudgetLimit(item.budgetId, parsed);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  // Bulk editor for DB-backed budgets only.
  Future<void> _showBulkEditBudgetDialog(BuildContext context) async {
    final editableBudgets = activeBudgetProgress
        .where((b) => !b.budgetId.startsWith('preset_'))
        .toList();
    if (editableBudgets.isEmpty) return;
    BudgetCategoryProgress selected = editableBudgets.first;
    final controller = TextEditingController(text: selected.limit.toStringAsFixed(0));
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Edit Budget'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selected.budgetId,
                    isExpanded: true,
                    items: editableBudgets
                        .map(
                          (b) => DropdownMenuItem<String>(
                            value: b.budgetId,
                            child: Text(b.title),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        selected = editableBudgets.firstWhere((b) => b.budgetId == value);
                        controller.text = selected.limit.toStringAsFixed(0);
                      });
                    },
                    decoration: const InputDecoration(labelText: 'Budget'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      prefixText: '\$',
                      labelText: 'Monthly limit',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final parsed = double.tryParse(controller.text.trim());
                    if (parsed == null || parsed <= 0) return;
                    await widget.onUpdateBudgetLimit(selected.budgetId, parsed);
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  // Placeholder UI for future custom category creation.
  Future<void> _showCustomCategoryDialog(BuildContext context) async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add Custom Category'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Category name',
              hintText: 'e.g. Pets, Travel, Gifts',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Custom category UI only (not connected yet).'),
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  // Budget card rendering helpers
  // -------------------------------------------------------------------------

  // Visual card for one budget category and its current usage.
  Widget _budgetItem(
    BuildContext context,
    BudgetCategoryProgress item,
  ) {
    final icon = iconForBudgetCategory(item.title);
    final tone = colorForDetailedCategory(item.title);
    final amount =
        '${formatMoney(item.spent, signed: false)} / ${formatMoney(item.limit, signed: false)}';
    final progress = item.ratio;
    final isWarning = item.isWarning;
    final limit = item.limit;
    final spent = item.spent;
    final remaining = (limit - spent).clamp(-999999, 999999);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            tone.withValues(alpha: 0.14),
            tone.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tone.withValues(alpha: 0.25)),
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
                onPressed: () {
                  _showEditBudgetDialog(
                    context,
                    item,
                  );
                },
                icon: Icon(Icons.tune, size: 20, color: tone),
              ),
              const SizedBox(width: 12),
              Text(
                amount,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: progress.clamp(0, 1),
            minHeight: 8,
            color: isWarning ? Colors.orange : tone,
            backgroundColor: Colors.black12,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                isWarning ? 'High usage' : 'Healthy',
                style: TextStyle(
                  color: isWarning ? Colors.orange : tone,
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
        ],
      ),
    );
  }
}
