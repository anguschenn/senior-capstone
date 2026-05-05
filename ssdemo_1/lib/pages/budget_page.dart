import 'package:flutter/material.dart';

import '../models/ai/ai_models.dart';
import '../models/app_models.dart';
import '../models/budget/budget_view_mode.dart';
import '../services/ai_api_client.dart';
import '../utils/app_helpers.dart';
import '../widgets/budget/budget_ai_analysis_card.dart';
import '../widgets/budget/budget_insight_banner.dart';
import '../widgets/budget/budget_progress_card.dart';
import '../widgets/budget/budget_scope_selector.dart';

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
  final Map<String, int> _manualBudgetOrder = <String, int>{};

  bool _loadingAi = false;
  String _aiError = '';
  AiBudgetSuggestionResponse? _aiSuggestion;
  String _aiContextSource = '';
  static const _client = AiApiClient();
  List<int> get _yearOptions {
    final years = <int>{DateTime.now().year, widget.selectedMonth.year};
    for (final m in widget.monthOptions) {
      years.add(m.year);
    }
    final sorted = years.toList()..sort((a, b) => b.compareTo(a));
    return sorted;
  }

  List<DateTime> get _monthOnlyOptions {
    final seen = <String>{};
    final out = <DateTime>[];
    for (final m in widget.monthOptions) {
      if (isAllYearOption(m)) continue;
      final n = normalizedMonthOption(m);
      final key = '${n.year}-${n.month}';
      if (seen.add(key)) out.add(n);
    }
    return out;
  }

  List<BudgetCategoryProgress> get activeBudgetProgress =>
      viewMode == BudgetViewMode.month
      ? widget.budgetProgress
      : (viewMode == BudgetViewMode.year
            ? widget.budgetProgressYear
            : widget.budgetProgressAll);

  List<BudgetCategoryProgress> get orderedBudgetProgress {
    final ordered = [...activeBudgetProgress];
    for (final item in ordered) {
      _manualBudgetOrder.putIfAbsent(
        item.budgetId,
        () => _manualBudgetOrder.length,
      );
    }
    ordered.sort((a, b) {
      final ai = _manualBudgetOrder[a.budgetId] ?? 1 << 30;
      final bi = _manualBudgetOrder[b.budgetId] ?? 1 << 30;
      return ai.compareTo(bi);
    });
    return ordered;
  }

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
    if (viewMode == BudgetViewMode.month) {
      return isAllYearOption(widget.selectedMonth)
          ? 'Total yearly expenses'
          : 'Total monthly expenses';
    }
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
          BudgetScopeSelector(
            viewMode: viewMode,
            onViewModeChanged: (mode) {
              setState(() {
                viewMode = mode;
                _aiSuggestion = null;
                _aiError = '';
                _aiContextSource = '';
              });
            },
            selectedMonth: widget.selectedMonth,
            monthOptions: _monthOnlyOptions,
            yearOptions: _yearOptions,
            onMonthChanged: widget.onMonthChanged,
          ),
          const SizedBox(height: 8),
          Text(
            '${periodLabelForSelection(widget.selectedMonth)} cash flow: ${widget.stats.cashFlowNetThisMonth >= 0 ? '+ ' : '- '}\$${widget.stats.cashFlowNetThisMonth.abs().toStringAsFixed(2)}',
          ),
          const SizedBox(height: 20),
          // Insight card summarizes the highest-risk budget category at a glance.
          BudgetInsightBanner(message: _budgetInsight()),
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
          if (activeBudgetProgress.isNotEmpty) _budgetList(context),
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
  Widget _budgetList(BuildContext context) {
    final items = orderedBudgetProgress;
    return ReorderableListView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      buildDefaultDragHandles: false,
      onReorder: (oldIndex, newIndex) {
        setState(() {
          if (newIndex > oldIndex) newIndex -= 1;
          final next = [...items];
          final moved = next.removeAt(oldIndex);
          next.insert(newIndex, moved);
          for (int i = 0; i < next.length; i++) {
            _manualBudgetOrder[next[i].budgetId] = i;
          }
        });
      },
      itemBuilder: (context, index) {
        final item = items[index];
        return Padding(
          key: ValueKey('budget-item-${item.budgetId}'),
          padding: EdgeInsets.only(bottom: index == items.length - 1 ? 0 : 14),
          child: BudgetProgressCard(
            item: item,
            index: index,
            onEdit: (selectedItem) =>
                _showEditBudgetDialog(context, selectedItem),
          ),
        );
      },
    );
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
                if (parsed == null || parsed < 0) return;
                final monthlyLimit = viewMode == BudgetViewMode.year
                    ? (parsed / 12)
                    : parsed;
                await widget.onUpdateBudgetLimit(item.budgetId, monthlyLimit);
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
    final editableBudgets = activeBudgetProgress.toList();
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
                    if (parsed == null || parsed < 0) return;
                    final monthlyLimit = viewMode == BudgetViewMode.year
                        ? (parsed / 12)
                        : parsed;
                    await widget.onUpdateBudgetLimit(
                      selected.budgetId,
                      monthlyLimit,
                    );
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
}
