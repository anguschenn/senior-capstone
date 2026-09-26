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

    test('builds monthly and yearly budget progress from the rows', () {
      final result = service.buildResult(_raw(), const {}, asOf: _asOf);

      final month = _food(result.budgetProgress);
      expect(month.limit, 200);
      expect(month.spent, 100);

      final year = _food(result.budgetProgressYear);
      expect(year.limit, 2400);
      expect(year.spent, 125); // t1 + t2 + t4, all in 2026
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
}
