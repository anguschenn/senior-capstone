import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssdemo_1/models/ai/ai_models.dart';
import 'package:ssdemo_1/services/chat_history_store.dart';

void main() {
  final turn = SavedChatTurn(
    prompt: 'How much did I spend this month?',
    response: const AiChatResponse(
      copy: 'For 2026-10, total expenses are about \$1234.',
      insights: ['From validated summary indexes.'],
      actions: ['Ask for a category breakdown.'],
      answerSource: 'deterministic',
      intent: 'amount_lookup',
    ),
    askedAt: DateTime.utc(2026, 10, 19, 22, 48),
  );

  test('a chat turn round-trips through an ai_chat_messages row', () {
    final row = turn.toRow('user-1', 'all');
    expect(row['user_id'], 'user-1');
    expect(row['account_scope'], 'all');
    expect(row['asked_at'], '2026-10-19T22:48:00.000Z');

    final back = SavedChatTurn.fromRow(row)!;
    expect(back.prompt, turn.prompt);
    expect(back.response.copy, turn.response.copy);
    expect(back.response.insights, turn.response.insights);
    expect(back.response.actions, turn.response.actions);
    expect(back.response.answerSource, 'deterministic');
    expect(back.askedAt.toUtc(), DateTime.utc(2026, 10, 19, 22, 48));
  });

  test('a malformed row is skipped', () {
    expect(SavedChatTurn.fromRow(null), isNull);
    expect(SavedChatTurn.fromRow({'prompt': 'hi'}), isNull);
    expect(
      SavedChatTurn.fromRow({
        'prompt': 'hi',
        'response': {'reply': 'x'},
        'asked_at': 'not a date',
      }),
      isNull,
    );
  });

  test('device copies from the earlier version are removed', () async {
    SharedPreferences.setMockInitialValues({
      'smartspend.ai_chat.user-1|all': '[]',
      'smartspend.sync_cache.user-1': '{}',
    });
    await ChatHistoryStore.instance.removeDeviceCopies();
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {'smartspend.sync_cache.user-1'});
  });
}
