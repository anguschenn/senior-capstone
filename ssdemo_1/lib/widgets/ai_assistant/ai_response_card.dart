import 'package:flutter/material.dart';

import '../../models/ai/ai_models.dart';

class AiResponseCard extends StatelessWidget {
  const AiResponseCard({super.key, required this.response});

  final AiChatResponse response;

  @override
  Widget build(BuildContext context) {
    final confidencePct = (response.confidence * 100).round().clamp(0, 100);
    final showConfidence = response.confidence > 0;
    final lowConfidence = response.confidence > 0 && response.confidence < 0.5;
    final citations = response.citations.where((item) => item.trim().isNotEmpty).toList();

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.grey.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          if (showConfidence)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Confidence: $confidencePct%',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: lowConfidence ? Colors.orange.shade700 : Colors.black54,
                ),
              ),
            ),
          if (lowConfidence)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Data may be limited. Sync transactions for a more precise answer.',
                style: TextStyle(fontSize: 11, color: Colors.orange.shade700),
              ),
            ),
          if (citations.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final citation in citations)
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.06),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        citation,
                        style: const TextStyle(
                          fontSize: 10,
                          color: Colors.black54,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                ],
              ),
            ),
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
                      child: Text(item, style: const TextStyle(fontSize: 13, height: 1.3)),
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
                    const Text('→ ', style: TextStyle(fontSize: 13, color: Colors.green)),
                    Expanded(
                      child: Text(item, style: const TextStyle(fontSize: 13, height: 1.3)),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
