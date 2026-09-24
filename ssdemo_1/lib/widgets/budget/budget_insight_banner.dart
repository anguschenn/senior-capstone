import 'package:flutter/material.dart';

/// Yellow insight strip: lists overspending categories as tappable links.
class BudgetInsightBanner extends StatelessWidget {
  const BudgetInsightBanner({
    super.key,
    required this.message,
    this.categories = const [],
    this.onCategoryTap,
  });

  /// Fallback / status when there are no tappable categories.
  final String message;

  /// Category titles shown as taps (e.g. Food, Transport).
  final List<String> categories;

  /// Called with the category title when a name chip is tapped.
  final ValueChanged<String>? onCategoryTap;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.orange.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.orange),
          const SizedBox(width: 10),
          Expanded(
            child: categories.isEmpty
                ? Text(
                    message,
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  )
                : Wrap(
                    crossAxisAlignment: WrapCrossAlignment.center,
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      const Text(
                        'On track to overspend:',
                        style: TextStyle(fontWeight: FontWeight.w500),
                      ),
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
                              color: Colors.orange.shade800,
                              decoration: TextDecoration.underline,
                              decorationColor: Colors.orange.shade800,
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
}
