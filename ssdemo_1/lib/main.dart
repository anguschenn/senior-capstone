// Core Flutter Material UI widgets and app structure.
import 'package:flutter/material.dart';
// Loads local environment variables from the app's .env file.
import 'package:flutter_dotenv/flutter_dotenv.dart';
// Calls the local Python backend over HTTP.
import 'package:http/http.dart' as http;
// Connects the Flutter app to Supabase for reads and writes.
import 'package:supabase_flutter/supabase_flutter.dart';

import 'constants/app_constants.dart';
import 'models/app_models.dart';
import 'pages/budget_page.dart';
import 'pages/cash_flow_page.dart';
import 'pages/home_page.dart';
import 'pages/subscriptions_page.dart';
import 'pages/transactions_page.dart';
import 'utils/app_helpers.dart';
import 'widgets/dashboard_widgets.dart';

// Fallback backend address for local development when BACKEND_URL is not set.
const _defaultBackendUrl = 'http://localhost:8000';

// ---------------------------------------------------------------------------
// App bootstrap and top-level configuration
// ---------------------------------------------------------------------------

// App entry point
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // Load app configuration from ssdemo_1/.env before any service starts.
  await dotenv.load(fileName: '.env');
  final supabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
  final supabaseKey = dotenv.env['SUPABASE_KEY'] ?? '';
  final demoUserId = dotenv.env['DEMO_USER_ID'] ?? '';
  final backendApiKey = dotenv.env['BACKEND_API_KEY'] ?? '';
  if (supabaseUrl.isEmpty || supabaseKey.isEmpty) {
    throw StateError(
      'Missing SUPABASE_URL or SUPABASE_KEY. '
      'Set them in ssdemo_1/.env.',
    );
  }
  if (demoUserId.isEmpty || backendApiKey.isEmpty) {
    throw StateError(
      'Missing DEMO_USER_ID or BACKEND_API_KEY. '
      'Set them in ssdemo_1/.env.',
    );
  }
  // Initialize the shared Supabase client used throughout the app.
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseKey,
  );
  runApp(const SmartSpendApp());
}

// Root app widget.
class SmartSpendApp extends StatelessWidget {
  const SmartSpendApp({super.key});

  @override
  Widget build(BuildContext context) {
    // App configuration
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SmartSpend',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      ),
      home: const MainScreen(),
    );
  }
}

// ---------------------------------------------------------------------------
// Main shell: owns live app state, sync actions, and tab routing
// ---------------------------------------------------------------------------

// Main screen with bottom navigation
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  // Live state shared across all tabs after sync/refresh.
  late final Uri _transactionsApiUri;
  late final Uri _aiChatApiUri;
  late final String _demoUserId;
  late final String _backendApiKey;
  int index = 0;
  bool syncing = false;
  String syncStatus = 'No data loaded yet';
  List<AppTransaction> liveTransactions = const [];
  List<DetectedSubscription> liveSubscriptions = const [];
  List<BudgetCategoryProgress> liveBudgetProgress = const [];
  List<BudgetCategoryProgress> liveBudgetProgressYear = const [];
  List<BudgetCategoryProgress> liveBudgetProgressAll = const [];
  List<CategoryOption> liveCategoryOptions = const [];
  List<AccountOption> liveAccountOptions = const [];
  Map<String, String> reviewedCategoryByTxId = const {};
  Set<String> confirmedReviewTxIds = const {};
  String selectedAccountId = kAllAccountsId;
  DashboardStats liveStats = const DashboardStats(
    totalBalance: 0,
    monthlyIncome: 0,
    monthlyExpenses: 0,
    netThisMonth: 0,
  );

  @override
  void initState() {
    super.initState();
    // Build the backend endpoint once so sync requests all use the same base URL.
    final backendUrl = dotenv.env['BACKEND_URL'] ?? _defaultBackendUrl;
    _demoUserId = dotenv.env['DEMO_USER_ID'] ?? '';
    _backendApiKey = dotenv.env['BACKEND_API_KEY'] ?? '';
    _transactionsApiUri = Uri.parse('$backendUrl/api/transactions');
    _aiChatApiUri = Uri.parse('$backendUrl/api/ai/chat');
  }

  // Refreshes UI state from Supabase only; does not call the Python sync endpoint.
  Future<void> _refreshLiveDataOnly() async {
    if (syncing) return;
    setState(() {
      syncing = true;
      syncStatus = 'Refreshing from DB...';
    });
    try {
      final replaced = await _refreshFromSupabase();
      if (!mounted) return;
      setState(() {
        syncStatus = replaced
            ? 'Connected: using database data'
            : 'No DB data yet';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        syncStatus = 'Refresh failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          syncing = false;
        });
      }
    }
  }

  // Clears only the in-memory UI state for the current app session.
  void _clearLiveData() {
    setState(() {
      liveTransactions = const [];
      liveSubscriptions = const [];
      liveBudgetProgress = const [];
      liveBudgetProgressYear = const [];
      liveBudgetProgressAll = const [];
      liveCategoryOptions = const [];
      liveAccountOptions = const [];
      reviewedCategoryByTxId = const {};
      confirmedReviewTxIds = const {};
      selectedAccountId = kAllAccountsId;
      liveStats = const DashboardStats(
        totalBalance: 0,
        monthlyIncome: 0,
        monthlyExpenses: 0,
        netThisMonth: 0,
      );
      syncStatus = 'Live data cleared';
    });
  }

  String _monthKey(DateTime date) =>
      '${date.year}-${date.month.toString().padLeft(2, '0')}';

  // -------------------------------------------------------------------------
  // Supabase-backed data preparation and synchronization helpers
  // -------------------------------------------------------------------------

  // Ensures a base set of categories exists for budget rendering and editing.
  Future<List<CategoryOption>> _ensureBaseCategories() async {
    try {
      final rows = await Supabase.instance.client
          .from('categories')
          .select('id,name,user_id')
          .or('user_id.eq.$_demoUserId,user_id.is.null');
      return (rows as List)
          .whereType<Map<String, dynamic>>()
          .map((r) => CategoryOption(id: '${r['id']}', name: '${r['name']}'))
          .where((c) => c.id.isNotEmpty && c.name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  // Seeds a default monthly budget for categories that do not yet have one.
  Future<void> _initializeBudgetsTo500(
    List<CategoryOption> categories,
    String monthYear,
  ) async {
    if (categories.isEmpty) return;
    try {
      final rows = await Supabase.instance.client
          .from('budgets')
          .select('id,category_id')
          .eq('user_id', _demoUserId)
          .eq('month_year', monthYear);
      final existing = (rows as List).whereType<Map<String, dynamic>>().toList();
      final hasBudgetByCategory = <String>{};

      for (final row in existing) {
        final categoryId = (row['category_id'] as String?)?.trim();
        if (categoryId == null || categoryId.isEmpty) {
          continue;
        }
        hasBudgetByCategory.add(categoryId);
      }

      // Seed missing monthly budgets at 500. Keep existing edited limits.
      for (final c in categories) {
        if (hasBudgetByCategory.contains(c.id)) continue;
        await Supabase.instance.client.from('budgets').insert({
          'user_id': _demoUserId,
          'category_id': c.id,
          'monthly_limit': 500,
          'rollover_amount': 0,
          'month_year': monthYear,
        });
      }
    } catch (_) {
      // If RLS blocks writes for publishable key, continue with read-only mode.
    }
  }

  // Updates a single budget limit, handling both DB-backed and local fallback budgets.
  Future<void> _updateBudgetLimit(String budgetId, double monthlyLimit) async {
    if (monthlyLimit <= 0) return;
    // Local preset budgets (fallback when DB budgets are unavailable/RLS blocked)
    if (budgetId.startsWith('preset_')) {
      setState(() {
        liveBudgetProgress = liveBudgetProgress
            .map(
              (b) => b.budgetId == budgetId
                  ? BudgetCategoryProgress(
                      budgetId: b.budgetId,
                      categoryId: b.categoryId,
                      title: b.title,
                      spent: b.spent,
                      limit: monthlyLimit,
                    )
                  : b,
            )
            .toList();
      });
      return;
    }
    await Supabase.instance.client
        .from('budgets')
        .update({'monthly_limit': monthlyLimit})
        .eq('id', budgetId)
        .eq('user_id', _demoUserId);
    await _refreshLiveDataOnly();
  }

  // Triggers the backend Plaid sync, then reloads Supabase-backed UI data.
  Future<void> _connectPlaidAndPullData() async {
    if (syncing) return;
    setState(() {
      syncing = true;
      syncStatus = 'Syncing...';
    });

    try {
      // Best-effort backend trigger; app still works with direct Supabase reads if this fails.
      await http
          .get(
            _transactionsApiUri,
            headers: {'x-api-key': _backendApiKey},
          )
          .timeout(const Duration(seconds: 4));
    } catch (_) {}

    try {
      final replaced = await _refreshFromSupabase();
      if (!mounted) return;
      setState(() {
        syncStatus = replaced ? 'Connected: using database data' : 'No DB data found';
      });
    } catch (e) {
      if (!mounted) return;
      setState(() {
        syncStatus = 'Sync failed: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          syncing = false;
        });
      }
    }
  }

  // Central load path for accounts, transactions, subscriptions, and budgets.
  Future<bool> _refreshFromSupabase() async {
    final now = DateTime.now();
    final monthYear = _monthKey(now);

    final accountsRows = await Supabase.instance.client
        .from('accounts')
        .select('current_balance,account_type,subtype,user_id,plaid_account_id,name,mask')
        .eq('user_id', _demoUserId);

    final userCategories = await _ensureBaseCategories();
    await _initializeBudgetsTo500(userCategories, monthYear);

    final budgetRows = await Supabase.instance.client
        .from('budgets')
        .select('id,category_id,monthly_limit,month_year')
        .eq('user_id', _demoUserId)
        .eq('month_year', monthYear);

    final subscriptionRows = await Supabase.instance.client
        .from('subscriptions')
        .select('id,merchant_name,amount,next_charge_date,frequency')
        .eq('user_id', _demoUserId)
        .order('next_charge_date', ascending: true)
        .limit(500);

    final rows = await Supabase.instance.client
        .from('transactions')
        .select(
          'plaid_transaction_id,plaid_account_id,merchant_name,name,category,pfc_primary,pfc_detailed,pfc_confidence,date,amount,pending,user_id',
        )
        .eq('user_id', _demoUserId)
        .order('date', ascending: false)
        .limit(1000);

    // Parse and de-duplicate transactions because sync/import flows can create repeats.
    final txRows = (rows as List).whereType<Map<String, dynamic>>().toList();
    final parsed = txRows
        .whereType<Map<String, dynamic>>()
        .map(AppTransaction.fromMap)
        .toList();
    final deduped = <AppTransaction>[];
    final seen = <String>{};
    for (final tx in parsed) {
      if (seen.add(tx.dedupeKey)) {
        deduped.add(tx);
      }
    }
    // Build subscription cards from DB rows and remove obvious duplicates.
    final dbSubscriptions = <DetectedSubscription>[];
    final subSeen = <String>{};
    for (final row in (subscriptionRows as List).whereType<Map<String, dynamic>>()) {
      final merchant = (row['merchant_name'] as String?)?.trim();
      if (merchant == null || merchant.isEmpty) continue;
      final rawAmount = row['amount'];
      final amount = rawAmount is num
          ? rawAmount.toDouble()
          : double.tryParse('$rawAmount') ?? 0;
      final rawDate = (row['next_charge_date'] as String?) ?? '';
      final nextDate = DateTime.tryParse(rawDate);
      if (nextDate == null) continue;
      final frequency = ((row['frequency'] as String?)?.trim().isNotEmpty ?? false)
          ? (row['frequency'] as String).trim()
          : 'monthly';
      final dedupeKey =
          '${merchant.toLowerCase()}|${amount.toStringAsFixed(2)}|${nextDate.toIso8601String().split("T").first}';
      if (!subSeen.add(dedupeKey)) continue;
      dbSubscriptions.add(
        DetectedSubscription(
          merchant: merchant,
          amount: amount.abs(),
          nextChargeDate: nextDate,
          frequency: frequency,
        ),
      );
    }

    // Compute dashboard summary totals for the active month.
    double monthlyIncome = 0;
    double monthlyExpenses = 0;
    for (final tx in deduped) {
      if (tx.date.year == now.year && tx.date.month == now.month) {
        if (tx.amount < 0) {
          monthlyIncome += tx.amount.abs();
        } else {
          monthlyExpenses += tx.amount;
        }
      }
    }

    double totalBalance = 0;
    for (final row in (accountsRows as List).whereType<Map<String, dynamic>>()) {
      final raw = row['current_balance'];
      final accountType = '${row['account_type'] ?? ''}';
      final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
      totalBalance += netWorthContribution(
        balance: parsed,
        accountType: accountType,
      );
    }

    // Build account filter options and attach transaction counts per account.
    final txCountByAccount = <String, int>{};
    for (final tx in deduped) {
      if (tx.accountId.isEmpty) continue;
      txCountByAccount[tx.accountId] = (txCountByAccount[tx.accountId] ?? 0) + 1;
    }
    final accountOptions = <AccountOption>[];
    final seenAccountIds = <String>{};
    for (final row in (accountsRows as List).whereType<Map<String, dynamic>>()) {
      final plaidAccountId = (row['plaid_account_id'] as String?)?.trim() ?? '';
      if (plaidAccountId.isEmpty || !seenAccountIds.add(plaidAccountId)) continue;
      final name = ((row['name'] as String?)?.trim().isNotEmpty ?? false)
          ? (row['name'] as String).trim()
          : 'Account';
      final mask = (row['mask'] as String?)?.trim() ?? '';
      final ending = mask.isNotEmpty
          ? mask
          : (plaidAccountId.length >= 4
                ? plaidAccountId.substring(plaidAccountId.length - 4)
                : plaidAccountId);
      accountOptions.add(
        AccountOption(
          accountId: plaidAccountId,
          label: '$name ••••$ending',
          ending: ending,
          balance: (() {
            final raw = row['current_balance'];
            final accountType = '${row['account_type'] ?? ''}';
            final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
            return netWorthContribution(
              balance: parsed,
              accountType: accountType,
            );
          })(),
          txCount: txCountByAccount[plaidAccountId] ?? 0,
        ),
      );
    }
    final optionsWithTx = accountOptions.where((a) => a.txCount > 0).toList();
    final effectiveAccountOptions = optionsWithTx.isNotEmpty ? optionsWithTx : accountOptions;
    effectiveAccountOptions.sort((a, b) => a.label.compareTo(b.label));

    final categoryMap = {for (final c in userCategories) c.id: c.name};

    // Prefer DB-backed budgets when present; otherwise fall back to preset buckets.
    final budgetRowsList = (budgetRows as List).whereType<Map<String, dynamic>>().toList();
    final budgetProgress = _buildBudgetProgressFromRows(
      budgetRows: budgetRowsList,
      categoryMap: categoryMap,
      txRows: txRows,
      now: now,
      yearly: false,
    );
    final budgetProgressYear = _buildBudgetProgressFromRows(
      budgetRows: budgetRowsList,
      categoryMap: categoryMap,
      txRows: txRows,
      now: now,
      yearly: true,
    );
    final effectiveBudgetProgress = budgetProgress.isNotEmpty
        ? budgetProgress
        : _presetBudgetProgress(deduped, now, false);
    final effectiveBudgetProgressYear = budgetProgressYear.isNotEmpty
        ? budgetProgressYear
        : _presetBudgetProgress(deduped, now, true);
    final effectiveBudgetProgressAll = _presetBudgetProgressAllTime(deduped, now);
    final txIdSet = deduped.map((e) => e.id).toSet();

    if (!mounted) return false;
    setState(() {
      liveTransactions = deduped;
      liveSubscriptions = dbSubscriptions;
      liveBudgetProgress = effectiveBudgetProgress;
      liveBudgetProgressYear = effectiveBudgetProgressYear;
      liveBudgetProgressAll = effectiveBudgetProgressAll;
      liveCategoryOptions = userCategories;
      liveAccountOptions = effectiveAccountOptions;
      reviewedCategoryByTxId = {
        for (final entry in reviewedCategoryByTxId.entries)
          if (txIdSet.contains(entry.key)) entry.key: entry.value,
      };
      confirmedReviewTxIds = {
        for (final txId in confirmedReviewTxIds)
          if (txIdSet.contains(txId)) txId,
      };
      if (selectedAccountId != kAllAccountsId &&
          !effectiveAccountOptions.any((a) => a.accountId == selectedAccountId)) {
        selectedAccountId = kAllAccountsId;
      }
      liveStats = DashboardStats(
        totalBalance: totalBalance,
        monthlyIncome: monthlyIncome,
        monthlyExpenses: monthlyExpenses,
        netThisMonth: monthlyIncome - monthlyExpenses,
      );
    });
    return deduped.isNotEmpty ||
        totalBalance > 0 ||
        effectiveBudgetProgress.isNotEmpty ||
        effectiveBudgetProgressYear.isNotEmpty ||
        dbSubscriptions.isNotEmpty;
  }

  // Stores a user-selected override for a transaction's budget category.
  void _onTransactionCategorySelected(AppTransaction tx, String category) {
    if (tx.amount < 0) {
      return;
    }
    final reviewedNext = Map<String, String>.from(reviewedCategoryByTxId);
    reviewedNext[tx.id] = category;
    final confirmedNext = Set<String>.from(confirmedReviewTxIds);
    // Any user re-tag requires explicit review confirmation.
    confirmedNext.remove(tx.id);
    setState(() {
      reviewedCategoryByTxId = reviewedNext;
      confirmedReviewTxIds = confirmedNext;
      _rebuildBudgetProgressFromCurrentTransactions();
    });
  }

  // Marks a reviewed transaction as confirmed so it leaves the review queue.
  void _confirmReviewedCategory(String txId) {
    final confirmedNext = Set<String>.from(confirmedReviewTxIds)..add(txId);
    setState(() {
      confirmedReviewTxIds = confirmedNext;
    });
  }

  // Rebuilds derived budget views after local category overrides.
  void _rebuildBudgetProgressFromCurrentTransactions() {
    final now = DateTime.now();
    liveBudgetProgress = _presetBudgetProgress(liveTransactions, now, false);
    liveBudgetProgressYear = _presetBudgetProgress(liveTransactions, now, true);
    liveBudgetProgressAll = _presetBudgetProgressAllTime(liveTransactions, now);
  }

  // Resolves a transaction into a budget bucket, preferring manual review overrides.
  String _budgetBucketFor(AppTransaction tx) {
    final reviewed = reviewedCategoryByTxId[tx.id];
    if (reviewed != null && reviewed.isNotEmpty) {
      return reviewed;
    }
    return _budgetBucketFromPfc(
      pfcDetailed: tx.category,
      pfcPrimary: tx.primaryCategory,
    );
  }

  // Same bucket mapping as above, but for raw rows before model conversion.
  String _budgetBucketForRawTransaction(Map<String, dynamic> row) {
    final txId = ((row['plaid_transaction_id'] as String?) ?? '').trim();
    final reviewed = reviewedCategoryByTxId[txId];
    if (reviewed != null && reviewed.isNotEmpty) {
      return reviewed;
    }
    return _budgetBucketFromPfc(
      pfcDetailed: ((row['pfc_detailed'] as String?) ?? '').trim(),
      pfcPrimary: ((row['pfc_primary'] as String?) ?? '').trim(),
    );
  }

  // Small adapter to keep category-to-budget mapping centralized.
  String _budgetBucketFromPfc({
    required String pfcDetailed,
    required String pfcPrimary,
  }) {
    return budgetCategoryFromPfc(
      pfcDetailed: pfcDetailed,
      pfcPrimary: pfcPrimary,
    );
  }

  // Local fallback budget builder used when DB budgets are unavailable.
  List<BudgetCategoryProgress> _presetBudgetProgress(
    List<AppTransaction> txs,
    DateTime now,
    bool yearly,
  ) {
    const preset = kPresetBudgetCategories;
    final spentMap = <String, double>{for (final p in preset) p: 0};
    for (final tx in txs) {
      if (tx.amount <= 0) continue;
      if (yearly) {
        if (tx.date.year != now.year) continue;
      } else {
        if (tx.date.year != now.year || tx.date.month != now.month) continue;
      }
      final bucket = _budgetBucketFor(tx);
      spentMap[bucket] = (spentMap[bucket] ?? 0) + tx.amount;
    }
    return preset
        .map(
          (name) => BudgetCategoryProgress(
            budgetId: 'preset_${name.toLowerCase()}',
            categoryId: 'preset_${name.toLowerCase()}',
            title: name,
            spent: spentMap[name] ?? 0,
            limit: yearly ? 500 * 12 : 500,
          ),
        )
        .toList();
  }

  // All-time fallback budget builder scaled by the number of covered months.
  List<BudgetCategoryProgress> _presetBudgetProgressAllTime(
    List<AppTransaction> txs,
    DateTime now,
  ) {
    const preset = kPresetBudgetCategories;
    final spentMap = <String, double>{for (final p in preset) p: 0};
    for (final tx in txs) {
      if (tx.amount <= 0) continue;
      final bucket = _budgetBucketFor(tx);
      spentMap[bucket] = (spentMap[bucket] ?? 0) + tx.amount;
    }

    int coveredMonths = 1;
    if (txs.isNotEmpty) {
      final earliest = txs
          .map((e) => DateTime(e.date.year, e.date.month, 1))
          .reduce((a, b) => a.isBefore(b) ? a : b);
      coveredMonths = (now.year - earliest.year) * 12 + (now.month - earliest.month) + 1;
      if (coveredMonths < 1) coveredMonths = 1;
    }

    return preset
        .map(
          (name) => BudgetCategoryProgress(
            budgetId: 'preset_${name.toLowerCase()}',
            categoryId: 'preset_${name.toLowerCase()}',
            title: name,
            spent: spentMap[name] ?? 0,
            limit: 500.0 * coveredMonths,
          ),
        )
        .toList();
  }

  // Converts DB budget rows plus transaction rows into render-ready progress cards.
  List<BudgetCategoryProgress> _buildBudgetProgressFromRows({
    required List<Map<String, dynamic>> budgetRows,
    required Map<String, String> categoryMap,
    required List<Map<String, dynamic>> txRows,
    required DateTime now,
    required bool yearly,
  }) {
    final spentByCategoryName = <String, double>{};
    for (final row in txRows) {
      final rawDate = (row['date'] as String?) ?? '';
      final txDate = DateTime.tryParse(rawDate);
      if (txDate == null) continue;
      if (yearly) {
        if (txDate.year != now.year) continue;
      } else {
        if (txDate.year != now.year || txDate.month != now.month) continue;
      }
      final rawAmount = row['amount'];
      final amount = rawAmount is num ? rawAmount.toDouble() : double.tryParse('$rawAmount') ?? 0;
      if (amount <= 0) continue;
      final bucket = _budgetBucketForRawTransaction(row);
      final bucketKey = normalizeCategoryKey(bucket);
      spentByCategoryName[bucketKey] = (spentByCategoryName[bucketKey] ?? 0) + amount;
    }

    final progress = <BudgetCategoryProgress>[];
    for (final row in budgetRows) {
      final budgetId = (row['id'] as String?)?.trim();
      final categoryId = (row['category_id'] as String?)?.trim();
      if (budgetId == null || budgetId.isEmpty || categoryId == null || categoryId.isEmpty) continue;
      final rawLimit = row['monthly_limit'];
      final monthlyLimit = rawLimit is num ? rawLimit.toDouble() : double.tryParse('$rawLimit') ?? 0;
      if (monthlyLimit <= 0) continue;
      final title = categoryMap[categoryId] ?? 'Unknown';
      final titleKey = normalizeCategoryKey(title);
      progress.add(
        BudgetCategoryProgress(
          budgetId: budgetId,
          categoryId: categoryId,
          title: title,
          spent: spentByCategoryName[titleKey] ?? 0,
          limit: yearly ? monthlyLimit * 12 : monthlyLimit,
        ),
      );
    }
    progress.sort((a, b) => b.ratio.compareTo(a.ratio));
    return progress;
  }

  // Builds a compact, token-efficient snapshot sent to AI chat endpoint.
  Map<String, dynamic> _buildAiSpendingSummary({
    required List<AppTransaction> transactions,
    required List<BudgetCategoryProgress> budgetProgress,
    required DashboardStats stats,
    required String selectedAccountId,
  }) {
    final now = DateTime.now();
    final cutoff = now.subtract(const Duration(days: 30));
    double income30d = 0;
    double expenses30d = 0;
    int txCount30d = 0;
    int expenseTxCount30d = 0;
    final categoryTotals = <String, double>{};
    final recent = <Map<String, dynamic>>[];

    for (final tx in transactions) {
      if (tx.date.isBefore(cutoff)) continue;
      txCount30d += 1;
      if (tx.amount < 0) {
        income30d += tx.amount.abs();
      } else {
        expenses30d += tx.amount;
        expenseTxCount30d += 1;
        categoryTotals[tx.category] = (categoryTotals[tx.category] ?? 0) + tx.amount;
      }
    }

    for (final tx in transactions.take(3)) {
      recent.add({
        'date': tx.date.toIso8601String().split('T').first,
        'name': tx.name,
        'amount': tx.amount,
        'category': tx.category,
      });
    }

    final topCategories = categoryTotals.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    final topCategoryPayload = topCategories
        .take(5)
        .map(
          (entry) => {
            'category': entry.key,
            'amount': entry.value,
          },
        )
        .toList();

    final budgetAlerts = budgetProgress
        .where((b) => b.ratio >= 1)
        .take(3)
        .map(
          (b) => {
            'category': b.title,
            'spent': b.spent,
            'limit': b.limit,
            'ratio': b.ratio,
          },
        )
        .toList();

    return {
      'version': 1,
      'generated_at': now.toIso8601String(),
      'scope': selectedAccountId == kAllAccountsId ? 'all_accounts' : 'single_account',
      'window_days': 30,
      'totals': {
        'income_30d': income30d,
        'expenses_30d': expenses30d,
        'net_30d': income30d - expenses30d,
        'tx_count_30d': txCount30d,
        'expense_tx_count_30d': expenseTxCount30d,
        'income_month': stats.monthlyIncome,
        'expenses_month': stats.monthlyExpenses,
        'net_month': stats.netThisMonth,
      },
      'top_expense_categories': topCategoryPayload,
      'recent_transactions': recent,
      'budget_alerts': budgetAlerts,
    };
  }

  @override
  Widget build(BuildContext context) {
    // Each page receives a filtered slice of the same shared live state.
    final visibleTransactions = selectedAccountId == kAllAccountsId
        ? liveTransactions
        : liveTransactions.where((tx) => tx.accountId == selectedAccountId).toList();
    final visibleSubscriptions = liveSubscriptions;
    final now = DateTime.now();
    final visibleBudgetProgress = selectedAccountId == kAllAccountsId
        ? liveBudgetProgress
        : _presetBudgetProgress(visibleTransactions, now, false);
    final visibleBudgetProgressYear = selectedAccountId == kAllAccountsId
        ? liveBudgetProgressYear
        : _presetBudgetProgress(visibleTransactions, now, true);
    final visibleBudgetProgressAll = selectedAccountId == kAllAccountsId
        ? liveBudgetProgressAll
        : _presetBudgetProgressAllTime(visibleTransactions, now);
    double visibleIncome = 0;
    double visibleExpenses = 0;
    for (final tx in visibleTransactions) {
      if (tx.date.year == now.year && tx.date.month == now.month) {
        if (tx.amount < 0) {
          visibleIncome += tx.amount.abs();
        } else {
          visibleExpenses += tx.amount;
        }
      }
    }
    final selectedBalance = selectedAccountId == kAllAccountsId
        ? liveStats.totalBalance
        : (() {
            for (final account in liveAccountOptions) {
              if (account.accountId == selectedAccountId) return account.balance;
            }
            return 0.0;
          })();
    final visibleStats = DashboardStats(
      totalBalance: selectedBalance,
      monthlyIncome: visibleIncome,
      monthlyExpenses: visibleExpenses,
      netThisMonth: visibleIncome - visibleExpenses,
    );

    final body = switch (index) {
      0 => HomePage(
          transactions: visibleTransactions.take(3).toList(),
          lowConfidenceTransactions:
              visibleTransactions,
          subscriptions: visibleSubscriptions.take(3).toList(),
          monthlySubscriptionTotal: visibleSubscriptions.fold<double>(
            0,
            (sum, item) => sum + item.amount,
          ),
          stats: visibleStats,
          syncing: syncing,
          syncStatus: syncStatus,
          onConnectPlaid: _connectPlaidAndPullData,
          onRefreshLiveData: _refreshLiveDataOnly,
          onClearLiveData: _clearLiveData,
          accountOptions: liveAccountOptions,
          selectedAccountId: selectedAccountId,
          reviewedCategoryByTxId: reviewedCategoryByTxId,
          confirmedReviewTxIds: confirmedReviewTxIds,
          onAccountChanged: (accountId) {
            setState(() => selectedAccountId = accountId);
          },
          onTransactionCategorySelected: _onTransactionCategorySelected,
          onReviewConfirm: _confirmReviewedCategory,
        ),
      1 => CashFlowPage(
          transactions: visibleTransactions,
        ),
      2 => TransactionsPage(
          transactions: visibleTransactions,
          accountOptions: liveAccountOptions,
          reviewedCategoryByTxId: reviewedCategoryByTxId,
          onTransactionCategorySelected: _onTransactionCategorySelected,
        ),
      3 => BudgetPage(
          stats: visibleStats,
          budgetProgress: visibleBudgetProgress,
          budgetProgressYear: visibleBudgetProgressYear,
          budgetProgressAll: visibleBudgetProgressAll,
          onUpdateBudgetLimit: _updateBudgetLimit,
        ),
      _ => SubscriptionsPage(subscriptions: visibleSubscriptions),
    };

    // The floating AI button sits above the tab scaffold and opens a placeholder panel.
    return Stack(
      children: [
        Scaffold(
          body: body,
          bottomNavigationBar: NavigationBar(
            selectedIndex: index,
            onDestinationSelected: (i) => setState(() => index = i),
            destinations: const [
              NavigationDestination(icon: Icon(Icons.home_outlined), label: 'Home'),
              NavigationDestination(icon: Icon(Icons.bar_chart), label: 'Flow'),
              NavigationDestination(icon: Icon(Icons.receipt_long), label: 'Activity'),
              NavigationDestination(icon: Icon(Icons.pie_chart_outline), label: 'Budget'),
              NavigationDestination(icon: Icon(Icons.subscriptions_outlined), label: 'Subs'),
            ],
          ),
        ),
        Positioned(
          right: 18,
          bottom: 96,
          child: AIAssistantButton(
            onTap: () {
              showModalBottomSheet(
                context: context,
                isScrollControlled: true,
                backgroundColor: Colors.transparent,
                builder: (context) => AIAssistantPanel(
                  chatApiUri: _aiChatApiUri,
                  apiKey: _backendApiKey,
                  spendingSummary: _buildAiSpendingSummary(
                    transactions: visibleTransactions,
                    budgetProgress: visibleBudgetProgress,
                    stats: visibleStats,
                    selectedAccountId: selectedAccountId,
                  ),
                ),
              );
            },
          ),
        ),
      ],
    );
  }
}
