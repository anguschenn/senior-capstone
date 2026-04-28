import '../core/config/supabase_client.dart';
import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';

class AutoCategoryRule {
  const AutoCategoryRule({required this.category, required this.confidence});
  final String category;
  final String confidence;
}

/// Manages category fetching, budget-bucket mapping, and review overrides.
class CategoryService {
  const CategoryService._();
  static const instance = CategoryService._();

  String _norm(String raw) => raw.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  Future<Map<String, String>> _categoryNameById(String userId) async {
    final rows = await AppSupabase.client
        .from('categories')
        .select('id,name,user_id')
        .or('user_id.eq.$userId,user_id.is.null');
    return {
      for (final row in (rows as List).whereType<Map<String, dynamic>>())
        '${row['id']}': '${row['name'] ?? ''}',
    };
  }

  Future<String?> _categoryIdForName(String userId, String category) async {
    final normalized = normalizeCategoryKey(category);
    final rows = await AppSupabase.client
        .from('categories')
        .select('id,name,user_id')
        .or('user_id.eq.$userId,user_id.is.null');
    for (final row in (rows as List).whereType<Map<String, dynamic>>()) {
      if (normalizeCategoryKey('${row['name'] ?? ''}') == normalized) {
        return '${row['id']}';
      }
    }
    return null;
  }

  String ruleKeyForRawTransaction(Map<String, dynamic> row) {
    final description = _norm('${row['description'] ?? ''}');
    final tellerCategory = _norm('${row['teller_category'] ?? row['category'] ?? ''}');
    return '$description|$tellerCategory';
  }

  String ruleKeyForTransaction(AppTransaction tx) {
    final description = _norm(tx.description);
    final tellerCategory = _norm(tx.category);
    return '$description|$tellerCategory';
  }

  Future<Map<String, AutoCategoryRule>> fetchAutoCategoryRules(String userId) async {
    try {
      final categoryNameById = await _categoryNameById(userId);
      final rows = await AppSupabase.client
          .from('category_rules')
          .select('rule_key,category_id,confidence')
          .eq('user_id', userId);
      final out = <String, AutoCategoryRule>{};
      for (final row in (rows as List).whereType<Map<String, dynamic>>()) {
        final key = ((row['rule_key'] as String?) ?? '').trim();
        final categoryId = ((row['category_id'] as String?) ?? '').trim();
        final category = (categoryNameById[categoryId] ?? '').trim();
        final confidence = ((row['confidence'] as String?) ?? 'medium')
            .trim()
            .toLowerCase();
        if (key.isEmpty || category.isEmpty) continue;
        out[key] = AutoCategoryRule(category: category, confidence: confidence);
      }
      return out;
    } catch (_) {
      return const <String, AutoCategoryRule>{};
    }
  }

  Future<void> saveAutoCategoryRule({
    required String userId,
    required String ruleKey,
    required String category,
    String confidence = 'medium',
  }) async {
    if (ruleKey.trim().isEmpty || category.trim().isEmpty) return;
    try {
      final categoryId = await _categoryIdForName(userId, category.trim());
      if (categoryId == null || categoryId.isEmpty) return;
      await AppSupabase.client.from('category_rules').upsert({
        'user_id': userId,
        'rule_key': ruleKey.trim(),
        'category_id': categoryId,
        'confidence': confidence.trim().toLowerCase(),
      }, onConflict: 'user_id,rule_key');
    } catch (_) {}
  }

  Future<void> saveAutoCategoryRulesBatch({
    required String userId,
    required Map<String, AutoCategoryRule> rulesByKey,
  }) async {
    if (rulesByKey.isEmpty) return;
    final categoryNameById = await _categoryNameById(userId);
    final categoryIdByName = {
      for (final entry in categoryNameById.entries)
        normalizeCategoryKey(entry.value): entry.key,
    };
    final payload = <Map<String, dynamic>>[];
    for (final entry in rulesByKey.entries) {
      final key = entry.key.trim();
      final category = entry.value.category.trim();
      final confidence = entry.value.confidence.trim().toLowerCase();
      final categoryId = categoryIdByName[normalizeCategoryKey(category)];
      if (key.isEmpty || category.isEmpty) continue;
      if (categoryId == null || categoryId.isEmpty) continue;
      payload.add({
        'user_id': userId,
        'rule_key': key,
        'category_id': categoryId,
        'confidence': confidence.isEmpty ? 'medium' : confidence,
      });
    }
    if (payload.isEmpty) return;
    try {
      await AppSupabase.client
          .from('category_rules')
          .upsert(payload, onConflict: 'user_id,rule_key');
    } catch (_) {}
  }

  String inferSeedRuleConfidence({
    required Map<String, dynamic> row,
    required String category,
  }) {
    final cat = category.trim();
    final detailed = _norm('${row['teller_category'] ?? row['category'] ?? ''}');
    final type = _norm('${row['transaction_type'] ?? ''}');
    final desc = _norm('${row['description'] ?? ''}');

    final categorySignal = cat.isNotEmpty && cat != 'Other';
    final descriptionSignal = RegExp(
      r'\b(atm|withdrawal|cash|zelle|transfer|wire|ach|rent|mortgage|water|electric|utility|internet|phone|dining|restaurant|grocer|shopping|fuel|medical|pharmacy|software|subscription)\b',
      caseSensitive: false,
    ).hasMatch('$desc $detailed $type');

    final hitCount = (categorySignal ? 1 : 0) + (descriptionSignal ? 1 : 0);
    if (hitCount >= 2) return 'high';
    if (hitCount == 1) return 'medium';
    return 'low';
  }

  Future<List<CategoryOption>> ensureBaseCategories(String userId) async {
    try {
      final existingRows = await AppSupabase.client
          .from('categories')
          .select('id,name,user_id,is_custom')
          .or('user_id.eq.$userId,user_id.is.null');
      final existing = (existingRows as List)
          .whereType<Map<String, dynamic>>()
          .toList();
      final existingNames = {
        for (final row in existing)
          normalizeCategoryKey('${row['name'] ?? ''}'),
      };

      final missingDefaults = <String>[];
      for (final name in kPresetBudgetCategories) {
        if (!existingNames.contains(normalizeCategoryKey(name))) {
          missingDefaults.add(name);
        }
      }

      if (missingDefaults.isNotEmpty) {
        final payload = [
          for (final name in missingDefaults)
            {
              'user_id': userId,
              'name': name,
              'is_custom': false,
            },
        ];
        await AppSupabase.client.from('categories').insert(payload);
      }

      final rows = await AppSupabase.client
          .from('categories')
          .select('id,name,user_id')
          .or('user_id.eq.$userId,user_id.is.null');
      return (rows as List)
          .whereType<Map<String, dynamic>>()
          .map((r) => CategoryOption(id: '${r['id']}', name: '${r['name']}'))
          .where((c) => c.id.isNotEmpty && c.name.isNotEmpty)
          .toList();
    } catch (_) {
      return const [];
    }
  }

  /// Resolves a transaction into a budget bucket, preferring manual overrides.
  String budgetBucketFor(
    AppTransaction tx,
    Map<String, String> reviewedCategoryByTxId,
  ) {
    final reviewed = reviewedCategoryByTxId[tx.id];
    if (reviewed != null && reviewed.isNotEmpty) return reviewed;
    return budgetCategoryFromPfc(
      pfcDetailed: tx.category,
      pfcPrimary: tx.primaryCategory,
    );
  }

  /// Same mapping but for raw Supabase rows before model conversion.
  String budgetBucketForRawTransaction(
    Map<String, dynamic> row,
    Map<String, String> reviewedCategoryByTxId,
  ) {
    final txId = ((row['teller_transaction_id'] as String?) ?? '').trim();
    final reviewed = reviewedCategoryByTxId[txId];
    if (reviewed != null && reviewed.isNotEmpty) return reviewed;
    return budgetCategoryFromPfc(
      pfcDetailed:
          ((row['teller_category'] as String?) ??
                  (row['category'] as String?) ??
                  '')
              .trim(),
      pfcPrimary:
          ((row['transaction_type'] as String?) ?? '')
              .trim(),
    );
  }
}
