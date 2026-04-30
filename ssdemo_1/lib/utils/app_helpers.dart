import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';

// Re-export formatters so existing imports keep working.
export 'formatters.dart';

IconData iconForTransaction(String category, String merchant) {
  final key = '$category $merchant'.toLowerCase();
  if (key.contains('uber') ||
      key.contains('transport') ||
      key.contains('taxi')) {
    return Icons.directions_car;
  }
  if (key.contains('coffee') ||
      key.contains('starbucks') ||
      key.contains('cafe')) {
    return Icons.local_cafe;
  }
  if (key.contains('subscription') ||
      key.contains('netflix') ||
      key.contains('spotify')) {
    return Icons.subscriptions_outlined;
  }
  if (key.contains('income') ||
      key.contains('payroll') ||
      key.contains('salary')) {
    return Icons.attach_money;
  }
  if (key.contains('food') || key.contains('restaurant')) {
    return Icons.restaurant;
  }
  return Icons.shopping_cart;
}

Color colorForDetailedCategory(String detailedCategory) {
  final key = detailedCategory.toLowerCase().trim();
  if (key.contains('food') ||
      key.contains('drink') ||
      key.contains('restaurant')) {
    return Colors.orange;
  }
  if (key.contains('transportation') ||
      key.contains('transport') ||
      key.contains('transit')) {
    return Colors.blue;
  }
  if (key.contains('entertainment') ||
      key.contains('streaming') ||
      key.contains('music')) {
    return Colors.purple;
  }
  if (key.contains('shopping') ||
      key.contains('retail') ||
      key.contains('merchandise')) {
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
    case 'Shopping':
      return Icons.shopping_bag;
    case 'Transport':
      return Icons.directions_car;
    case 'Bills & Utilities':
      return Icons.receipt_long;
    case 'Housing':
      return Icons.home_work_outlined;
    case 'Health':
      return Icons.local_hospital_outlined;
    case 'Entertainment':
      return Icons.movie;
    case 'Subscriptions':
      return Icons.subscriptions_outlined;
    case 'Fees & Transfers':
      return Icons.swap_horiz;
    case 'Cash / ATM':
      return Icons.atm_outlined;
    case 'Other':
      return Icons.category_outlined;
    default:
      return Icons.category_outlined;
  }
}

String accountEndingForId(String accountId, List<AccountOption> accounts) {
  for (final account in accounts) {
    if (account.accountId == accountId ||
        account.linkedAccountIds.contains(accountId)) {
      return account.ending;
    }
  }
  if (accountId.length >= 4) return accountId.substring(accountId.length - 4);
  return '----';
}

DateTime allYearOptionFor(int year) => DateTime(year, 1, 2);

bool isAllYearOption(DateTime value) => value.month == 1 && value.day == 2;

DateTime normalizedMonthOption(DateTime value) {
  if (isAllYearOption(value)) return allYearOptionFor(value.year);
  return DateTime(value.year, value.month, 1);
}

String monthOptionLabel(DateTime value) {
  if (isAllYearOption(value)) return '${value.year} All Year';
  return '${kMonthShortLabels[value.month - 1]} ${value.year}';
}

String periodLabelForSelection(DateTime value) {
  if (isAllYearOption(value)) return '${value.year}';
  return monthOptionLabel(value);
}

bool transactionInSelectedPeriod(AppTransaction tx, DateTime selection) {
  if (isAllYearOption(selection)) return tx.date.year == selection.year;
  return tx.date.year == selection.year && tx.date.month == selection.month;
}

String budgetCategoryFromPfc({
  required String pfcDetailed,
  required String pfcPrimary,
}) {
  final detailed = pfcDetailed.toLowerCase();
  final primary = pfcPrimary.toLowerCase();
  final key = '$detailed $primary';
  final isCardPayment =
      key.contains('card_payment') || key.contains('card payment');

  if (key.contains('atm') ||
      key.contains('withdrawal') ||
      key.contains('cash')) {
    return 'Cash / ATM';
  }
  if (key.contains('utility') ||
      key.contains('utilities') ||
      key.contains('water') ||
      key.contains('electric') ||
      key.contains('gas bill') ||
      key.contains('phone') ||
      key.contains('internet')) {
    return 'Bills & Utilities';
  }
  if (key.contains('rent') ||
      key.contains('mortgage') ||
      key.contains('housing') ||
      key.contains('property')) {
    return 'Housing';
  }
  if (key.contains('health') ||
      key.contains('medical') ||
      key.contains('pharmacy') ||
      key.contains('clinic') ||
      key.contains('doctor') ||
      key.contains('dental')) {
    return 'Health';
  }
  if (key.contains('software') ||
      key.contains('subscription') ||
      key.contains('streaming') ||
      key.contains('saas') ||
      key.contains('cloud')) {
    return 'Subscriptions';
  }
  if (key.contains('food') ||
      key.contains('drink') ||
      key.contains('restaurant')) {
    return 'Food';
  }
  if (key.contains('transportation') ||
      key.contains('transport') ||
      key.contains('transit')) {
    return 'Transport';
  }
  if (key.contains('travel') || key.contains('hotel') || key.contains('gas')) {
    return 'Transport';
  }
  if (key.contains('entertainment') ||
      key.contains('music') ||
      key.contains('movie') ||
      key.contains('game')) {
    return 'Entertainment';
  }
  if (key.contains('grocery') || key.contains('groceries')) {
    return 'Food';
  }
  if (key.contains('shopping') ||
      key.contains('retail') ||
      key.contains('merchandise') ||
      key.contains('electronics')) {
    return 'Shopping';
  }
  if (key.contains('transfer') ||
      key.contains('wire') ||
      key.contains('ach') ||
      key.contains('bill_payment') ||
      key.contains('bill payment') ||
      key.contains('fee') ||
      key.contains('insufficient funds') ||
      key.contains('overdraft') ||
      (key.contains('payment') && !isCardPayment) ||
      (key.contains('charge') && !isCardPayment)) {
    return 'Fees & Transfers';
  }
  if (key.contains('airline') || key.contains('flight')) return 'Transport';
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
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? tone.withValues(alpha: 0.16)
                            : Colors.white,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: isSelected ? tone : Colors.black12,
                        ),
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
