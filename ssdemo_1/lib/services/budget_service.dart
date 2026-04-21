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

  Future<void> initializeBudgetsTo500(
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
          .eq('month_year', monthYear);
      final existing = (rows as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      final hasBudgetByCategory = <String>{};
      for (final row in existing) {
        final categoryId = (row['category_id'] as String?)?.trim();
        if (categoryId == null || categoryId.isEmpty) continue;
        hasBudgetByCategory.add(categoryId);
      }
      for (final c in categories) {
        if (hasBudgetByCategory.contains(c.id)) continue;
        await AppSupabase.client.from('budgets').insert({
          'user_id': userId,
          'category_id': c.id,
          'monthly_limit': 500,
          'rollover_amount': 0,
          'month_year': monthYear,
        });
      }
    } catch (_) {}
  }

  Future<void> updateBudgetLimit(
    String budgetId,
    double monthlyLimit,
    String userId,
  ) async {
    if (monthlyLimit <= 0) return;
    if (budgetId.startsWith('preset_')) return;
    await AppSupabase.client
        .from('budgets')
        .update({'monthly_limit': monthlyLimit})
        .eq('id', budgetId)
        .eq('user_id', userId);
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
      if (amount <= 0) {
        continue;
      }
      final bucket = _categoryService.budgetBucketForRawTransaction(
        row,
        reviewedCategoryByTxId,
      );
      final bucketKey = normalizeCategoryKey(bucket);
      spentByCategoryName[bucketKey] =
          (spentByCategoryName[bucketKey] ?? 0) + amount;
    }

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
      if (monthlyLimit <= 0) {
        continue;
      }
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

  List<BudgetCategoryProgress> presetBudgetProgress(
    List<AppTransaction> txs,
    DateTime now,
    bool yearly,
    Map<String, String> reviewedCategoryByTxId,
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
      final bucket = _categoryService.budgetBucketFor(
        tx,
        reviewedCategoryByTxId,
      );
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

  List<BudgetCategoryProgress> presetBudgetProgressAllTime(
    List<AppTransaction> txs,
    DateTime now,
    Map<String, String> reviewedCategoryByTxId,
  ) {
    const preset = kPresetBudgetCategories;
    final spentMap = <String, double>{for (final p in preset) p: 0};
    for (final tx in txs) {
      if (tx.amount <= 0) continue;
      final bucket = _categoryService.budgetBucketFor(
        tx,
        reviewedCategoryByTxId,
      );
      spentMap[bucket] = (spentMap[bucket] ?? 0) + tx.amount;
    }

    int coveredMonths = 1;
    if (txs.isNotEmpty) {
      final earliest = txs
          .map((e) => DateTime(e.date.year, e.date.month, 1))
          .reduce((a, b) => a.isBefore(b) ? a : b);
      coveredMonths =
          (now.year - earliest.year) * 12 + (now.month - earliest.month) + 1;
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
      if (tx.amount <= 0) continue;
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
      spentByCategory[key] = (spentByCategory[key] ?? 0) + tx.amount;
    }
    final rebased = template
        .map(
          (item) => BudgetCategoryProgress(
            budgetId: item.budgetId,
            categoryId: item.categoryId,
            title: item.title,
            spent: spentByCategory[normalizeCategoryKey(item.title)] ?? 0,
            limit: item.limit,
          ),
        )
        .toList();
    rebased.sort((a, b) => b.ratio.compareTo(a.ratio));
    return rebased;
  }
}
