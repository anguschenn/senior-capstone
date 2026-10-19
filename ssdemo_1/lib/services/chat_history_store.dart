import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import '../models/ai/ai_models.dart';

/// One answered question in the AI chat.
class SavedChatTurn {
  const SavedChatTurn({
    required this.prompt,
    required this.response,
    required this.askedAt,
  });

  final String prompt;
  final AiChatResponse response;
  final DateTime askedAt;

  Map<String, dynamic> toJson() => {
    'prompt': prompt,
    'response': response.toJson(),
    'asked_at': askedAt.toIso8601String(),
  };

  static SavedChatTurn? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final prompt = raw['prompt'];
    final response = raw['response'];
    final askedAt = DateTime.tryParse('${raw['asked_at']}');
    if (prompt is! String || response is! Map || askedAt == null) return null;
    return SavedChatTurn(
      prompt: prompt,
      response: AiChatResponse.fromJson(Map<String, dynamic>.from(response)),
      askedAt: askedAt,
    );
  }
}

/// On-device copy of the AI chat, so it is still there after closing the
/// panel or reloading the app.
///
/// Kept per user and account scope, newest [maxTurns] questions only, and
/// cleared on sign-out. Every method is best-effort: a storage failure must
/// never break the chat.
class ChatHistoryStore {
  const ChatHistoryStore._();
  static const instance = ChatHistoryStore._();

  /// Questions kept per account scope; older ones drop off.
  static const maxTurns = 30;
  static const _prefix = 'smartspend.ai_chat.';

  String _key(String userId, String accountId) => '$_prefix$userId|$accountId';

  Future<List<SavedChatTurn>> load(String userId, String accountId) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.getString(_key(userId, accountId));
      if (raw == null) return const [];
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      return [for (final item in decoded) ?SavedChatTurn.fromJson(item)];
    } catch (_) {
      return const [];
    }
  }

  Future<void> save(
    String userId,
    String accountId,
    List<SavedChatTurn> turns,
  ) async {
    try {
      final kept = turns.length > maxTurns
          ? turns.sublist(turns.length - maxTurns)
          : turns;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(
        _key(userId, accountId),
        jsonEncode([for (final turn in kept) turn.toJson()]),
      );
    } catch (_) {}
  }

  /// Removes one scope's chat, or every saved chat when no user is given
  /// (used on sign-out).
  Future<void> clear({String? userId, String? accountId}) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (userId != null && accountId != null) {
        await prefs.remove(_key(userId, accountId));
        return;
      }
      final keys = prefs.getKeys().where((k) => k.startsWith(_prefix)).toList();
      for (final key in keys) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }
}
