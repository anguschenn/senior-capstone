import 'dart:math' as math;

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

  /// Money moving between two linked accounts (savings transfers, card
  /// payments): shown in the list but never counted.
  internal,

  /// Money from a friend that the user linked to a purchase: counts as
  /// nothing itself, it lowers that purchase instead (in the purchase's
  /// month and category).
  payback,

  none,
}

/// What the user decided about one transaction (transaction_decisions).
/// Money from a person is never decided by a name-based rule: the same
/// friend may pay back a meal one week and a ride the next.
class TxDecision {
  const TxDecision({
    this.category = '',
    this.paidBackPurchaseId = '',
    this.sharedAmount = 0,
  });

  /// This transaction's own category pick.
  final String category;

  /// Money in: the purchase it pays back.
  final String paidBackPurchaseId;

  /// A purchase split with others: what they will pay back. It still counts
  /// in full until they do; it only shows what's left to get back.
  final double sharedAmount;

  bool get isEmpty =>
      category.isEmpty && paidBackPurchaseId.isEmpty && sharedAmount <= 0;

  factory TxDecision.fromRow(Map<String, dynamic> row) {
    final shared = row['shared_amount'];
    return TxDecision(
      category: ((row['category'] as String?) ?? '').trim(),
      paidBackPurchaseId: ((row['paid_back_purchase_id'] as String?) ?? '')
          .trim(),
      sharedAmount: shared is num
          ? shared.toDouble()
          : double.tryParse('${shared ?? ''}') ?? 0,
    );
  }

  Map<String, dynamic> toRow() => {
    'category': category.isEmpty ? null : category,
    'paid_back_purchase_id': paidBackPurchaseId.isEmpty
        ? null
        : paidBackPurchaseId,
    'shared_amount': sharedAmount > 0 ? sharedAmount : null,
  };
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

  bool get isExpense => amount != 0 && amount > 0;

  bool get isInflow => amount != 0 && !isExpense;

  bool get isIncome => amount != 0 && amount < 0;

  bool get isRefundIncome => isIncome && _isRefundLike();

  double get displayAmount => amount.abs();

  bool get isCreditCardPayment => isCreditCardPaymentByPfc(
    pfcDetailed: rawPfcDetailed,
    pfcPrimary: rawPfcPrimary,
  );

  /// Kinds for the loaded transactions, set by [classifyTransactions] so
  /// remembered rules, own-account pairing and refund matching apply. Ids
  /// missing here fall back to [ownKind].
  static Map<String, TxKind> kindById = const {};

  TxKind get kind => kindById[id] ?? ownKind();

  /// What friends paid back on each purchase (money in the user linked to
  /// it), set by [classifyTransactions] with [kindById].
  static Map<String, double> paidBackById = const {};

  /// What friends paid back on this purchase.
  double get paidBack => paidBackById[id] ?? 0;

  /// Purchases split with others: what they will pay back (the user's
  /// decisions). Display only: spending goes down when they actually pay.
  static Map<String, double> sharedAmountById = const {};

  /// Money in linked to a purchase -> that purchase, for labelling the row.
  static Map<String, AppTransaction> purchaseByPaybackId = const {};

  double get sharedAmount => sharedAmountById[id] ?? 0;

  /// Still to get back on a split purchase.
  double get toGetBack => math.max(sharedAmount - paidBack, 0);

  /// Spending contributed by this transaction: negative for a refund, so it
  /// nets against its category. Money moved between two linked accounts (a
  /// card payment, a savings transfer) counts as nothing: the purchases
  /// already count when they happen. Money sent to an account the app doesn't
  /// have is spending, like cash. A purchase friends paid back counts only
  /// what's left; the payback itself counts as nothing.
  double get expenseAmount => switch (kind) {
    TxKind.spend => math.max(displayAmount - paidBack, 0),
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
    if (isExpense) return TxKind.spend;
    if (_isRefundLike() || isSpendingPfc(rawPfcPrimary)) return TxKind.refund;
    return TxKind.income;
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
  String get inflowLabel => switch (kind) {
    TxKind.internal => kInternalTransfer,
    TxKind.payback => 'Paid back',
    _ => 'Income',
  };

  /// Money in from a person (Zelle, Venmo, ...): never decided by a
  /// name-based rule, and always offered for review until the user decides.
  bool get isPeerToPeerInflow => isInflow && isPeerToPeer('$name $description');

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

  /// Plaid labels the checking-side payment LOAN_PAYMENTS_CREDIT_CARD_PAYMENT.
  /// (The card side arrives as a negative amount, so it is never an expense.)
  static bool isCreditCardPaymentByPfc({
    required String pfcDetailed,
    required String pfcPrimary,
  }) =>
      '$pfcDetailed $pfcPrimary'.toUpperCase().contains('CREDIT_CARD_PAYMENT');

  bool _isRefundLike() {
    final text =
        '${name.toLowerCase()} ${description.toLowerCase()} '
        '${category.toLowerCase()} ${primaryCategory.toLowerCase()}';
    return text.contains('refund') ||
        text.contains('reversal') ||
        text.contains('returned') ||
        text.contains('return');
  }
}

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

  DateTime get effectiveNextChargeDate => nextChargeDateAfter(DateTime.now());

  // Rolls a past renewal forward. Monthly and annual bills keep their day of
  // the month (clamped to the month's last day), so Oct 18 renews Nov 18.
  DateTime nextChargeDateAfter(DateTime today) {
    final start = nextChargeDate;
    final todayDay = DateTime(today.year, today.month, today.day);
    var date = start;
    var step = 0;
    while (date.isBefore(todayDay)) {
      step++;
      date = switch (frequency) {
        'weekly' => start.add(Duration(days: 7 * step)),
        'annual' => _sameDayInMonth(start, 12 * step),
        _ => _sameDayInMonth(start, step),
      };
    }
    return date;
  }

  static DateTime _sameDayInMonth(DateTime from, int months) {
    final first = DateTime(from.year, from.month + months);
    final lastDay = DateTime(first.year, first.month + 1, 0).day;
    return DateTime(first.year, first.month, math.min(from.day, lastDay));
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

typedef Classified = ({
  Map<String, TxKind> kinds,
  Map<String, String> purchaseIdByRefundId,
  Map<String, String> purchaseIdByPaybackId,
  Map<String, double> paidBackById,
});

/// Makes [classified] what every [AppTransaction] reads: kinds, what friends
/// paid back, split purchases and the purchase each payback belongs to.
void useClassification(
  Classified classified,
  List<AppTransaction> transactions,
  Map<String, TxDecision> decisions,
) {
  final byId = {for (final tx in transactions) tx.id: tx};
  AppTransaction.kindById = classified.kinds;
  AppTransaction.paidBackById = classified.paidBackById;
  AppTransaction.sharedAmountById = {
    for (final e in decisions.entries)
      if (e.value.sharedAmount > 0) e.key: e.value.sharedAmount,
  };
  AppTransaction.purchaseByPaybackId = {
    for (final e in classified.purchaseIdByPaybackId.entries)
      if (byId[e.value] != null) e.key: byId[e.value]!,
  };
}

/// Money in -> the purchase it pays back, from the user's decisions.
Map<String, String> paidBackPurchaseIds(Map<String, TxDecision> decisions) => {
  for (final e in decisions.entries)
    if (e.value.paidBackPurchaseId.isNotEmpty)
      e.key: e.value.paidBackPurchaseId,
};

/// Kinds for a whole list of transactions, plus the purchase each refund
/// belongs to. [userCategoryById] holds categories the user picked or has a
/// remembered rule for. A refund is money back from a merchant with an
/// earlier purchase of at least that amount on the same account.
/// [paidBackPurchaseById] links money in to the purchase it pays back (the
/// user's pick): it becomes a payback and lowers that purchase, oldest
/// payback first, never below nothing ([paidBackById]).
Classified classifyTransactions(
  List<AppTransaction> transactions,
  Map<String, String> userCategoryById, {
  Map<String, String> paidBackPurchaseById = const {},
}) {
  final kinds = <String, TxKind>{};
  final purchaseIdByRefundId = <String, String>{};
  final purchasesByMerchant = <String, List<AppTransaction>>{};
  final byId = <String, AppTransaction>{};
  for (final tx in transactions) {
    byId.putIfAbsent(tx.id, () => tx);
    final userCategory = userCategoryById[tx.id] ?? '';
    var kind = tx.ownKind(userCategory: userCategory);
    if (kind == TxKind.spend) {
      purchasesByMerchant
          .putIfAbsent(merchantMatchKey(tx.name), () => [])
          .add(tx);
    }
    kinds[tx.id] = kind;
  }
  _pairOwnTransfers(transactions, userCategoryById, kinds);
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

  // Oldest payback first, each lowering its purchase until nothing is left.
  final purchaseIdByPaybackId = <String, String>{};
  final paidBackById = <String, double>{};
  final linked =
      transactions
          .where(
            (tx) =>
                tx.amount < 0 && (paidBackPurchaseById[tx.id] ?? '').isNotEmpty,
          )
          .toList()
        ..sort((a, b) {
          final byDate = a.date.compareTo(b.date);
          return byDate != 0 ? byDate : a.id.compareTo(b.id);
        });
  final seenPaybacks = <String>{};
  for (final tx in linked) {
    if (!seenPaybacks.add(tx.id)) continue;
    final purchaseId = paidBackPurchaseById[tx.id]!;
    final purchase = byId[purchaseId];
    if (purchase == null) {
      // The purchase is outside the loaded rows (older, or on a hidden
      // account): the money still went back to it, so it counts as nothing.
      kinds[tx.id] = TxKind.payback;
      purchaseIdByRefundId.remove(tx.id);
      continue;
    }
    if (kinds[purchaseId] != TxKind.spend) continue;
    final paid = paidBackById[purchaseId] ?? 0;
    final take = math.min(
      tx.displayAmount,
      math.max(purchase.displayAmount - paid, 0),
    );
    paidBackById[purchaseId] = paid + take;
    kinds[tx.id] = TxKind.payback;
    purchaseIdByRefundId.remove(tx.id);
    purchaseIdByPaybackId[tx.id] = purchaseId;
  }
  return (
    kinds: kinds,
    purchaseIdByRefundId: purchaseIdByRefundId,
    purchaseIdByPaybackId: purchaseIdByPaybackId,
    paidBackById: {
      for (final e in paidBackById.entries)
        e.key: (e.value * 100).roundToDouble() / 100,
    },
  );
}

/// Money leaving one linked account and the same amount arriving in another
/// linked account within 5 days is a move between the user's own accounts.
/// The app only manages linked accounts, so money to or from any other
/// account counts as spending or income.
/// Only transfer- or payment-looking rows pair, so a purchase never pairs with
/// an unrelated deposit; person-to-person payments never pair.
void _pairOwnTransfers(
  List<AppTransaction> transactions,
  Map<String, String> userCategoryById,
  Map<String, TxKind> kinds,
) {
  bool candidate(AppTransaction tx) {
    if (tx.accountId.isEmpty) return false;
    final userCategory = userCategoryById[tx.id] ?? '';
    if (userCategory.isNotEmpty && userCategory != 'Fees & Transfers') {
      return false;
    }
    final kind = kinds[tx.id];
    if (kind != TxKind.spend && kind != TxKind.income) return false;
    if (AppTransaction.isPeerToPeer('${tx.name} ${tx.description}')) {
      return false;
    }
    return looksLikeTransfer(
      tx.name,
      tx.description,
      tx.rawPfcPrimary,
      tx.rawPfcDetailed,
    );
  }

  int byDateThenId(AppTransaction a, AppTransaction b) {
    final byDate = a.date.compareTo(b.date);
    return byDate != 0 ? byDate : a.id.compareTo(b.id);
  }

  // Oldest first, each taking the closest-dated match, so the app and the
  // server pair the same rows whatever order they arrive in.
  final outflows =
      transactions.where((tx) => tx.amount > 0 && candidate(tx)).toList()
        ..sort(byDateThenId);
  final inflows =
      transactions.where((tx) => tx.amount < 0 && candidate(tx)).toList()
        ..sort(byDateThenId);
  final paired = <String>{};
  for (final out in outflows) {
    AppTransaction? best;
    var bestGap = 0;
    for (final into in inflows) {
      if (paired.contains(into.id) || into.accountId == out.accountId) {
        continue;
      }
      if ((into.displayAmount - out.displayAmount).abs() >= 0.005) continue;
      final gap = into.date.difference(out.date).inDays.abs();
      if (gap > 5) continue;
      if (best == null || gap < bestGap) {
        best = into;
        bestGap = gap;
      }
    }
    if (best == null) continue;
    paired.addAll([out.id, best.id]);
    kinds[out.id] = TxKind.internal;
    kinds[best.id] = TxKind.internal;
  }
}

/// A row a bank would use for moving money: Plaid's transfer and loan
/// payment groups, or the usual words.
bool looksLikeTransfer(
  String name,
  String description,
  String pfcPrimary,
  String pfcDetailed,
) {
  final pfc = '$pfcPrimary $pfcDetailed'.toUpperCase();
  if (pfc.contains('TRANSFER') || pfc.contains('LOAN_')) return true;
  return RegExp(
    r'\b(transfer|trans|xfer|trnsfr|payment|deposit|withdrawal|online)\b',
  ).hasMatch('$name $description'.toLowerCase());
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
