import 'package:supabase_flutter/supabase_flutter.dart';

import '../constants/app_constants.dart';
import '../core/config/supabase_client.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';
import 'category_service.dart';

/// Budget initialization, updates, and progress computation.
class BudgetService {
  const BudgetService._();
  static const instance = BudgetService._();

  final _categoryService = CategoryService.instance;
  static const _budgetMonthColumn = 'month_year';
  static final _otherKey = normalizeCategoryKey('Other');

  /// Which card a spending bucket counts toward. A bucket with no budget card
  /// of its own (say a remembered category the budget doesn't list) goes to
  /// "Other" when there is one, so the cards still add up to the month's
  /// expenses on Home. Mirrored by python/budget_progress.py.
  static String cardKeyForBucket(String bucketKey, Set<String> cardKeys) {
    if (cardKeys.contains(bucketKey)) return bucketKey;
    if (cardKeys.contains(_otherKey)) return _otherKey;
    return bucketKey;
  }

  static Map<String, double> _foldIntoCards(
    Map<String, double> spentByBucket,
    Set<String> cardKeys,
  ) {
    final out = <String, double>{};
    for (final entry in spentByBucket.entries) {
      final key = cardKeyForBucket(entry.key, cardKeys);
      out[key] = (out[key] ?? 0) + entry.value;
    }
    return out;
  }

  /// Creates [monthYear]'s missing budget rows. A limit the user set last
  /// month carries forward; otherwise the limit comes from spending history
  /// (category_month_stats, see [autoLimits]); otherwise last month's limit.
  /// Existing rows are never changed.
  Future<void> ensureMonthlyBudgetRows(
    List<CategoryOption> categories,
    String monthYear,
    String userId,
  ) async {
    if (categories.isEmpty) return;
    try {
      final rows = await AppSupabase.client
          .from('budgets')
          .select('id,category_id')
          .eq('user_id', userId)
          .eq(_budgetMonthColumn, monthYear);
      final existing = (rows as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      final hasBudgetByCategory = <String>{};
      for (final row in existing) {
        final categoryId = (row['category_id'] as String?)?.trim();
        if (categoryId == null || categoryId.isEmpty) continue;
        hasBudgetByCategory.add(categoryId);
      }
      final missing = [
        for (final c in categories)
          if (!hasBudgetByCategory.contains(c.id)) c,
      ];
      if (missing.isEmpty) return;
      final limits = autoLimits(
        stats: await _historyStats(userId, monthYear),
        cardNames: [for (final c in categories) c.name],
        previous: await _previousLimits(userId, monthYear, categories),
        month: monthYear,
      );
      for (final c in missing) {
        final value = limits[c.name] ?? (limit: 0.0, source: 'auto');
        final row = {
          'user_id': userId,
          'category_id': c.id,
          'monthly_limit': value.limit,
          'rollover_amount': 0,
          _budgetMonthColumn: monthYear,
        };
        try {
          await AppSupabase.client.from('budgets').insert({
            ...row,
            'limit_source': value.source,
          });
        } catch (_) {
          // Before migration 015 there is no limit_source column. A row the
          // backend created at the same moment fails here too; that's fine.
          try {
            await AppSupabase.client.from('budgets').insert(row);
          } catch (_) {}
        }
      }
    } catch (_) {}
  }

  Future<List<Map<String, dynamic>>> _historyStats(
    String userId,
    String monthYear,
  ) async {
    try {
      final months = previousMonths(monthYear, autoLimitHistoryMonths);
      final rows = await AppSupabase.client
          .from('category_month_stats')
          .select('month,category,spent')
          .eq('user_id', userId)
          .inFilter('month', months);
      return (rows as List).whereType<Map<String, dynamic>>().toList();
    } catch (_) {
      return const [];
    }
  }

  /// Last month's limits by normalized category name.
  Future<Map<String, ({double limit, String source})>> _previousLimits(
    String userId,
    String monthYear,
    List<CategoryOption> categories,
  ) async {
    final nameById = {for (final c in categories) c.id: c.name};
    final previous = previousMonths(monthYear, 1).single;
    List rows;
    try {
      rows = await AppSupabase.client
          .from('budgets')
          .select('category_id,monthly_limit,limit_source')
          .eq('user_id', userId)
          .eq(_budgetMonthColumn, previous);
    } catch (_) {
      try {
        // Before migration 015: every existing limit counts as the user's.
        rows = await AppSupabase.client
            .from('budgets')
            .select('category_id,monthly_limit')
            .eq('user_id', userId)
            .eq(_budgetMonthColumn, previous);
      } catch (_) {
        return const {};
      }
    }
    final out = <String, ({double limit, String source})>{};
    for (final row in rows.whereType<Map<String, dynamic>>()) {
      final name = nameById['${row['category_id']}'];
      if (name == null) continue;
      out[normalizeCategoryKey(name)] = (
        limit: double.tryParse('${row['monthly_limit']}') ?? 0,
        source: (row['limit_source'] as String?) ?? 'user',
      );
    }
    return out;
  }

  static const autoLimitHistoryMonths = 6;
  static const _autoLimitMinMonths = 3;

  /// The [count] months ('YYYY-MM') before [month], oldest first.
  static List<String> previousMonths(String month, int count) {
    final parts = month.split('-');
    var year = int.parse(parts[0]);
    var mon = int.parse(parts[1]);
    final out = <String>[];
    for (var i = 0; i < count; i++) {
      mon -= 1;
      if (mon == 0) {
        year -= 1;
        mon = 12;
      }
      out.add('$year-${mon.toString().padLeft(2, '0')}');
    }
    return out.reversed.toList();
  }

  static double _trimmedMean(List<double> values) {
    final ordered = [...values]..sort();
    final kept = ordered.length >= 3
        ? ordered.sublist(1, ordered.length - 1)
        : ordered;
    if (kept.isEmpty) return 0;
    return kept.reduce((a, b) => a + b) / kept.length;
  }

  /// Limits for a new month's rows, by card name: the user's own limit from
  /// last month as is ('user'); else the trimmed mean (highest and lowest
  /// month dropped) of the card's spend over the last 6 months with any
  /// spending, at least 3, rounded to $5 ('auto'); else last month's limit;
  /// else 0. [previous] is keyed by normalized name. Mirrors
  /// python/user_model.py auto_limits: both run
  /// python/tests/data/budget_auto_limit_contract.json.
  static Map<String, ({double limit, String source})> autoLimits({
    required List<Map<String, dynamic>> stats,
    required List<String> cardNames,
    required Map<String, ({double limit, String source})> previous,
    required String month,
  }) {
    final cardKeys = {for (final n in cardNames) normalizeCategoryKey(n)};
    final withSpending = {
      for (final s in stats)
        if ((double.tryParse('${s['spent']}') ?? 0) > 0) '${s['month']}',
    };
    final months = [
      for (final m in previousMonths(month, autoLimitHistoryMonths))
        if (withSpending.contains(m)) m,
    ];
    final totals = <String, double>{};
    for (final s in stats) {
      final m = '${s['month']}';
      if (!months.contains(m)) continue;
      final key = cardKeyForBucket(
        normalizeCategoryKey('${s['category']}'),
        cardKeys,
      );
      totals['$m|$key'] =
          (totals['$m|$key'] ?? 0) + (double.tryParse('${s['spent']}') ?? 0);
    }
    final out = <String, ({double limit, String source})>{};
    for (final name in cardNames) {
      final key = normalizeCategoryKey(name);
      final prev = previous[key];
      if (prev != null && prev.source == 'user') {
        out[name] = (limit: prev.limit, source: 'user');
        continue;
      }
      if (months.length >= _autoLimitMinMonths) {
        final spend = [
          for (final m in months)
            ((totals['$m|$key'] ?? 0) * 100).roundToDouble() / 100,
        ];
        final limit = (_trimmedMean(spend) / 5 + 0.5).floorToDouble() * 5;
        if (limit > 0) {
          out[name] = (limit: limit, source: 'auto');
          continue;
        }
      }
      out[name] = (limit: prev?.limit ?? 0, source: 'auto');
    }
    return out;
  }

  Future<void> updateBudgetLimit(
    String budgetId,
    double monthlyLimit,
    String userId,
  ) async {
    if (monthlyLimit < 0) return;
    if (budgetId.startsWith('preset_')) return;
    await _writeUserLimit(
      (values) => AppSupabase.client
          .from('budgets')
          .update(values)
          .eq('id', budgetId)
          .eq('user_id', userId),
      {'monthly_limit': monthlyLimit},
    );
  }

  Future<void> upsertMonthlyBudgetByCategoryTitle({
    required String userId,
    required String categoryTitle,
    required double monthlyLimit,
    required String monthYear,
  }) async {
    if (monthlyLimit < 0 || categoryTitle.trim().isEmpty) return;
    final normalizedTitle = normalizeCategoryKey(categoryTitle);

    final categoriesRows = await AppSupabase.client
        .from('categories')
        .select('id,name,user_id')
        .or('user_id.eq.$userId,user_id.is.null');
    final categories = (categoriesRows as List)
        .whereType<Map<String, dynamic>>();

    String? categoryId;
    for (final row in categories) {
      final name = normalizeCategoryKey('${row['name'] ?? ''}');
      if (name == normalizedTitle) {
        categoryId = '${row['id']}';
        break;
      }
    }

    if (categoryId == null || categoryId.isEmpty) {
      final inserted = await AppSupabase.client
          .from('categories')
          .insert({
            'user_id': userId,
            'name': categoryTitle.trim(),
            'is_custom': false,
          })
          .select('id')
          .limit(1);
      final insertedRows = inserted.whereType<Map<String, dynamic>>().toList();
      if (insertedRows.isNotEmpty) {
        categoryId = '${insertedRows.first['id']}';
      }
    }
    if (categoryId == null || categoryId.isEmpty) return;

    final budgetRows = await AppSupabase.client
        .from('budgets')
        .select('id')
        .eq('user_id', userId)
        .eq('category_id', categoryId)
        .eq(_budgetMonthColumn, monthYear)
        .limit(1);
    final existing = (budgetRows as List)
        .whereType<Map<String, dynamic>>()
        .toList();
    if (existing.isNotEmpty) {
      await _writeUserLimit(
        (values) => AppSupabase.client
            .from('budgets')
            .update(values)
            .eq('id', '${existing.first['id']}')
            .eq('user_id', userId),
        {'monthly_limit': monthlyLimit},
      );
      return;
    }

    await _writeUserLimit(
      (values) => AppSupabase.client.from('budgets').insert(values),
      {
        'user_id': userId,
        'category_id': categoryId,
        'monthly_limit': monthlyLimit,
        'rollover_amount': 0,
        _budgetMonthColumn: monthYear,
      },
    );
  }

  /// A limit the user typed (or accepted) is theirs: limit_source 'user', so it
  /// carries into the next month. Retried without the column before
  /// migration 015.
  Future<void> _writeUserLimit(
    Future<dynamic> Function(Map<String, dynamic> values) write,
    Map<String, dynamic> values,
  ) async {
    try {
      await write({...values, 'limit_source': 'user'});
    } on PostgrestException catch (error) {
      if (!error.message.contains('limit_source')) rethrow;
      await write(values);
    }
  }

  List<BudgetCategoryProgress> buildProgressFromRows({
    required List<Map<String, dynamic>> budgetRows,
    required Map<String, String> categoryMap,
    required List<Map<String, dynamic>> txRows,
    required DateTime now,
    required bool yearly,
    required Map<String, String> reviewedCategoryByTxId,
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
      final amount = rawAmount is num
          ? rawAmount.toDouble()
          : double.tryParse('$rawAmount') ?? 0;
      final pfcDetailed =
          ((row['pfc_detailed'] as String?) ??
                  (row['category'] as String?) ??
                  '')
              .trim();
      final pfcPrimary = ((row['pfc_primary'] as String?) ?? '').trim();
      final pfcExpense = AppTransaction.isExpenseByPfc(
        pfcDetailed: pfcDetailed,
        pfcPrimary: pfcPrimary,
      );
      final pfcIncome = AppTransaction.isIncomeByPfc(
        pfcDetailed: pfcDetailed,
        pfcPrimary: pfcPrimary,
      );
      final pfcKnown = AppTransaction.isKnownByPfc(
        pfcDetailed: pfcDetailed,
        pfcPrimary: pfcPrimary,
      );
      final accountName = ((row['account_name'] as String?) ?? '').trim();
      final accountType = ((row['account_type'] as String?) ?? '').trim();
      final accountSubtype = ((row['subtype'] as String?) ?? '').trim();
      final usesDepository = AppTransaction.usesDepositoryPolarity(
        accountName: accountName,
        accountType: accountType,
        accountSubtype: accountSubtype,
      );
      final isDepositoryAccount = accountType.toLowerCase() == 'depository';
      final fallbackExpense = isDepositoryAccount
          ? amount > 0
          : (usesDepository ? amount < 0 : amount > 0);
      final isExpense = pfcKnown ? (pfcExpense && !pfcIncome) : fallbackExpense;
      if (!isExpense) {
        continue;
      }
      if (AppTransaction.isCreditCardPaymentByPfc(
        pfcDetailed: pfcDetailed,
        pfcPrimary: pfcPrimary,
      )) {
        continue;
      }
      final expenseAmount = amount.abs();
      final bucket = _categoryService.budgetBucketForRawTransaction(
        row,
        reviewedCategoryByTxId,
      );
      final bucketKey = normalizeCategoryKey(bucket);
      spentByCategoryName[bucketKey] =
          (spentByCategoryName[bucketKey] ?? 0) + expenseAmount;
    }

    final spentByCard = _foldIntoCards(spentByCategoryName, {
      for (final row in budgetRows)
        normalizeCategoryKey(
          categoryMap[(row['category_id'] as String?)?.trim()] ?? 'Unknown',
        ),
    });
    final progress = <BudgetCategoryProgress>[];
    for (final row in budgetRows) {
      final budgetId = (row['id'] as String?)?.trim();
      final categoryId = (row['category_id'] as String?)?.trim();
      if (budgetId == null ||
          budgetId.isEmpty ||
          categoryId == null ||
          categoryId.isEmpty) {
        continue;
      }
      final rawLimit = row['monthly_limit'];
      final monthlyLimit = rawLimit is num
          ? rawLimit.toDouble()
          : double.tryParse('$rawLimit') ?? 0;
      final title = categoryMap[categoryId] ?? 'Unknown';
      final titleKey = normalizeCategoryKey(title);
      progress.add(
        BudgetCategoryProgress(
          budgetId: budgetId,
          categoryId: categoryId,
          title: title,
          spent: spentByCard[titleKey] ?? 0,
          limit: yearly ? monthlyLimit * 12 : monthlyLimit,
        ),
      );
    }
    return progress;
  }

  List<BudgetCategoryProgress> buildZeroLimitProgressFromPresetCategories(
    List<AppTransaction> txs,
    DateTime now,
    bool yearly,
    Map<String, String> reviewedCategoryByTxId,
  ) {
    const preset = kPresetBudgetCategories;
    final spentMap = <String, double>{for (final p in preset) p: 0};
    for (final tx in txs) {
      if (!tx.isExpense) continue;
      if (yearly) {
        if (tx.date.year != now.year) continue;
      } else {
        if (tx.date.year != now.year || tx.date.month != now.month) continue;
      }
      final bucket = _categoryService.budgetBucketFor(
        tx,
        reviewedCategoryByTxId,
      );
      spentMap[bucket] = (spentMap[bucket] ?? 0) + tx.expenseAmount;
    }
    return preset
        .map(
          (name) => BudgetCategoryProgress(
            budgetId: 'preset_${name.toLowerCase()}',
            categoryId: 'preset_${name.toLowerCase()}',
            title: name,
            spent: spentMap[name] ?? 0,
            limit: 0,
          ),
        )
        .toList();
  }

  List<BudgetCategoryProgress>
  buildZeroLimitProgressFromPresetCategoriesAllTime(
    List<AppTransaction> txs,
    DateTime now,
    Map<String, String> reviewedCategoryByTxId,
  ) {
    const preset = kPresetBudgetCategories;
    final spentMap = <String, double>{for (final p in preset) p: 0};
    for (final tx in txs) {
      if (!tx.isExpense) continue;
      final bucket = _categoryService.budgetBucketFor(
        tx,
        reviewedCategoryByTxId,
      );
      spentMap[bucket] = (spentMap[bucket] ?? 0) + tx.expenseAmount;
    }

    return preset
        .map(
          (name) => BudgetCategoryProgress(
            budgetId: 'preset_${name.toLowerCase()}',
            categoryId: 'preset_${name.toLowerCase()}',
            title: name,
            spent: spentMap[name] ?? 0,
            limit: 0,
          ),
        )
        .toList();
  }

  List<BudgetCategoryProgress> rebasedProgressFromTemplate({
    required List<BudgetCategoryProgress> template,
    required List<AppTransaction> txs,
    required DateTime focusMonth,
    required bool yearly,
    required bool allTime,
    required Map<String, String> reviewedCategoryByTxId,
  }) {
    if (template.isEmpty) return const <BudgetCategoryProgress>[];
    final spentByCategory = <String, double>{};
    for (final tx in txs) {
      if (!tx.isExpense) continue;
      if (!allTime) {
        if (yearly) {
          if (tx.date.year != focusMonth.year) continue;
        } else {
          if (tx.date.year != focusMonth.year ||
              tx.date.month != focusMonth.month) {
            continue;
          }
        }
      }
      final bucket = _categoryService.budgetBucketFor(
        tx,
        reviewedCategoryByTxId,
      );
      final key = normalizeCategoryKey(bucket);
      spentByCategory[key] = (spentByCategory[key] ?? 0) + tx.expenseAmount;
    }
    final spentByCard = _foldIntoCards(spentByCategory, {
      for (final item in template) normalizeCategoryKey(item.title),
    });
    final rebased = template
        .map(
          (item) => BudgetCategoryProgress(
            budgetId: item.budgetId,
            categoryId: item.categoryId,
            title: item.title,
            spent: spentByCard[normalizeCategoryKey(item.title)] ?? 0,
            limit: item.limit,
          ),
        )
        .toList();
    return rebased;
  }
}
