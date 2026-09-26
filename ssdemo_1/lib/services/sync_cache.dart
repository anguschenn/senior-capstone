import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/app_models.dart';

/// The raw rows behind one Supabase refresh.
///
/// Held as plain JSON-safe data (not the parsed models) so the last successful
/// load can be persisted as-is and re-parsed by `SyncService.buildResult` on the
/// next launch, with no separate serialization for every model class.
class RawSyncData {
  const RawSyncData({
    required this.userId,
    required this.monthYear,
    required this.savedAt,
    required this.accountsRows,
    required this.categories,
    required this.budgetRows,
    required this.subscriptionRows,
    required this.txRows,
    required this.rememberedRules,
  });

  final String userId;

  /// Month the budget rows belong to ("YYYY-MM").
  final String monthYear;
  final DateTime savedAt;
  final List<Map<String, dynamic>> accountsRows;
  final List<CategoryOption> categories;
  final List<Map<String, dynamic>> budgetRows;
  final List<Map<String, dynamic>> subscriptionRows;
  final List<Map<String, dynamic>> txRows;

  /// rule_key -> {category, confidence}
  final Map<String, Map<String, String>> rememberedRules;

  /// Same data without budgets, for when the saved month is no longer the one
  /// being viewed (budget limits are stored per month).
  RawSyncData withoutBudgets() => RawSyncData(
    userId: userId,
    monthYear: monthYear,
    savedAt: savedAt,
    accountsRows: accountsRows,
    categories: categories,
    budgetRows: const [],
    subscriptionRows: subscriptionRows,
    txRows: txRows,
    rememberedRules: rememberedRules,
  );

  Map<String, dynamic> toJson() => {
    'v': SyncCache.version,
    'userId': userId,
    'monthYear': monthYear,
    'savedAt': savedAt.toIso8601String(),
    'accountsRows': accountsRows,
    'categories': [
      for (final c in categories) {'id': c.id, 'name': c.name},
    ],
    'budgetRows': budgetRows,
    'subscriptionRows': subscriptionRows,
    'txRows': txRows,
    'rememberedRules': rememberedRules,
  };

  /// Returns null for anything that isn't a well-formed, current-version entry.
  static RawSyncData? fromJson(Object? decoded) {
    try {
      if (decoded is! Map || decoded['v'] != SyncCache.version) return null;
      List<Map<String, dynamic>> rows(String key) => [
        for (final row in decoded[key] as List)
          Map<String, dynamic>.from(row as Map),
      ];
      return RawSyncData(
        userId: decoded['userId'] as String,
        monthYear: decoded['monthYear'] as String,
        savedAt: DateTime.parse(decoded['savedAt'] as String),
        accountsRows: rows('accountsRows'),
        categories: [
          for (final c in decoded['categories'] as List)
            CategoryOption(
              id: (c as Map)['id'] as String,
              name: c['name'] as String,
            ),
        ],
        budgetRows: rows('budgetRows'),
        subscriptionRows: rows('subscriptionRows'),
        txRows: rows('txRows'),
        rememberedRules: {
          for (final e in (decoded['rememberedRules'] as Map).entries)
            e.key as String: {
              'category': (e.value as Map)['category'] as String,
              'confidence': e.value['confidence'] as String,
            },
        },
      );
    } catch (_) {
      return null;
    }
  }
}

/// On-device copy of the last successful sync, so the app can paint real data
/// on launch without waiting on the network.
///
/// Entries are keyed by user id and cleared on sign-out. Every method is
/// best-effort: a storage failure must never break loading.
class SyncCache {
  const SyncCache._();
  static const instance = SyncCache._();

  static const version = 1;
  static const _prefix = 'smartspend.sync_cache.';

  String _key(String userId) => '$_prefix$userId';

  Future<void> save(RawSyncData data) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_key(data.userId), jsonEncode(data.toJson()));
    } catch (_) {}
  }

  /// The saved data for [userId], or null when there is none, it is from an
  /// older format, or it is unreadable.
  Future<RawSyncData?> load(String userId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(userId));
      if (raw == null) return null;
      Object? decoded;
      try {
        decoded = jsonDecode(raw);
      } catch (_) {
        decoded = null;
      }
      final data = RawSyncData.fromJson(decoded);
      if (data == null || data.userId != userId) {
        await prefs.remove(_key(userId));
        return null;
      }
      return data;
    } catch (_) {
      return null;
    }
  }

  /// Removes every user's saved data (used on sign-out and "Clear").
  Future<void> clear() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }
}
