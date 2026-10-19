import 'package:shared_preferences/shared_preferences.dart';

import '../core/config/supabase_client.dart';
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

  /// An `ai_chat_messages` row for [userId] and [accountScope].
  Map<String, dynamic> toRow(String userId, String accountScope) => {
    'user_id': userId,
    'account_scope': accountScope,
    'prompt': prompt,
    'response': response.toJson(),
    'asked_at': askedAt.toUtc().toIso8601String(),
  };

  static SavedChatTurn? fromRow(Object? raw) {
    if (raw is! Map) return null;
    final prompt = raw['prompt'];
    final response = raw['response'];
    final askedAt = DateTime.tryParse('${raw['asked_at']}');
    if (prompt is! String || response is! Map || askedAt == null) return null;
    return SavedChatTurn(
      prompt: prompt,
      response: AiChatResponse.fromJson(Map<String, dynamic>.from(response)),
      askedAt: askedAt.toLocal(),
    );
  }
}

/// The AI chat history in Supabase (`ai_chat_messages`, see
/// db/migrations/013_ai_chat_messages.sql), so a conversation is still there
/// after a reload or on another device.
///
/// Kept per user and account scope; the table keeps the newest [maxTurns]
/// questions. RLS limits every user to their own rows. Every method is
/// best-effort: a storage failure must never break the chat.
class ChatHistoryStore {
  const ChatHistoryStore._();
  static const instance = ChatHistoryStore._();

  /// Questions kept per account scope; the table trims older ones.
  static const maxTurns = 30;
  static const _table = 'ai_chat_messages';

  Future<List<SavedChatTurn>> load(String userId, String accountScope) async {
    try {
      final rows = await AppSupabase.client
          .from(_table)
          .select('prompt,response,asked_at')
          .eq('user_id', userId)
          .eq('account_scope', accountScope)
          .order('asked_at', ascending: false)
          .limit(maxTurns);
      return [
        for (final row in (rows as List).reversed) ?SavedChatTurn.fromRow(row),
      ];
    } catch (_) {
      return const [];
    }
  }

  Future<void> add(
    String userId,
    String accountScope,
    SavedChatTurn turn,
  ) async {
    try {
      await AppSupabase.client
          .from(_table)
          .insert(turn.toRow(userId, accountScope));
    } catch (_) {}
  }

  /// Deletes chats an earlier version kept on the device, now that they
  /// live in Supabase.
  Future<void> removeDeviceCopies() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final keys = prefs.getKeys().where((k) => k.startsWith(_devicePrefix));
      for (final key in keys.toList()) {
        await prefs.remove(key);
      }
    } catch (_) {}
  }

  static const _devicePrefix = 'smartspend.ai_chat.';

  /// Removes one account scope's chat.
  Future<void> clear(String userId, String accountScope) async {
    try {
      await AppSupabase.client
          .from(_table)
          .delete()
          .eq('user_id', userId)
          .eq('account_scope', accountScope);
    } catch (_) {}
  }
}
