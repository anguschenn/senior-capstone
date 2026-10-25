import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../models/ai/ai_models.dart';
import '../../utils/app_helpers.dart';
import '../common/ui.dart';

class BudgetAiAnalysisCard extends StatelessWidget {
  const BudgetAiAnalysisCard({
    super.key,
    required this.loading,
    required this.error,
    required this.suggestion,
    required this.contextSource,
    required this.highestCategoryText,
    required this.expensesLabel,
    required this.expensesValue,
    required this.canGenerate,
    required this.onGenerate,
  });

  final bool loading;
  final String error;
  final AiBudgetSuggestionResponse? suggestion;
  final String contextSource;
  final String highestCategoryText;
  final String expensesLabel;
  final double expensesValue;
  final bool canGenerate;
  final VoidCallback onGenerate;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final showSuggestion = suggestion != null;
    final hasVisibleSpend = expensesValue > 0;
    final rawCopy = suggestion?.copy ?? '';
    final shouldRewriteInsufficientCopy =
        hasVisibleSpend &&
        rawCopy.toLowerCase().startsWith(
          'not enough data to generate a reliable forecast',
        );
    final displayCopy = shouldRewriteInsufficientCopy
        ? 'Limited history confidence, but current budget overrun risk appears low based on available spending.'
        : rawCopy;
    final showConfidenceBadge =
        (suggestion?.confidence.isNotEmpty ?? false) &&
        !shouldRewriteInsufficientCopy;
    var actionLines = shouldRewriteInsufficientCopy
        ? const [
            'Keep current budget limits and monitor weekly.',
            'Focus on top spending category to avoid trend drift.',
          ]
        : suggestion?.actions.take(3).map((item) {
                final readableText = item.why.trim().isNotEmpty
                    ? item.why.trim()
                    : item.category.replaceAll('_', ' ').trim();
                final targetSuffix = item.target.trim().isEmpty
                    ? ''
                    : ' (${item.target})';
                return '$readableText$targetSuffix';
              }).toList() ??
              const <String>[];
    if (hasVisibleSpend && actionLines.isEmpty) {
      actionLines = const [
        'Keep current budget limits and monitor weekly.',
        'Review top spending category before the next cycle.',
      ];
    }
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: cardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Text(
                'AI Analysis',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: loading || !canGenerate ? null : onGenerate,
                icon: AskMark(size: 16, color: loading ? c.muted : null),
                label: Text(
                  loading
                      ? 'Analyzing...'
                      : showSuggestion
                      ? 'Generate again'
                      : 'Generate',
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            '• Highest category usage: $highestCategoryText',
            style: TextStyle(color: c.muted),
          ),
          const SizedBox(height: 6),
          Text(
            '• $expensesLabel: ${formatMoney(expensesValue, signed: false)}',
            style: TextStyle(color: c.muted),
          ),
          const SizedBox(height: 10),
          // The result area: a skeleton of the answer while it is being
          // made (unless it comes back quickly), then the answer itself.
          DelayedSkeleton(
            loading: loading,
            skeleton: const _AnalysisSkeleton(),
            child: Column(
              // A new answer is a new subtree, so its blocks come in again.
              key: ObjectKey(suggestion),
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                if (!canGenerate && suggestion == null && error.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text(
                      'Need more expense history before generating AI suggestions.',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                  ),
                if (error.isNotEmpty)
                  Text(
                    error,
                    style: TextStyle(
                      color: c.bad,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                if (error.isEmpty && canGenerate && suggestion == null)
                  const Text(
                    // Nothing judged yet: don't claim the pace is fine.
                    'Tap Generate for suggestions on this period.',
                    style: TextStyle(fontWeight: FontWeight.w500),
                  ),
                if (showSuggestion)
                  ...FadeSlideIn.staggered(
                    _suggestionBlocks(
                      c,
                      displayCopy,
                      showConfidenceBadge,
                      actionLines,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// The answer in blocks (badges, summary, alerts, actions), so they can
  /// come in one after another.
  List<Widget> _suggestionBlocks(
    AppColors c,
    String displayCopy,
    bool showConfidenceBadge,
    List<String> actionLines,
  ) {
    final s = suggestion!;
    return [
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Row(
          children: [
            if (contextSource.isNotEmpty && contextSource != 'rule_fallback')
              _metaBadge(contextSource, c.muted),
            if (showConfidenceBadge) ...[
              const SizedBox(width: 6),
              _metaBadge(s.confidence, _confidenceBadgeColor(c, s.confidence)),
            ],
          ],
        ),
      ),
      if (displayCopy.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Text(
            displayCopy,
            style: const TextStyle(fontWeight: FontWeight.w500),
          ),
        ),
      if (s.alerts.isNotEmpty)
        Padding(
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Alerts',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              for (final item in s.alerts.take(3))
                Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text(
                    '• [${item.severity}] ${item.category}: ${item.reason}',
                  ),
                ),
            ],
          ),
        ),
      if (actionLines.isNotEmpty)
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Actions',
              style: TextStyle(fontWeight: FontWeight.w700),
            ),
            const SizedBox(height: 6),
            for (final line in actionLines)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Text('• $line'),
              ),
          ],
        ),
    ];
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
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
      ),
    );
  }

  Color _confidenceBadgeColor(AppColors c, String confidence) {
    switch (confidence) {
      case 'high':
        return c.good;
      case 'medium':
        return c.warn;
      case 'low':
        return c.bad;
      default:
        return c.muted;
    }
  }
}

/// Stands in for the answer while it is being made: badges, a few lines of
/// summary and a short list of actions, where the real ones will land.
class _AnalysisSkeleton extends StatelessWidget {
  const _AnalysisSkeleton();

  static Widget _line(double widthFactor, {double height = 13}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: FractionallySizedBox(
        alignment: Alignment.centerLeft,
        widthFactor: widthFactor,
        child: SkeletonBox(height: height),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return SkeletonShimmer(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Padding(
            padding: EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SkeletonBox(width: 58, height: 16),
                SizedBox(width: 6),
                SkeletonBox(width: 44, height: 16),
              ],
            ),
          ),
          _line(1),
          _line(0.94),
          _line(0.6),
          const SizedBox(height: 8),
          _line(0.22, height: 14),
          _line(0.88),
          _line(0.74),
          _line(0.8),
        ],
      ),
    );
  }
}
