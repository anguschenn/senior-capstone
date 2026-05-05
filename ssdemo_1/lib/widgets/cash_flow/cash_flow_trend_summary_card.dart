import 'package:flutter/material.dart';

import '../../utils/app_helpers.dart';

class CashFlowTrendSummaryCard extends StatelessWidget {
  const CashFlowTrendSummaryCard({
    super.key,
    required this.summaryText,
    required this.rangeLabel,
    required this.income,
    required this.expenses,
  });

  final String summaryText;
  final String rangeLabel;
  final double income;
  final double expenses;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(16),
        boxShadow: const [
          BoxShadow(color: Colors.black12, blurRadius: 6, offset: Offset(0, 2)),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.trending_up, color: Colors.green),
              SizedBox(width: 8),
              Text(
                'Trend Summary',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(summaryText),
          const SizedBox(height: 6),
          Text('• $rangeLabel income: ${formatMoney(income, signed: false)}'),
          const SizedBox(height: 6),
          Text(
            '• $rangeLabel expenses: ${formatMoney(expenses, signed: false)}',
          ),
        ],
      ),
    );
  }
}
