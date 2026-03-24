import 'dart:math' as math;
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_dotenv/flutter_dotenv.dart';
import 'package:http/http.dart' as http;
import 'package:supabase_flutter/supabase_flutter.dart';

// App entry point
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await dotenv.load(fileName: '.env');
  } catch (_) {
    // Optional local env file; startup can still use shell env or dart-define.
  }
  final envSupabaseUrl = kIsWeb ? '' : (Platform.environment['SUPABASE_URL'] ?? '');
  final envSupabaseKey = kIsWeb ? '' : (Platform.environment['SUPABASE_KEY'] ?? '');
  const defineSupabaseUrl = String.fromEnvironment('SUPABASE_URL');
  const defineSupabaseKey = String.fromEnvironment('SUPABASE_KEY');
  final dotenvSupabaseUrl = dotenv.env['SUPABASE_URL'] ?? '';
  final dotenvSupabaseKey = dotenv.env['SUPABASE_KEY'] ?? '';
  final supabaseUrl = envSupabaseUrl.isNotEmpty
      ? envSupabaseUrl
      : (defineSupabaseUrl.isNotEmpty ? defineSupabaseUrl : dotenvSupabaseUrl);
  final supabaseKey = envSupabaseKey.isNotEmpty
      ? envSupabaseKey
      : (defineSupabaseKey.isNotEmpty ? defineSupabaseKey : dotenvSupabaseKey);
  if (supabaseUrl.isEmpty || supabaseKey.isEmpty) {
    throw StateError(
      'Missing SUPABASE_URL or SUPABASE_KEY. '
      'Set them in ssdemo_1/.env, shell env vars SUPABASE_URL/SUPABASE_KEY, '
      'or run with --dart-define=SUPABASE_URL=... --dart-define=SUPABASE_KEY=...',
    );
  }
  await Supabase.initialize(
    url: supabaseUrl,
    anonKey: supabaseKey,
  );
  runApp(const SmartSpendApp());
}

// Root app widget
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

class CategoryOption {
  const CategoryOption({
    required this.id,
    required this.name,
  });

  final String id;
  final String name;
}

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

const String kDemoUserId = 'e22c81ff-c63d-4f42-a67b-e6812ffed2a3';
const String kAllAccountsId = '__all_accounts__';
const List<String> kReviewCategories = ['Food', 'Transport', 'Entertainment', 'Shopping', 'Other'];

String formatMoney(double amount, {bool signed = true}) {
  final absAmount = amount.abs().toStringAsFixed(2);
  if (!signed) {
    return '\$$absAmount';
  }
  final isIncome = amount < 0;
  return '${isIncome ? '+' : '-'} \$$absAmount';
}

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
    'Dec'
  ];
  final now = DateTime.now();
  final showYear = alwaysShowYear || value.year != now.year;
  return showYear
      ? '${months[value.month - 1]} ${value.day}, ${value.year}'
      : '${months[value.month - 1]} ${value.day}';
}

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

String normalizeMerchant(String raw) {
  return raw
      .toLowerCase()
      .replaceAll(RegExp(r'[^a-z0-9 ]'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ')
      .trim();
}

String normalizeCategoryKey(String raw) {
  return raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');
}

String accountEndingForId(String accountId, List<AccountOption> accounts) {
  for (final account in accounts) {
    if (account.accountId == accountId) return account.ending;
  }
  if (accountId.length >= 4) return accountId.substring(accountId.length - 4);
  return '----';
}

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

// Main screen with bottom navigation
class MainScreen extends StatefulWidget {
  const MainScreen({super.key});

  @override
  State<MainScreen> createState() => _MainScreenState();
}

class _MainScreenState extends State<MainScreen> {
  int index = 0;
  bool syncing = false;
  String syncStatus = 'No data loaded yet';
  List<AppTransaction> liveTransactions = const [];
  List<DetectedSubscription> liveSubscriptions = const [];
  List<MonthlyFlowPoint> liveFlowSeries = const [];
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

  void _clearLiveData() {
    setState(() {
      liveTransactions = const [];
      liveSubscriptions = const [];
      liveFlowSeries = const [];
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

  Future<List<CategoryOption>> _ensureBaseCategories() async {
    try {
      final rows = await Supabase.instance.client
          .from('categories')
          .select('id,name,user_id')
          .or('user_id.eq.$kDemoUserId,user_id.is.null');
      return (rows as List)
          .whereType<Map<String, dynamic>>()
          .map((r) => CategoryOption(id: '${r['id']}', name: '${r['name']}'))
          .where((c) => c.id.isNotEmpty && c.name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  Future<void> _initializeBudgetsTo500(
    List<CategoryOption> categories,
    String monthYear,
  ) async {
    if (categories.isEmpty) return;
    try {
      final rows = await Supabase.instance.client
          .from('budgets')
          .select('id,category_id')
          .eq('user_id', kDemoUserId)
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
          'user_id': kDemoUserId,
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
        .eq('user_id', kDemoUserId);
    await _refreshLiveDataOnly();
  }

  Future<void> _connectPlaidAndPullData() async {
    if (syncing) return;
    setState(() {
      syncing = true;
      syncStatus = 'Syncing...';
    });

    try {
      // Best-effort backend trigger; app still works with direct Supabase reads if this fails.
      final uri = Uri.parse('http://localhost:8000/api/transactions');
      await http.get(uri).timeout(const Duration(seconds: 4));
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

  Future<bool> _refreshFromSupabase() async {
    final now = DateTime.now();
    final monthYear = _monthKey(now);

    final accountsRows = await Supabase.instance.client
        .from('accounts')
        .select('current_balance,account_type,subtype,user_id,plaid_account_id,name,mask')
        .eq('user_id', kDemoUserId);

    final userCategories = await _ensureBaseCategories();
    await _initializeBudgetsTo500(userCategories, monthYear);

    final budgetRows = await Supabase.instance.client
        .from('budgets')
        .select('id,category_id,monthly_limit,month_year')
        .eq('user_id', kDemoUserId)
        .eq('month_year', monthYear);

    final subscriptionRows = await Supabase.instance.client
        .from('subscriptions')
        .select('id,merchant_name,amount,next_charge_date,frequency')
        .eq('user_id', kDemoUserId)
        .order('next_charge_date', ascending: true)
        .limit(500);

    final rows = await Supabase.instance.client
        .from('transactions')
        .select(
          'plaid_transaction_id,plaid_account_id,merchant_name,name,category,pfc_primary,pfc_detailed,pfc_confidence,date,amount,pending,user_id',
        )
        .eq('user_id', kDemoUserId)
        .order('date', ascending: false)
        .limit(1000);

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
      final accountType = ('${row['account_type'] ?? ''}').toLowerCase();
      if (raw is num) {
        final value = raw.toDouble();
        if (accountType.contains('credit') || accountType.contains('loan')) {
          totalBalance -= value.abs();
        } else {
          totalBalance += value;
        }
      } else {
        final parsed = double.tryParse('$raw') ?? 0;
        if (accountType.contains('credit') || accountType.contains('loan')) {
          totalBalance -= parsed.abs();
        } else {
          totalBalance += parsed;
        }
      }
    }

    final flowSeries = _buildFlowSeries(deduped, now);
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
            final accountType = ('${row['account_type'] ?? ''}').toLowerCase();
            final parsed = raw is num ? raw.toDouble() : double.tryParse('$raw') ?? 0;
            if (accountType.contains('credit') || accountType.contains('loan')) {
              return -parsed.abs();
            }
            return parsed;
          })(),
          txCount: txCountByAccount[plaidAccountId] ?? 0,
        ),
      );
    }
    final optionsWithTx = accountOptions.where((a) => a.txCount > 0).toList();
    final effectiveAccountOptions = optionsWithTx.isNotEmpty ? optionsWithTx : accountOptions;
    effectiveAccountOptions.sort((a, b) => a.label.compareTo(b.label));

    final categoryMap = {for (final c in userCategories) c.id: c.name};

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
      liveFlowSeries = flowSeries;
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

  void _confirmReviewedCategory(String txId) {
    final confirmedNext = Set<String>.from(confirmedReviewTxIds)..add(txId);
    setState(() {
      confirmedReviewTxIds = confirmedNext;
    });
  }

  void _rebuildBudgetProgressFromCurrentTransactions() {
    final now = DateTime.now();
    liveBudgetProgress = _presetBudgetProgress(liveTransactions, now, false);
    liveBudgetProgressYear = _presetBudgetProgress(liveTransactions, now, true);
    liveBudgetProgressAll = _presetBudgetProgressAllTime(liveTransactions, now);
  }

  List<MonthlyFlowPoint> _buildFlowSeries(List<AppTransaction> txs, DateTime now) {
    const monthLabels = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    final series = <MonthlyFlowPoint>[];
    for (int offset = 4; offset >= 0; offset--) {
      final anchor = DateTime(now.year, now.month - offset, 1);
      double income = 0;
      double expenses = 0;
      for (final tx in txs) {
        if (tx.date.year == anchor.year && tx.date.month == anchor.month) {
          if (tx.amount < 0) {
            income += tx.amount.abs();
          } else {
            expenses += tx.amount;
          }
        }
      }
      series.add(
        MonthlyFlowPoint(
          label: "${monthLabels[anchor.month - 1]} '${(anchor.year % 100).toString().padLeft(2, '0')}",
          income: income,
          expenses: expenses,
        ),
      );
    }
    return series;
  }

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

  String _budgetBucketFromPfc({
    required String pfcDetailed,
    required String pfcPrimary,
  }) {
    return budgetCategoryFromPfc(
      pfcDetailed: pfcDetailed,
      pfcPrimary: pfcPrimary,
    );
  }

  List<BudgetCategoryProgress> _presetBudgetProgress(
    List<AppTransaction> txs,
    DateTime now,
    bool yearly,
  ) {
    const preset = ['Food', 'Transport', 'Shopping', 'Entertainment', 'Other'];
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

  List<BudgetCategoryProgress> _presetBudgetProgressAllTime(
    List<AppTransaction> txs,
    DateTime now,
  ) {
    const preset = ['Food', 'Transport', 'Shopping', 'Entertainment', 'Other'];
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

  @override
  Widget build(BuildContext context) {
    final visibleTransactions = selectedAccountId == kAllAccountsId
        ? liveTransactions
        : liveTransactions.where((tx) => tx.accountId == selectedAccountId).toList();
    final visibleSubscriptions = liveSubscriptions;
    final visibleFlowSeries = _buildFlowSeries(visibleTransactions, DateTime.now());
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
          flowSeries: visibleFlowSeries,
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
                backgroundColor: Colors.transparent,
                builder: (context) => const AIAssistantPanel(),
              );
            },
          ),
        ),
      ],
    );
  }
}

// Home dashboard page
class HomePage extends StatelessWidget {
  const HomePage({
    super.key,
    required this.transactions,
    required this.lowConfidenceTransactions,
    required this.subscriptions,
    required this.monthlySubscriptionTotal,
    required this.stats,
    required this.syncing,
    required this.syncStatus,
    required this.onConnectPlaid,
    required this.onRefreshLiveData,
    required this.onClearLiveData,
    required this.accountOptions,
    required this.selectedAccountId,
    required this.reviewedCategoryByTxId,
    required this.confirmedReviewTxIds,
    required this.onAccountChanged,
    required this.onTransactionCategorySelected,
    required this.onReviewConfirm,
  });

  final List<AppTransaction> transactions;
  final List<AppTransaction> lowConfidenceTransactions;
  final List<DetectedSubscription> subscriptions;
  final double monthlySubscriptionTotal;
  final DashboardStats stats;
  final bool syncing;
  final String syncStatus;
  final VoidCallback onConnectPlaid;
  final VoidCallback onRefreshLiveData;
  final VoidCallback onClearLiveData;
  final List<AccountOption> accountOptions;
  final String selectedAccountId;
  final Map<String, String> reviewedCategoryByTxId;
  final Set<String> confirmedReviewTxIds;
  final ValueChanged<String> onAccountChanged;
  final void Function(AppTransaction tx, String category) onTransactionCategorySelected;
  final void Function(String txId) onReviewConfirm;

  @override
  Widget build(BuildContext context) {
    final pendingReviewTransactions = lowConfidenceTransactions
        .where(
          (tx) =>
              !confirmedReviewTxIds.contains(tx.id) &&
              tx.amount > 0 &&
              (tx.confidence == 'low' || reviewedCategoryByTxId.containsKey(tx.id)),
        )
        .toList();
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            'SmartSpend',
            style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              FilledButton.icon(
                onPressed: syncing ? null : onConnectPlaid,
                icon: syncing
                    ? const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.link),
                label: Text(syncing ? 'Syncing' : 'Connect'),
              ),
              OutlinedButton(
                onPressed: syncing ? null : onRefreshLiveData,
                child: const Text('Refresh'),
              ),
              TextButton(
                onPressed: syncing ? null : onClearLiveData,
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(syncStatus, style: const TextStyle(color: Colors.black54)),
          const SizedBox(height: 12),
          Row(
            children: [
              const Text('Account', style: TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(width: 12),
              Expanded(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black12),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      isExpanded: true,
                      value: selectedAccountId,
                      items: [
                        const DropdownMenuItem<String>(
                          value: kAllAccountsId,
                          child: Text('All Accounts'),
                        ),
                        ...accountOptions.map(
                          (account) => DropdownMenuItem<String>(
                            value: account.accountId,
                            child: Text('${account.label} (${account.txCount})'),
                          ),
                        ),
                      ],
                      onChanged: syncing
                          ? null
                          : (value) {
                              if (value == null) return;
                              onAccountChanged(value);
                            },
                    ),
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text('Net Worth'),
          Text(
            formatMoney(stats.totalBalance, signed: false),
            style: const TextStyle(fontSize: 32, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 4),
          Text(
            'Net this month: ${stats.netThisMonth >= 0 ? '+ ' : '- '}\$${stats.netThisMonth.abs().toStringAsFixed(2)}',
            style: TextStyle(color: stats.netThisMonth >= 0 ? Colors.green : Colors.red),
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: SummaryCard(
                  title: 'Income',
                  value: formatMoney(stats.monthlyIncome, signed: false),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: SummaryCard(
                  title: 'Expenses',
                  value: formatMoney(stats.monthlyExpenses, signed: false),
                ),
              ),
            ],
          ),
          const SizedBox(height: 20),
          const Text('Recent Transactions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          if (transactions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No transactions yet. Tap Connect or Refresh.'),
            ),
          ...transactions.map(
            (tx) {
              final effectiveCategory = tx.amount < 0
                  ? 'Income'
                  : (reviewedCategoryByTxId[tx.id] ??
                        budgetCategoryFromPfc(
                          pfcDetailed: tx.category,
                          pfcPrimary: tx.primaryCategory,
                        ));
              final colorKey =
                  reviewedCategoryByTxId[tx.id] ?? effectiveCategory;
              return ListTile(
                leading: Icon(iconForTransaction(tx.category, tx.name)),
                title: Text(tx.name),
                subtitle: Wrap(
                  spacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    Text(shortDate(tx.date, alwaysShowYear: true)),
                    InkWell(
                      borderRadius: BorderRadius.circular(999),
                      onTap: tx.amount < 0
                          ? null
                          : () {
                        showTransactionCategoryPicker(
                          context: context,
                          tx: tx,
                          selectedCategory: effectiveCategory,
                          onSelected: (category) => onTransactionCategorySelected(tx, category),
                        );
                      },
                      child: TransactionCategoryTag(
                        label: effectiveCategory,
                        colorKey: colorKey,
                      ),
                    ),
                    Text(
                      'Acct ••••${accountEndingForId(tx.accountId, accountOptions)}',
                      style: const TextStyle(color: Colors.black54, fontSize: 12),
                    ),
                  ],
                ),
                trailing: Text(formatMoney(tx.amount)),
              );
            },
          ),
          const SizedBox(height: 16),
          const Text(
            'Review Transactions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          if (pendingReviewTransactions.isEmpty)
            const Text(
              'No low-confidence transactions to review.',
              style: TextStyle(color: Colors.black54),
            ),
          ...pendingReviewTransactions.map(
            (tx) {
              final selected = tx.amount < 0
                  ? 'Income'
                  : (reviewedCategoryByTxId[tx.id] ??
                        budgetCategoryFromPfc(
                          pfcDetailed: tx.category,
                          pfcPrimary: tx.primaryCategory,
                        ));
              return Container(
                margin: const EdgeInsets.only(bottom: 10),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tx.name,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 4),
                    Row(
                      children: [
                        Expanded(
                          child: Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: [
                              Text(
                                shortDate(tx.date, alwaysShowYear: true),
                                style: const TextStyle(color: Colors.black54, fontSize: 12),
                              ),
                              InkWell(
                                borderRadius: BorderRadius.circular(999),
                                onTap: tx.amount < 0
                                    ? null
                                    : () {
                                  showTransactionCategoryPicker(
                                    context: context,
                                    tx: tx,
                                    selectedCategory: selected,
                                    onSelected: (category) =>
                                        onTransactionCategorySelected(tx, category),
                                  );
                                },
                                child: TransactionCategoryTag(
                                  label: selected,
                                  colorKey: selected,
                                ),
                              ),
                              Text(
                                'Acct ••••${accountEndingForId(tx.accountId, accountOptions)}',
                                style: const TextStyle(color: Colors.black54, fontSize: 12),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        FilledButton(
                          onPressed: () => onReviewConfirm(tx.id),
                          style: FilledButton.styleFrom(
                            minimumSize: const Size(52, 30),
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                            visualDensity: VisualDensity.compact,
                          ),
                          child: const Text('Confirm', style: TextStyle(fontSize: 12)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      formatMoney(tx.amount),
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Tap category tag to adjust, then confirm to mark reviewed.',
                      style: const TextStyle(color: Colors.black54, fontSize: 12),
                    ),
                  ],
                ),
              );
            },
          ),
          const SizedBox(height: 20),
          const Text('Upcoming Subscriptions', style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text(
            'Monthly total: ${formatMoney(monthlySubscriptionTotal, signed: false)}',
            style: const TextStyle(color: Colors.black54),
          ),
          if (subscriptions.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: Text('No recurring subscriptions detected yet.'),
            ),
          ...subscriptions.map(
            (sub) => ListTile(
              leading: const Icon(Icons.subscriptions_outlined),
              title: Text(sub.merchant),
              subtitle: Text('Renews ${shortDate(sub.nextChargeDate)}'),
              trailing: Text(formatMoney(sub.amount, signed: false)),
            ),
          ),
        ],
      ),
    );
  }
}

// Cash flow page
class CashFlowPage extends StatefulWidget {
  const CashFlowPage({
    super.key,
    required this.transactions,
    required this.flowSeries,
  });

  final List<AppTransaction> transactions;
  final List<MonthlyFlowPoint> flowSeries;

  @override
  State<CashFlowPage> createState() => _CashFlowPageState();
}

class _CashFlowPageState extends State<CashFlowPage> {
  FlowViewMode viewMode = FlowViewMode.month;

  DateTime get _now {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  List<AppTransaction> get _periodTransactions {
    final now = _now;
    return widget.transactions.where((tx) {
      if (viewMode == FlowViewMode.month) {
        return tx.date.year == now.year && tx.date.month == now.month;
      }
      if (viewMode == FlowViewMode.year) {
        return tx.date.year == now.year;
      }
      return true;
    }).toList();
  }

  double get _periodIncome {
    double total = 0;
    for (final tx in _periodTransactions) {
      if (tx.amount < 0) total += tx.amount.abs();
    }
    return total;
  }

  double get _periodExpenses {
    double total = 0;
    for (final tx in _periodTransactions) {
      if (tx.amount > 0) total += tx.amount;
    }
    return total;
  }

  double get _periodNet => _periodIncome - _periodExpenses;

  List<MonthlyFlowPoint> get _activeSeries {
    final now = _now;
    if (viewMode == FlowViewMode.month) {
      return _buildCurrentMonthWeeklySeries(now);
    }
    if (viewMode == FlowViewMode.year) {
      return _buildCurrentYearSeries(now);
    }
    return _buildRecentAllTimeSeries(now, 12);
  }

  List<MonthlyFlowPoint> _buildCurrentMonthWeeklySeries(DateTime now) {
    final incomes = List<double>.filled(5, 0);
    final expenses = List<double>.filled(5, 0);

    for (final tx in widget.transactions) {
      if (tx.date.year != now.year || tx.date.month != now.month) continue;
      final weekIndex = ((tx.date.day - 1) ~/ 7).clamp(0, 4);
      if (tx.amount < 0) {
        incomes[weekIndex] += tx.amount.abs();
      } else {
        expenses[weekIndex] += tx.amount;
      }
    }

    return List<MonthlyFlowPoint>.generate(
      5,
      (i) => MonthlyFlowPoint(
        label: 'W${i + 1}',
        income: incomes[i],
        expenses: expenses[i],
      ),
    );
  }

  List<MonthlyFlowPoint> _buildRecentAllTimeSeries(DateTime now, int count) {
    const monthLabels = [
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
      'Dec'
    ];
    final series = <MonthlyFlowPoint>[];
    for (int offset = count - 1; offset >= 0; offset--) {
      final anchor = DateTime(now.year, now.month - offset, 1);
      double income = 0;
      double expenses = 0;
      for (final tx in widget.transactions) {
        if (tx.date.year == anchor.year && tx.date.month == anchor.month) {
          if (tx.amount < 0) {
            income += tx.amount.abs();
          } else {
            expenses += tx.amount;
          }
        }
      }
      series.add(
        MonthlyFlowPoint(
          label: monthLabels[anchor.month - 1],
          income: income,
          expenses: expenses,
        ),
      );
    }
    return series;
  }

  List<MonthlyFlowPoint> _buildCurrentYearSeries(DateTime now) {
    const monthLabels = [
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
      'Dec'
    ];
    final series = <MonthlyFlowPoint>[];
    for (int month = 1; month <= 12; month++) {
      double income = 0;
      double expenses = 0;
      for (final tx in widget.transactions) {
        if (tx.date.year == now.year && tx.date.month == month) {
          if (tx.amount < 0) {
            income += tx.amount.abs();
          } else {
            expenses += tx.amount;
          }
        }
      }
      series.add(
        MonthlyFlowPoint(
          label: monthLabels[month - 1],
          income: income,
          expenses: expenses,
        ),
      );
    }
    return series;
  }

  @override
  Widget build(BuildContext context) {
    // avoid system UI overlap
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Cash Flow', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text('Track money in and out'),
          const SizedBox(height: 12),
          SegmentedButton<FlowViewMode>(
            segments: const [
              ButtonSegment<FlowViewMode>(
                value: FlowViewMode.month,
                label: Text('This Month'),
              ),
              ButtonSegment<FlowViewMode>(
                value: FlowViewMode.year,
                label: Text('This Year'),
              ),
              ButtonSegment<FlowViewMode>(
                value: FlowViewMode.all,
                label: Text('All Time'),
              ),
            ],
            selected: {viewMode},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) return;
              setState(() => viewMode = selection.first);
            },
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Column(
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Income', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(formatMoney(_periodIncome, signed: false)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Expenses', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(formatMoney(_periodExpenses, signed: false)),
                  ],
                ),
                const SizedBox(height: 8),
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Net', style: TextStyle(fontWeight: FontWeight.bold)),
                    Text(
                      '${_periodNet >= 0 ? '+' : '-'} \$${_periodNet.abs().toStringAsFixed(2)}',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 24),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.06),
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceAround,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: _buildBars(),
            ),
          ),
          const SizedBox(height: 20),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(18),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              boxShadow: const [
                BoxShadow(
                  color: Colors.black12,
                  blurRadius: 6,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.trending_up, color: Colors.green),
                    SizedBox(width: 8),
                    Text(
                      'Trend Summary',
                      style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text(_monthCompareText()),
                const SizedBox(height: 6),
                Text(
                  '• ${viewMode == FlowViewMode.month ? 'This month' : (viewMode == FlowViewMode.year ? 'This year' : 'All time')} income: ${formatMoney(_periodIncome, signed: false)}',
                ),
                const SizedBox(height: 6),
                Text(
                  '• ${viewMode == FlowViewMode.month ? 'This month' : (viewMode == FlowViewMode.year ? 'This year' : 'All time')} expenses: ${formatMoney(_periodExpenses, signed: false)}',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildBars() {
    final series = _activeSeries;
    if (series.isEmpty) {
      return const [
        ChartBar(label: '-', height: 40, value: 0),
        ChartBar(label: '-', height: 40, value: 0),
        ChartBar(label: '-', height: 40, value: 0),
        ChartBar(label: '-', height: 40, value: 0),
        ChartBar(label: '-', height: 40, value: 0),
      ];
    }
    final maxExpense = series.map((e) => e.expenses).fold<double>(0, math.max);
    final safeMax = maxExpense <= 0 ? 1 : maxExpense;
    return series
        .map(
          (e) => ChartBar(
            label: e.label,
            height: 40 + (e.expenses / safeMax) * 80,
            value: e.expenses,
          ),
        )
        .toList();
  }

  String _monthCompareText() {
    final series = _activeSeries;
    if (series.length < 2) {
      return '• Not enough history to compare trend yet';
    }
    final current = series.last.expenses;
    final previous = series[series.length - 2].expenses;
    if (previous <= 0 && current <= 0) {
      if (viewMode == FlowViewMode.month) {
        return '• No expense activity in the latest 2 months';
      }
      if (viewMode == FlowViewMode.year) {
        return '• No expense activity in the latest 2 periods';
      }
      return '• No expense activity in the latest 2 months';
    }
    if (previous <= 0) {
      if (viewMode == FlowViewMode.month) {
        return '• Spending started this week';
      }
      if (viewMode == FlowViewMode.year) {
        return '• Spending started in the latest period';
      }
      return '• Spending started in the latest month';
    }
    final pct = ((current - previous) / previous) * 100;
    final direction = pct >= 0 ? 'increased' : 'decreased';
    if (viewMode == FlowViewMode.month) {
      return '• Spending $direction ${pct.abs().toStringAsFixed(1)}% vs last week';
    }
    if (viewMode == FlowViewMode.year) {
      return '• Spending $direction ${pct.abs().toStringAsFixed(1)}% vs previous period';
    }
    return '• Spending $direction ${pct.abs().toStringAsFixed(1)}% vs previous month';
  }
}

// summary card widget
class SummaryCard extends StatelessWidget {
  final String title;
  final String value;

  const SummaryCard({super.key, required this.title, required this.value});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.green.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        children: [
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
          Text(title),
        ],
      ),
    );
  }
}

// chart bar widget
class ChartBar extends StatelessWidget {
  final String label;
  final double height;
  final double value;

  const ChartBar({
    super.key,
    required this.label,
    required this.height,
    required this.value,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        Text(
          '\$${value.toStringAsFixed(0)}',
          style: const TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w600,
            color: Colors.black54,
          ),
        ),
        const SizedBox(height: 4),
        Container(
          width: 22,
          height: height,
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Colors.green, Colors.lightGreen],
              begin: Alignment.bottomCenter,
              end: Alignment.topCenter,
            ),
            borderRadius: BorderRadius.circular(6),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 4,
                offset: Offset(0, 2),
              )
            ],
          ),
        ),
        const SizedBox(height: 6),
        Text(
          label,
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }
}

class CategoryChip extends StatelessWidget {
  final String label;
  final bool selected;

  const CategoryChip({super.key, required this.label, this.selected = false});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
      decoration: BoxDecoration(
        color: selected ? Colors.green : Colors.green.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: selected ? Colors.white : Colors.green,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}

class AIAssistantButton extends StatelessWidget {
  final VoidCallback onTap;

  const AIAssistantButton({super.key, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(28),
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.72),
            borderRadius: BorderRadius.circular(28),
            border: Border.all(color: Colors.white.withValues(alpha: 0.6)),
            boxShadow: const [
              BoxShadow(
                color: Colors.black12,
                blurRadius: 12,
                offset: Offset(0, 4),
              ),
            ],
          ),
          child: const Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.smart_toy_outlined, color: Colors.green),
              SizedBox(width: 8),
              Text(
                'AI',
                style: TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Colors.green,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class AIAssistantPanel extends StatelessWidget {
  const AIAssistantPanel({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.9),
        borderRadius: BorderRadius.circular(24),
      ),
      child: const Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.smart_toy_outlined, color: Colors.green),
              SizedBox(width: 10),
              Text(
                'AI Assistant',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ],
          ),
          SizedBox(height: 12),
          Text(
            'This is a floating AI chatbot placeholder. Later it can provide spending insights, subscription reminders, and budget suggestions.',
            style: TextStyle(height: 1.4),
          ),
          SizedBox(height: 14),
          TextField(
            decoration: InputDecoration(
              hintText: 'Ask about your spending...',
              prefixIcon: Icon(Icons.chat_bubble_outline),
              border: OutlineInputBorder(),
            ),
          ),
        ],
      ),
    );
  }
}

// transactions list page
class TransactionsPage extends StatefulWidget {
  const TransactionsPage({
    super.key,
    required this.transactions,
    required this.accountOptions,
    required this.reviewedCategoryByTxId,
    required this.onTransactionCategorySelected,
  });

  final List<AppTransaction> transactions;
  final List<AccountOption> accountOptions;
  final Map<String, String> reviewedCategoryByTxId;
  final void Function(AppTransaction tx, String category) onTransactionCategorySelected;

  @override
  State<TransactionsPage> createState() => _TransactionsPageState();
}

class _TransactionsPageState extends State<TransactionsPage> {
  String query = '';
  ActivityViewMode viewMode = ActivityViewMode.month;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final periodTransactions = widget.transactions.where((tx) {
      if (viewMode == ActivityViewMode.month) {
        return tx.date.year == now.year && tx.date.month == now.month;
      }
      if (viewMode == ActivityViewMode.year) {
        return tx.date.year == now.year;
      }
      return true;
    }).toList();

    final filtered = periodTransactions.where((tx) {
      if (query.trim().isEmpty) return true;
      final q = query.toLowerCase();
      return tx.name.toLowerCase().contains(q) ||
          tx.category.toLowerCase().contains(q) ||
          tx.primaryCategory.toLowerCase().contains(q) ||
          (widget.reviewedCategoryByTxId[tx.id]?.toLowerCase().contains(q) ?? false);
    }).toList();

    return SafeArea(
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
            child: SegmentedButton<ActivityViewMode>(
              segments: const [
                ButtonSegment<ActivityViewMode>(
                  value: ActivityViewMode.month,
                  label: Text('This Month'),
                ),
                ButtonSegment<ActivityViewMode>(
                  value: ActivityViewMode.year,
                  label: Text('This Year'),
                ),
                ButtonSegment<ActivityViewMode>(
                  value: ActivityViewMode.all,
                  label: Text('All Time'),
                ),
              ],
              selected: {viewMode},
              onSelectionChanged: (selection) {
                if (selection.isEmpty) return;
                setState(() => viewMode = selection.first);
              },
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: TextField(
              onChanged: (value) => setState(() => query = value),
              decoration: InputDecoration(
                hintText: 'Search transactions',
                prefixIcon: const Icon(Icons.search),
                filled: true,
                fillColor: Colors.green.withValues(alpha: 0.06),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(14),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text(
                '${filtered.length} transactions (${viewMode == ActivityViewMode.month ? 'this month' : (viewMode == ActivityViewMode.year ? 'this year' : 'all time')})',
                style: const TextStyle(color: Colors.black54),
              ),
            ),
          ),
          Expanded(
            child: filtered.isEmpty
                ? const Center(child: Text('No transactions found'))
                : ListView.builder(
                    padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
                    itemCount: filtered.length,
                    itemBuilder: (context, i) {
                      final tx = filtered[i];
                      final effectiveCategory = tx.amount < 0
                          ? 'Income'
                          : (widget.reviewedCategoryByTxId[tx.id] ??
                                budgetCategoryFromPfc(
                                  pfcDetailed: tx.category,
                                  pfcPrimary: tx.primaryCategory,
                                ));
                      final colorKey =
                          widget.reviewedCategoryByTxId[tx.id] ?? effectiveCategory;
                      return ListTile(
                        leading: Icon(iconForTransaction(tx.category, tx.name)),
                        title: Text(tx.name),
                        subtitle: Wrap(
                          spacing: 8,
                          crossAxisAlignment: WrapCrossAlignment.center,
                          children: [
                            Text(shortDate(tx.date, alwaysShowYear: true)),
                            InkWell(
                              borderRadius: BorderRadius.circular(999),
                              onTap: tx.amount < 0
                                  ? null
                                  : () {
                                showTransactionCategoryPicker(
                                  context: context,
                                  tx: tx,
                                  selectedCategory: effectiveCategory,
                                  onSelected: (category) =>
                                      widget.onTransactionCategorySelected(tx, category),
                                );
                              },
                              child: TransactionCategoryTag(
                                label: effectiveCategory,
                                colorKey: colorKey,
                              ),
                            ),
                            Text(
                              'Acct ••••${accountEndingForId(tx.accountId, widget.accountOptions)}',
                              style: const TextStyle(color: Colors.black54, fontSize: 12),
                            ),
                          ],
                        ),
                        trailing: Text(formatMoney(tx.amount)),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

// budget page
enum BudgetViewMode { month, year, all }

class BudgetPage extends StatefulWidget {
  const BudgetPage({
    super.key,
    required this.stats,
    required this.budgetProgress,
    required this.budgetProgressYear,
    required this.budgetProgressAll,
    required this.onUpdateBudgetLimit,
  });

  final DashboardStats stats;
  final List<BudgetCategoryProgress> budgetProgress;
  final List<BudgetCategoryProgress> budgetProgressYear;
  final List<BudgetCategoryProgress> budgetProgressAll;
  final Future<void> Function(String budgetId, double monthlyLimit) onUpdateBudgetLimit;

  @override
  State<BudgetPage> createState() => _BudgetPageState();
}

class _BudgetPageState extends State<BudgetPage> {
  BudgetViewMode viewMode = BudgetViewMode.month;

  List<BudgetCategoryProgress> get activeBudgetProgress =>
      viewMode == BudgetViewMode.month
          ? widget.budgetProgress
          : (viewMode == BudgetViewMode.year
                ? widget.budgetProgressYear
                : widget.budgetProgressAll);

  @override
  Widget build(BuildContext context) {
    // avoid system UI overlap
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          Row(
            children: [
              const Expanded(
                child: Text(
                  'Budget',
                  style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold),
                ),
              ),
              OutlinedButton.icon(
                onPressed: () => _showBulkEditBudgetDialog(context),
                icon: const Icon(Icons.tune),
                label: const Text('Edit Budget'),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: () => _showCustomCategoryDialog(context),
              icon: const Icon(Icons.add_circle_outline),
              label: const Text('Add Custom Category'),
            ),
          ),
          const SizedBox(height: 8),
          SegmentedButton<BudgetViewMode>(
            segments: const [
              ButtonSegment<BudgetViewMode>(
                value: BudgetViewMode.month,
                label: Text('This Month'),
              ),
              ButtonSegment<BudgetViewMode>(
                value: BudgetViewMode.year,
                label: Text('This Year'),
              ),
              ButtonSegment<BudgetViewMode>(
                value: BudgetViewMode.all,
                label: Text('All Time'),
              ),
            ],
            selected: {viewMode},
            onSelectionChanged: (selection) {
              if (selection.isEmpty) return;
              setState(() => viewMode = selection.first);
            },
          ),
          const SizedBox(height: 8),
          Text('Current month net: ${widget.stats.netThisMonth >= 0 ? '+ ' : '- '}\$${widget.stats.netThisMonth.abs().toStringAsFixed(2)}'),
          const SizedBox(height: 20),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.orange.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Row(
              children: [
                const Icon(Icons.warning_amber_rounded, color: Colors.orange),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    _budgetInsight(),
                    style: const TextStyle(fontWeight: FontWeight.w500),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 18),
          if (activeBudgetProgress.isEmpty)
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(14),
              ),
              child: const Text(
                'No budgets configured for this view yet.',
              ),
            ),
          if (activeBudgetProgress.isNotEmpty)
            ..._budgetListWidgets(context),
          const SizedBox(height: 18),
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.green.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(14),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Row(
                  children: [
                    Icon(Icons.smart_toy_outlined, color: Colors.green),
                    SizedBox(width: 10),
                    Text(
                      'AI Analysis',
                      style: TextStyle(fontWeight: FontWeight.bold),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Text('• Highest category usage: ${_highestCategoryText()}'),
                const SizedBox(height: 6),
                Text('• Total monthly expenses: ${formatMoney(widget.stats.monthlyExpenses, signed: false)}'),
                const SizedBox(height: 10),
                Text(
                  _budgetSuggestion(),
                  style: const TextStyle(fontWeight: FontWeight.w500),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _budgetListWidgets(BuildContext context) {
    final widgets = <Widget>[];
    for (int i = 0; i < activeBudgetProgress.length; i++) {
      final item = activeBudgetProgress[i];
      widgets.add(
        _budgetItem(
          context,
          item,
        ),
      );
      if (i != activeBudgetProgress.length - 1) {
        widgets.add(const SizedBox(height: 14));
      }
    }
    return widgets;
  }

  String _highestCategoryText() {
    if (activeBudgetProgress.isEmpty) return 'No budget categories yet';
    final sorted = [...activeBudgetProgress]..sort((a, b) => b.ratio.compareTo(a.ratio));
    return '${sorted.first.title} (${(sorted.first.ratio * 100).toStringAsFixed(0)}%)';
  }

  String _budgetInsight() {
    if (activeBudgetProgress.isEmpty) return 'Budget Insight: no spending data yet.';
    final sorted = [...activeBudgetProgress]..sort((a, b) => b.ratio.compareTo(a.ratio));
    final lead = sorted.first;
    if (lead.ratio >= 1) {
      return 'Budget Insight: ${lead.title} is over limit this month.';
    }
    if (lead.ratio >= 0.8) {
      return 'Budget Insight: ${lead.title} is close to limit this month.';
    }
    return 'Budget Insight: all categories are currently within limits.';
  }

  String _budgetSuggestion() {
    if (activeBudgetProgress.isEmpty) {
      return 'Suggestion: connect data to see budget guidance.';
    }
    final sorted = [...activeBudgetProgress]..sort((a, b) => b.ratio.compareTo(a.ratio));
    final lead = sorted.first;
    if (lead.ratio >= 1) {
      return 'Suggestion: cut ${lead.title.toLowerCase()} spending this week to recover your budget.';
    }
    if (lead.ratio >= 0.8) {
      return 'Suggestion: reduce non-essential ${lead.title.toLowerCase()} spend for the rest of the month.';
    }
    return 'Suggestion: current pace is healthy; keep spending patterns stable.';
  }

  // budget item widget
  Future<void> _showEditBudgetDialog(
    BuildContext context,
    BudgetCategoryProgress item,
  ) async {
    final controller = TextEditingController(text: item.limit.toStringAsFixed(0));
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: Text('Set ${item.title} Budget'),
          content: TextField(
            controller: controller,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(
              prefixText: '\$',
              labelText: 'Monthly limit',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () async {
                final parsed = double.tryParse(controller.text.trim());
                if (parsed == null || parsed <= 0) return;
                await widget.onUpdateBudgetLimit(item.budgetId, parsed);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showBulkEditBudgetDialog(BuildContext context) async {
    final editableBudgets = activeBudgetProgress
        .where((b) => !b.budgetId.startsWith('preset_'))
        .toList();
    if (editableBudgets.isEmpty) return;
    BudgetCategoryProgress selected = editableBudgets.first;
    final controller = TextEditingController(text: selected.limit.toStringAsFixed(0));
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('Edit Budget'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  DropdownButtonFormField<String>(
                    initialValue: selected.budgetId,
                    isExpanded: true,
                    items: editableBudgets
                        .map(
                          (b) => DropdownMenuItem<String>(
                            value: b.budgetId,
                            child: Text(b.title),
                          ),
                        )
                        .toList(),
                    onChanged: (value) {
                      if (value == null) return;
                      setDialogState(() {
                        selected = editableBudgets.firstWhere((b) => b.budgetId == value);
                        controller.text = selected.limit.toStringAsFixed(0);
                      });
                    },
                    decoration: const InputDecoration(labelText: 'Budget'),
                  ),
                  const SizedBox(height: 12),
                  TextField(
                    controller: controller,
                    keyboardType: const TextInputType.numberWithOptions(decimal: true),
                    decoration: const InputDecoration(
                      prefixText: '\$',
                      labelText: 'Monthly limit',
                    ),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: () async {
                    final parsed = double.tryParse(controller.text.trim());
                    if (parsed == null || parsed <= 0) return;
                    await widget.onUpdateBudgetLimit(selected.budgetId, parsed);
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: const Text('Save'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showCustomCategoryDialog(BuildContext context) async {
    final controller = TextEditingController();
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('Add Custom Category'),
          content: TextField(
            controller: controller,
            decoration: const InputDecoration(
              labelText: 'Category name',
              hintText: 'e.g. Pets, Travel, Gifts',
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                Navigator.of(dialogContext).pop();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Custom category UI only (not connected yet).'),
                  ),
                );
              },
              child: const Text('Save'),
            ),
          ],
        );
      },
    );
  }

  Widget _budgetItem(
    BuildContext context,
    BudgetCategoryProgress item,
  ) {
    final icon = _categoryIcon(item.title);
    final tone = _categoryColor(item.title);
    final amount =
        '${formatMoney(item.spent, signed: false)} / ${formatMoney(item.limit, signed: false)}';
    final progress = item.ratio;
    final isWarning = item.isWarning;
    final limit = item.limit;
    final spent = item.spent;
    final remaining = (limit - spent).clamp(-999999, 999999);

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            tone.withValues(alpha: 0.14),
            tone.withValues(alpha: 0.05),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: tone.withValues(alpha: 0.25)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                width: 34,
                height: 34,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.85),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Icon(icon, size: 18, color: tone),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  item.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  softWrap: false,
                  style: const TextStyle(fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Set budget',
                onPressed: () {
                  _showEditBudgetDialog(
                    context,
                    item,
                  );
                },
                icon: Icon(Icons.tune, size: 20, color: tone),
              ),
              const SizedBox(width: 12),
              Text(
                amount,
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: progress.clamp(0, 1),
            minHeight: 8,
            color: isWarning ? Colors.orange : tone,
            backgroundColor: Colors.black12,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Text(
                isWarning ? 'High usage' : 'Healthy',
                style: TextStyle(
                  color: isWarning ? Colors.orange : tone,
                  fontWeight: FontWeight.w600,
                  fontSize: 12,
                ),
              ),
              const Spacer(),
              Text(
                'Remaining: ${remaining >= 0 ? '' : '-'}\$${remaining.abs().toStringAsFixed(2)}',
                style: TextStyle(
                  fontSize: 12,
                  color: remaining >= 0 ? Colors.black54 : Colors.redAccent,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  IconData _categoryIcon(String category) {
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

  Color _categoryColor(String category) {
    switch (category) {
      case 'Food':
        return Colors.orange;
      case 'Transport':
        return Colors.blue;
      case 'Entertainment':
        return Colors.purple;
      case 'Shopping':
        return Colors.green;
      case 'Other':
        return Colors.blueGrey;
      default:
        return Colors.blueGrey;
    }
  }
}

// subscriptions page
class SubscriptionsPage extends StatelessWidget {
  const SubscriptionsPage({super.key, required this.subscriptions});

  final List<DetectedSubscription> subscriptions;

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('Subs', style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          Text('Recurring ${subscriptions.length} subscriptions'),
          const SizedBox(height: 16),
          if (subscriptions.isEmpty)
            const Text('No recurring subscriptions detected yet.'),
          ...subscriptions.map(
            (sub) => ListTile(
              leading: const Icon(Icons.subscriptions_outlined),
              title: Text(sub.merchant),
              subtitle: Text('Renews ${shortDate(sub.nextChargeDate)} • ${sub.frequency}'),
              trailing: Text(formatMoney(sub.amount, signed: false)),
            ),
          ),
        ],
      ),
    );
  }
}
