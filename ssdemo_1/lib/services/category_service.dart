import '../core/config/supabase_client.dart';
import '../constants/app_constants.dart';
import '../models/app_models.dart';
import '../utils/app_helpers.dart';

class CategoryDecision {
  const CategoryDecision({required this.category, required this.confidence});
  final String category;
  final String confidence; // high | mid | low
}

/// Manages category fetching, budget-bucket mapping, and review overrides.
class CategoryService {
  const CategoryService._();
  static const instance = CategoryService._();

  String _norm(String raw) => raw
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[_\s]+'), ' ')
      .replaceAll(RegExp(r'\s+'), ' ');

  String _normToken(String raw) {
    final v = _norm(raw);
    return v.isEmpty ? '_' : v;
  }

  String _keywordFallbackCategory(String merchantName, String transactionName) {
    final text = '${merchantName.trim()} ${transactionName.trim()}'.toLowerCase();
    if (text.contains('openai') ||
        text.contains('chatgpt') ||
        text.contains('spotify') ||
        text.contains('netflix') ||
        text.contains('apple.com/bill') ||
        text.contains('youtube premium')) {
      return 'Subscriptions';
    }
    if (text.contains('starbucks') ||
        text.contains('mcdonald') ||
        text.contains('doordash') ||
        text.contains('ubereats')) {
      return 'Food';
    }
    if (text.contains('paypal transfer') ||
        text.contains('zelle payment') ||
        text.contains('venmo') ||
        text.contains('payment to chase card') ||
        text.contains('transfer ppd') ||
        text.contains('cash deposit')) {
      return 'Fees & Transfers';
    }
    return '';
  }

  CategoryDecision? _strongSignalOverride({
    required String pfcPrimary,
    required String pfcDetailed,
    required String merchantName,
    required String transactionName,
  }) {
    final primary = pfcPrimary.toLowerCase();
    final detailed = pfcDetailed.toLowerCase();
    final text = '${merchantName.trim()} ${transactionName.trim()}'.toLowerCase();

    // High-confidence payment/transfer classes from provider signals.
    if (detailed.contains('loan_payments_credit_card_payment') ||
        detailed.contains('transfer_out_account_transfer') ||
        detailed.contains('transfer_in_deposit') ||
        detailed.contains('bank_fees')) {
      return const CategoryDecision(
        category: 'Fees & Transfers',
        confidence: 'high',
      );
    }
    if (primary.contains('loan_payments') ||
        primary.contains('transfer_out') ||
        primary.contains('transfer_in') ||
        primary.contains('bank_fees')) {
      return const CategoryDecision(
        category: 'Fees & Transfers',
        confidence: 'high',
      );
    }

    // High-confidence merchant/name signals.
    if (text.contains('payment to chase card') ||
        text.contains('paypal transfer') ||
        text.contains('zelle payment') ||
        text.contains('venmo')) {
      return const CategoryDecision(
        category: 'Fees & Transfers',
        confidence: 'high',
      );
    }
    if (text.contains('openai') ||
        text.contains('chatgpt') ||
        text.contains('spotify') ||
        text.contains('netflix')) {
      return const CategoryDecision(
        category: 'Subscriptions',
        confidence: 'high',
      );
    }
    return null;
  }

  String buildRuleKey({
    required String merchantName,
    required String pfcPrimary,
    required String pfcDetailed,
  }) {
    return '${_normToken(merchantName)}|${_normToken(pfcPrimary)}|${_normToken(pfcDetailed)}';
  }

  String ruleKeyForTransaction(AppTransaction tx) {
    return buildRuleKey(
      merchantName: tx.rawMerchantName.isNotEmpty
          ? tx.rawMerchantName
          : tx.name,
      pfcPrimary: tx.rawPfcPrimary,
      pfcDetailed: tx.rawPfcDetailed,
    );
  }

  String ruleKeyForRawTransaction(Map<String, dynamic> row) {
    final merchantName =
        ((row['name'] as String?) ?? (row['merchant_name'] as String?) ?? '')
            .trim();
    final pfcPrimary = ((row['pfc_primary'] as String?) ?? '').trim();
    final pfcDetailed =
        ((row['pfc_detailed'] as String?) ?? (row['category'] as String?) ?? '')
            .trim();
    return buildRuleKey(
      merchantName: merchantName,
      pfcPrimary: pfcPrimary,
      pfcDetailed: pfcDetailed,
    );
  }

  Future<Map<String, CategoryDecision>> fetchRememberedRuleDecisions(
    String userId,
  ) async {
    try {
      final rows = await AppSupabase.client
          .from('category_match_rules')
          .select('rule_key,category,confidence')
          .eq('user_id', userId);
      final out = <String, CategoryDecision>{};
      for (final row in (rows as List).whereType<Map<String, dynamic>>()) {
        final key = ((row['rule_key'] as String?) ?? '').trim();
        final category = ((row['category'] as String?) ?? '').trim();
        final confidence = ((row['confidence'] as String?) ?? 'high')
            .trim()
            .toLowerCase();
        if (key.isEmpty || category.isEmpty) continue;
        out[key] = CategoryDecision(
          category: category,
          confidence: confidence.isEmpty ? 'high' : confidence,
        );
      }
      return out;
    } catch (_) {
      return const <String, CategoryDecision>{};
    }
  }

  Future<bool> rememberRuleDecision({
    required String userId,
    required String ruleKey,
    required String category,
  }) async {
    if (ruleKey.trim().isEmpty || category.trim().isEmpty) return false;
    try {
      await AppSupabase.client.from('category_match_rules').upsert({
        'user_id': userId,
        'rule_key': ruleKey.trim(),
        'category': category.trim(),
        'confidence': 'high',
      }, onConflict: 'user_id,rule_key');
      return true;
    } catch (_) {
      return false;
    }
  }

  CategoryDecision classifyByPfcSignals({
    required String pfcPrimary,
    required String pfcDetailed,
    String merchantName = '',
    String transactionName = '',
  }) {
    final strong = _strongSignalOverride(
      pfcPrimary: pfcPrimary,
      pfcDetailed: pfcDetailed,
      merchantName: merchantName,
      transactionName: transactionName,
    );
    if (strong != null) return strong;

    final primaryCategory = budgetCategoryFromPfc(
      pfcDetailed: '',
      pfcPrimary: pfcPrimary,
    );
    final detailedCategory = budgetCategoryFromPfc(
      pfcDetailed: pfcDetailed,
      pfcPrimary: '',
    );
    final keywordCategory = _keywordFallbackCategory(
      merchantName,
      transactionName,
    );

    final hits = <String>[
      if (pfcPrimary.trim().isNotEmpty && primaryCategory != 'Other')
        primaryCategory,
      if (pfcDetailed.trim().isNotEmpty && detailedCategory != 'Other')
        detailedCategory,
      if (keywordCategory.isNotEmpty) keywordCategory,
    ];

    if (hits.isEmpty) {
      return const CategoryDecision(category: 'Other', confidence: 'low');
    }

    final normalizedUnique = <String>{
      for (final category in hits) normalizeCategoryKey(category),
    };

    // Product rule:
    // - Only one signal hit => low confidence (send to review queue).
    // - Multiple hits but conflicting categories => low confidence.
    if (hits.length == 1 || normalizedUnique.length > 1) {
      return CategoryDecision(category: hits.first, confidence: 'low');
    }

    final resolved = hits.last;
    final confidence = hits.length >= 3 ? 'high' : 'mid';
    return CategoryDecision(category: resolved, confidence: confidence);
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
            {'user_id': userId, 'name': name, 'is_custom': false},
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
    final txId = ((row['plaid_transaction_id'] as String?) ?? '').trim();
    final reviewed = reviewedCategoryByTxId[txId];
    if (reviewed != null && reviewed.isNotEmpty) return reviewed;
    return budgetCategoryFromPfc(
      pfcDetailed:
          ((row['pfc_detailed'] as String?) ??
                  (row['category'] as String?) ??
                  '')
              .trim(),
      pfcPrimary: ((row['pfc_primary'] as String?) ?? '').trim(),
    );
  }
}
