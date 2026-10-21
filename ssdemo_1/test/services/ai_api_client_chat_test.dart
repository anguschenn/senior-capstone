import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:ssdemo_1/services/ai_api_client.dart';

const _summary = {'version': 3, 'scope': 'all_accounts'};
final _uri = Uri.parse('https://backend.test/api/ai/chat');

Future<List<Map<String, dynamic>>> _send(
  List<Map<String, dynamic>> replies, {
  Map<String, dynamic>? context,
}) async {
  final bodies = <Map<String, dynamic>>[];
  final client = MockClient((request) async {
    bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
    return http.Response(
      jsonEncode(replies[bodies.length - 1]),
      200,
      headers: {'content-type': 'application/json'},
    );
  });
  await http.runWithClient(
    () => const AiApiClient().sendChat(
      uri: _uri,
      apiKey: 'k',
      prompt: 'How much did I spend?',
      history: const [],
      spendingSummary: _summary,
      context: context,
    ),
    () => client,
  );
  return bodies;
}

void main() {
  final context = AiApiClient.chatContext(
    accountIds: const [],
    selectedMonth: DateTime(2026, 10),
    allYear: false,
    scopeLabel: 'Overall (All Accounts)',
    now: DateTime(2026, 10, 10, 9),
  );

  test('with a context only the context is sent', () async {
    final bodies = await _send([
      {'reply': 'ok'},
    ], context: context);
    expect(bodies, hasLength(1));
    expect(bodies.single.containsKey('spending_summary'), isFalse);
    expect(bodies.single['context']['selected_month'], '2026-10');
    expect(bodies.single['context']['today'], '2026-10-10');
  });

  test('the summary is resent once when the server asks for it', () async {
    final bodies = await _send([
      {'retry_with_summary': true},
      {'reply': 'ok'},
    ], context: context);
    expect(bodies, hasLength(2));
    expect(bodies[1]['spending_summary'], _summary);
  });

  test('without a context the summary is sent as before', () async {
    final bodies = await _send([
      {'reply': 'ok'},
    ]);
    expect(bodies.single['spending_summary'], _summary);
    expect(bodies.single.containsKey('context'), isFalse);
  });

  test('the all-year view sends just the year', () {
    final all = AiApiClient.chatContext(
      accountIds: const ['a'],
      selectedMonth: DateTime(2026, 1, 2),
      allYear: true,
      scopeLabel: 'Card',
    );
    expect(all['selected_month'], '2026');
    expect(all['account_ids'], ['a']);
  });

  test('hidden accounts are sent only when there are some', () {
    final none = AiApiClient.chatContext(
      accountIds: const [],
      selectedMonth: DateTime(2026, 10),
      allYear: false,
      scopeLabel: 'All',
    );
    expect(none.containsKey('hidden_account_ids'), isFalse);
    final hidden = AiApiClient.chatContext(
      accountIds: const [],
      hiddenAccountIds: const ['card'],
      selectedMonth: DateTime(2026, 10),
      allYear: false,
      scopeLabel: 'All',
    );
    expect(hidden['hidden_account_ids'], ['card']);
    expect(hidden['account_ids'], isEmpty);
  });
}
