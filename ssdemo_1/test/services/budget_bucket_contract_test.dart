// Shared contract with the Python backend (python/budget_progress.py).
// Both this test and python/tests/test_budget_progress.py read the same
// fixture, so server-side burn-rate alerts use exactly the spend-per-category
// numbers the Budget page shows. Change the rules on either side -> add a case
// to the fixture and make both tests pass.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/services/budget_service.dart';
import 'package:ssdemo_1/services/category_service.dart';

final _fixture =
    jsonDecode(
          File(
            '../python/tests/data/budget_bucket_contract.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

final _rules = (_fixture['rules'] as Map<String, dynamic>)
    .cast<String, String>();

/// Mirrors the per-transaction loop in SyncService.buildResult:
/// remembered rule first, otherwise classifyByPfcSignals.
String _bucketFor(Map<String, dynamic> row) {
  final service = CategoryService.instance;
  final remembered = _rules[service.ruleKeyForRawTransaction(row)];
  if (remembered != null && remembered.isNotEmpty) return remembered;
  return service
      .classifyByPfcSignals(
        pfcPrimary: ((row['pfc_primary'] as String?) ?? '').trim(),
        pfcDetailed:
            ((row['pfc_detailed'] as String?) ??
                    (row['category'] as String?) ??
                    '')
                .trim(),
        merchantName:
            ((row['name'] as String?) ??
                    (row['merchant_name'] as String?) ??
                    '')
                .trim(),
        transactionName: ((row['name'] as String?) ?? '').trim(),
      )
      .category;
}

void main() {
  group('budget bucket contract', () {
    for (final raw in _fixture['transactions'] as List) {
      final testCase = raw as Map<String, dynamic>;
      final row = testCase['row'] as Map<String, dynamic>;
      final expected = testCase['expected'] as Map<String, dynamic>;
      test(testCase['description'], () {
        expect(
          CategoryService.instance.ruleKeyForRawTransaction(row),
          expected['rule_key'],
        );
        expect(_bucketFor(row), expected['bucket']);
        expect(AppTransaction.fromMap(row).isExpense, expected['is_expense']);
        expect(
          AppTransaction.fromMap(row).expenseAmount > 0,
          expected['counts_as_spending'],
        );
      });
    }

    test('month progress matches the Budget page computation', () {
      final spec = _fixture['progress'] as Map<String, dynamic>;
      final categories = (spec['categories'] as Map<String, dynamic>)
          .cast<String, String>();
      final rows = (spec['transactions'] as List).cast<Map<String, dynamic>>();
      final txs = rows.map(AppTransaction.fromMap).toList();
      final reviewed = {
        for (var i = 0; i < rows.length; i++) txs[i].id: _bucketFor(rows[i]),
      };
      final template = [
        for (final b in (spec['budgets'] as List).cast<Map<String, dynamic>>())
          BudgetCategoryProgress(
            budgetId: b['id'] as String,
            categoryId: b['category_id'] as String,
            title: categories[b['category_id']] ?? 'Unknown',
            spent: 0,
            limit: (b['monthly_limit'] as num).toDouble(),
          ),
      ];
      final month = DateTime.parse('${spec['month']}-01');
      final progress = BudgetService.instance.rebasedProgressFromTemplate(
        template: template,
        txs: txs,
        focusMonth: month,
        yearly: false,
        allTime: false,
        reviewedCategoryByTxId: reviewed,
      );

      final expected = (spec['expected'] as List).cast<Map<String, dynamic>>();
      expect(progress.length, expected.length);
      for (var i = 0; i < expected.length; i++) {
        expect(progress[i].categoryId, expected[i]['category_id']);
        expect(progress[i].title, expected[i]['category']);
        expect(
          progress[i].spent,
          closeTo((expected[i]['spent'] as num).toDouble(), 0.005),
        );
        expect(progress[i].limit, (expected[i]['limit'] as num).toDouble());
      }
    });
  });
}
