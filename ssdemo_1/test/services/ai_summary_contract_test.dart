// Shared contract with the Python backend (python/ai/server_summary.py).
// Both this test and python/tests/test_server_summary.py build the chat's
// spending summary from the same rows and must equal the fixture's `expected`,
// so a chat answered from the server's summary matches the one the app built.
// Change the summary rules on either side -> regenerate `expected` from Python
// (python tests/test_server_summary.py --write) and make this test pass.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/constants/app_constants.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/services/ai_summary_service.dart';
import 'package:ssdemo_1/services/category_service.dart';
import 'package:ssdemo_1/utils/app_helpers.dart';

final _fixture =
    jsonDecode(
          File(
            '../python/tests/data/ai_summary_contract.json',
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

/// Rows with account metadata merged in, as SyncService.fetchRaw does.
List<Map<String, dynamic>> _rows() {
  final accounts = {
    for (final a in (_fixture['accounts'] as List).cast<Map<String, dynamic>>())
      a['plaid_account_id'] as String: a,
  };
  return (_fixture['transactions'] as List).cast<Map<String, dynamic>>().map((
    row,
  ) {
    final meta = accounts[row['plaid_account_id']] ?? const {};
    return {
      ...row,
      'account_name': meta['name'] ?? '',
      'account_type': meta['account_type'] ?? '',
      'subtype': meta['subtype'] ?? '',
    };
  }).toList();
}

/// The user's per-transaction choices in the fixture.
final Map<String, TxDecision> _decisions = {
  for (final e
      in ((_fixture['decisions'] as Map<String, dynamic>?) ?? const {}).entries)
    e.key: TxDecision.fromRow((e.value as Map).cast<String, dynamic>()),
};

/// Mirrors SyncService.buildResult: the transaction's own pick, then a
/// remembered rule (never for money from a person), keyed by transaction id.
Map<String, String> _ruleCategories(List<Map<String, dynamic>> rows) {
  final rules = (_fixture['rules'] as Map<String, dynamic>)
      .cast<String, String>();
  final out = <String, String>{};
  for (final row in rows) {
    final tx = AppTransaction.fromMap(row);
    final picked = _decisions[tx.id]?.category ?? '';
    if (picked.isNotEmpty) {
      out[tx.id] = picked;
      continue;
    }
    if (tx.isPeerToPeerInflow) continue;
    final remembered =
        rules[CategoryService.instance.ruleKeyForRawTransaction(row)];
    if (remembered != null) out[tx.id] = remembered;
  }
  return out;
}

/// Mirrors SyncService.buildResult: the user's category first, otherwise
/// classifyByPfcSignals, keyed by transaction id.
Map<String, String> _reviewedCategories(List<Map<String, dynamic>> rows) {
  final service = CategoryService.instance;
  final userCategories = _ruleCategories(rows);
  final out = <String, String>{};
  for (final row in rows) {
    final tx = AppTransaction.fromMap(row);
    final remembered = userCategories[tx.id];
    out[tx.id] = (remembered != null && remembered.isNotEmpty)
        ? remembered
        : service
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
  return out;
}

void _expectClose(Object? actual, Object? expected, String path) {
  if (expected is Map) {
    expect(actual, isA<Map>(), reason: path);
    final a = actual as Map;
    expect(
      a.keys.map((k) => '$k').toSet(),
      expected.keys.map((k) => '$k').toSet(),
      reason: path,
    );
    for (final key in expected.keys) {
      _expectClose(a[key], expected[key], '$path.$key');
    }
  } else if (expected is List) {
    expect(actual, isA<List>(), reason: path);
    final a = actual as List;
    expect(a.length, expected.length, reason: path);
    for (var i = 0; i < expected.length; i++) {
      _expectClose(a[i], expected[i], '$path[$i]');
    }
  } else if (expected is num) {
    expect(actual, isA<num>(), reason: path);
    expect(
      (actual as num).toDouble(),
      closeTo(expected.toDouble(), 1e-6),
      reason: path,
    );
  } else {
    expect(actual, expected, reason: path);
  }
}

void main() {
  final rows = _rows();
  final reviewed = _reviewedCategories(rows);
  final seen = <String>{};
  final allTransactions = [
    for (final tx in rows.map(AppTransaction.fromMap))
      if (seen.add(tx.dedupeKey)) tx,
  ];
  final now = DateTime.parse(_fixture['now'] as String);
  // SyncService.buildResult: what counts, with the user's categories; a
  // refund, and a friend's payback linked to a purchase, take the category
  // of the purchase they pay back.
  final ruleCategories = _ruleCategories(rows);
  final classified = classifyTransactions(
    allTransactions,
    ruleCategories,
    paidBackPurchaseById: paidBackPurchaseIds(_decisions),
  );
  useClassification(classified, allTransactions, _decisions);
  for (final entry in classified.purchaseIdByRefundId.entries) {
    if (ruleCategories.containsKey(entry.key)) continue;
    reviewed[entry.key] = reviewed[entry.value] ?? reviewed[entry.key]!;
  }
  for (final entry in classified.purchaseIdByPaybackId.entries) {
    reviewed[entry.key] = reviewed[entry.value] ?? reviewed[entry.key]!;
  }
  for (final tx in allTransactions) {
    if (tx.kind == TxKind.internal && !ruleCategories.containsKey(tx.id)) {
      reviewed[tx.id] = kInternalTransfer;
    }
  }

  group('ai summary contract', () {
    for (final raw in _fixture['cases'] as List) {
      final testCase = raw as Map<String, dynamic>;
      test(testCase['description'], () {
        final accountIds = (testCase['account_ids'] as List).cast<String>();
        final visible = accountIds.isEmpty
            ? allTransactions
            : allTransactions
                  .where((tx) => accountIds.contains(tx.accountId))
                  .toList();
        final month = DateTime.parse('${testCase['focus_month']}-01');
        final focus = testCase['all_year'] == true
            ? allYearOptionFor(month.year)
            : month;
        // FinancialSnapshotService: income/expenses in the selected period.
        double income = 0;
        double expenses = 0;
        for (final tx in visible) {
          if (transactionInSelectedPeriod(tx, focus)) {
            income += tx.incomeAmount;
            expenses += tx.expenseAmount;
          }
        }
        final progress = [
          for (final item
              in (testCase['budget_progress'] as List)
                  .cast<Map<String, dynamic>>())
            BudgetCategoryProgress(
              budgetId: 'b-${item['category']}',
              categoryId: 'c-${item['category']}',
              title: item['category'] as String,
              spent: (item['spent'] as num).toDouble(),
              limit: (item['limit'] as num).toDouble(),
            ),
        ];
        final summary = AiSummaryService.instance.build(
          transactions: visible,
          budgetProgress: progress,
          stats: DashboardStats(
            totalBalance: 0,
            monthlyIncome: income,
            monthlyExpenses: expenses,
            netThisMonth: income - expenses,
          ),
          selectedAccountId: accountIds.isEmpty
              ? kAllAccountsId
              : accountIds.first,
          scopeLabel: testCase['scope_label'] as String,
          accountType: testCase['account_type'] as String,
          reviewedCategoryByTxId: reviewed,
          focusMonth: focus,
          now: now,
        );
        final actual = Map<String, dynamic>.from(summary)
          ..remove('generated_at');
        final timeAnchor = Map<String, dynamic>.from(
          actual['time_anchor'] as Map,
        );
        timeAnchor['tz'] = '';
        actual['time_anchor'] = timeAnchor;
        _expectClose(actual, testCase['expected'], r'$');
      });
    }
  });
}
