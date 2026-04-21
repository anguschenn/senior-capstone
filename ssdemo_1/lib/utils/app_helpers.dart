import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';

// Re-export formatters so existing imports keep working.
export 'formatters.dart';

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

String accountEndingForId(String accountId, List<AccountOption> accounts) {
  for (final account in accounts) {
    if (account.accountId == accountId || account.linkedAccountIds.contains(accountId)) {
      return account.ending;
    }
  }
  if (accountId.length >= 4) return accountId.substring(accountId.length - 4);
  return '----';
}

String budgetCategoryFromPfc({
  required String pfcDetailed,
  required String pfcPrimary,
}) {
  final detailed = pfcDetailed.toLowerCase();
  final primary = pfcPrimary.toLowerCase();
  final key = '$detailed $primary';

  if (key.contains('airline') || key.contains('flight')) return 'Other';
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
