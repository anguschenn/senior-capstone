import 'package:flutter/material.dart';

import '../../utils/app_helpers.dart';

class CashFlowTotalsCard extends StatelessWidget {
  const CashFlowTotalsCard({
    super.key,
    required this.income,
    required this.expenses,
    required this.net,
  });

  final double income;
  final double expenses;
  final double net;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Income',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(formatMoney(income, signed: false)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Expenses',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
              Text(formatMoney(expenses, signed: false)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text('Net', style: TextStyle(fontWeight: FontWeight.bold)),
              Text('${net >= 0 ? '+' : '-'} \$${net.abs().toStringAsFixed(2)}'),
            ],
          ),
        ],
      ),
    );
  }
}
