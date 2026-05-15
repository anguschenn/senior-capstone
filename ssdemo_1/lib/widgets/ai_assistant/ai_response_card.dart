import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../../models/ai/ai_models.dart';

class AiResponseCard extends StatelessWidget {
  const AiResponseCard({super.key, required this.response});

  final AiChatResponse response;

  @override
  Widget build(BuildContext context) {
    final hasDebugData =
        response.answerSource.trim().isNotEmpty ||
        response.factsUsed.isNotEmpty ||
        response.periodResolved.isNotEmpty;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (response.copy.isNotEmpty)
            Text(
              response.copy,
              style: const TextStyle(fontSize: 13.5, height: 1.4),
            ),
          if (response.insights.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Insights',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 4),
            ...response.insights.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('• ', style: TextStyle(fontSize: 13)),
                    Expanded(
                      child: Text(
                        item,
                        style: const TextStyle(fontSize: 13, height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (response.actions.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Text(
              'Actions',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: Colors.black54,
              ),
            ),
            const SizedBox(height: 4),
            ...response.actions.map(
              (item) => Padding(
                padding: const EdgeInsets.only(bottom: 3),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text(
                      '→ ',
                      style: TextStyle(fontSize: 13, color: Colors.green),
                    ),
                    Expanded(
                      child: Text(
                        item,
                        style: const TextStyle(fontSize: 13, height: 1.3),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
          if (kDebugMode && hasDebugData) ...[
            const SizedBox(height: 10),
            const Divider(height: 1),
            const SizedBox(height: 8),
            Text(
              'Debug',
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: Colors.black.withValues(alpha: 0.5),
              ),
            ),
            if (response.answerSource.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'source: ${response.answerSource}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.black.withValues(alpha: 0.65),
                    height: 1.25,
                  ),
                ),
              ),
            if (response.periodResolved.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'period: ${response.periodResolved}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.black.withValues(alpha: 0.65),
                    height: 1.25,
                  ),
                ),
              ),
            if (response.factsUsed.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  'facts: ${response.factsUsed.join(' | ')}',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.black.withValues(alpha: 0.65),
                    height: 1.25,
                  ),
                ),
              ),
          ],
        ],
      ),
    );
  }
}
