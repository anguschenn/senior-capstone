import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../utils/app_helpers.dart';
import '../common/ui.dart';

class CashFlowTrendSummaryCard extends StatelessWidget {
  const CashFlowTrendSummaryCard({
    super.key,
    required this.summaryText,
    required this.rangeLabel,
    required this.income,
    required this.expenses,
    this.onAskWhy,
  });

  final String summaryText;
  final String rangeLabel;
  final double income;
  final double expenses;

  /// Shows a ✦ "Why?" chip that opens the AI about this trend.
  final VoidCallback? onAskWhy;

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final body = TextStyle(fontSize: 14, height: 1.35, color: c.text);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
      decoration: cardDecoration(context),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Trend Summary',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700),
                ),
              ),
              if (onAskWhy != null) AskChip(label: 'Why?', onTap: onAskWhy!),
            ],
          ),
          const SizedBox(height: 10),
          Text(summaryText, style: body),
          const SizedBox(height: 6),
          Text(
            '• $rangeLabel income: ${formatMoney(income, signed: false)}',
            style: body,
          ),
          const SizedBox(height: 6),
          Text(
            '• $rangeLabel expenses: ${formatMoney(expenses, signed: false)}',
            style: body,
          ),
        ],
      ),
    );
  }
}
