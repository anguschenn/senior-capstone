import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';

// Formats currency using the app's convention: positive spend, negative income.
String formatMoney(double amount, {bool signed = true}) {
  final absAmount = amount.abs().toStringAsFixed(2);
  if (!signed) {
    return '\$$absAmount';
  }
  final isIncome = amount < 0;
  return '${isIncome ? '+' : '-'} \$$absAmount';
}

// Short date formatter shared by transaction, subscription, and budget UIs.
String shortDate(DateTime value, {bool alwaysShowYear = false}) {
  const months = [
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  final now = DateTime.now();
  final showYear = alwaysShowYear || value.year != now.year;
  return showYear
      ? '${months[value.month - 1]} ${value.day}, ${value.year}'
      : '${months[value.month - 1]} ${value.day}';
}

// Keyword-based icon mapping for transaction rows.
IconData iconForTransaction(String category, String merchant) {
  final key = '$category $merchant'.toLowerCase();
  if (key.contains('uber') || key.contains('transport') || key.contains('taxi')) {
    return Icons.directions_car;
  }
  if (key.contains('coffee') || key.contains('starbucks') || key.contains('cafe')) {
    return Icons.local_cafe;
  }
  if (key.contains('subscription') || key.contains('netflix') || key.contains('spotify')) {
    return Icons.subscriptions_outlined;
  }
  if (key.contains('income') || key.contains('payroll') || key.contains('salary')) {
    return Icons.attach_money;
  }
  if (key.contains('food') || key.contains('restaurant')) {
    return Icons.restaurant;
  }
  return Icons.shopping_cart;
}

// Shared color mapping so category-related UI stays visually consistent.
Color colorForDetailedCategory(String detailedCategory) {
  final key = detailedCategory.toLowerCase().trim();
  if (key.contains('food') || key.contains('drink') || key.contains('restaurant')) {
    return Colors.orange;
  }
  if (key.contains('transportation') || key.contains('transport') || key.contains('transit')) {
    return Colors.blue;
  }
  if (key.contains('entertainment') || key.contains('streaming') || key.contains('music')) {
    return Colors.purple;
  }
  if (key.contains('shopping') || key.contains('retail') || key.contains('merchandise')) {
    return Colors.green;
  }
  return Colors.blueGrey;
}

bool isDebtAccountType(String rawAccountType) {
  final accountType = rawAccountType.toLowerCase();
  return accountType.contains('credit') || accountType.contains('loan');
}

double netWorthContribution({
  required double balance,
  required String accountType,
}) {
  return isDebtAccountType(accountType) ? -balance.abs() : balance;
}

IconData iconForBudgetCategory(String category) {
  switch (category) {
    case 'Food':
      return Icons.restaurant;
    case 'Transport':
      return Icons.directions_car;
    case 'Entertainment':
      return Icons.movie;
    case 'Shopping':
      return Icons.shopping_bag;
    case 'Other':
      return Icons.category_outlined;
    default:
      return Icons.category_outlined;
  }
}

// Normalizes category labels so reviewed names and DB labels compare cleanly.
String normalizeCategoryKey(String raw) {
  return raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

// Resolves the masked account ending shown in transaction lists.
String accountEndingForId(String accountId, List<AccountOption> accounts) {
  for (final account in accounts) {
    if (account.accountId == accountId) return account.ending;
  }
  if (accountId.length >= 4) return accountId.substring(accountId.length - 4);
  return '----';
}

// Converts machine-style category keys into user-facing labels.
String prettifyCategoryLabel(String raw) {
  final cleaned = raw.trim();
  if (cleaned.isEmpty) return 'Uncategorized';
  final spaced = cleaned.replaceAll('_', ' ').toLowerCase();
  return spaced
      .split(RegExp(r'\s+'))
      .where((part) => part.isNotEmpty)
      .map((part) => '${part[0].toUpperCase()}${part.substring(1)}')
      .join(' ');
}

// Maps detailed Plaid/Supabase categories into the app's simplified budget buckets.
String budgetCategoryFromPfc({
  required String pfcDetailed,
  required String pfcPrimary,
}) {
  final detailed = pfcDetailed.toLowerCase();
  final primary = pfcPrimary.toLowerCase();
  final key = '$detailed $primary';

  if (key.contains('airline') || key.contains('flight')) {
    return 'Other';
  }
  if (key.contains('food') || key.contains('drink') || key.contains('restaurant')) {
    return 'Food';
  }
  if (key.contains('transportation') || key.contains('transport') || key.contains('transit')) {
    return 'Transport';
  }
  if (key.contains('travel') || key.contains('hotel') || key.contains('gas')) {
    return 'Transport';
  }
  if (key.contains('entertainment') || key.contains('streaming') || key.contains('music')) {
    return 'Entertainment';
  }
  if (key.contains('shopping') || key.contains('retail') || key.contains('merchandise')) {
    return 'Shopping';
  }
  return 'Other';
}

// Bottom sheet used when the user manually re-categorizes a transaction.
Future<void> showTransactionCategoryPicker({
  required BuildContext context,
  required AppTransaction tx,
  required String selectedCategory,
  required void Function(String category) onSelected,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (sheetContext) {
      return SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'Set Category • ${tx.name}',
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: kReviewCategories.map((category) {
                  final isSelected = selectedCategory == category;
                  final tone = colorForDetailedCategory(category);
                  return InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () {
                      onSelected(category);
                      Navigator.of(sheetContext).pop();
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      decoration: BoxDecoration(
                        color: isSelected ? tone.withValues(alpha: 0.16) : Colors.white,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: isSelected ? tone : Colors.black12),
                      ),
                      child: Text(
                        category,
                        style: TextStyle(
                          color: isSelected ? tone : Colors.black87,
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      );
    },
  );
}
