import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
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
    final c = context.colors;
    Widget line(String label, String value, {Color? color, bool bold = false}) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                fontSize: 15,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
              ),
            ),
            Text(
              value,
              style: TextStyle(
                fontSize: 15,
                fontWeight: bold ? FontWeight.w700 : FontWeight.w500,
                color: color ?? c.text,
              ),
            ),
          ],
        ),
      );
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: BorderRadius.circular(14),
      ),
      child: Column(
        children: [
          line('Income', formatMoney(income, signed: false)),
          line('Expenses', formatMoney(expenses, signed: false)),
          Divider(height: 10, thickness: 0.5, color: c.line),
          line(
            'Net',
            '${net >= 0 ? '+' : '-'} \$${net.abs().toStringAsFixed(2)}',
            color: net >= 0 ? c.good : c.bad,
            bold: true,
          ),
        ],
      ),
    );
  }
}
