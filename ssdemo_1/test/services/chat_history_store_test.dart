import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssdemo_1/models/ai/ai_models.dart';
import 'package:ssdemo_1/services/chat_history_store.dart';

SavedChatTurn _turn(int i) => SavedChatTurn(
  prompt: 'question $i',
  response: AiChatResponse(
    copy: 'answer $i',
    insights: const ['an insight'],
    actions: const ['an action'],
    answerSource: 'deterministic',
  ),
  askedAt: DateTime(2026, 10, 19, 12, i % 60),
);

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('a saved chat comes back with its answers', () async {
    const store = ChatHistoryStore.instance;
    await store.save('user-1', 'all', [_turn(1), _turn(2)]);
    final loaded = await store.load('user-1', 'all');
    expect(loaded.map((t) => t.prompt), ['question 1', 'question 2']);
    expect(loaded.last.response.copy, 'answer 2');
    expect(loaded.last.response.insights, ['an insight']);
    expect(loaded.last.response.answerSource, 'deterministic');
    expect(loaded.last.askedAt, DateTime(2026, 10, 19, 12, 2));
  });

  test('keeps the newest 30 questions per account and user', () async {
    const store = ChatHistoryStore.instance;
    await store.save('user-1', 'all', [for (var i = 0; i < 35; i++) _turn(i)]);
    final loaded = await store.load('user-1', 'all');
    expect(loaded, hasLength(ChatHistoryStore.maxTurns));
    expect(loaded.first.prompt, 'question 5');
    expect(await store.load('user-1', 'card'), isEmpty);
    expect(await store.load('user-2', 'all'), isEmpty);
  });

  test('clear removes one scope, or everything on sign-out', () async {
    const store = ChatHistoryStore.instance;
    await store.save('user-1', 'all', [_turn(1)]);
    await store.save('user-1', 'card', [_turn(2)]);
    await store.clear(userId: 'user-1', accountId: 'all');
    expect(await store.load('user-1', 'all'), isEmpty);
    expect(await store.load('user-1', 'card'), hasLength(1));
    await store.clear();
    expect(await store.load('user-1', 'card'), isEmpty);
  });
}
