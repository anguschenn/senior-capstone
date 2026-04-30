import 'package:flutter/material.dart';

import '../../utils/app_helpers.dart';

class TransactionCategoryTag extends StatelessWidget {
  const TransactionCategoryTag({super.key, required this.label, this.colorKey});

  final String label;
  final String? colorKey;

  @override
  Widget build(BuildContext context) {
    final tone = colorForDetailedCategory(colorKey ?? label);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: tone.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: tone.withValues(alpha: 0.3)),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: tone,
          fontSize: 12,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
