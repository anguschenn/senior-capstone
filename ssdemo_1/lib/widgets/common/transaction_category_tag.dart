import 'package:flutter/material.dart';

import '../../app/app_theme.dart';
import '../../utils/app_helpers.dart';

class TransactionCategoryTag extends StatelessWidget {
  const TransactionCategoryTag({super.key, required this.label, this.colorKey});

  final String label;
  final String? colorKey;

  @override
  Widget build(BuildContext context) {
    final tone = colorForDetailedCategory(colorKey ?? label);
    final c = context.colors;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: c.raised,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 7,
            height: 7,
            decoration: BoxDecoration(color: tone, shape: BoxShape.circle),
          ),
          const SizedBox(width: 5),
          Text(
            label,
            style: TextStyle(
              color: c.text,
              fontSize: 12,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
