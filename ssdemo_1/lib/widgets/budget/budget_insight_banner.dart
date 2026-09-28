import 'package:flutter/material.dart';

/// Summary strip above the budget cards. Light red when any category is already
/// over budget, orange when categories are only on pace to overspend. Category
/// names are tappable links to their cards.
class BudgetInsightBanner extends StatelessWidget {
  const BudgetInsightBanner({
    super.key,
    required this.message,
    this.overCategories = const [],
    this.atRiskCategories = const [],
    this.onCategoryTap,
  });

  /// Fallback / status when there are no tappable categories.
  final String message;

  /// Categories already past their limit (e.g. Food, Entertainment).
  final List<String> overCategories;

  /// Categories under their limit but projected to finish the month over it.
  final List<String> atRiskCategories;

  /// Called with the category title when a name is tapped.
  final ValueChanged<String>? onCategoryTap;

  @override
  Widget build(BuildContext context) {
    final alert = overCategories.isNotEmpty;
    final hasCategories =
        overCategories.isNotEmpty || atRiskCategories.isNotEmpty;

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: alert
            ? Colors.red.shade50.withValues(alpha: 0.9)
            : Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
        border: alert ? Border.all(color: Colors.red.shade200) : null,
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            alert ? Icons.error_outline : Icons.warning_amber_rounded,
            color: alert ? Colors.red.shade700 : Colors.orange,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: !hasCategories
                ? Text(
                    message,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (overCategories.isNotEmpty)
                        _line(
                          'Over budget:',
                          overCategories,
                          Colors.red.shade800,
                        ),
                      if (overCategories.isNotEmpty &&
                          atRiskCategories.isNotEmpty)
                        const SizedBox(height: 6),
                      if (atRiskCategories.isNotEmpty)
                        _line(
                          'On track to overspend:',
                          atRiskCategories,
                          Colors.orange.shade800,
                        ),
                    ],
                  ),
          ),
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
          if (i > 0)
            Text(
              i == categories.length - 1 ? 'and' : ',',
              style: const TextStyle(fontWeight: FontWeight.w500),
            ),
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
        ],
      ],
    );
  }
}
