import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../models/app_models.dart';
import 'budget_alert_toasts.dart';

/// Summary strip above the budget cards. Light red when any category is already
/// over budget, orange when categories are only on pace to overspend. Category
/// names are tappable links to their cards. [details] repeats each alert's
/// numbers underneath, so they stay visible after the pop-ups are dismissed.
class BudgetInsightBanner extends StatefulWidget {
  const BudgetInsightBanner({
    super.key,
    required this.message,
    this.overCategories = const [],
    this.atRiskCategories = const [],
    this.details = const [],
    this.onCategoryTap,
  });

  /// Flagged categories whose used %, amounts and pace are listed below.
  final List<BudgetCategoryProgress> details;

  /// Fallback / status when there are no tappable categories.
  final String message;

  /// Categories already past their limit (e.g. Food, Entertainment).
  final List<String> overCategories;

  /// Categories under their limit but projected to finish the month over it.
  final List<String> atRiskCategories;

  /// Called with the category title when a name is tapped.
  final ValueChanged<String>? onCategoryTap;

  @override
  State<BudgetInsightBanner> createState() => _BudgetInsightBannerState();
}

class _BudgetInsightBannerState extends State<BudgetInsightBanner> {
  bool _expanded = false;

  List<String> get overCategories => widget.overCategories;
  List<String> get atRiskCategories => widget.atRiskCategories;
  List<BudgetCategoryProgress> get details => widget.details;
  ValueChanged<String>? get onCategoryTap => widget.onCategoryTap;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final alert = overCategories.isNotEmpty;
    final hasCategories =
        overCategories.isNotEmpty || atRiskCategories.isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            alert ? Icons.error_outline : Icons.warning_amber_rounded,
            color: alert ? c.bad : c.warn,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: !hasCategories
                ? Text(
                    widget.message,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (overCategories.isNotEmpty)
                        _line('Over budget:', overCategories, c.bad),
                      if (overCategories.isNotEmpty &&
                          atRiskCategories.isNotEmpty)
                        const SizedBox(height: 6),
                      if (atRiskCategories.isNotEmpty)
                        _line(
                          'On track to overspend:',
                          atRiskCategories,
                          c.warn,
                        ),
                      if (details.isNotEmpty) ...[
                        const SizedBox(height: 4),
                        _detailsToggle(),
                        // Drops down the same numbers the pop-up alerts show.
                        AnimatedSize(
                          duration: const Duration(milliseconds: 220),
                          curve: Curves.easeOut,
                          alignment: Alignment.topLeft,
                          child: !_expanded
                              ? const SizedBox(width: double.infinity)
                              // Side by side, wrapping onto a new row when
                              // the screen is too narrow.
                              : Padding(
                                  padding: const EdgeInsets.only(top: 8),
                                  child: Wrap(
                                    spacing: 32,
                                    runSpacing: 10,
                                    children: [
                                      for (final item in details) _detail(item),
                                    ],
                                  ),
                                ),
                        ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  Widget _detailsToggle() {
    final c = context.colors;
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => setState(() => _expanded = !_expanded),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              _expanded ? 'Hide details' : 'Show details',
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w600,
                color: c.muted,
              ),
            ),
            AnimatedRotation(
              turns: _expanded ? 0.5 : 0,
              duration: const Duration(milliseconds: 220),
              child: Icon(Icons.expand_more, size: 18, color: c.muted),
            ),
          ],
        ),
      ),
    );
  }

  /// One category's numbers, matching what its pop-up alert says.
  Widget _detail(BudgetCategoryProgress item) {
    final color = item.isOverBudget ? context.colors.bad : context.colors.warn;
    return GestureDetector(
      onTap: onCategoryTap == null ? null : () => onCategoryTap!(item.title),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            item.title,
            style: TextStyle(fontWeight: FontWeight.w700, color: color),
          ),
          Text(
            budgetAlertUsageText(item),
            style: TextStyle(fontSize: 12, color: color),
          ),
          if (budgetAlertPaceText(item) case final pace?)
            Text(pace, style: TextStyle(fontSize: 12, color: color)),
        ],
      ),
    );
  }

  Widget _line(String label, List<String> categories, Color linkColor) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 6,
      runSpacing: 6,
      children: [
        Text(label, style: const TextStyle(fontWeight: FontWeight.w500)),
        for (var i = 0; i < categories.length; i++) ...[
          if (i > 0 && i == categories.length - 1)
            const Text('and', style: TextStyle(fontWeight: FontWeight.w500)),
          // The comma sits right after its name, not spaced off like a word.
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              GestureDetector(
                onTap: onCategoryTap == null
                    ? null
                    : () => onCategoryTap!(categories[i]),
                child: Text(
                  categories[i],
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: linkColor,
                    decoration: TextDecoration.underline,
                    decorationColor: linkColor,
                  ),
                ),
              ),
              if (i < categories.length - 2)
                const Text(',', style: TextStyle(fontWeight: FontWeight.w500)),
            ],
          ),
        ],
      ],
    );
  }
}
