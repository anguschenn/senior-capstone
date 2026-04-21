import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/ai/ai_models.dart';
import '../models/app_models.dart';
import '../services/ai_api_client.dart';
import '../utils/app_helpers.dart';
import '../widgets/budget/budget_ai_analysis_card.dart';

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
    required this.selectedMonth,
    required this.monthOptions,
    required this.onMonthChanged,
  });

  final DashboardStats stats;
  final List<BudgetCategoryProgress> budgetProgress;
  final List<BudgetCategoryProgress> budgetProgressYear;
  final List<BudgetCategoryProgress> budgetProgressAll;
  final Future<void> Function(String budgetId, double monthlyLimit)
  onUpdateBudgetLimit;
  final Uri aiBudgetSuggestApiUri;
  final String apiKey;
  final Map<String, dynamic> spendingSummary;
  final DateTime selectedMonth;
  final List<DateTime> monthOptions;
  final ValueChanged<DateTime> onMonthChanged;

  @override
  State<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends State<BudgetPage> {
  // Controls which budget aggregation window is visible.
  BudgetViewMode viewMode = BudgetViewMode.month;

  bool _loadingAi = false;
  String _aiError = '';
  AiBudgetSuggestionResponse? _aiSuggestion;
  String _aiContextSource = '';
  static const _client = AiApiClient();

  List<BudgetCategoryProgress> get activeBudgetProgress =>
      viewMode == BudgetViewMode.month
      ? widget.budgetProgress
      : (viewMode == BudgetViewMode.year
            ? widget.budgetProgressYear
            : widget.budgetProgressAll);

  bool _hasEnoughAiData() {
    final totals = (widget.spendingSummary['totals'] is Map)
        ? (widget.spendingSummary['totals'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};
    final annualSummary = (widget.spendingSummary['annual_summary'] is Map)
        ? (widget.spendingSummary['annual_summary'] as Map)
              .cast<String, dynamic>()
        : const <String, dynamic>{};
    final annualTotals = (annualSummary['totals'] is Map)
        ? (annualSummary['totals'] as Map).cast<String, dynamic>()
        : const <String, dynamic>{};

    final expenses30d = ((totals['expenses_30d'] as num?) ?? 0).toDouble();
    final expensesYear = ((annualTotals['expenses_year'] as num?) ?? 0)
        .toDouble();
    final viewExpenses = _selectedRangeExpensesValue();
    final hasActiveSpend = activeBudgetProgress.any((item) => item.spent > 0);

    if (viewMode == BudgetViewMode.month) {
      return expenses30d > 0 || viewExpenses > 0 || hasActiveSpend;
    }
    return expensesYear > 0 || viewExpenses > 0 || hasActiveSpend;
  }

  Future<void> _generateAiBudgetSuggestions() async {
    if (_loadingAi) return;
    final hasEnoughData = _hasEnoughAiData();
    if (!hasEnoughData) {
      setState(() {
        _aiError = '';
        _aiSuggestion = const AiBudgetSuggestionResponse(
          copy:
              'Not enough expense data in this selected time range to generate reliable AI suggestions yet. Connect and refresh transactions, then try again.',
          alerts: [],
          actions: [
            AiBudgetAction(
              category: 'Data',
              type: 'review',
              target: '',
              why: 'Refresh transactions and retry.',
            ),
          ],
          confidence: '',
          contextSource: 'rule_fallback',
        );
        _aiContextSource = '';
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
      final suggestion = await _client.fetchBudgetSuggestions(
        uri: widget.aiBudgetSuggestApiUri,
        apiKey: widget.apiKey,
        spendingSummary: widget.spendingSummary,
        budgetProgress: budgetProgressPayload,
        viewMode: viewMode.name,
        simplified: true,
      );
      setState(() {
        _aiSuggestion = suggestion;
        _aiContextSource = suggestion.contextSource;
      });
    } catch (e) {
      setState(() {
        _aiError = e is AiApiException
            ? e.message
            : 'Failed to reach AI service: $e';
      });
    } finally {
      if (mounted) {
        setState(() => _loadingAi = false);
      }
    }
  }

  String _selectedRangeExpensesLabel() {
    if (viewMode == BudgetViewMode.month) return 'Total monthly expenses';
    if (viewMode == BudgetViewMode.year) return 'Total yearly expenses';
    return 'Total all-time expenses';
  }

  double _selectedRangeExpensesValue() {
    return activeBudgetProgress.fold<double>(
      0,
      (sum, item) => sum + item.spent,
    );
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
                label: Text('By Month'),
              ),
              ButtonSegment<BudgetViewMode>(
                value: BudgetViewMode.year,
                label: Text('By Year'),
              ),
              ButtonSegment<BudgetViewMode>(
                value: BudgetViewMode.all,
                label: Text('All Time'),
              ),
            ],
            selected: {viewMode},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) return;
              setState(() {
                viewMode = selection.first;
                // Reset prior AI output when switching scope to avoid stale messages.
                _aiSuggestion = null;
                _aiError = '';
                _aiContextSource = '';
              });
            },
          ),
          if (viewMode != BudgetViewMode.all) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                const Text('Month', style: TextStyle(color: Colors.black54)),
                const SizedBox(width: 12),
                Expanded(
                  child: DropdownButtonFormField<DateTime>(
                    key: ValueKey(
                      'budget-month-${widget.selectedMonth.year}-${widget.selectedMonth.month}',
                    ),
                    initialValue: DateTime(
                      widget.selectedMonth.year,
                      widget.selectedMonth.month,
                      1,
                    ),
                    decoration: const InputDecoration(
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: widget.monthOptions
                        .map(
                          (m) => DropdownMenuItem<DateTime>(
                            value: DateTime(m.year, m.month, 1),
                            child: Text(
                              '${kMonthShortLabels[m.month - 1]} ${m.year}',
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      widget.onMonthChanged(value);
                    },
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 8),
          Text(
            '${kMonthShortLabels[widget.selectedMonth.month - 1]} ${widget.selectedMonth.year} net: ${widget.stats.netThisMonth >= 0 ? '+ ' : '- '}\$${widget.stats.netThisMonth.abs().toStringAsFixed(2)}',
          ),
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
              child: const Text('No budgets configured for this view yet.'),
            ),
          if (activeBudgetProgress.isNotEmpty) ..._budgetListWidgets(context),
          const SizedBox(height: 18),
          BudgetAiAnalysisCard(
            loading: _loadingAi,
            error: _aiError,
            suggestion: _aiSuggestion,
            contextSource: _aiContextSource,
            highestCategoryText: _highestCategoryText(),
            expensesLabel: _selectedRangeExpensesLabel(),
            expensesValue: _selectedRangeExpensesValue(),
            canGenerate: _hasEnoughAiData(),
            onGenerate: _generateAiBudgetSuggestions,
          ),
        ],
      ),
    );
  }

  // Builds the visible list of budget cards for the selected time scope.
  List<Widget> _budgetListWidgets(BuildContext context) {
    final widgets = <Widget>[];
    for (int i = 0; i < activeBudgetProgress.length; i++) {
      final item = activeBudgetProgress[i];
      widgets.add(_budgetItem(context, item));
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
    if (lead == null) return 'No expense activity yet';
    if (lead.spent <= 0 || lead.ratio <= 0) return 'No expense activity yet';
    return '${lead.title} (${(lead.ratio * 100).toStringAsFixed(0)}%)';
  }

  // Short status sentence shown in the warning card near the top of the page.
  String _budgetInsight() {
    final lead = _topCategory();
    if (lead == null) return 'Budget Insight: no spending data yet.';
    if (lead.spent <= 0 || lead.ratio <= 0) {
      return 'Budget Insight: no spending data yet.';
    }
    if (lead.ratio >= 1) {
      return 'Budget Insight: ${lead.title} is over limit for selected month.';
    }
    if (lead.ratio >= 0.8) {
      return 'Budget Insight: ${lead.title} is close to limit for selected month.';
    }
    return 'Budget Insight: all categories are currently within limits.';
  }

  BudgetCategoryProgress? _topCategory() {
    if (activeBudgetProgress.isEmpty) return null;
    final sorted = [...activeBudgetProgress]
      ..sort((a, b) => b.ratio.compareTo(a.ratio));
    final lead = sorted.first;
    if (lead.spent <= 0 || lead.ratio <= 0) return null;
    return lead;
  }

  // -------------------------------------------------------------------------
  // Budget editing dialogs
  // -------------------------------------------------------------------------

  // Inline editor for a single budget row.
  Future<void> _showEditBudgetDialog(
    BuildContext context,
    BudgetCategoryProgress item,
  ) async {
    final controller = TextEditingController(
      text: item.limit.toStringAsFixed(0),
    );
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
    final controller = TextEditingController(
      text: selected.limit.toStringAsFixed(0),
    );
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
                        selected = editableBudgets.firstWhere(
                          (b) => b.budgetId == value,
                        );
                        controller.text = selected.limit.toStringAsFixed(0);
                      });
                    },
                    decoration: const InputDecoration(labelText: 'Budget'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(
                      decimal: true,
                    ),
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
                    content: Text(
                      'Custom category UI only (not connected yet).',
                    ),
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
  Widget _budgetItem(BuildContext context, BudgetCategoryProgress item) {
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
          colors: [tone.withValues(alpha: 0.14), tone.withValues(alpha: 0.05)],
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
                  _showEditBudgetDialog(context, item);
                },
                icon: Icon(Icons.tune, size: 20, color: tone),
              ),
              const SizedBox(width: 12),
              Text(amount, style: const TextStyle(fontWeight: FontWeight.w600)),
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
