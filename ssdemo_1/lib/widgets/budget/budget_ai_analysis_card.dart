import 'package:flutter/material.dart';

import '../../models/ai/ai_models.dart';
import '../../utils/app_helpers.dart';

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
                onPressed: loading || !canGenerate ? null : onGenerate,
                icon: loading
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
          Text('• Highest category usage: $highestCategoryText'),
          const SizedBox(height: 6),
          Text(
            '• $expensesLabel: ${formatMoney(expensesValue, signed: false)}',
          ),
          const SizedBox(height: 10),
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
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
          if (error.isEmpty && canGenerate && suggestion == null)
            const Text(
              'Suggestion: current pace is healthy; keep spending patterns stable.',
              style: TextStyle(fontWeight: FontWeight.w500),
            ),
          if (showSuggestion) ...[
            Row(
              children: [
                if (contextSource.isNotEmpty &&
                    contextSource != 'rule_fallback')
                  _metaBadge(contextSource, Colors.black45),
                if (showConfidenceBadge) ...[
                  const SizedBox(width: 6),
                  _metaBadge(
                    suggestion!.confidence,
                    _confidenceBadgeColor(suggestion!.confidence),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 6),
            if (displayCopy.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  displayCopy,
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ),
            if (suggestion!.alerts.isNotEmpty) ...[
              const Text(
                'Alerts',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              ...suggestion!.alerts
                  .take(3)
                  .map(
                    (item) => Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        '• [${item.severity}] ${item.category}: ${item.reason}',
                      ),
                    ),
                  ),
              const SizedBox(height: 10),
            ],
            if (actionLines.isNotEmpty) ...[
              const Text(
                'Actions',
                style: TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 6),
              ...actionLines.map((line) {
                return Padding(
                  padding: const EdgeInsets.only(bottom: 6),
                  child: Text('• $line'),
                );
              }),
            ],
          ],
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
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: color,
        ),
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
}
