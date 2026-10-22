import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../core/config/api_config.dart';
import '../core/config/env_config.dart';
import '../core/config/supabase_client.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import 'account_service.dart';
import 'auth_service.dart';
import 'budget_service.dart';
import 'category_service.dart';
import 'sync_cache.dart';
import 'transaction_decision_service.dart';

/// Parses the JSON body of GET /api/budget_progress (already json-decoded)
/// into the same model the Dart-computed path produces. A pure function, no
/// network/auth involved, so it can be tested directly against a fixture
/// shaped like the real response -- see budget_progress.py's
/// build_budget_progress for the producing side.
///
/// Malformed input (wrong shape, missing ids, non-numeric spent/limit)
/// is skipped per-row rather than thrown: a single bad row from the server
/// should not discard every other category's progress.
List<BudgetCategoryProgress> parseBudgetProgressResponse(Object? decoded) {
  if (decoded is! Map) return const [];
  final rows = decoded['progress'];
  if (rows is! List) return const [];

  final progress = <BudgetCategoryProgress>[];
  for (final row in rows) {
    if (row is! Map) continue;
    final budgetId = (row['budget_id'] as String?) ?? '';
    final categoryId = (row['category_id'] as String?) ?? '';
    if (budgetId.isEmpty || categoryId.isEmpty) continue;
    final rawSpent = row['spent'];
    final rawLimit = row['limit'];
    progress.add(
      BudgetCategoryProgress(
        budgetId: budgetId,
        categoryId: categoryId,
        title: (row['category'] as String?) ?? 'Unknown',
        spent: rawSpent is num ? rawSpent.toDouble() : 0,
        limit: rawLimit is num ? rawLimit.toDouble() : 0,
      ),
    );
  }
  return progress;
}

/// Thrown when Plaid reports ITEM_LOGIN_REQUIRED for a linked bank.
class ItemLoginRequiredException implements Exception {
  const ItemLoginRequiredException();
  @override
  String toString() => 'Bank re-authentication required';
}

/// What a bank sync reported: whether the backend confirmed it, and whether
/// any linked bank needs the user to log in again (the other banks may still
/// have synced).
typedef BankSync = ({bool synced, bool loginRequired});

/// Reads the backend's /api/transactions reply. A 400 with
/// ITEM_LOGIN_REQUIRED (every bank needs a new login) throws
/// [ItemLoginRequiredException]; a 200 can still name banks that need one in
/// login_required_items. Plaid API errors also surface as 400, so the status
/// alone is not enough.
BankSync bankSyncFromResponse(int statusCode, String body) {
  Object? decoded;
  try {
    decoded = jsonDecode(body);
  } catch (_) {
    decoded = null;
  }
  final map = decoded is Map ? decoded : const {};
  if (statusCode == 400 && map['error_code'] == 'ITEM_LOGIN_REQUIRED') {
    throw const ItemLoginRequiredException();
  }
  final items = map['login_required_items'];
  return (
    synced: statusCode == 200,
    loginRequired: statusCode == 200 && items is List && items.isNotEmpty,
  );
}

/// Result payload returned by a full sync or refresh.
class SyncResult {
  const SyncResult({
    required this.transactions,
    required this.subscriptions,
    required this.budgetProgress,
    required this.budgetProgressYear,
    required this.budgetProgressAll,
    required this.categoryOptions,
    required this.accountOptions,
    required this.stats,
    required this.hasData,
    required this.autoReviewedCategoryByTxId,
    required this.autoLowConfidenceReviewTxIds,
    this.budgetLimitsByMonth = const {},
    this.ruleCategoryByTxId = const {},
    this.decisions = const {},
  });

  final List<AppTransaction> transactions;
  final List<DetectedSubscription> subscriptions;
  final List<BudgetCategoryProgress> budgetProgress;
  final List<BudgetCategoryProgress> budgetProgressYear;
  final List<BudgetCategoryProgress> budgetProgressAll;
  final List<CategoryOption> categoryOptions;
  final List<AccountOption> accountOptions;
  final DashboardStats stats;
  final bool hasData;
  final Map<String, String> autoReviewedCategoryByTxId;
  final Set<String> autoLowConfidenceReviewTxIds;

  /// Categories from the user's remembered rules (category_match_rules) and
  /// their one-off picks (transaction_decisions). Money from a person only
  /// takes its own pick.
  final Map<String, String> ruleCategoryByTxId;

  /// The user's per-transaction choices, by transaction id.
  final Map<String, TxDecision> decisions;

  /// The focused year's limits per month ("2026-09" → category id → limit).
  final Map<String, Map<String, double>> budgetLimitsByMonth;
}

/// A [SyncResult] rebuilt from the on-device copy, and when that copy was saved.
class CachedSyncResult {
  const CachedSyncResult({required this.result, required this.savedAt});

  final SyncResult result;
  final DateTime savedAt;
}

/// Orchestrates bank sync trigger and Supabase data loading.
class SyncService {
  const SyncService._();
  static const instance = SyncService._();

  Map<String, String> _backendHeaders() {
    final headers = <String, String>{
      'x-api-key': EnvConfig.instance.backendApiKey,
    };
    final accessToken = AuthService.instance.currentAccessToken;
    if (accessToken != null && accessToken.isNotEmpty) {
      headers['Authorization'] = 'Bearer $accessToken';
    }
    return headers;
  }

  /// Triggers the backend bank sync endpoint. synced is true when the backend
  /// confirmed the sync, false when it could not be reached or failed;
  /// loginRequired is true when a linked bank needs a new login.
  /// Throws [ItemLoginRequiredException] if every bank needs one.
  ///
  /// [full] (the Refresh button) also recomputes subscriptions, alerts and
  /// suggestions when the bank sent nothing new.
  Future<BankSync> triggerBankSync({bool full = false}) async {
    final uri = ApiConfig.instance.transactionsUri;
    try {
      final response = await http
          .get(
            full ? uri.replace(queryParameters: {'full': '1'}) : uri,
            headers: _backendHeaders(),
          )
          .timeout(const Duration(seconds: 30));
      return bankSyncFromResponse(response.statusCode, response.body);
    } on ItemLoginRequiredException {
      rethrow;
    } catch (_) {
      // Other network/server errors are best-effort — don't block the UI.
      return (synced: false, loginRequired: false);
    }
  }

  /// Asks the backend to recompute subscriptions, budget alerts and
  /// suggestions from the stored transactions. Best effort: false on failure.
  Future<bool> refreshInsights() async {
    try {
      final response = await http
          .post(
            ApiConfig.instance.refreshInsightsUri,
            headers: _backendHeaders(),
          )
          .timeout(const Duration(seconds: 30));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Central load path: accounts, transactions, subscriptions, budgets.
  /// Also saves the raw rows on-device so the next launch can paint from them.
  Future<SyncResult> refreshFromSupabase(
    Map<String, String> reviewedCategoryByTxId,
    DateTime selectedMonth,
  ) async {
    final raw = await fetchRaw(
      AuthService.instance.currentUserId,
      selectedMonth,
    );
    unawaited(SyncCache.instance.save(raw));
    return buildResult(raw, reviewedCategoryByTxId);
  }

  /// The last successful load saved on this device, rebuilt into a result, or
  /// null when there is none. Never throws: the saved copy is an optimization.
  Future<CachedSyncResult?> loadCachedResult(
    Map<String, String> reviewedCategoryByTxId,
    DateTime selectedMonth,
  ) async {
    try {
      final raw = await SyncCache.instance.load(
        AuthService.instance.currentUserId,
      );
      if (raw == null) return null;
      final monthYear = monthKeyOf(normalizedMonthOption(selectedMonth));
      // Budget limits are stored per month; don't show another month's limits.
      final usable = raw.monthYear == monthYear ? raw : raw.withoutBudgets();
      return CachedSyncResult(
        result: buildResult(usable, reviewedCategoryByTxId),
        savedAt: raw.savedAt,
      );
    } catch (_) {
      return null;
    }
  }

  /// Forgets the on-device copy (sign-out, "Clear").
  Future<void> clearSavedData() => SyncCache.instance.clear();

  /// Budget progress for [month] computed by the backend from ALL the user's
  /// transactions (see python/budget_progress.py) -- no per-account filter,
  /// so this is only valid for the "All Accounts" view. Null on any failure,
  /// or when the server has no budget rows for that month yet; callers fall
  /// back to the Dart computation (BudgetService.rebasedProgressFromTemplate).
  Future<List<BudgetCategoryProgress>?> fetchServerBudgetProgress(
    DateTime month,
  ) async {
    try {
      final uri = ApiConfig.instance.budgetProgressUri.replace(
        queryParameters: {'month': monthKeyOf(normalizedMonthOption(month))},
      );
      final response = await http
          .get(uri, headers: _backendHeaders())
          .timeout(const Duration(seconds: 15));
      if (response.statusCode != 200) return null;
      // Empty means the month has no budget rows: the page shows spending
      // without limits instead of borrowing another month's.
      return parseBudgetProgressResponse(jsonDecode(response.body));
    } catch (_) {
      return null;
    }
  }

  /// When the backend last synced this user's banks (by webhook or by the
  /// app), read straight from Supabase so it never wakes the backend. Null
  /// when unknown, including before migration 012 is applied; callers then
  /// sync as usual.
  Future<DateTime?> fetchLastSyncedAt() async {
    try {
      final row = await AppSupabase.client
          .from('sync_status')
          .select('last_synced_at')
          .eq('user_id', AuthService.instance.currentUserId)
          .maybeSingle();
      final raw = row?['last_synced_at'] as String?;
      return raw == null ? null : DateTime.tryParse(raw)?.toLocal();
    } catch (_) {
      return null;
    }
  }

  /// Fetches everything a refresh needs from Supabase, unparsed.
  Future<RawSyncData> fetchRaw(String userId, DateTime selectedMonth) async {
    final focused = normalizedMonthOption(selectedMonth);
    final monthYear = monthKeyOf(focused);

    final accountsRows = await AccountService.instance.fetchAccountRows(
      userId,
      unscoped: false,
    );
    final accountMetaById = {
      for (final row in accountsRows)
        ((row['plaid_account_id'] as String?) ?? '').trim(): {
          'account_name': ((row['name'] as String?) ?? '').trim(),
          'account_type': ((row['account_type'] as String?) ?? '').trim(),
          'subtype': ((row['subtype'] as String?) ?? '').trim(),
        },
    }..remove('');
    final userCategories = await CategoryService.instance.ensureBaseCategories(
      userId,
    );
    await BudgetService.instance.ensureMonthlyBudgetRows(
      userCategories,
      monthYear,
      userId,
    );

    final budgetRows = await AppSupabase.client
        .from('budgets')
        .select('id,category_id,monthly_limit,month_year')
        .eq('user_id', userId)
        .eq('month_year', monthYear);

    // The whole year's limits, month by month, for the Year view.
    List yearBudgetRows;
    try {
      yearBudgetRows = await AppSupabase.client
          .from('budgets')
          .select('category_id,monthly_limit,month_year')
          .eq('user_id', userId)
          .gte('month_year', '${focused.year}-01')
          .lte('month_year', '${focused.year}-12');
    } catch (_) {
      yearBudgetRows = const [];
    }

    final subscriptionRows = await AppSupabase.client
        .from('subscriptions')
        .select(
          'id,merchant_name,amount,next_charge_date,frequency,needs_confirmation',
        )
        .eq('user_id', userId)
        .eq('is_active', true)
        .order('next_charge_date', ascending: true)
        .limit(500);

    final rows = await AppSupabase.client
        .from('transactions')
        .select(
          'plaid_transaction_id,plaid_account_id,merchant_name,name,category,pfc_primary,pfc_detailed,pfc_confidence,pending,date,amount,user_id',
        )
        .eq('user_id', userId)
        .order('date', ascending: false)
        .limit(1000);

    final txRows = (rows as List).whereType<Map<String, dynamic>>().map((row) {
      final accountId = ((row['plaid_account_id'] as String?) ?? '').trim();
      final meta = accountMetaById[accountId] ?? const <String, String>{};
      return {
        ...row,
        'account_name': meta['account_name'] ?? '',
        'account_type': meta['account_type'] ?? '',
        'subtype': meta['subtype'] ?? '',
      };
    }).toList();
    final rememberedRules = await CategoryService.instance
        .fetchRememberedRuleDecisions(userId);
    final decisions = await TransactionDecisionService.instance.fetchRows(
      userId,
    );

    return RawSyncData(
      userId: userId,
      monthYear: monthYear,
      savedAt: DateTime.now(),
      accountsRows: accountsRows,
      categories: userCategories,
      budgetRows: (budgetRows as List)
          .whereType<Map<String, dynamic>>()
          .toList(),
      yearBudgetRows: yearBudgetRows.whereType<Map<String, dynamic>>().toList(),
      subscriptionRows: (subscriptionRows as List)
          .whereType<Map<String, dynamic>>()
          .toList(),
      txRows: txRows,
      rememberedRules: {
        for (final e in rememberedRules.entries)
          e.key: {
            'category': e.value.category,
            'confidence': e.value.confidence,
          },
      },
      decisions: decisions,
    );
  }

  /// Turns raw rows (fresh from Supabase or from the on-device copy) into the
  /// parsed result the UI renders. Pure: no network, no storage.
  SyncResult buildResult(
    RawSyncData raw,
    Map<String, String> reviewedCategoryByTxId, {
    DateTime? asOf,
  }) {
    final now = asOf ?? DateTime.now();
    final txRows = raw.txRows;
    final accountsRows = raw.accountsRows;
    final userCategories = raw.categories;
    final rememberedRules = {
      for (final e in raw.rememberedRules.entries)
        e.key: CategoryDecision(
          category: e.value['category'] ?? '',
          confidence: e.value['confidence'] ?? 'high',
        ),
    };

    // Parse and de-duplicate transactions.
    final parsed = txRows.map(AppTransaction.fromMap).toList();
    final deduped = <AppTransaction>[];
    final seen = <String>{};
    for (final tx in parsed) {
      if (seen.add(tx.dedupeKey)) deduped.add(tx);
    }

    final effectiveReviewedCategoryByTxId = <String, String>{
      ...reviewedCategoryByTxId,
    };
    final autoReviewedCategoryByTxId = <String, String>{};
    final autoLowConfidenceReviewTxIds = <String>{};

    // Categories the user decided (one-off picks, then remembered rules,
    // which money from a person never uses), then what counts as spending,
    // income, a refund, a payback or a transfer between their own accounts.
    final decisions = {
      for (final e in raw.decisions.entries) e.key: TxDecision.fromRow(e.value),
    };
    final ruleCategoryByTxId = <String, String>{};
    for (int i = 0; i < txRows.length && i < parsed.length; i++) {
      final picked = decisions[parsed[i].id]?.category ?? '';
      if (picked.isNotEmpty) {
        ruleCategoryByTxId[parsed[i].id] = picked;
        continue;
      }
      if (parsed[i].isPeerToPeerInflow) continue;
      final key = CategoryService.instance.ruleKeyForRawTransaction(txRows[i]);
      final remembered = key.isEmpty ? null : rememberedRules[key];
      if (remembered != null && remembered.category.isNotEmpty) {
        ruleCategoryByTxId[parsed[i].id] = remembered.category;
      }
    }
    final classified = classifyTransactions(
      deduped,
      ruleCategoryByTxId,
      paidBackPurchaseById: paidBackPurchaseIds(decisions),
    );
    useClassification(classified, deduped, decisions);

    for (int i = 0; i < txRows.length && i < parsed.length; i++) {
      final tx = parsed[i];
      final key = CategoryService.instance.ruleKeyForRawTransaction(txRows[i]);
      if (key.isEmpty) continue;
      final remembered = ruleCategoryByTxId[tx.id];
      if (remembered != null) {
        autoReviewedCategoryByTxId[tx.id] = remembered;
        continue;
      }
      final decision = CategoryService.instance.classifyByPfcSignals(
        pfcPrimary: ((txRows[i]['pfc_primary'] as String?) ?? '').trim(),
        pfcDetailed:
            ((txRows[i]['pfc_detailed'] as String?) ??
                    (txRows[i]['category'] as String?) ??
                    '')
                .trim(),
        merchantName:
            ((txRows[i]['name'] as String?) ??
                    (txRows[i]['merchant_name'] as String?) ??
                    '')
                .trim(),
        transactionName: ((txRows[i]['name'] as String?) ?? '').trim(),
      );
      // Money in that counts as income reads as Income; the review queue
      // still offers it when the signals were weak (a friend paying back a
      // dinner belongs in Food).
      // A move between own accounts still gets the category it would have
      // on its own (pages show it as Internal Transfer while it is one), so
      // hiding the other account turns a card payment into Fees & Transfers,
      // not Other.
      autoReviewedCategoryByTxId[tx.id] = tx.kind == TxKind.payback
          ? tx.inflowLabel
          : tx.kind == TxKind.income ||
                (tx.kind == TxKind.internal && !tx.isExpense)
          ? 'Income'
          : decision.category;
      if (tx.kind == TxKind.internal || tx.kind == TxKind.payback) continue;
      // Money from a person may pay back something you bought (then it
      // belongs to that purchase), so it's offered for review every time
      // until the user decides.
      if (decision.confidence == 'low' || tx.isPeerToPeerInflow) {
        autoLowConfidenceReviewTxIds.add(tx.id);
      }
    }
    // A refund lands in the category of the purchase it pays back, and so
    // does a friend's payback the user linked to a purchase.
    for (final entry in classified.purchaseIdByRefundId.entries) {
      if (ruleCategoryByTxId.containsKey(entry.key)) continue;
      final purchaseCategory = autoReviewedCategoryByTxId[entry.value];
      if (purchaseCategory == null) continue;
      autoReviewedCategoryByTxId[entry.key] = purchaseCategory;
      autoLowConfidenceReviewTxIds.remove(entry.key);
    }
    for (final entry in classified.purchaseIdByPaybackId.entries) {
      final purchaseCategory = autoReviewedCategoryByTxId[entry.value];
      if (purchaseCategory == null) continue;
      autoReviewedCategoryByTxId[entry.key] = purchaseCategory;
    }
    effectiveReviewedCategoryByTxId.addAll(autoReviewedCategoryByTxId);

    // Build subscriptions.
    final dbSubscriptions = <DetectedSubscription>[];
    final subSeen = <String>{};
    for (final row in raw.subscriptionRows) {
      final merchant = (row['merchant_name'] as String?)?.trim();
      if (merchant == null || merchant.isEmpty) continue;
      final rawAmount = row['amount'];
      final amount = rawAmount is num
          ? rawAmount.toDouble()
          : double.tryParse('$rawAmount') ?? 0;
      final rawDate = (row['next_charge_date'] as String?) ?? '';
      final nextDate = DateTime.tryParse(rawDate);
      if (nextDate == null) continue;
      final frequency =
          ((row['frequency'] as String?)?.trim().isNotEmpty ?? false)
          ? (row['frequency'] as String).trim()
          : 'monthly';
      final dedupeKey =
          '${merchant.toLowerCase()}|${amount.toStringAsFixed(2)}|${nextDate.toIso8601String().split("T").first}';
      if (!subSeen.add(dedupeKey)) continue;
      dbSubscriptions.add(
        DetectedSubscription(
          id: (row['id'] as String?) ?? '',
          merchant: merchant,
          amount: amount.abs(),
          nextChargeDate: nextDate,
          frequency: frequency,
          needsConfirmation: row['needs_confirmation'] == true,
        ),
      );
    }

    // Dashboard stats.
    double monthlyIncome = 0;
    double monthlyExpenses = 0;
    for (final tx in deduped) {
      if (tx.date.year == now.year && tx.date.month == now.month) {
        monthlyIncome += tx.incomeAmount;
        monthlyExpenses += tx.expenseAmount;
      }
    }
    final totalBalance = AccountService.instance.computeTotalBalance(
      accountsRows,
    );

    // Account options.
    final txCountByAccount = <String, int>{};
    for (final tx in deduped) {
      if (tx.accountId.isEmpty) continue;
      txCountByAccount[tx.accountId] =
          (txCountByAccount[tx.accountId] ?? 0) + 1;
    }
    final accountOptions = AccountService.instance.buildAccountOptions(
      accountsRows,
      txCountByAccount,
    );

    // Budget progress.
    final categoryMap = {for (final c in userCategories) c.id: c.name};
    final budgetRowsList = raw.budgetRows;
    final budgetProgress = BudgetService.instance.buildProgressFromRows(
      budgetRows: budgetRowsList,
      categoryMap: categoryMap,
      txRows: txRows,
      now: now,
      yearly: false,
      reviewedCategoryByTxId: effectiveReviewedCategoryByTxId,
    );
    final budgetProgressYear = BudgetService.instance.buildProgressFromRows(
      budgetRows: budgetRowsList,
      categoryMap: categoryMap,
      txRows: txRows,
      now: now,
      yearly: true,
      reviewedCategoryByTxId: effectiveReviewedCategoryByTxId,
      yearLimitByCategoryId: raw.yearBudgetRows.isEmpty
          ? null
          : BudgetService.yearLimitsByCategoryId(raw.yearBudgetRows),
      yearMonthsByCategoryId: raw.yearBudgetRows.isEmpty
          ? null
          : BudgetService.yearMonthsByCategoryId(raw.yearBudgetRows),
    );
    final effectiveBudgetProgress = budgetProgress.isNotEmpty
        ? budgetProgress
        : BudgetService.instance.buildZeroLimitProgressFromPresetCategories(
            deduped,
            now,
            false,
            effectiveReviewedCategoryByTxId,
          );
    final effectiveBudgetProgressYear = budgetProgressYear.isNotEmpty
        ? budgetProgressYear
        : BudgetService.instance.buildZeroLimitProgressFromPresetCategories(
            deduped,
            now,
            true,
            effectiveReviewedCategoryByTxId,
          );
    final effectiveBudgetProgressAll = BudgetService.instance
        .buildZeroLimitProgressFromPresetCategoriesAllTime(
          deduped,
          now,
          effectiveReviewedCategoryByTxId,
        );

    return SyncResult(
      transactions: deduped,
      subscriptions: dbSubscriptions,
      budgetProgress: effectiveBudgetProgress,
      budgetProgressYear: effectiveBudgetProgressYear,
      budgetProgressAll: effectiveBudgetProgressAll,
      budgetLimitsByMonth: BudgetService.limitsByMonth(raw.yearBudgetRows),
      categoryOptions: userCategories,
      accountOptions: accountOptions,
      stats: DashboardStats(
        totalBalance: totalBalance,
        monthlyIncome: monthlyIncome,
        monthlyExpenses: monthlyExpenses,
        netThisMonth: monthlyIncome - monthlyExpenses,
      ),
      hasData:
          deduped.isNotEmpty ||
          totalBalance > 0 ||
          effectiveBudgetProgress.isNotEmpty ||
          effectiveBudgetProgressYear.isNotEmpty ||
          dbSubscriptions.isNotEmpty,
      autoReviewedCategoryByTxId: autoReviewedCategoryByTxId,
      autoLowConfidenceReviewTxIds: autoLowConfidenceReviewTxIds,
      ruleCategoryByTxId: ruleCategoryByTxId,
      decisions: decisions,
    );
  }
}
