import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/constants/app_constants.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/services/ai_summary_service.dart';

AppTransaction _tx({
  required String id,
  required DateTime date,
  required double amount,
  String category = 'Food',
  String name = 'Txn',
  String transactionType = 'debit',
  String rawPfcPrimary = '',
  String rawPfcDetailed = '',
}) {
  return AppTransaction(
    dedupeKey: id,
    id: id,
    accountId: 'acc-1',
    accountName: 'Checking',
    name: name,
    description: name,
    transactionType: transactionType,
    category: category,
    primaryCategory: category,
    date: date,
    amount: amount,
    accountType: 'depository',
    accountSubtype: 'checking',
    pending: false,
    confidence: 'high',
    userId: 'u1',
    rawMerchantName: name,
    rawPfcPrimary: rawPfcPrimary,
    rawPfcDetailed: rawPfcDetailed,
  );
}

DashboardStats _stats() => const DashboardStats(
  totalBalance: 1000,
  monthlyIncome: 2000,
  monthlyExpenses: 800,
  netThisMonth: 1200,
);

void main() {
  group('AiSummaryService', () {
    test('build returns v3 schema blocks and indexes', () {
      final now = DateTime.now();
      final result = AiSummaryService.instance.build(
        transactions: [
          _tx(id: 'a1', date: now.subtract(const Duration(days: 2)), amount: 50),
          _tx(id: 'a2', date: now.subtract(const Duration(days: 1)), amount: 20),
        ],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
      );

      expect(result['version'], 3);
      expect(result.containsKey('windows_anchor'), isTrue);
      expect(result.containsKey('windows_rolling'), isTrue);
      expect(result.containsKey('window_definition'), isTrue);
      expect(result.containsKey('data_coverage'), isTrue);
      expect(result.containsKey('confidence'), isTrue);
      expect(result.containsKey('warnings'), isTrue);
      expect(result.containsKey('category_index'), isTrue);
      expect(result.containsKey('month_index'), isTrue);
      expect(result.containsKey('year_index'), isTrue);
      expect(result.containsKey('day_index_recent'), isTrue);
    });

    test('recent_transactions sorted by date desc then id desc', () {
      final now = DateTime.now();
      final sameDay = DateTime(now.year, now.month, now.day - 1, 12);
      final result = AiSummaryService.instance.build(
        transactions: [
          _tx(id: 'id_2', date: sameDay, amount: 10, name: 'Second'),
          _tx(id: 'id_9', date: sameDay, amount: 15, name: 'FirstById'),
          _tx(id: 'id_1', date: now.subtract(const Duration(days: 2)), amount: 20),
          _tx(id: 'id_0', date: now.subtract(const Duration(days: 3)), amount: 25),
        ],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
      );

      final recent = (result['recent_transactions'] as List).cast<Map<String, dynamic>>();
      expect(recent.length, 3);
      expect(recent[0]['id'], 'id_9');
      expect(recent[1]['id'], 'id_2');
      expect(recent[2]['id'], 'id_1');
    });

    test('warnings include sparse and transfer-like noise when applicable', () {
      final now = DateTime.now();
      final transactions = [
        _tx(id: 't1', date: now.subtract(const Duration(days: 1)), amount: 20, category: 'Transfer'),
        _tx(id: 't2', date: now.subtract(const Duration(days: 1)), amount: 25, category: 'Transfer'),
        _tx(id: 't3', date: now.subtract(const Duration(days: 2)), amount: 30, category: 'Transfer'),
        _tx(id: 't4', date: now.subtract(const Duration(days: 2)), amount: 10, category: 'Food'),
      ];
      final result = AiSummaryService.instance.build(
        transactions: transactions,
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
      );

      final warnings = (result['warnings'] as List).cast<String>();
      expect(warnings, contains('sparse_recent_data'));
      expect(warnings, contains('contains_transfer_like_noise'));
      final confidence = result['confidence'] as Map<String, dynamic>;
      expect(confidence['overall'], anyOf('low', 'medium', 'high'));
      expect((confidence['score'] as num) >= 0, isTrue);
      expect((confidence['score'] as num) <= 1, isTrue);
    });

    test('precomputed summary overrides computed blocks', () {
      final now = DateTime.now();
      final result = AiSummaryService.instance.build(
        transactions: [_tx(id: 'x1', date: now, amount: 42)],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
        precomputedSummary: {
          'version': 9,
          'totals': {'expenses_30d': 999.0},
          'warnings': ['from_precomputed'],
        },
      );

      expect(result['version'], 9);
      final totals = result['totals'] as Map<String, dynamic>;
      expect(totals['expenses_30d'], 999.0);
      expect(result['warnings'], ['from_precomputed']);
    });

    test('returns backend-consumable numeric structures', () {
      final now = DateTime.now();
      final result = AiSummaryService.instance.build(
        transactions: [
          _tx(id: 'n1', date: now.subtract(const Duration(days: 1)), amount: 12.5, category: 'Food'),
          _tx(id: 'n2', date: now.subtract(const Duration(days: 8)), amount: 30, category: 'Transport'),
          _tx(id: 'n3', date: now.subtract(const Duration(days: 20)), amount: -2000, category: 'Income', transactionType: 'income'),
        ],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
      );

      final totals = result['totals'] as Map<String, dynamic>;
      expect(totals['expenses_30d'], isA<num>());
      expect(totals['income_30d'], isA<num>());
      expect(totals['tx_count_30d'], isA<int>());
      expect(totals['expense_tx_count_30d'], isA<int>());

      final monthIndex = result['month_index'] as Map<String, dynamic>;
      expect(monthIndex.isNotEmpty, isTrue);
      final firstMonth = monthIndex.values.first as Map<String, dynamic>;
      expect(firstMonth['income'], isA<num>());
      expect(firstMonth['expenses'], isA<num>());
      expect(firstMonth['tx_count'], isA<int>());

      final yearIndex = result['year_index'] as Map<String, dynamic>;
      expect(yearIndex.isNotEmpty, isTrue);
      final firstYear = yearIndex.values.first as Map<String, dynamic>;
      expect(firstYear['income'], isA<num>());
      expect(firstYear['expenses'], isA<num>());
      expect(firstYear['tx_count'], isA<int>());

      final windowsRolling = result['windows_rolling'] as Map<String, dynamic>;
      final last30 = windowsRolling['last_30d'] as Map<String, dynamic>;
      expect(last30['expenses'], isA<num>());
      expect(last30['income'], isA<num>());
      expect(last30['tx_count'], isA<int>());
    });

    test('returns required indexes for deterministic intents', () {
      final now = DateTime.now();
      final result = AiSummaryService.instance.build(
        transactions: [
          _tx(id: 'd1', date: now.subtract(const Duration(days: 1)), amount: 18, category: 'Food'),
          _tx(id: 'd2', date: now.subtract(const Duration(days: 2)), amount: 22, category: 'Transport'),
          _tx(id: 'd3', date: now.subtract(const Duration(days: 10)), amount: 35, category: 'Food'),
        ],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
      );

      final dayIndexRecent = result['day_index_recent'] as Map<String, dynamic>;
      expect(dayIndexRecent.isNotEmpty, isTrue);
      final dayBucket = dayIndexRecent.values.first as Map<String, dynamic>;
      expect(dayBucket['expenses'], isA<num>());
      expect(dayBucket['tx_count'], isA<int>());

      final categoryIndex = result['category_index'] as Map<String, dynamic>;
      expect(categoryIndex.containsKey('Food'), isTrue);
      expect(categoryIndex['Food'], isA<num>());

      final annualSummary = result['annual_summary'] as Map<String, dynamic>;
      final annualTotals = annualSummary['totals'] as Map<String, dynamic>;
      expect(annualTotals['expenses_year'], isA<num>());
      expect(annualTotals['income_year'], isA<num>());
      expect(annualTotals['expense_tx_count_year'], isA<int>());
    });

    test('windows_anchor and windows_rolling diverge on boundary dates', () {
      final now = DateTime.now();
      final focusMonth = DateTime(2024, 1, 1);
      final oldButAnchorIncluded = _tx(
        id: 'w1',
        date: DateTime(2024, 1, 3),
        amount: 30,
        category: 'Food',
      );
      final recentRollingIncluded = _tx(
        id: 'w2',
        date: now.subtract(const Duration(days: 1)),
        amount: 40,
        category: 'Transport',
      );

      final result = AiSummaryService.instance.build(
        transactions: [oldButAnchorIncluded, recentRollingIncluded],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
        focusMonth: focusMonth,
      );

      final windowsAnchor = result['windows_anchor'] as Map<String, dynamic>;
      final windowsRolling = result['windows_rolling'] as Map<String, dynamic>;
      final anchor7 = windowsAnchor['last_7d'] as Map<String, dynamic>;
      final rolling7 = windowsRolling['last_7d'] as Map<String, dynamic>;
      final anchor30 = windowsAnchor['last_30d'] as Map<String, dynamic>;
      final rolling30 = windowsRolling['last_30d'] as Map<String, dynamic>;

      // Anchor-based windows follow focusMonth boundaries; rolling windows follow now.
      expect(anchor7['expenses'], 70.0);
      expect(rolling7['expenses'], 40.0);
      expect(anchor30['expenses'], 70.0);
      expect(rolling30['expenses'], 40.0);
    });

    test('transfer-like filtering uses pfc signals and name patterns', () {
      final now = DateTime.now();
      final result = AiSummaryService.instance.build(
        transactions: [
          _tx(
            id: 'c1',
            date: now.subtract(const Duration(days: 2)),
            amount: 60,
            category: 'Other',
            name: 'Payment to Chase card ending 4191',
            rawPfcPrimary: 'LOAN_PAYMENTS',
            rawPfcDetailed: 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT',
          ),
          _tx(
            id: 'c2',
            date: now.subtract(const Duration(days: 1)),
            amount: 12.99,
            category: 'Other',
            name: 'Spotify',
            rawPfcPrimary: 'OTHER',
            rawPfcDetailed: 'OTHER_OTHER',
          ),
          _tx(
            id: 'c3',
            date: now.subtract(const Duration(days: 1)),
            amount: 5,
            category: 'Other',
            name: 'MONTHLY SERVICE FEE',
            rawPfcPrimary: 'OTHER',
            rawPfcDetailed: 'OTHER_OTHER',
          ),
        ],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
      );

      final categoryIndex = result['category_index'] as Map<String, dynamic>;
      // Card payment is transfer-like and excluded from category aggregation.
      expect(categoryIndex['Other'], closeTo(17.99, 0.0001));
    });
  });
}

