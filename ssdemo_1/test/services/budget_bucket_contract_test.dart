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
import 'package:ssdemo_1/services/sync_cache.dart';
import 'package:ssdemo_1/services/sync_service.dart';

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
        if (expected['kind'] != null) {
          expect(AppTransaction.fromMap(row).ownKind().name, expected['kind']);
        }
      });
    }

    for (final caseKey in ['progress', 'progress_unbudgeted']) {
      test('month progress matches the Budget page computation ($caseKey)', () {
        final spec = _fixture[caseKey] as Map<String, dynamic>;
        final categories = (spec['categories'] as Map<String, dynamic>)
            .cast<String, String>();
        final rows = (spec['transactions'] as List)
            .cast<Map<String, dynamic>>();
        final txs = rows.map(AppTransaction.fromMap).toList();
        // Like sync: pair moves between linked accounts, match refunds.
        AppTransaction.kindById = classifyTransactions(txs, const {}).kinds;
        addTearDown(() => AppTransaction.kindById = const {});
        final reviewed = {
          for (var i = 0; i < rows.length; i++) txs[i].id: _bucketFor(rows[i]),
        };
        final template = [
          for (final b
              in (spec['budgets'] as List).cast<Map<String, dynamic>>())
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

        final expected = (spec['expected'] as List)
            .cast<Map<String, dynamic>>();
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
    }

    test('money from friends: paybacks, splits, no name rules (sync)', () {
      final spec = _fixture['progress_paybacks'] as Map<String, dynamic>;
      final categories = (spec['categories'] as Map<String, dynamic>)
          .cast<String, String>();
      addTearDown(() {
        AppTransaction.kindById = const {};
        AppTransaction.paidBackById = const {};
        AppTransaction.sharedAmountById = const {};
        AppTransaction.purchaseByPaybackId = const {};
      });
      final result = SyncService.instance.buildResult(
        RawSyncData(
          userId: 'u1',
          monthYear: spec['month'] as String,
          savedAt: DateTime(2026, 10, 10),
          accountsRows: const [],
          categories: [
            for (final e in categories.entries)
              CategoryOption(id: e.key, name: e.value),
          ],
          budgetRows: [
            for (final b
                in (spec['budgets'] as List).cast<Map<String, dynamic>>())
              {...b, 'month_year': spec['month']},
          ],
          subscriptionRows: const [],
          txRows: (spec['transactions'] as List).cast<Map<String, dynamic>>(),
          rememberedRules: {
            for (final e in (spec['rules'] as Map<String, dynamic>).entries)
              e.key: {'category': e.value as String, 'confidence': 'high'},
          },
          decisions: {
            for (final e in (spec['decisions'] as Map<String, dynamic>).entries)
              e.key: (e.value as Map).cast<String, dynamic>(),
          },
        ),
        const {},
        asOf: DateTime.parse('${spec['month']}-30'),
      );

      final kinds = {for (final tx in result.transactions) tx.id: tx.kind.name};
      expect(kinds, spec['expected_kinds']);
      expect(AppTransaction.paidBackById, spec['expected_paid_back']);
      final expected = (spec['expected'] as List).cast<Map<String, dynamic>>();
      for (final e in expected) {
        final card = result.budgetProgress.firstWhere(
          (p) => p.categoryId == e['category_id'],
        );
        expect(card.spent, closeTo((e['spent'] as num).toDouble(), 0.005));
      }
      // Each payment from a person waits for the user, with no rule applied;
      // a linked payback and one with its own category don't.
      expect(result.autoLowConfidenceReviewTxIds, contains('pb-carl'));
      expect(
        result.autoLowConfidenceReviewTxIds,
        isNot(anyOf(contains('pb-amy-1'), contains('pb-bob'))),
      );
      // The split purchase still counts in full until paid back.
      final dinner = result.transactions.firstWhere((t) => t.id == 'pb-dinner');
      expect(dinner.sharedAmount, 60);
      expect(dinner.toGetBack, 0);
      expect(AppTransaction.purchaseByPaybackId['pb-amy-1']?.id, 'pb-dinner');
      expect(result.autoReviewedCategoryByTxId['pb-amy-1'], 'Food');
    });
  });
  group('classify cases (shared with Python)', () {
    for (final raw in _fixture['classify_cases'] as List) {
      final spec = raw as Map<String, dynamic>;
      test(spec['_comment'], () {
        final categories = (spec['categories'] as Map<String, dynamic>)
            .cast<String, String>();
        addTearDown(() {
          AppTransaction.kindById = const {};
          AppTransaction.paidBackById = const {};
          AppTransaction.sharedAmountById = const {};
          AppTransaction.purchaseByPaybackId = const {};
        });
        final result = SyncService.instance.buildResult(
          RawSyncData(
            userId: 'u1',
            monthYear: spec['month'] as String,
            savedAt: DateTime(2026, 10, 10),
            accountsRows: const [],
            categories: [
              for (final e in categories.entries)
                CategoryOption(id: e.key, name: e.value),
            ],
            budgetRows: [
              for (final b
                  in (spec['budgets'] as List).cast<Map<String, dynamic>>())
                {...b, 'month_year': spec['month']},
            ],
            subscriptionRows: const [],
            txRows: (spec['transactions'] as List).cast<Map<String, dynamic>>(),
            rememberedRules: {
              for (final e in (spec['rules'] as Map<String, dynamic>).entries)
                e.key: {'category': e.value as String, 'confidence': 'high'},
            },
            decisions: {
              for (final e
                  in (spec['decisions'] as Map<String, dynamic>).entries)
                e.key: (e.value as Map).cast<String, dynamic>(),
            },
          ),
          const {},
          asOf: DateTime.parse('${spec['month']}-30'),
        );

        final byId = {for (final tx in result.transactions) tx.id: tx};
        final expectedKinds = spec['expected_kinds'] as Map<String, dynamic>;
        expect({
          for (final id in expectedKinds.keys) id: byId[id]!.kind.name,
        }, expectedKinds);
        final paidBack =
            (spec['expected_paid_back'] as Map<String, dynamic>?) ?? const {};
        for (final e in paidBack.entries) {
          expect(
            byId[e.key]!.paidBack,
            closeTo((e.value as num).toDouble(), 0.005),
          );
        }
        final income =
            (spec['expected_income'] as Map<String, dynamic>?) ?? const {};
        for (final e in income.entries) {
          expect(
            byId[e.key]!.incomeAmount,
            closeTo((e.value as num).toDouble(), 0.005),
          );
        }
        for (final e
            in (spec['expected'] as List).cast<Map<String, dynamic>>()) {
          final card = result.budgetProgress.firstWhere(
            (p) => p.categoryId == e['category_id'],
          );
          expect(card.spent, closeTo((e['spent'] as num).toDouble(), 0.005));
        }
      });
    }
  });
}
