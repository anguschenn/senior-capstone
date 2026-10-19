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
  String accountType = 'depository',
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
    accountType: accountType,
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
      expect(result['account_type'], '');
    });

    test('budgets carry the selected month\'s limits, not unbudgeted ones', () {
      final result = AiSummaryService.instance.build(
        transactions: const [],
        budgetProgress: const [
          BudgetCategoryProgress(
            budgetId: 'b1',
            categoryId: 'c1',
            title: 'Food',
            spent: 516.44,
            limit: 100,
          ),
          BudgetCategoryProgress(
            budgetId: 'b2',
            categoryId: 'c2',
            title: 'Health',
            spent: 20,
            limit: 0,
          ),
        ],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
        focusMonth: DateTime(2026, 10),
      );
      expect(result['budgets'], {
        'month': '2026-10',
        'items': [
          {'category': 'Food', 'spent': 516.44, 'limit': 100.0},
        ],
      });
    });

    test('credit card payments are not income, and their totals are kept', () {
      final now = DateTime.now();
      final cardPayment = _tx(
        id: 'p1',
        date: now,
        amount: -500,
        name: 'Payment Thank You-Mobile',
        rawPfcPrimary: 'LOAN_DISBURSEMENTS',
        rawPfcDetailed: 'LOAN_DISBURSEMENTS_OTHER_DISBURSEMENT',
        accountType: 'credit',
      );
      final cardRefund = _tx(
        id: 'p2',
        date: now,
        amount: -20,
        name: 'Store refund',
        accountType: 'credit',
      );
      final bankPayment = _tx(
        id: 'p3',
        date: now,
        amount: 500,
        name: 'Payment to Chase card ending in 4191',
        rawPfcPrimary: 'LOAN_PAYMENTS',
        rawPfcDetailed: 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT',
      );
      final paycheck = _tx(id: 'p4', date: now, amount: -1000, name: 'Payroll');

      expect(cardPayment.incomeAmount, 0);
      expect(cardPayment.cardPaymentAmount, 500);
      expect(cardPayment.inflowLabel, 'Fees & Transfers');
      expect(cardRefund.incomeAmount, 20);
      expect(paycheck.incomeAmount, 1000);
      expect(paycheck.inflowLabel, 'Income');

      final result = AiSummaryService.instance.build(
        transactions: [cardPayment, cardRefund, bankPayment, paycheck],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
      );
      final key =
          '${now.year.toString().padLeft(4, '0')}-${now.month.toString().padLeft(2, '0')}';
      final month = (result['month_index'] as Map)[key] as Map;
      expect(month['income'], 1020);
      expect(month['expenses'], 0);
      expect(month['card_payments_in'], 500);
      expect(month['card_payments_out'], 500);
    });

    test('a single selected account carries its account type', () {
      final now = DateTime.now();
      final result = AiSummaryService.instance.build(
        transactions: [
          _tx(id: 'k1', date: now.subtract(const Duration(days: 1)), amount: 30),
        ],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: 'card-1',
        scopeLabel: 'CREDIT CARD 4191',
        accountType: 'credit',
      );

      expect(result['scope'], 'single_account');
      expect(result['account_type'], 'credit');
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
      expect(recent.length, 4);
      expect(recent[0]['id'], 'id_9');
      expect(recent[1]['id'], 'id_2');
      expect(recent[2]['id'], 'id_1');
      expect(recent[3]['id'], 'id_0');
    });

    test('warnings include sparse and transfer-like noise when applicable', () {
      final now = DateTime.now();
      final transactions = [
        _tx(
          id: 't1',
          date: now.subtract(const Duration(days: 1)),
          amount: 20,
          category: 'Transfer',
          name: 'Transfer to savings',
        ),
        _tx(
          id: 't2',
          date: now.subtract(const Duration(days: 1)),
          amount: 25,
          category: 'Transfer',
          name: 'Transfer to savings',
        ),
        _tx(
          id: 't3',
          date: now.subtract(const Duration(days: 2)),
          amount: 30,
          category: 'Transfer',
          name: 'Transfer to savings',
        ),
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

      // Anchor-based windows end with the selected month; rolling windows follow now.
      // Jan 3 is outside the last 7 days of January but inside its last 30.
      expect(anchor7['expenses'], 0.0);
      expect(rolling7['expenses'], 40.0);
      expect(anchor30['expenses'], 30.0);
      expect(rolling30['expenses'], 40.0);
    });

    test('current month: 30-day totals stop at 30 days, not last month start', () {
      final now = DateTime.now();
      final result = AiSummaryService.instance.build(
        transactions: [
          _tx(id: 'old', date: now.subtract(const Duration(days: 40)), amount: 100),
          _tx(id: 'new', date: now.subtract(const Duration(days: 2)), amount: 10),
        ],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
        focusMonth: DateTime(now.year, now.month, 1),
      );

      final totals = result['totals'] as Map<String, dynamic>;
      final top = (result['top_expense_categories'] as List)
          .cast<Map<String, dynamic>>();
      expect(totals['expenses_30d'], 10.0);
      expect(top.single['amount'], 10.0);
    });

    test('month_index lists spend per category for each month', () {
      final month = DateTime(2026, 3, 1);
      final result = AiSummaryService.instance.build(
        transactions: [
          _tx(id: 'f1', date: DateTime(2026, 3, 4), amount: 12, category: 'Food'),
          _tx(id: 'f2', date: DateTime(2026, 3, 9), amount: 8, category: 'Food'),
          _tx(id: 't1', date: DateTime(2026, 3, 5), amount: 30, category: 'Transport'),
        ],
        budgetProgress: const [],
        stats: _stats(),
        selectedAccountId: kAllAccountsId,
        scopeLabel: 'All',
        focusMonth: month,
      );

      final monthIndex = result['month_index'] as Map<String, dynamic>;
      final march = monthIndex['2026-03'] as Map<String, dynamic>;
      expect(march['categories'], {'Transport': 30.0, 'Food': 20.0});
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

