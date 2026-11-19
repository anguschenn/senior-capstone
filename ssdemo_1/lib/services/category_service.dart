import 'package:flutter/foundation.dart';

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

  /// The user's own categories, by name, set by MainScreenController after
  /// every load. The transaction category picker shows them as choices.
  static final customCategoryNames = ValueNotifier<List<String>>(const []);

  /// Whether [name] is one of the app's own categories (kReviewCategories).
  static bool isBuiltInCategory(String name) {
    final key = normalizeCategoryKey(name);
    return kReviewCategories.any((c) => normalizeCategoryKey(c) == key);
  }

  /// [categories]' names that aren't built in, once each, in order.
  static List<String> customNamesFrom(List<CategoryOption> categories) {
    final seen = <String>{};
    return [
      for (final c in categories)
        if (!isBuiltInCategory(c.name) &&
            seen.add(normalizeCategoryKey(c.name)))
          c.name.trim(),
    ];
  }

  // Built once: _norm runs for every transaction on each sync.
  static final _separators = RegExp(r'[_\s]+');

  String _norm(String raw) =>
      raw.trim().toLowerCase().replaceAll(_separators, ' ');

  String _normToken(String raw) {
    final v = _norm(raw);
    return v.isEmpty ? '_' : v;
  }

  /// Mirrors budget_progress.py's normalize_merchant / subscription_detector.py's
  /// normalize_merchant: lowercase, drop a trailing inc/llc/ltd/corp/.com, strip
  /// punctuation, collapse whitespace. Used to match a transaction against the
  /// subscriptions table's merchant identity.
  static String normalizeMerchant(String name) {
    var value = name.trim().toLowerCase();
    value = value.replaceFirst(
      RegExp(r'\s*(inc\.?|llc\.?|ltd\.?|corp\.?|co\.?|\.com)$'),
      '',
    );
    value = value.replaceAll(RegExp(r'[^\w\s]'), ' ');
    value = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return value;
  }

  /// Normalized merchant names of the user's active, confirmed subscriptions -- the
  /// same set the Subscriptions page's "Confirmed" section shows.
  static Set<String> confirmedSubscriptionMerchantsFrom(
    List<DetectedSubscription> subscriptions,
  ) {
    return {
      for (final s in subscriptions)
        if (!s.needsConfirmation) normalizeMerchant(s.merchant),
    };
  }

  /// Same, from the raw subscription rows a sync reads before they're parsed into
  /// DetectedSubscription (SyncService.buildResult, which already filters is_active).
  static Set<String> confirmedSubscriptionMerchantsFromRows(
    List<Map<String, dynamic>> subscriptionRows,
  ) {
    final out = <String>{};
    for (final row in subscriptionRows) {
      if (row['needs_confirmation'] == true) continue;
      final merchant = ((row['merchant_name'] as String?) ?? '').trim();
      if (merchant.isEmpty) continue;
      out.add(normalizeMerchant(merchant));
    }
    return out;
  }

  bool _matchesConfirmedSubscription(
    String text,
    Set<String>? confirmedSubscriptionMerchants,
  ) {
    if (confirmedSubscriptionMerchants == null ||
        confirmedSubscriptionMerchants.isEmpty) {
      return false;
    }
    final normText = normalizeMerchant(text);
    return confirmedSubscriptionMerchants.any(
      (m) => m.isNotEmpty && normText.contains(m),
    );
  }

  // "Subscriptions" is deliberately not reachable here or from PFC alone (removed: a
  // keyword/PFC match had no requirement the merchant ever recurred, so a one-off
  // purchase from a subscription-type brand got miscounted). The only way to land in
  // Subscriptions now is the confirmed-subscriptions check in _strongSignalOverride, or
  // the user's own pick -- both guaranteed to agree with the Subscriptions page.
  String _keywordFallbackCategory(String merchantName, String transactionName) {
    final text = '${merchantName.trim()} ${transactionName.trim()}'
        .toLowerCase();
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
    Set<String>? confirmedSubscriptionMerchants,
  }) {
    final primary = pfcPrimary.toLowerCase();
    final detailed = pfcDetailed.toLowerCase();
    final text = '${merchantName.trim()} ${transactionName.trim()}'
        .toLowerCase();

    // The user's own subscriptions table already proved this merchant is an active,
    // confirmed recurring charge -- that beats any keyword/PFC guess below.
    if (_matchesConfirmedSubscription(text, confirmedSubscriptionMerchants)) {
      return const CategoryDecision(
        category: 'Subscriptions',
        confidence: 'high',
      );
    }

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
    Set<String>? confirmedSubscriptionMerchants,
  }) {
    final strong = _strongSignalOverride(
      pfcPrimary: pfcPrimary,
      pfcDetailed: pfcDetailed,
      merchantName: merchantName,
      transactionName: transactionName,
      confirmedSubscriptionMerchants: confirmedSubscriptionMerchants,
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

  /// The user's category named [name] (any spelling), created if missing.
  /// The same row backs a transaction's category and its budget card.
  Future<CategoryOption> createCustomCategory(
    String userId,
    String name,
  ) async {
    final trimmed = name.trim();
    final key = normalizeCategoryKey(trimmed);
    final rows = await AppSupabase.client
        .from('categories')
        .select('id,name')
        .or('user_id.eq.$userId,user_id.is.null');
    for (final row in (rows as List).whereType<Map<String, dynamic>>()) {
      if (normalizeCategoryKey('${row['name'] ?? ''}') == key) {
        return CategoryOption(id: '${row['id']}', name: '${row['name']}');
      }
    }
    final inserted = await AppSupabase.client
        .from('categories')
        .insert({'user_id': userId, 'name': trimmed, 'is_custom': true})
        .select('id,name')
        .single();
    return CategoryOption(id: '${inserted['id']}', name: '${inserted['name']}');
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
    Map<String, String> reviewedCategoryByTxId, {
    Set<String>? confirmedSubscriptionMerchants,
  }) {
    final reviewed = reviewedCategoryByTxId[tx.id];
    if (reviewed != null && reviewed.isNotEmpty) return reviewed;
    final merchantName = tx.rawMerchantName.isNotEmpty
        ? tx.rawMerchantName
        : tx.name;
    if (_matchesConfirmedSubscription(
      '$merchantName ${tx.name}',
      confirmedSubscriptionMerchants,
    )) {
      return 'Subscriptions';
    }
    return budgetCategoryFromPfc(
      pfcDetailed: tx.category,
      pfcPrimary: tx.primaryCategory,
    );
  }

  /// Same mapping but for raw Supabase rows before model conversion.
  String budgetBucketForRawTransaction(
    Map<String, dynamic> row,
    Map<String, String> reviewedCategoryByTxId, {
    Set<String>? confirmedSubscriptionMerchants,
  }) {
    final txId = ((row['plaid_transaction_id'] as String?) ?? '').trim();
    final reviewed = reviewedCategoryByTxId[txId];
    if (reviewed != null && reviewed.isNotEmpty) return reviewed;
    final merchantName =
        ((row['name'] as String?) ?? (row['merchant_name'] as String?) ?? '')
            .trim();
    if (_matchesConfirmedSubscription(
      merchantName,
      confirmedSubscriptionMerchants,
    )) {
      return 'Subscriptions';
    }
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
