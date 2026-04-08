import 'package:flutter/material.dart';

import '../utils/app_helpers.dart';

// Normalized transaction model used by the UI after reading raw Supabase rows.
class AppTransaction {
  const AppTransaction({
    required this.dedupeKey,
    required this.id,
    required this.accountId,
    required this.name,
    required this.category,
    required this.primaryCategory,
    required this.date,
    required this.amount,
    required this.pending,
    required this.confidence,
  });

  final String dedupeKey;
  final String id;
  final String accountId;
  final String name;
  final String category;
  final String primaryCategory;
  final DateTime date;
  final double amount;
  final bool pending;
  final String confidence;

  factory AppTransaction.fromMap(Map<String, dynamic> row) {
    final merchant = (row['merchant_name'] as String?)?.trim();
    final fallbackName = (row['name'] as String?)?.trim();
    final name = (merchant?.isNotEmpty ?? false)
        ? merchant!
        : ((fallbackName?.isNotEmpty ?? false) ? fallbackName! : 'Unknown');
    final rawDetailedCategory = (row['pfc_detailed'] as String?)?.trim();
    final rawCategory = (row['pfc_primary'] as String?)?.trim();
    final legacyCategory = (row['category'] as String?)?.trim();
    final category = (rawDetailedCategory?.isNotEmpty ?? false)
        ? prettifyCategoryLabel(rawDetailedCategory!)
        : ((rawCategory?.isNotEmpty ?? false)
              ? prettifyCategoryLabel(rawCategory!)
              : ((legacyCategory?.isNotEmpty ?? false)
                    ? prettifyCategoryLabel(legacyCategory!)
                    : 'Uncategorized'));
    final primaryCategory = (rawCategory?.isNotEmpty ?? false)
        ? prettifyCategoryLabel(rawCategory!)
        : ((legacyCategory?.isNotEmpty ?? false)
              ? prettifyCategoryLabel(legacyCategory!)
              : 'Uncategorized');
    final rawDate = (row['date'] as String?) ?? DateTime.now().toIso8601String();
    final date = DateTime.tryParse(rawDate) ?? DateTime.now();
    final amountRaw = row['amount'];
    final parsedAmount = amountRaw is num
        ? amountRaw.toDouble()
        : double.tryParse('$amountRaw') ?? 0;
    final amount = parsedAmount;
    final plaidId = (row['plaid_transaction_id'] as String?)?.trim() ?? '';
    final accountId = (row['plaid_account_id'] as String?)?.trim() ?? '';
    final confidence = ((row['pfc_confidence'] as String?) ?? '').trim().toLowerCase();
    final dedupeKey = plaidId.isNotEmpty
        ? plaidId
        : '${name.toLowerCase()}|${amount.toStringAsFixed(2)}|${date.toIso8601String().split("T").first}';
    return AppTransaction(
      dedupeKey: dedupeKey,
      id: plaidId.isNotEmpty ? plaidId : dedupeKey,
      accountId: accountId,
      name: name,
      category: category,
      primaryCategory: primaryCategory,
      date: date,
      amount: amount,
      pending: (row['pending'] as bool?) ?? false,
      confidence: confidence,
    );
  }
}

// Lightweight subscription model shown in dashboard and subscription views.
class DetectedSubscription {
  const DetectedSubscription({
    required this.merchant,
    required this.amount,
    required this.nextChargeDate,
    required this.frequency,
  });

  final String merchant;
  final double amount;
  final DateTime nextChargeDate;
  final String frequency;
}

// Aggregated summary metrics shown across multiple pages.
class DashboardStats {
  const DashboardStats({
    required this.totalBalance,
    required this.monthlyIncome,
    required this.monthlyExpenses,
    required this.netThisMonth,
  });

  final double totalBalance;
  final double monthlyIncome;
  final double monthlyExpenses;
  final double netThisMonth;
}

// Single chart point for income/expense visualizations.
class MonthlyFlowPoint {
  const MonthlyFlowPoint({
    required this.label,
    required this.income,
    required this.expenses,
  });

  final String label;
  final double income;
  final double expenses;

  double get net => income - expenses;
}

enum FlowViewMode { month, year, all }

enum ActivityViewMode { month, year, all }

// Computed budget usage for one category and one time scope.
class BudgetCategoryProgress {
  const BudgetCategoryProgress({
    required this.budgetId,
    required this.categoryId,
    required this.title,
    required this.spent,
    required this.limit,
  });

  final String budgetId;
  final String categoryId;
  final String title;
  final double spent;
  final double limit;

  double get ratio => limit <= 0 ? 0 : (spent / limit).clamp(0, 1.5);
  bool get isWarning => ratio >= 0.8;
}

// Category option loaded from Supabase and reused by budget flows.
class CategoryOption {
  const CategoryOption({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;
}

// Account metadata used for filters and transaction labels.
class AccountOption {
  const AccountOption({
    required this.accountId,
    required this.label,
    required this.ending,
    required this.balance,
    required this.txCount,
  });

  final String accountId;
  final String label;
  final String ending;
  final double balance;
  final int txCount;
}

// Reusable pill tag used to show or edit a transaction category.
class TransactionCategoryTag extends StatelessWidget {
  const TransactionCategoryTag({
    super.key,
    required this.label,
    this.colorKey,
  });

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
