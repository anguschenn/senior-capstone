import '../utils/app_helpers.dart';

// Normalized transaction model used by the UI after reading raw Supabase rows.
class AppTransaction {
  const AppTransaction({
    required this.dedupeKey,
    required this.id,
    required this.accountId,
    required this.accountName,
    required this.name,
    required this.description,
    required this.transactionType,
    required this.category,
    required this.primaryCategory,
    required this.date,
    required this.amount,
    required this.accountType,
    required this.accountSubtype,
    required this.pending,
    required this.confidence,
    required this.userId,
    required this.rawMerchantName,
    required this.rawPfcPrimary,
    required this.rawPfcDetailed,
  });

  final String dedupeKey;
  final String id;
  final String accountId;
  final String accountName;
  final String name;
  final String description;
  final String transactionType;
  final String category;
  final String primaryCategory;
  final DateTime date;
  final double amount;
  final String accountType;
  final String accountSubtype;
  final bool pending;
  final String confidence;
  final String userId;
  final String rawMerchantName;
  final String rawPfcPrimary;
  final String rawPfcDetailed;

  bool get usesCheckingSavingsPolarity => usesDepositoryPolarity(
    accountName: accountName,
    accountType: accountType,
    accountSubtype: accountSubtype,
  );

  bool get isDepositoryAccount =>
      accountType.toLowerCase().trim() == 'depository';

  bool get isExpense =>
      amount != 0 &&
      (isDepositoryAccount
          ? amount > 0
          : _isExpenseByFallback(
              amount: amount,
              pfcDetailed: category,
              pfcPrimary: primaryCategory,
              usesCheckingSavingsPolarity: usesCheckingSavingsPolarity,
            ));

  bool get isInflow => amount != 0 && !isExpense;

  bool get isIncome =>
      amount != 0 &&
      (isDepositoryAccount
          ? amount < 0
          : (_directionByPfc(
                      pfcDetailed: category,
                      pfcPrimary: primaryCategory,
                    ) ==
                    _TxDirection.income ||
                (isInflow &&
                    isDepositIncomeSignal(
                      transactionType: transactionType,
                      category: category,
                      primaryCategory: primaryCategory,
                      name: name,
                      description: description,
                    ))));

  bool get isRefundIncome => isIncome && _isRefundLike();

  String get incomeType =>
      !isIncome ? '' : (isRefundIncome ? 'refund' : 'other_income');

  bool get isNonIncomeInflow => isInflow && !isIncome;

  double get displayAmount => amount.abs();

  double get expenseAmount => isExpense ? displayAmount : 0;

  double get incomeAmount => isIncome ? displayAmount : 0;

  double get nonIncomeInflowAmount => isNonIncomeInflow ? displayAmount : 0;

  factory AppTransaction.fromMap(Map<String, dynamic> row) {
    final merchant = (row['merchant_name'] as String?)?.trim();
    final fallbackName = (row['name'] as String?)?.trim();
    final description = (row['name'] as String?)?.trim();
    final name = (merchant?.isNotEmpty ?? false)
        ? merchant!
        : ((fallbackName?.isNotEmpty ?? false)
              ? fallbackName!
              : ((description?.isNotEmpty ?? false)
                    ? description!
                    : 'Unknown'));
    final rawDetailedCategory =
        ((row['pfc_detailed'] as String?) ?? (row['category'] as String?))
            ?.trim();
    final rawCategory = (row['pfc_primary'] as String?)?.trim();
    final transactionType = (row['pfc_primary'] as String?)?.trim();
    final category = (rawDetailedCategory?.isNotEmpty ?? false)
        ? prettifyCategoryLabel(rawDetailedCategory!)
        : ((rawCategory?.isNotEmpty ?? false)
              ? prettifyCategoryLabel(rawCategory!)
              : ((transactionType?.isNotEmpty ?? false)
                    ? prettifyCategoryLabel(transactionType!)
                    : 'Uncategorized'));
    final primaryCategory = (rawCategory?.isNotEmpty ?? false)
        ? prettifyCategoryLabel(rawCategory!)
        : ((transactionType?.isNotEmpty ?? false)
              ? prettifyCategoryLabel(transactionType!)
              : 'Uncategorized');
    final rawDate =
        (row['date'] as String?) ?? DateTime.now().toIso8601String();
    final date = DateTime.tryParse(rawDate) ?? DateTime.now();
    final amountRaw = row['amount'];
    final parsedAmount = amountRaw is num
        ? amountRaw.toDouble()
        : double.tryParse('$amountRaw') ?? 0;
    final amount = parsedAmount;
    final externalTransactionId =
        ((row['plaid_transaction_id'] as String?) ?? '').trim();
    final providerId = externalTransactionId;
    final externalAccountId = ((row['plaid_account_id'] as String?) ?? '')
        .trim();
    final accountId = externalAccountId;
    final accountName = ((row['account_name'] as String?) ?? '').trim();
    final accountType = ((row['account_type'] as String?) ?? '').trim();
    final accountSubtype = ((row['subtype'] as String?) ?? '').trim();
    final confidence = ((row['pfc_confidence'] as String?) ?? 'medium')
        .trim()
        .toLowerCase();
    final userId = ((row['user_id'] as String?) ?? '').trim();
    final dedupeKey = providerId.isNotEmpty
        ? providerId
        : '${name.toLowerCase()}|${amount.toStringAsFixed(2)}|${date.toIso8601String().split("T").first}';
    return AppTransaction(
      dedupeKey: dedupeKey,
      id: providerId.isNotEmpty ? providerId : dedupeKey,
      accountId: accountId,
      accountName: accountName,
      name: name,
      description: description ?? '',
      transactionType: transactionType ?? '',
      category: category,
      primaryCategory: primaryCategory,
      date: date,
      amount: amount,
      accountType: accountType,
      accountSubtype: accountSubtype,
      pending: ((row['pending'] as bool?) ?? false),
      confidence: confidence,
      userId: userId,
      rawMerchantName: merchant ?? '',
      rawPfcPrimary: rawCategory ?? '',
      rawPfcDetailed: rawDetailedCategory ?? '',
    );
  }

  static bool usesDepositoryPolarity({
    required String accountName,
    required String accountType,
    required String accountSubtype,
  }) {
    final type = accountType.toLowerCase().trim();
    final subtype = accountSubtype.toLowerCase().trim();
    if (type == 'depository') return true;
    if (type == 'credit' || type == 'loan') return false;
    if (subtype == 'checking' || subtype == 'savings') return true;
    if (subtype.contains('credit')) return false;
    final key = accountName.toLowerCase();
    if (key.contains('checking') || key.contains('saving')) return true;
    if (key.contains('credit')) return false;
    return false;
  }

  static bool isDepositIncomeSignal({
    required String transactionType,
    required String category,
    required String primaryCategory,
    required String name,
    required String description,
  }) {
    final desc = description.toLowerCase().replaceAll('_', ' ');
    return RegExp(r'\bdeposit\b', caseSensitive: false).hasMatch(desc);
  }

  static bool isExpenseByPfc({
    required String pfcDetailed,
    required String pfcPrimary,
  }) =>
      _directionByPfc(pfcDetailed: pfcDetailed, pfcPrimary: pfcPrimary) ==
      _TxDirection.expense;

  static bool isIncomeByPfc({
    required String pfcDetailed,
    required String pfcPrimary,
  }) =>
      _directionByPfc(pfcDetailed: pfcDetailed, pfcPrimary: pfcPrimary) ==
      _TxDirection.income;

  static bool isKnownByPfc({
    required String pfcDetailed,
    required String pfcPrimary,
  }) =>
      _directionByPfc(pfcDetailed: pfcDetailed, pfcPrimary: pfcPrimary) !=
      _TxDirection.unknown;

  static bool _isExpenseByFallback({
    required double amount,
    required String pfcDetailed,
    required String pfcPrimary,
    required bool usesCheckingSavingsPolarity,
  }) {
    final byPfc = _directionByPfc(
      pfcDetailed: pfcDetailed,
      pfcPrimary: pfcPrimary,
    );
    if (byPfc == _TxDirection.expense) return true;
    if (byPfc == _TxDirection.income) return false;
    return usesCheckingSavingsPolarity ? amount < 0 : amount > 0;
  }

  bool _isRefundLike() {
    final text =
        '${name.toLowerCase()} ${description.toLowerCase()} '
        '${category.toLowerCase()} ${primaryCategory.toLowerCase()}';
    return text.contains('refund') ||
        text.contains('reversal') ||
        text.contains('returned') ||
        text.contains('return');
  }

  static _TxDirection _directionByPfc({
    required String pfcDetailed,
    required String pfcPrimary,
  }) {
    final detailed = pfcDetailed.toUpperCase().trim();
    final primary = pfcPrimary.toUpperCase().trim();
    final key = '$detailed $primary';
    if (key.contains('INCOME')) return _TxDirection.income;
    if (key.contains('FOOD_AND_DRINK')) return _TxDirection.expense;
    if (key.contains('TRANSPORTATION')) return _TxDirection.expense;
    if (key.contains('TRAVEL')) return _TxDirection.expense;
    if (key.contains('ENTERTAINMENT')) return _TxDirection.expense;
    if (key.contains('TRANSFER_OUT')) return _TxDirection.expense;
    return _TxDirection.unknown;
  }
}

enum _TxDirection { income, expense, unknown }

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

  double get cashFlowNetThisMonth => netThisMonth;
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

  double get cashFlowNet => income - expenses;
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
  const CategoryOption({required this.id, required this.name});

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
    required this.linkedAccountIds,
  });

  final String accountId;
  final String label;
  final String ending;
  final double balance;
  final int txCount;
  final List<String> linkedAccountIds;
}
