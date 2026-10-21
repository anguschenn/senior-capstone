import '../constants/app_constants.dart';
import '../utils/app_helpers.dart';

/// How a transaction counts in spending and income totals.
enum TxKind {
  /// Money spent: counts in its category's spending.
  spend,

  /// Money back for a purchase: lowers its category's spending.
  refund,

  /// Money earned or received from someone else.
  income,

  /// Money moving between the user's own accounts (savings transfers, card
  /// payments): shown in the list but never counted.
  internal,

  none,
}

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

  bool get isExpense => amount != 0 && amount > 0;

  bool get isInflow => amount != 0 && !isExpense;

  bool get isIncome => amount != 0 && amount < 0;

  bool get isRefundIncome => isIncome && _isRefundLike();

  String get incomeType =>
      !isIncome ? '' : (isRefundIncome ? 'refund' : 'other_income');

  bool get isNonIncomeInflow => isInflow && !isIncome;

  double get displayAmount => amount.abs();

  bool get isCreditCardPayment => isCreditCardPaymentByPfc(
    pfcDetailed: rawPfcDetailed,
    pfcPrimary: rawPfcPrimary,
  );

  /// Kinds for the loaded transactions, set by [classifyTransactions] so
  /// remembered rules and refund matching apply. Ids missing here fall back to
  /// [ownKind].
  static Map<String, TxKind> kindById = const {};

  TxKind get kind => kindById[id] ?? ownKind();

  /// Spending contributed by this transaction: negative for a refund, so it
  /// nets against its category. Transfers between the user's own accounts
  /// (a card payment, a savings transfer) count as nothing:
  /// the purchases already count when they happen.
  double get expenseAmount => switch (kind) {
    TxKind.spend => displayAmount,
    TxKind.refund => -displayAmount,
    _ => 0,
  };

  /// The kind from this transaction alone. [userCategory] is a category the
  /// user picked or remembered: Internal Transfer stops it counting, Income
  /// counts money in as income, a spending category counts money in as a
  /// refund of that category.
  TxKind ownKind({String userCategory = ''}) {
    if (amount == 0) return TxKind.none;
    if (userCategory == kInternalTransfer) return TxKind.internal;
    // Any other pick counts it. Fees & Transfers is the old catch-all for
    // payments and transfers, so it leaves the decision to the rules below.
    if (userCategory.isNotEmpty && userCategory != 'Fees & Transfers') {
      if (isExpense) return TxKind.spend;
      return userCategory == 'Income' ? TxKind.income : TxKind.refund;
    }
    if (isCreditCardPayment || isCardPaymentCredit) return TxKind.internal;
    if (isOwnAccountTransferBySignals(
      name: name,
      description: description,
      pfcDetailed: rawPfcDetailed,
    )) {
      return TxKind.internal;
    }
    if (isExpense) return TxKind.spend;
    if (_isRefundLike() || isSpendingPfc(rawPfcPrimary)) return TxKind.refund;
    return TxKind.income;
  }

  /// Money moved to or from one of the user's own accounts. Person-to-person
  /// apps (Zelle, Venmo...) are real payments, so they still count. Cash isn't
  /// tracked, so a withdrawal counts as spending and a cash deposit as income.
  /// The user can mark any of them as Internal Transfer.
  static bool isOwnAccountTransferBySignals({
    required String name,
    required String description,
    required String pfcDetailed,
  }) {
    final text = '$name $description'.toLowerCase();
    if (isPeerToPeer(text)) return false;
    final detailed = pfcDetailed.toUpperCase();
    if (_ownTransferPfc.any(detailed.contains)) return true;
    // Banks shorten it: "GOLDMAN SACHS BA TRANS", "ONLINE XFER TO SAV".
    return RegExp(r'\b(transfer|trans|xfer|trnsfr)\b').hasMatch(text);
  }

  static bool isPeerToPeer(String text) =>
      _peerToPeerWords.any(text.toLowerCase().contains);

  static const _peerToPeerWords = [
    'zelle',
    'venmo',
    'paypal',
    'cash app',
    'apple cash',
  ];

  static const _ownTransferPfc = [
    'TRANSFER_IN_ACCOUNT_TRANSFER',
    'TRANSFER_OUT_ACCOUNT_TRANSFER',
    'TRANSFER_IN_SAVINGS',
    'TRANSFER_OUT_SAVINGS',
    'TRANSFER_IN_INVESTMENT_AND_RETIREMENT_FUNDS',
    'TRANSFER_OUT_INVESTMENT_AND_RETIREMENT_FUNDS',
  ];

  /// Plaid groups that are things you buy: money back in one is a refund.
  static bool isSpendingPfc(String pfcPrimary) => const {
    'FOOD_AND_DRINK',
    'GENERAL_MERCHANDISE',
    'GENERAL_SERVICES',
    'ENTERTAINMENT',
    'TRAVEL',
    'TRANSPORTATION',
    'PERSONAL_CARE',
    'HOME_IMPROVEMENT',
    'MEDICAL',
    'RENT_AND_UTILITIES',
    'BANK_FEES',
  }.contains(pfcPrimary.toUpperCase().trim());

  /// The card side of paying off a credit card ("Payment Thank You"): money
  /// moving between the user's own accounts, so it isn't income. Refunds on
  /// the card still count.
  bool get isCardPaymentCredit {
    if (!isIncome) return false;
    if (isCreditCardPayment) return true;
    final text = '${name.toLowerCase()} ${description.toLowerCase()}';
    final type = accountType.toLowerCase().trim();
    if (type.isEmpty) return text.contains('payment thank you');
    if (type != 'credit' || isRefundIncome) return false;
    final pfc = '$rawPfcPrimary $rawPfcDetailed'.toUpperCase();
    return pfc.contains('LOAN_DISBURSEMENTS') ||
        pfc.contains('LOAN_PAYMENTS') ||
        pfc.contains('TRANSFER_IN') ||
        text.contains('payment') ||
        text.contains('autopay');
  }

  double get incomeAmount => kind == TxKind.income ? displayAmount : 0;

  /// Money paid onto a credit card, seen from the card's side.
  double get cardPaymentAmount => isCardPaymentCredit ? displayAmount : 0;

  /// Label for money coming in that has no category of its own.
  String get inflowLabel =>
      kind == TxKind.internal ? kInternalTransfer : 'Income';

  double get nonIncomeInflowAmount => isNonIncomeInflow ? displayAmount : 0;

  factory AppTransaction.fromMap(Map<String, dynamic> row) {
    final merchant = (row['merchant_name'] as String?)?.trim();
    final fallbackName = (row['name'] as String?)?.trim();
    final description = (row['name'] as String?)?.trim();
    final name = (fallbackName?.isNotEmpty ?? false)
        ? fallbackName!
        : ((merchant?.isNotEmpty ?? false)
              ? merchant!
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
      rawMerchantName: (fallbackName?.isNotEmpty ?? false)
          ? fallbackName!
          : (merchant ?? ''),
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
    if (type == 'credit' || type == 'loan') return true;
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

  /// Plaid labels the checking-side payment LOAN_PAYMENTS_CREDIT_CARD_PAYMENT.
  /// (The card side arrives as a negative amount, so it is never an expense.)
  static bool isCreditCardPaymentByPfc({
    required String pfcDetailed,
    required String pfcPrimary,
  }) =>
      '$pfcDetailed $pfcPrimary'.toUpperCase().contains('CREDIT_CARD_PAYMENT');

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
    required this.id,
    required this.merchant,
    required this.amount,
    required this.nextChargeDate,
    required this.frequency,
    this.needsConfirmation = false,
  });

  final String id;
  final String merchant;
  final double amount;
  final DateTime nextChargeDate;
  final String frequency;
  final bool needsConfirmation;

  double get monthlyEquivalent {
    switch (frequency) {
      case 'weekly':
        return amount * 52 / 12;
      case 'annual':
        return amount / 12;
      default:
        return amount;
    }
  }

  DateTime get effectiveNextChargeDate {
    final interval = switch (frequency) {
      'weekly' => const Duration(days: 7),
      'annual' => const Duration(days: 365),
      _ => const Duration(days: 30),
    };
    var date = nextChargeDate;
    final today = DateTime.now();
    while (date.isBefore(today)) {
      date = date.add(interval);
    }
    return date;
  }
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
    this.paceApplies = true,
    this.budgetedMonths,
  });

  final String budgetId;
  final String categoryId;
  final String title;
  final double spent;
  final double limit;

  /// Whether [spent] is the current month so far, so a month-end pace means
  /// something. False for a finished month, a year or all time: there is
  /// nothing left to project, only over or under the limit.
  final bool paceApplies;

  /// Year view only: the months (1-12) whose limits make up [limit]. Spending
  /// counts for those months alone, so a month with no budget can't put the
  /// year over. Null or empty: the whole year.
  final Set<int>? budgetedMonths;

  /// The same figures with no month-end projection.
  BudgetCategoryProgress withoutPace() => BudgetCategoryProgress(
    budgetId: budgetId,
    categoryId: categoryId,
    title: title,
    spent: spent,
    limit: limit,
    paceApplies: false,
    budgetedMonths: budgetedMonths,
  );

  double get ratio {
    if (limit <= 0 || !spent.isFinite || !limit.isFinite) return 0;
    final value = spent / limit;
    if (!value.isFinite) return 0;
    return value.clamp(0, 1.5);
  }

  /// Share of the limit spent, unclamped (for "137% used" labels; [ratio] is
  /// capped for progress bars).
  double get usedRatio {
    if (limit <= 0 || !spent.isFinite || !limit.isFinite) return 0;
    final value = spent / limit;
    return value.isFinite ? value : 0;
  }

  bool get isOverBudget => limit > 0 && spent > limit;

  /// A limit of 0 means the user hasn't set a budget for this category yet.
  bool get hasLimit => limit > 0 && limit.isFinite;

  /// Money spent in a category that has no budget to measure it against.
  bool get isUnbudgetedSpend => !hasLimit && spent > 0;

  /// Days elapsed in the current calendar month (at least 1).
  static int get daysElapsedThisMonth {
    final now = DateTime.now();
    final dim = daysInMonth(now.year, now.month);
    final day = now.day;
    if (day < 1) return 1;
    if (day > dim) return dim;
    return day;
  }

  static int daysInMonth(int year, int month) =>
      DateTime(year, month + 1, 0).day;

  /// Daily spend pace so far this month.
  double get burnRateDaily {
    final elapsed = daysElapsedThisMonth;
    if (elapsed <= 0 || !spent.isFinite) return 0;
    final value = spent / elapsed;
    return value.isFinite ? value : 0;
  }

  /// Extrapolated month-end spend if today's pace continues; just [spent]
  /// when [paceApplies] is false.
  double get projectedMonthEnd {
    if (!paceApplies) return spent.isFinite ? spent : 0;
    final now = DateTime.now();
    final dim = daysInMonth(now.year, now.month);
    final value = burnRateDaily * dim;
    return value.isFinite ? value : 0;
  }

  double get projectedOverrun {
    if (limit <= 0 || !limit.isFinite) return 0;
    final over = projectedMonthEnd - limit;
    if (!over.isFinite || over <= 0) return 0;
    return over;
  }

  double get allowedDaily {
    if (limit <= 0 || !limit.isFinite) return 0;
    final now = DateTime.now();
    final value = limit / daysInMonth(now.year, now.month);
    return value.isFinite ? value : 0;
  }

  /// Projected to finish the month over the limit.
  bool get isBurnRateHigh =>
      paceApplies &&
      limit > 0 &&
      projectedMonthEnd.isFinite &&
      projectedMonthEnd > limit;

  /// On pace to use most of the budget (>= 90%) but not yet over.
  bool get isBurnRateApproaching {
    if (!paceApplies || limit <= 0 || isBurnRateHigh) return false;
    return projectedMonthEnd >= limit * 0.9;
  }

  bool get isWarning => ratio >= 0.8 || isBurnRateHigh || isBurnRateApproaching;
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

/// Kinds for a whole list of transactions, plus the purchase each refund
/// belongs to. [userCategoryById] holds categories the user picked or has a
/// remembered rule for. A refund is money back from a merchant with an
/// earlier purchase of at least that amount on the same account.
({Map<String, TxKind> kinds, Map<String, String> purchaseIdByRefundId})
classifyTransactions(
  List<AppTransaction> transactions,
  Map<String, String> userCategoryById,
) {
  final kinds = <String, TxKind>{};
  final purchaseIdByRefundId = <String, String>{};
  final purchasesByMerchant = <String, List<AppTransaction>>{};
  for (final tx in transactions) {
    final userCategory = userCategoryById[tx.id] ?? '';
    var kind = tx.ownKind(userCategory: userCategory);
    if (kind == TxKind.spend) {
      purchasesByMerchant
          .putIfAbsent(merchantMatchKey(tx.name), () => [])
          .add(tx);
    }
    kinds[tx.id] = kind;
  }
  for (final tx in transactions) {
    final kind = kinds[tx.id];
    if (kind != TxKind.income && kind != TxKind.refund) continue;
    final userCategory = userCategoryById[tx.id] ?? '';
    if (userCategory.isNotEmpty && userCategory != 'Fees & Transfers') {
      continue;
    }
    final purchase = _matchingPurchase(
      tx,
      purchasesByMerchant[merchantMatchKey(tx.name)] ?? const [],
    );
    if (purchase == null) continue;
    kinds[tx.id] = TxKind.refund;
    purchaseIdByRefundId[tx.id] = purchase.id;
  }
  return (kinds: kinds, purchaseIdByRefundId: purchaseIdByRefundId);
}

/// A merchant name without digits, punctuation or extra spaces.
String merchantMatchKey(String name) => name
    .toLowerCase()
    .replaceAll(RegExp(r'[^a-z ]'), ' ')
    .replaceAll(RegExp(r'\s+'), ' ')
    .trim();

AppTransaction? _matchingPurchase(
  AppTransaction refund,
  List<AppTransaction> purchases,
) {
  if (merchantMatchKey(refund.name).isEmpty) return null;
  // Money from a person is not a merchant handing a purchase back.
  if (AppTransaction.isPeerToPeer('${refund.name} ${refund.description}')) {
    return null;
  }
  AppTransaction? best;
  for (final purchase in purchases) {
    if (refund.accountId.isNotEmpty &&
        purchase.accountId.isNotEmpty &&
        refund.accountId != purchase.accountId) {
      continue;
    }
    final days = refund.date.difference(purchase.date).inDays;
    if (days < 0 || days > 120) continue;
    if (purchase.displayAmount + 0.005 < refund.displayAmount) continue;
    final exact = (purchase.displayAmount - refund.displayAmount).abs() < 0.005;
    if (best == null) {
      best = purchase;
      continue;
    }
    final bestExact = (best.displayAmount - refund.displayAmount).abs() < 0.005;
    if (exact && !bestExact) {
      best = purchase;
    } else if (exact == bestExact && purchase.date.isAfter(best.date)) {
      best = purchase;
    }
  }
  return best;
}
