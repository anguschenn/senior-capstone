import 'dart:async';

import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../models/ai/ai_models.dart';
import '../models/app_models.dart';
import '../models/budget_pace.dart';
import '../models/budget/budget_view_mode.dart';
import '../services/ai_api_client.dart';
import '../services/budget_service.dart';
import '../services/category_service.dart';
import '../utils/app_helpers.dart';
import '../widgets/budget/budget_ai_analysis_card.dart';
import '../widgets/budget/budget_alert_toasts.dart';
import '../widgets/budget/budget_insight_banner.dart';
import '../widgets/budget/budget_progress_card.dart';
import '../widgets/budget/budget_alert_history_card.dart';
import '../widgets/budget/budget_scope_selector.dart';
import '../widgets/budget/budget_suggestions_card.dart';
import '../widgets/common/ui.dart';

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
    this.transactions = const [],
    this.reviewedCategoryByTxId = const {},
    this.onAsk,
    this.isVisible = true,
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

  /// Visible transactions, for the per-category breakdown on each card.
  final List<AppTransaction> transactions;
  final Map<String, String> reviewedCategoryByTxId;

  /// Opens the AI with a question filled in (the ✦ chips).
  final void Function({String? prompt, String? contextLabel})? onAsk;

  /// Whether the Budget tab is on screen; the popups' timer only runs then.
  final bool isVisible;

  @override
  State<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends State<BudgetPage> {
  // Controls which budget aggregation window is visible.
  BudgetViewMode viewMode = BudgetViewMode.month;
  final Map<String, int> _manualBudgetOrder = <String, int>{};
  final Map<String, GlobalKey> _budgetItemKeys = <String, GlobalKey>{};
  String? _highlightedBudgetId;

  /// The category card opened up in the stack.
  String? _expandedBudgetId;

  /// Edit mode: cards in a flat list with drag handles to reorder.
  bool _editing = false;
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

  List<BudgetCategoryProgress> get activeBudgetProgress {
    final source = viewMode == BudgetViewMode.month
        ? widget.budgetProgress
        : (viewMode == BudgetViewMode.year
              ? widget.budgetProgressYear
              : widget.budgetProgressAll);
    if (_showsCurrentMonth) return source;
    // A finished month, a year or all time: no month-end pace to project.
    return [for (final item in source) item.withoutPace()];
  }

  bool get _showsCurrentMonth {
    if (viewMode != BudgetViewMode.month) return false;
    final month = widget.selectedMonth;
    final now = DateTime.now();
    return !isAllYearOption(month) &&
        month.year == now.year &&
        month.month == now.month;
  }

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

  /// Cards needing attention first (over, then running high), each group
  /// keeping the user's order, so every month reads the same way.
  List<BudgetCategoryProgress> get _cardsByStatus {
    int rank(BudgetCategoryProgress b) {
      if (b.isOverBudget || b.isBurnRateHigh) return 0;
      if (b.isWarning) return 1;
      return 2;
    }

    final ordered = orderedBudgetProgress;
    // All time: biggest spending first, as there are no limits to rank by.
    if (viewMode == BudgetViewMode.all) {
      return ordered..sort((a, b) => b.spent.compareTo(a.spent));
    }
    final position = {for (final (i, b) in ordered.indexed) b.budgetId: i};
    return ordered..sort((a, b) {
      final byRank = rank(a).compareTo(rank(b));
      if (byRank != 0) return byRank;
      return position[a.budgetId]!.compareTo(position[b.budgetId]!);
    });
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

  /// All spending in the period, as on Cash Flow. Not the cards' total: in
  /// the Year view those count only the months that had a budget.
  double _selectedRangeExpensesValue() {
    final focus = widget.selectedMonth;
    double total = 0;
    for (final tx in widget.transactions) {
      if (viewMode == BudgetViewMode.month &&
          !isAllYearOption(focus) &&
          (tx.date.year != focus.year || tx.date.month != focus.month)) {
        continue;
      }
      if (viewMode != BudgetViewMode.all && tx.date.year != focus.year) {
        continue;
      }
      total += tx.expenseAmount;
    }
    return total;
  }

  @override
  Widget build(BuildContext context) {
    // Budget page combines editable category limits with lightweight insight text.
    return SafeArea(bottom: false, child: _budgetListView(context));
  }

  String get _insightPeriod => switch (viewMode) {
    BudgetViewMode.month => periodLabelForSelection(widget.selectedMonth),
    BudgetViewMode.year => '${widget.selectedMonth.year}',
    BudgetViewMode.all => 'all time',
  };

  String get _periodLabel => switch (viewMode) {
    BudgetViewMode.month => periodLabelForSelection(widget.selectedMonth),
    BudgetViewMode.year => '${widget.selectedMonth.year}',
    BudgetViewMode.all => 'All time',
  };

  void _ask(String prompt) => widget.onAsk?.call(
    prompt: prompt,
    contextLabel: 'From Budget · $_periodLabel',
  );

  Widget _budgetListView(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.only(bottom: 32),
      children: [
        LargeTitle(
          'Budget',
          trailing: [
            TextButton(
              key: const ValueKey('budget-edit'),
              onPressed: activeBudgetProgress.isEmpty
                  ? null
                  : () => setState(() => _editing = !_editing),
              child: Text(
                _editing ? 'Done' : 'Edit',
                style: const TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            CircleIconButton(
              icon: Icons.add_rounded,
              tooltip: 'Add Category',
              onPressed: () => _showCustomCategoryDialog(context),
            ),
          ],
        ),
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
          // Overspend alerts sit in a pill beside the month instead of
          // popping up over the page.
          alert: BudgetAlertPill(
            items: _overspendCategories(),
            onTap: (c) => _scrollToBudgetCategory(c.budgetId),
          ),
        ),
        _budgetHeader(context),
        // Lists overspending categories; tap a name to jump to its card.
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
          child: Builder(
            builder: (context) {
              final flagged = _overspendCategories();
              final byTitle = {for (final c in flagged) c.title: c.budgetId};
              return BudgetInsightBanner(
                message: _budgetInsight(),
                overCategories: [
                  for (final c in flagged)
                    if (c.isOverBudget) c.title,
                ],
                atRiskCategories: [
                  for (final c in flagged)
                    if (!c.isOverBudget) c.title,
                ],
                details: [
                  ...flagged.where((c) => c.isOverBudget),
                  ...flagged.where((c) => !c.isOverBudget),
                ],
                onCategoryTap: (title) {
                  final id = byTitle[title];
                  if (id != null) _scrollToBudgetCategory(id);
                },
              );
            },
          ),
        ),
        // Category budget cards show spent vs. limit for the current time scope.
        if (activeBudgetProgress.isEmpty)
          Section(
            child: Text(
              'No budgets configured for this view yet.',
              style: TextStyle(color: context.colors.muted),
            ),
          ),
        if (activeBudgetProgress.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
            child: _editing
                ? _budgetList(context)
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      // All time has no limits, so no dots to explain.
                      if (viewMode != BudgetViewMode.all &&
                          activeBudgetProgress.any((b) => b.hasLimit))
                        _statusLegend(context),
                      _budgetStack(context),
                    ],
                  ),
          ),
        if (_editing)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
            child: OutlinedButton.icon(
              onPressed: () => _showBulkEditBudgetDialog(context),
              icon: const Icon(Icons.tune, size: 18),
              label: const Text('Edit Budget'),
            ),
          ),
        const SizedBox(height: 8),
        // Limits the backend suggests from past months; this month only.
        if (_showsCurrentMonth)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: BudgetSuggestionsCard(
              month: widget.selectedMonth,
              onUpdateBudgetLimit: widget.onUpdateBudgetLimit,
              onAskWhy: widget.onAsk == null
                  ? null
                  : (category) => _ask(
                      'Why is the suggested $category budget different from my current one?',
                    ),
            ),
          ),
        // Past months that ended over budget (backend alert history).
        if (viewMode == BudgetViewMode.month &&
            !isAllYearOption(widget.selectedMonth))
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: BudgetAlertHistoryCard(month: widget.selectedMonth),
          ),
        const SizedBox(height: 10),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: BudgetAiAnalysisCard(
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
        ),
      ],
    );
  }

  /// Income minus spending for the view's period, the same figure the Cash
  /// Flow page shows for that month, year or all time.
  double get _periodNet {
    if (viewMode == BudgetViewMode.month) {
      return widget.stats.cashFlowNetThisMonth;
    }
    final year = widget.selectedMonth.year;
    double net = 0;
    for (final tx in widget.transactions) {
      if (viewMode == BudgetViewMode.year && tx.date.year != year) continue;
      net += tx.incomeAmount - tx.expenseAmount;
    }
    return net;
  }

  /// "Left to spend" hero with the period's cash flow under it.
  Widget _budgetHeader(BuildContext context) {
    final c = context.colors;
    final net = _periodNet;
    final positive = net >= 0;
    final budgeted = activeBudgetProgress
        .where((b) => b.hasLimit)
        .fold<double>(0, (sum, b) => sum + b.limit);
    final double left;
    if (viewMode == BudgetViewMode.month &&
        !isAllYearOption(widget.selectedMonth)) {
      // Same number as "Budget left" on Wallet and Cash Flow: the month's
      // budgets minus all of its spending, budgeted category or not.
      left = BudgetPaceSnapshot.build(
        focusMonth: normalizedMonthOption(widget.selectedMonth),
        budgets: activeBudgetProgress,
        transactions: widget.transactions,
      ).remaining;
    } else {
      final spent = activeBudgetProgress
          .where((b) => b.hasLimit)
          .fold<double>(0, (sum, b) => sum + b.spent);
      left = budgeted - spent;
    }

    return Section(
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 10),
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (viewMode == BudgetViewMode.all)
            Text(
              'Budgets are set per month. Pick Month or Year to see '
              'what is left to spend.',
              key: const ValueKey('budget-all-time-note'),
              style: TextStyle(fontSize: 14, color: c.muted),
            )
          else if (budgeted <= 0)
            Text(
              'No budget was set for $_insightPeriod, so there is nothing '
              'to be over. Spending is shown below.',
              key: const ValueKey('budget-none-set-note'),
              style: TextStyle(fontSize: 14, color: c.muted),
            )
          else ...[
            Text(
              left >= 0 ? 'Left to spend' : 'Over budget',
              style: TextStyle(fontSize: 13, color: c.muted),
            ),
            const SizedBox(height: 2),
            Row(
              crossAxisAlignment: CrossAxisAlignment.baseline,
              textBaseline: TextBaseline.alphabetic,
              children: [
                Text(
                  dollars(left, decimals: 0),
                  style: TextStyle(
                    fontSize: 34,
                    fontWeight: FontWeight.w700,
                    letterSpacing: -0.8,
                    color: left >= 0 ? c.text : c.bad,
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  'of ${dollars(budgeted, decimals: 0)} budgeted',
                  style: TextStyle(fontSize: 14, color: c.muted),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          Divider(height: 1, thickness: 0.5, color: c.line),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  '$_periodLabel cash flow',
                  style: TextStyle(fontSize: 14, color: c.muted),
                ),
              ),
              Text(
                dollars(net, sign: true),
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w700,
                  color: positive ? c.good : c.bad,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  /// Wallet-style stack of category cards; tap one to open it up.
  Widget _budgetStack(BuildContext context) {
    // Categories with no budget and no spending fold into one row at the end
    // so they don't take a full card each.
    final items = [
      for (final b in _cardsByStatus)
        if (b.hasLimit || b.spent > 0) b,
    ];
    final unset = [
      for (final b in orderedBudgetProgress)
        if (!b.hasLimit && b.spent <= 0) b,
    ];
    final txByCategory = _transactionsByCategory();
    return Column(
      children: [
        for (final (index, item) in items.indexed)
          Builder(
            builder: (context) {
              final open = _expandedBudgetId == item.budgetId;
              final last = index == items.length - 1;
              final itemKey = _budgetItemKeys.putIfAbsent(
                item.budgetId,
                GlobalKey.new,
              );
              // A closed card is drawn full height but only its top strip
              // takes up room, so the next card overlaps the rest of it.
              return AnimatedSize(
                key: ValueKey('budget-item-${item.budgetId}'),
                duration: const Duration(milliseconds: 220),
                curve: Curves.easeOutCubic,
                alignment: Alignment.topCenter,
                child: Align(
                  alignment: Alignment.topCenter,
                  heightFactor: open || last ? 1 : 0.62,
                  child: Padding(
                    padding: EdgeInsets.only(bottom: open && !last ? 10 : 0),
                    child: KeyedSubtree(
                      key: itemKey,
                      child: BudgetProgressCard(
                        item: item,
                        index: index,
                        expanded: open,
                        transactions:
                            txByCategory[normalizeCategoryKey(item.title)] ??
                            const [],
                        highlighted: _highlightedBudgetId == item.budgetId,
                        showNoBudget: viewMode != BudgetViewMode.all,
                        onTap: () => setState(
                          () => _expandedBudgetId = open ? null : item.budgetId,
                        ),
                        onEdit: (selectedItem) =>
                            _showEditBudgetDialog(context, selectedItem),
                        onAskWhy: widget.onAsk == null
                            ? null
                            : () => _ask(
                                'Why is my ${item.title} spending high in $_periodLabel?',
                              ),
                      ),
                    ),
                  ),
                ),
              );
            },
          ),
        if (unset.isNotEmpty && viewMode != BudgetViewMode.all)
          _unsetBudgetsRow(context, unset),
      ],
    );
  }

  /// What the dots on the category cards mean.
  Widget _statusLegend(BuildContext context) {
    final c = context.colors;
    final style = TextStyle(fontSize: 13, color: c.muted);
    Widget entry(Widget swatch, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        swatch,
        const SizedBox(width: 6),
        Text(label, style: style),
      ],
    );
    const dot = 10.0;
    return Padding(
      key: const ValueKey('budget-legend'),
      padding: const EdgeInsets.fromLTRB(4, 0, 4, 10),
      child: Wrap(
        spacing: 16,
        runSpacing: 6,
        children: [
          // Red: spent more than the limit, or (this month only) the pace
          // ends over it.
          entry(
            const BudgetStatusDot(
              color: BudgetStatusDot.over,
              size: dot,
              ring: false,
            ),
            _showsCurrentMonth ? 'Over or will go over' : 'Over budget',
          ),
          // Amber: 80% used, or this month's pace ends at 90% or more.
          entry(
            const BudgetStatusDot(
              color: BudgetStatusDot.high,
              size: dot,
              ring: false,
            ),
            'Near limit',
          ),
          // Healthy cards carry no dot: an empty ring stands for that.
          entry(
            Container(
              width: dot,
              height: dot,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: c.muted, width: 1.5),
              ),
            ),
            'On track',
          ),
        ],
      ),
    );
  }

  /// "No budget set: Bills, Housing… · Set ›" — tap to pick one and set it.
  Widget _unsetBudgetsRow(
    BuildContext context,
    List<BudgetCategoryProgress> unset,
  ) {
    final c = context.colors;
    return Section(
      key: const ValueKey('budget-unset'),
      margin: const EdgeInsets.only(top: 10),
      onTap: () async {
        final picked = await showOptionSheet<BudgetCategoryProgress>(
          context: context,
          title: 'Set a budget',
          values: unset,
          labelOf: (b) => b.title,
          selected: null,
        );
        if (picked != null && context.mounted) {
          _showEditBudgetDialog(context, picked);
        }
      },
      child: Row(
        children: [
          Expanded(
            child: Text(
              'No budget set: ${unset.map((b) => b.title).join(', ')}',
              style: TextStyle(fontSize: 13.5, color: c.muted),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            'Set',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: c.text,
            ),
          ),
          Icon(Icons.chevron_right_rounded, size: 20, color: c.muted),
        ],
      ),
    );
  }

  // Edit mode: a flat list of cards with drag handles to reorder them.
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
          key: ValueKey('budget-edit-${item.budgetId}'),
          padding: const EdgeInsets.only(bottom: 8),
          child: BudgetProgressCard(
            item: item,
            index: index,
            expanded: false,
            reorderable: true,
            onTap: () => _showEditBudgetDialog(context, item),
            onEdit: (selectedItem) =>
                _showEditBudgetDialog(context, selectedItem),
          ),
        );
      },
    );
  }

  // -------------------------------------------------------------------------
  /// Spending transactions behind each card, largest first. Grouped exactly
  /// like the card's "spent" figure (BudgetService.rebasedProgressFromTemplate),
  /// so the rows add up to it.
  Map<String, List<AppTransaction>> _transactionsByCategory() {
    final focus = widget.selectedMonth;
    final cardKeys = {
      for (final item in activeBudgetProgress) normalizeCategoryKey(item.title),
    };
    final out = <String, List<AppTransaction>>{};
    for (final tx in widget.transactions) {
      if (tx.expenseAmount <= 0) continue;
      if (viewMode == BudgetViewMode.month &&
          (tx.date.year != focus.year || tx.date.month != focus.month)) {
        continue;
      }
      if (viewMode == BudgetViewMode.year && tx.date.year != focus.year) {
        continue;
      }
      final bucket = CategoryService.instance.budgetBucketFor(
        tx,
        widget.reviewedCategoryByTxId,
      );
      final key = BudgetService.cardKeyForBucket(
        normalizeCategoryKey(bucket),
        cardKeys,
      );
      out.putIfAbsent(key, () => []).add(tx);
    }
    for (final list in out.values) {
      list.sort((a, b) => b.expenseAmount.compareTo(a.expenseAmount));
    }
    return out;
  }

  // Budget insight text helpers
  // -------------------------------------------------------------------------

  String _highestCategoryText() {
    final lead = _topCategory();
    if (lead == null) return 'No expense activity yet';
    if (lead.spent <= 0 || lead.ratio <= 0) return 'No expense activity yet';
    return '${lead.title} (${(lead.usedRatio * 100).toStringAsFixed(0)}%)';
  }

  /// Categories over budget or projected to finish the month over it
  /// (month view; past months can only be over).
  List<BudgetCategoryProgress> _overspendCategories() {
    if (viewMode != BudgetViewMode.month) return const [];
    final over =
        activeBudgetProgress
            .where(
              (item) =>
                  item.spent > 0 && (item.isOverBudget || item.isBurnRateHigh),
            )
            .toList()
          ..sort((a, b) => b.projectedOverrun.compareTo(a.projectedOverrun));
    return over;
  }

  Future<void> _scrollToBudgetCategory(String budgetId) async {
    if (_editing || _expandedBudgetId != budgetId) {
      setState(() {
        _editing = false;
        _expandedBudgetId = budgetId;
      });
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
    }
    final key = _budgetItemKeys[budgetId];
    final target = key?.currentContext;
    if (target == null || !target.mounted) return;

    setState(() => _highlightedBudgetId = budgetId);
    await Scrollable.ensureVisible(
      target,
      duration: const Duration(milliseconds: 350),
      curve: Curves.easeOutCubic,
      alignment: 0.15,
    );
    await Future<void>.delayed(const Duration(milliseconds: 1600));
    if (!mounted) return;
    if (_highlightedBudgetId == budgetId) {
      setState(() => _highlightedBudgetId = null);
    }
  }

  // Short status sentence shown in the warning card near the top of the page.
  String _budgetInsight() {
    // All time has no limits (budgets are monthly): name the biggest spend.
    if (viewMode == BudgetViewMode.all) {
      final spenders = [...activeBudgetProgress.where((b) => b.spent > 0)]
        ..sort((a, b) => b.spent.compareTo(a.spent));
      if (spenders.isEmpty) return 'Budget Insight: no spending data yet.';
      final top = spenders.first;
      return 'Budget Insight: ${top.title} is your biggest spending category '
          'all time (${dollars(top.spent, decimals: 0)}).';
    }
    final unbudgeted = [
      for (final item in activeBudgetProgress)
        if (item.isUnbudgetedSpend) item.title,
    ];
    final unbudgetedNote = unbudgeted.isEmpty
        ? ''
        : ' No budget set for ${unbudgeted.join(', ')}.';
    final lead = _topCategory();
    if (lead == null || lead.spent <= 0 || lead.ratio <= 0) {
      if (unbudgeted.isNotEmpty) {
        return 'Budget Insight: spending in categories without a budget.'
            '$unbudgetedNote';
      }
      return 'Budget Insight: no spending data yet.';
    }

    // Month view: prefer burn-rate pace messaging (no Generate click required).
    if (viewMode == BudgetViewMode.month) {
      if (lead.isBurnRateHigh) {
        return 'Burn rate alert: ${lead.title} projects '
            '${dollars(lead.projectedMonthEnd, decimals: 0)} by month end '
            '(${dollars(lead.projectedOverrun, decimals: 0)} over budget).';
      }
      if (lead.isBurnRateApproaching) {
        return 'Burn rate alert: ${lead.title} is on pace for '
            '${dollars(lead.projectedMonthEnd, decimals: 0)} by month end (near limit).';
      }
      // Prefer the worst burn-rate category even if ratio leader looks fine.
      final burnLead = _topBurnRateCategory();
      if (burnLead != null && burnLead.isBurnRateHigh) {
        return 'Burn rate alert: ${burnLead.title} projects '
            '${dollars(burnLead.projectedMonthEnd, decimals: 0)} by month end '
            '(${dollars(burnLead.projectedOverrun, decimals: 0)} over budget).';
      }
      if (burnLead != null && burnLead.isBurnRateApproaching) {
        return 'Burn rate alert: ${burnLead.title} is on pace for '
            '${dollars(burnLead.projectedMonthEnd, decimals: 0)} by month end (near limit).';
      }
    }

    if (lead.ratio >= 1) {
      final over = [
        for (final b in activeBudgetProgress)
          if (b.isOverBudget) b.title,
      ];
      final names = over.length <= 1
          ? lead.title
          : over.length == 2
          ? '${over[0]} and ${over[1]}'
          : '${over[0]}, ${over[1]} and ${over.length - 2} more';
      return 'Budget Insight: $names ${over.length > 1 ? 'are' : 'is'} '
          'over limit for $_insightPeriod.';
    }
    if (lead.ratio >= 0.8) {
      return 'Budget Insight: ${lead.title} is close to limit for $_insightPeriod.';
    }
    if (unbudgeted.isNotEmpty) {
      return 'Budget Insight: budgeted categories are within limits.'
          '$unbudgetedNote';
    }
    return 'Budget Insight: all categories are currently within limits.';
  }

  BudgetCategoryProgress? _topCategory() {
    if (activeBudgetProgress.isEmpty) return null;
    final sorted = [...activeBudgetProgress]
      ..sort((a, b) => b.usedRatio.compareTo(a.usedRatio));
    final lead = sorted.first;
    if (lead.spent <= 0 || lead.ratio <= 0) return null;
    return lead;
  }

  BudgetCategoryProgress? _topBurnRateCategory() {
    if (activeBudgetProgress.isEmpty) return null;
    final sorted = [...activeBudgetProgress]
      ..sort((a, b) {
        final ap = a.projectedMonthEnd;
        final bp = b.projectedMonthEnd;
        if (!ap.isFinite && !bp.isFinite) return 0;
        if (!ap.isFinite) return 1;
        if (!bp.isFinite) return -1;
        return bp.compareTo(ap);
      });
    final candidates = sorted.where(
      (item) =>
          item.limit > 0 &&
          item.spent > 0 &&
          (item.isBurnRateHigh || item.isBurnRateApproaching),
    );
    if (candidates.isEmpty) return null;
    return candidates.first;
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
                if (parsed == null || !parsed.isFinite || parsed < 0) return;
                final monthlyLimit = viewMode == BudgetViewMode.year
                    ? (parsed / 12)
                    : parsed;
                // Pop first so parent rebuild during save cannot break the dialog route.
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
                await widget.onUpdateBudgetLimit(item.budgetId, monthlyLimit);
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
                    if (parsed == null || !parsed.isFinite || parsed < 0) {
                      return;
                    }
                    final monthlyLimit = viewMode == BudgetViewMode.year
                        ? (parsed / 12)
                        : parsed;
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                    await widget.onUpdateBudgetLimit(
                      selected.budgetId,
                      monthlyLimit,
                    );
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
