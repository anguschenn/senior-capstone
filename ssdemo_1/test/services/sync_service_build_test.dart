import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/services/category_service.dart';
import 'package:ssdemo_1/services/sync_cache.dart';
import 'package:ssdemo_1/services/sync_service.dart';

final _asOf = DateTime(2026, 9, 24);

Map<String, dynamic> _tx(
  String id,
  String date,
  double amount, {
  String primary = 'FOOD_AND_DRINK',
  String detailed = 'FOOD_AND_DRINK_RESTAURANT',
}) => {
  'plaid_transaction_id': id,
  'plaid_account_id': 'acc1',
  'merchant_name': 'Merchant $id',
  'name': 'Merchant $id',
  'category': null,
  'pfc_primary': primary,
  'pfc_detailed': detailed,
  'pfc_confidence': 'HIGH',
  'pending': false,
  'date': date,
  'amount': amount,
  'user_id': 'user-a',
  'account_name': 'Checking',
  'account_type': 'depository',
  'subtype': 'checking',
};

RawSyncData _raw({
  Map<String, Map<String, String>> rules = const {},
  List<Map<String, dynamic>>? budgets,
  List<Map<String, dynamic>> extraTx = const [],
}) {
  return RawSyncData(
    userId: 'user-a',
    monthYear: '2026-09',
    savedAt: DateTime.utc(2026, 9, 24),
    accountsRows: [
      {
        'plaid_account_id': 'acc1',
        'name': 'Checking',
        'account_type': 'depository',
        'subtype': 'checking',
        'current_balance': 1000,
        'mask': '5973',
        'updated_at': '2026-09-24T10:00:00Z',
      },
    ],
    categories: [const CategoryOption(id: 'c-food', name: 'Food')],
    budgetRows:
        budgets ??
        [
          {
            'id': 'b-food',
            'category_id': 'c-food',
            'monthly_limit': 200,
            'month_year': '2026-09',
          },
        ],
    subscriptionRows: [
      {
        'id': 's1',
        'merchant_name': 'Spotify',
        'amount': 21.99,
        'next_charge_date': '2026-10-17',
        'frequency': 'monthly',
        'needs_confirmation': true,
      },
    ],
    txRows: [
      _tx('t1', '2026-09-20', 40),
      _tx('t2', '2026-09-10', 60),
      _tx(
        't3',
        '2026-09-05',
        -1000,
        primary: 'INCOME',
        detailed: 'INCOME_WAGES',
      ),
      _tx('t4', '2026-08-30', 25),
      ...extraTx,
    ],
    rememberedRules: rules,
  );
}

BudgetCategoryProgress _food(List<BudgetCategoryProgress> list) =>
    list.firstWhere((b) => b.title == 'Food');

void main() {
  final service = SyncService.instance;

  group('SyncService.buildResult', () {
    test('parses transactions, stats, subscriptions and accounts', () {
      final result = service.buildResult(_raw(), const {}, asOf: _asOf);

      expect(result.transactions.map((t) => t.id), ['t1', 't2', 't3', 't4']);
      expect(result.stats.monthlyExpenses, 100); // t1 + t2, September only
      expect(result.stats.monthlyIncome, 1000);
      expect(result.stats.netThisMonth, 900);
      expect(result.subscriptions, hasLength(1));
      expect(result.subscriptions.single.merchant, 'Spotify');
      expect(result.subscriptions.single.needsConfirmation, isTrue);
      expect(result.accountOptions.single.label, 'Checking ••••5973');
      expect(result.accountOptions.single.txCount, 4);
      expect(result.hasData, isTrue);
    });

    test('a card payment between linked accounts keeps its own category', () {
      final pay = {
        ..._tx(
          'pay',
          '2026-09-12',
          330,
          primary: 'LOAN_PAYMENTS',
          detailed: 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT',
        ),
        'name': 'Payment to Chase card ending in 4191',
        'merchant_name': null,
      };
      final thanks = {
        ..._tx(
          'thanks',
          '2026-09-12',
          -330,
          primary: 'LOAN_DISBURSEMENTS',
          detailed: 'LOAN_DISBURSEMENTS_OTHER_DISBURSEMENT',
        ),
        'plaid_account_id': 'acc2',
        'name': 'Payment Thank You-Mobile',
        'merchant_name': null,
      };
      final result = service.buildResult(
        _raw(extraTx: [pay, thanks]),
        const {},
        asOf: _asOf,
      );
      addTearDown(() => AppTransaction.kindById = const {});
      expect(AppTransaction.kindById['pay'], TxKind.internal);
      // Hiding the card later turns the payment into spending: it must land
      // in Fees & Transfers then, not Other.
      expect(result.autoReviewedCategoryByTxId['pay'], 'Fees & Transfers');
      expect(result.autoReviewedCategoryByTxId['thanks'], 'Income');
      expect(result.autoLowConfidenceReviewTxIds, isNot(contains('pay')));
    });

    test('builds monthly and yearly budget progress from the rows', () {
      final result = service.buildResult(_raw(), const {}, asOf: _asOf);

      final month = _food(result.budgetProgress);
      expect(month.limit, 200);
      expect(month.spent, 100);

      final year = _food(result.budgetProgressYear);
      expect(year.limit, 2400);
      expect(year.spent, 125); // t1 + t2 + t4, all in 2026
    });

    test('a transaction stored twice counts once in budget progress', () {
      final result = service.buildResult(
        _raw(extraTx: [_tx('t1', '2026-09-20', 40)]),
        const {},
        asOf: _asOf,
      );

      expect(_food(result.budgetProgress).spent, 100);
      expect(_food(result.budgetProgressYear).spent, 125);
    });

    test('applies remembered category rules', () {
      final key = CategoryService.instance.buildRuleKey(
        merchantName: 'Merchant t1',
        pfcPrimary: 'FOOD_AND_DRINK',
        pfcDetailed: 'FOOD_AND_DRINK_RESTAURANT',
      );
      final raw = _raw(
        rules: {
          key: {'category': 'Entertainment', 'confidence': 'high'},
        },
      );

      final result = service.buildResult(raw, const {}, asOf: _asOf);

      expect(result.autoReviewedCategoryByTxId['t1'], 'Entertainment');
      expect(_food(result.budgetProgress).spent, 60); // t1 moved out of Food
    });

    test('without budget rows falls back to zero-limit categories', () {
      final result = service.buildResult(
        _raw().withoutBudgets(),
        const {},
        asOf: _asOf,
      );

      expect(result.budgetProgress.every((b) => b.limit == 0), isTrue);
      expect(_food(result.budgetProgress).spent, 100);
    });

    test('does not mutate the caller\'s reviewed-category map', () {
      final reviewed = <String, String>{'t1': 'Shopping'};
      service.buildResult(_raw(), reviewed, asOf: _asOf);
      expect(reviewed, {'t1': 'Shopping'});
    });
  });

  test('the Year view adds up each month\'s real limits', () {
    final base = _raw();
    final raw = RawSyncData(
      userId: base.userId,
      monthYear: base.monthYear,
      savedAt: base.savedAt,
      accountsRows: base.accountsRows,
      categories: base.categories,
      budgetRows: base.budgetRows,
      yearBudgetRows: const [
        {
          'category_id': 'c-food',
          'monthly_limit': 300,
          'month_year': '2026-08',
        },
        {
          'category_id': 'c-food',
          'monthly_limit': 200,
          'month_year': '2026-09',
        },
      ],
      subscriptionRows: base.subscriptionRows,
      txRows: base.txRows,
      rememberedRules: base.rememberedRules,
    );
    final year = service.buildResult(raw, const {}, asOf: _asOf);
    expect(year.budgetProgressYear.single.limit, 500);
    expect(year.budgetProgressYear.single.budgetedMonths, {8, 9});
    // Without the year's rows (an older saved copy) it falls back to x12.
    final old = service.buildResult(_raw(), const {}, asOf: _asOf);
    expect(old.budgetProgressYear.single.limit, 2400);
    // The saved copy keeps the year's rows.
    final again = RawSyncData.fromJson(jsonDecode(jsonEncode(raw.toJson())))!;
    expect(again.yearBudgetRows, hasLength(2));
  });

  group('saved copy is equivalent to a fresh load', () {
    test('parsing the JSON round-trip gives the same result', () {
      final raw = _raw();
      final restored = RawSyncData.fromJson(
        jsonDecode(jsonEncode(raw.toJson())),
      );
      expect(restored, isNotNull);

      final fresh = service.buildResult(raw, const {}, asOf: _asOf);
      final saved = service.buildResult(restored!, const {}, asOf: _asOf);

      expect(saved.transactions.map((t) => '${t.id}|${t.amount}|${t.date}'), [
        for (final t in fresh.transactions) '${t.id}|${t.amount}|${t.date}',
      ]);
      String progress(List<BudgetCategoryProgress> l) =>
          l.map((b) => '${b.title}:${b.spent}/${b.limit}').join(',');
      expect(progress(saved.budgetProgress), progress(fresh.budgetProgress));
      expect(
        progress(saved.budgetProgressYear),
        progress(fresh.budgetProgressYear),
      );
      expect(
        progress(saved.budgetProgressAll),
        progress(fresh.budgetProgressAll),
      );
      expect(saved.stats.totalBalance, fresh.stats.totalBalance);
      expect(saved.stats.monthlyExpenses, fresh.stats.monthlyExpenses);
      expect(saved.stats.monthlyIncome, fresh.stats.monthlyIncome);
      expect(saved.subscriptions.map((s) => s.id), [
        for (final s in fresh.subscriptions) s.id,
      ]);
      expect(saved.accountOptions.map((a) => a.label), [
        for (final a in fresh.accountOptions) a.label,
      ]);
      expect(
        saved.autoReviewedCategoryByTxId,
        fresh.autoReviewedCategoryByTxId,
      );
      expect(saved.hasData, fresh.hasData);
    });
  });

  group('parseBudgetProgressResponse', () {
    // Shaped like the real GET /api/budget_progress response -- see
    // get_budget_progress / build_budget_progress in python/budget_progress.py.
    test('parses a well-formed response', () {
      final decoded = jsonDecode('''
      {
        "month": "2026-09",
        "progress": [
          {"budget_id": "b1", "category_id": "c1", "category": "Food", "spent": 278.25, "limit": 300.0, "ratio": 0.9275},
          {"budget_id": "b2", "category_id": "c2", "category": "Transport", "spent": 66.2, "limit": 100.0, "ratio": 0.662}
        ]
      }
      ''');

      final progress = parseBudgetProgressResponse(decoded);

      expect(progress, hasLength(2));
      expect(progress[0].budgetId, 'b1');
      expect(progress[0].categoryId, 'c1');
      expect(progress[0].title, 'Food');
      expect(progress[0].spent, 278.25);
      expect(progress[0].limit, 300.0);
      expect(progress[1].title, 'Transport');
    });

    test('skips a row missing budget_id or category_id, keeps the rest', () {
      final decoded = jsonDecode('''
      {
        "month": "2026-09",
        "progress": [
          {"budget_id": "", "category_id": "c1", "category": "Food", "spent": 1, "limit": 2},
          {"budget_id": "b2", "category_id": null, "category": "Bad", "spent": 1, "limit": 2},
          {"budget_id": "b3", "category_id": "c3", "category": "Health", "spent": 5, "limit": 50}
        ]
      }
      ''');

      final progress = parseBudgetProgressResponse(decoded);

      expect(progress, hasLength(1));
      expect(progress.single.title, 'Health');
    });

    test('an empty progress list (no budgets set yet) parses to empty', () {
      final decoded = jsonDecode('{"month": "2026-09", "progress": []}');
      expect(parseBudgetProgressResponse(decoded), isEmpty);
    });

    test('non-numeric spent/limit falls back to 0 rather than throwing', () {
      final decoded = jsonDecode('''
      {"month": "2026-09", "progress": [
        {"budget_id": "b1", "category_id": "c1", "category": "Food", "spent": "oops", "limit": null}
      ]}
      ''');
      final progress = parseBudgetProgressResponse(decoded);
      expect(progress.single.spent, 0);
      expect(progress.single.limit, 0);
    });

    for (final badShape in [
      'null',
      '[]',
      '"not an object"',
      '{"month": "2026-09"}', // no "progress" key
      '{"progress": "not a list"}',
      '{"progress": [1, 2, "not objects"]}',
    ]) {
      test('malformed input "$badShape" never throws', () {
        expect(
          () => parseBudgetProgressResponse(jsonDecode(badShape)),
          returnsNormally,
        );
      });
    }
  });
}
