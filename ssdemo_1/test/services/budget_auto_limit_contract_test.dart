// Shared contract with the Python backend (python/user_model.py auto_limits).
// Both build a new month's budget limits from the same history and must equal
// the fixture's `expected`; otherwise a limit the app sets on the 1st would be
// second-guessed by a server suggestion right away.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/services/budget_service.dart';

final _fixture =
    jsonDecode(
          File(
            '../python/tests/data/budget_auto_limit_contract.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

void main() {
  group('budget auto-limit contract', () {
    for (final raw in _fixture['cases'] as List) {
      final testCase = raw as Map<String, dynamic>;
      test(testCase['description'], () {
        final previous = {
          for (final entry
              in (testCase['previous'] as Map<String, dynamic>).entries)
            entry.key: (
              limit: ((entry.value as Map)['limit'] as num).toDouble(),
              source: (entry.value as Map)['source'] as String,
            ),
        };
        final actual = BudgetService.autoLimits(
          stats: (testCase['stats'] as List).cast<Map<String, dynamic>>(),
          cardNames: (testCase['cards'] as List).cast<String>(),
          previous: previous,
          month: testCase['month'] as String,
        );
        final expected = testCase['expected'] as Map<String, dynamic>;
        expect(actual.keys.toSet(), expected.keys.toSet());
        for (final entry in expected.entries) {
          final want = entry.value as Map<String, dynamic>;
          expect(
            actual[entry.key]!.limit,
            (want['limit'] as num).toDouble(),
            reason: entry.key,
          );
          expect(actual[entry.key]!.source, want['source'], reason: entry.key);
        }
      });
    }
  });

  test('historyLimits is the trimmed mean and counts its months', () {
    Map<String, dynamic> stat(String month, double spent) => {
      'month': month,
      'category': 'Groceries',
      'spent': spent,
    };
    final limits = BudgetService.historyLimits(
      stats: [
        stat('2026-07', 100),
        stat('2026-08', 300),
        stat('2026-09', 320),
        stat('2026-10', 900),
      ],
      cardNames: ['Groceries', 'Travel'],
      month: '2026-11',
    );
    // 100 and 900 are dropped: (300 + 320) / 2 = 310.
    expect(limits['Groceries'], (limit: 310.0, months: 4));
    expect(limits['Travel'], (limit: 0.0, months: 4));
  });

  test('historyLimits needs 3 months with spending', () {
    final limits = BudgetService.historyLimits(
      stats: [
        {'month': '2026-09', 'category': 'Groceries', 'spent': 300},
        {'month': '2026-10', 'category': 'Groceries', 'spent': 320},
      ],
      cardNames: ['Groceries'],
      month: '2026-11',
    );
    expect(limits, isEmpty);
  });

  test('previousMonths crosses the year boundary', () {
    expect(BudgetService.previousMonths('2027-02', 3), [
      '2026-11',
      '2026-12',
      '2027-01',
    ]);
  });
}
