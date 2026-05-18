import 'package:flutter/material.dart';

import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../services/ai_api_client.dart';

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
  Uri? aiBackendUri,
  String? apiKey,
  String? accessToken,
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
                children: [
                  ...kReviewCategories.map((category) {
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
                  if (aiBackendUri != null && apiKey != null)
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: () async {
                        Navigator.of(sheetContext).pop();
                        await _askAiForCategory(
                          context: context,
                          tx: tx,
                          aiBackendUri: aiBackendUri,
                          apiKey: apiKey,
                          accessToken: accessToken,
                          onSelected: onSelected,
                        );
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.white,
                          borderRadius: BorderRadius.circular(999),
                          border: Border.all(
                            color: Colors.purple,
                            width: 1.5,
                          ),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.auto_awesome, size: 14, color: Colors.purple),
                            SizedBox(width: 4),
                            Text(
                              'Ask AI',
                              style: TextStyle(
                                color: Colors.purple,
                                fontWeight: FontWeight.w600,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  InkWell(
                    borderRadius: BorderRadius.circular(999),
                    onTap: () {
                      Navigator.of(sheetContext).pop();
                      _showCustomCategoryDialog(
                        context: context,
                        onCustomCategoryEntered: onSelected,
                      );
                    },
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(
                          color: Colors.green,
                          width: 1.5,
                        ),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.add, size: 14, color: Colors.green),
                          SizedBox(width: 4),
                          Text(
                            'Custom',
                            style: TextStyle(
                              color: Colors.green,
                              fontWeight: FontWeight.w600,
                              fontSize: 12,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      );
    },
  );
}

Future<void> _askAiForCategory({
  required BuildContext context,
  required AppTransaction tx,
  required Uri aiBackendUri,
  required String apiKey,
  String? accessToken,
  required void Function(String category) onSelected,
}) async {
  try {
    // Show loading indicator
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => const AlertDialog(
        content: SizedBox(
          width: 200,
          height: 80,
          child: Center(
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                CircularProgressIndicator(),
                SizedBox(height: 16),
                Text('Asking AI...'),
              ],
            ),
          ),
        ),
      ),
    );

    // Fetch suggestion
    final suggestion = await AiApiClient().suggestCategory(
      uri: aiBackendUri,
      apiKey: apiKey,
      accessToken: accessToken,
      merchantName: tx.rawMerchantName.isNotEmpty
          ? tx.rawMerchantName
          : tx.name,
      transactionName: tx.name,
      pfcPrimary: tx.rawPfcPrimary,
      pfcDetailed: tx.category,
    );

    // Close loading dialog
    Navigator.of(context).pop();

    if (suggestion.suggestedCategory.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not generate category suggestion'),
        ),
      );
      return;
    }

    // Show approval dialog
    String? selectedCategory;
    await showAiCategorySuggestionDialog(
      context: context,
      suggestedCategory: suggestion.suggestedCategory,
      transactionName: tx.name,
      onAccept: (category) {
        selectedCategory = category;
      },
    );

    if (selectedCategory != null && selectedCategory!.isNotEmpty) {
      onSelected(selectedCategory!);
    }
  } catch (e) {
    Navigator.of(context).pop(); // Close loading dialog if still open
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('AI error: ${e.toString()}'),
      ),
    );
  }
}

Future<void> _showCustomCategoryDialog({
  required BuildContext context,
  required void Function(String category) onCustomCategoryEntered,
}) async {
  final controller = TextEditingController();
  
  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return AlertDialog(
        title: const Text('Create Custom Category'),
        content: TextField(
          controller: controller,
          decoration: const InputDecoration(
            hintText: 'Enter category name',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () {
              final categoryName = controller.text.trim();
              if (categoryName.isNotEmpty) {
                Navigator.of(dialogContext).pop();
                onCustomCategoryEntered(categoryName);
              }
            },
            child: const Text('Create'),
          ),
        ],
      );
    },
  );
  controller.dispose();
}

Future<void> showAiCategorySuggestionDialog({
  required BuildContext context,
  required String suggestedCategory,
  required String transactionName,
  required void Function(String category) onAccept,
}) async {
  final editController = TextEditingController(text: suggestedCategory);
  bool isEditingCategory = false;

  await showDialog<void>(
    context: context,
    builder: (dialogContext) {
      return StatefulBuilder(
        builder: (context, setState) {
          return AlertDialog(
            title: const Text('AI Suggested Category'),
            content: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'For: $transactionName',
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
                const SizedBox(height: 16),
                if (!isEditingCategory)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'Suggested:',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 8,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.blue.withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: Colors.blue),
                        ),
                        child: Text(
                          suggestedCategory,
                          style: const TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w600,
                            color: Colors.blue,
                          ),
                        ),
                      ),
                    ],
                  )
                else
                  TextField(
                    controller: editController,
                    decoration: const InputDecoration(
                      hintText: 'Edit category name',
                      border: OutlineInputBorder(),
                    ),
                    autofocus: true,
                  ),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => setState(() => isEditingCategory = !isEditingCategory),
                child: Text(isEditingCategory ? 'Cancel Edit' : 'Edit'),
              ),
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: const Text('Reject'),
              ),
              TextButton(
                onPressed: () {
                  final categoryToUse = isEditingCategory
                      ? editController.text.trim()
                      : suggestedCategory;
                  if (categoryToUse.isNotEmpty) {
                    Navigator.of(dialogContext).pop();
                    onAccept(categoryToUse);
                  }
                },
                child: const Text('Accept'),
              ),
            ],
          );
        },
      );
    },
  );
  editController.dispose();
}

