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
  static const _budgetMonthColumn = 'month';

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
      for (final c in categories) {
        if (hasBudgetByCategory.contains(c.id)) continue;
        await AppSupabase.client.from('budgets').insert({
          'user_id': userId,
          'category_id': c.id,
          'monthly_limit': 0,
          'rollover_amount': 0,
          _budgetMonthColumn: monthYear,
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

  Future<void> upsertMonthlyBudgetByCategoryTitle({
    required String userId,
    required String categoryTitle,
    required double monthlyLimit,
    required String monthYear,
  }) async {
    if (monthlyLimit <= 0 || categoryTitle.trim().isEmpty) return;
    final normalizedTitle = normalizeCategoryKey(categoryTitle);

    final categoriesRows = await AppSupabase.client
        .from('categories')
        .select('id,name,user_id')
        .or('user_id.eq.$userId,user_id.is.null');
    final categories = (categoriesRows as List).whereType<Map<String, dynamic>>();

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
    final existing = (budgetRows as List).whereType<Map<String, dynamic>>().toList();
    if (existing.isNotEmpty) {
      await AppSupabase.client
          .from('budgets')
          .update({'monthly_limit': monthlyLimit})
          .eq('id', '${existing.first['id']}')
          .eq('user_id', userId);
      return;
    }

    await AppSupabase.client.from('budgets').insert({
      'user_id': userId,
      'category_id': categoryId,
      'monthly_limit': monthlyLimit,
      'rollover_amount': 0,
      _budgetMonthColumn: monthYear,
    });
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
      final accountName = ((row['account_name'] as String?) ?? '').trim();
      final accountType = ((row['account_type'] as String?) ?? '').trim();
      final accountSubtype = ((row['subtype'] as String?) ?? '').trim();
      final usesDepository = AppTransaction.usesDepositoryPolarity(
        accountName: accountName,
        accountType: accountType,
        accountSubtype: accountSubtype,
      );
      final isExpense = usesDepository ? amount < 0 : amount > 0;
      if (!isExpense) {
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
          spent: spentByCategoryName[titleKey] ?? 0,
          limit: yearly ? monthlyLimit * 12 : monthlyLimit,
        ),
      );
    }
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

  List<BudgetCategoryProgress> presetBudgetProgressAllTime(
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
    return rebased;
  }
}
