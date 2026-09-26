import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/services/sync_cache.dart';

RawSyncData _sample({String userId = 'user-a', String monthYear = '2026-09'}) {
  return RawSyncData(
    userId: userId,
    monthYear: monthYear,
    savedAt: DateTime.utc(2026, 9, 26, 12),
    accountsRows: [
      {
        'plaid_account_id': 'acc1',
        'name': 'Checking',
        'account_type': 'depository',
        'subtype': 'checking',
        'current_balance': 100.5,
        'mask': '1234',
      },
    ],
    categories: [const CategoryOption(id: 'c1', name: 'Food')],
    budgetRows: [
      {
        'id': 'b1',
        'category_id': 'c1',
        'monthly_limit': 200,
        'month_year': monthYear,
      },
    ],
    subscriptionRows: [
      {
        'id': 's1',
        'merchant_name': 'Spotify',
        'amount': 21.99,
        'next_charge_date': '2026-10-17',
        'frequency': 'monthly',
        'needs_confirmation': false,
      },
    ],
    txRows: [
      {
        'plaid_transaction_id': 't1',
        'plaid_account_id': 'acc1',
        'merchant_name': 'Cafe',
        'name': 'Cafe',
        'category': null,
        'pfc_primary': 'FOOD_AND_DRINK',
        'pfc_detailed': 'FOOD_AND_DRINK_COFFEE',
        'pfc_confidence': 'HIGH',
        'pending': false,
        'date': '2026-09-20',
        'amount': 4.5,
        'user_id': userId,
        'account_name': 'Checking',
        'account_type': 'depository',
        'subtype': 'checking',
      },
    ],
    rememberedRules: {
      'cafe|food and drink|coffee': {'category': 'Food', 'confidence': 'high'},
    },
  );
}

void _expectSame(RawSyncData actual, RawSyncData expected) {
  expect(actual.userId, expected.userId);
  expect(actual.monthYear, expected.monthYear);
  expect(actual.savedAt, expected.savedAt);
  expect(actual.accountsRows, expected.accountsRows);
  expect(actual.categories.map((c) => '${c.id}:${c.name}'), [
    for (final c in expected.categories) '${c.id}:${c.name}',
  ]);
  expect(actual.budgetRows, expected.budgetRows);
  expect(actual.subscriptionRows, expected.subscriptionRows);
  expect(actual.txRows, expected.txRows);
  expect(actual.rememberedRules, expected.rememberedRules);
}

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('RawSyncData JSON', () {
    test('round-trips without losing anything', () {
      final original = _sample();
      final decoded = RawSyncData.fromJson(
        jsonDecode(jsonEncode(original.toJson())),
      );
      expect(decoded, isNotNull);
      _expectSame(decoded!, original);
    });

    test('rejects other formats and malformed data instead of throwing', () {
      expect(RawSyncData.fromJson(null), isNull);
      expect(RawSyncData.fromJson('nope'), isNull);
      expect(RawSyncData.fromJson({'v': 999}), isNull);
      expect(RawSyncData.fromJson({'v': SyncCache.version}), isNull);
    });

    test('withoutBudgets drops only the budget rows', () {
      final stripped = _sample().withoutBudgets();
      expect(stripped.budgetRows, isEmpty);
      expect(stripped.txRows, _sample().txRows);
      expect(stripped.subscriptionRows, _sample().subscriptionRows);
    });
  });

  group('SyncCache', () {
    test('save then load returns the same data', () async {
      await SyncCache.instance.save(_sample());
      final loaded = await SyncCache.instance.load('user-a');
      expect(loaded, isNotNull);
      _expectSame(loaded!, _sample());
    });

    test('returns nothing when nothing was saved', () async {
      expect(await SyncCache.instance.load('user-a'), isNull);
    });

    test('is keyed by user, so another user never sees it', () async {
      await SyncCache.instance.save(_sample(userId: 'user-a'));
      expect(await SyncCache.instance.load('user-b'), isNull);
    });

    test('clear removes every user\'s copy and only those', () async {
      SharedPreferences.setMockInitialValues({'unrelated': 'keep me'});
      await SyncCache.instance.save(_sample(userId: 'user-a'));
      await SyncCache.instance.save(_sample(userId: 'user-b'));

      await SyncCache.instance.clear();

      expect(await SyncCache.instance.load('user-a'), isNull);
      expect(await SyncCache.instance.load('user-b'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('unrelated'), 'keep me');
    });

    test('ignores unreadable saved data and removes it', () async {
      SharedPreferences.setMockInitialValues({
        'smartspend.sync_cache.user-a': 'this is not json',
      });
      expect(await SyncCache.instance.load('user-a'), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.containsKey('smartspend.sync_cache.user-a'), isFalse);
    });

    test('ignores saved data from another format version', () async {
      final stale = {..._sample().toJson(), 'v': SyncCache.version + 1};
      SharedPreferences.setMockInitialValues({
        'smartspend.sync_cache.user-a': jsonEncode(stale),
      });
      expect(await SyncCache.instance.load('user-a'), isNull);
    });

    test('ignores an entry whose stored user does not match its key', () async {
      final wrongOwner = jsonEncode(_sample(userId: 'user-b').toJson());
      SharedPreferences.setMockInitialValues({
        'smartspend.sync_cache.user-a': wrongOwner,
      });
      expect(await SyncCache.instance.load('user-a'), isNull);
    });
  });
}
