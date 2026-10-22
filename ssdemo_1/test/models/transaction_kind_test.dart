// What counts as spending, income, a refund or a move between own accounts.
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/constants/app_constants.dart';
import 'package:ssdemo_1/models/app_models.dart';

AppTransaction _tx({
  required String id,
  required double amount,
  required String name,
  DateTime? date,
  String pfcPrimary = '',
  String pfcDetailed = '',
  String accountId = 'acc-card',
  String accountType = 'credit',
}) {
  return AppTransaction(
    dedupeKey: id,
    id: id,
    accountId: accountId,
    accountName: 'Card',
    name: name,
    description: name,
    transactionType: pfcPrimary,
    category: pfcDetailed,
    primaryCategory: pfcPrimary,
    date: date ?? DateTime(2026, 10, 20),
    amount: amount,
    accountType: accountType,
    accountSubtype: '',
    pending: false,
    confidence: 'high',
    userId: 'u1',
    rawMerchantName: name,
    rawPfcPrimary: pfcPrimary,
    rawPfcDetailed: pfcDetailed,
  );
}

void main() {
  tearDown(() => AppTransaction.kindById = const {});

  test('money sent to an account that is not linked is spending', () {
    final tx = _tx(
      id: 't1',
      amount: 100,
      name: 'GOLDMAN SACHS BA TRANSFER',
      pfcPrimary: 'TRANSFER_OUT',
      pfcDetailed: 'TRANSFER_OUT_ACCOUNT_TRANSFER',
      accountType: 'depository',
    );
    final kinds = classifyTransactions([tx], const {}).kinds;
    expect(kinds['t1'], TxKind.spend);
    expect(tx.expenseAmount, 100);
  });

  test('a card payment between two linked accounts counts as nothing', () {
    final bankSide = _tx(
      id: 't1',
      amount: 330,
      name: 'Payment to Chase card ending in 4191',
      date: DateTime(2026, 10, 19),
      pfcPrimary: 'LOAN_PAYMENTS',
      pfcDetailed: 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT',
      accountId: 'acc-checking',
      accountType: 'depository',
    );
    final cardSide = _tx(
      id: 't2',
      amount: -330,
      name: 'Payment Thank You-Mobile',
      pfcPrimary: 'LOAN_DISBURSEMENTS',
    );
    AppTransaction.kindById = classifyTransactions([
      bankSide,
      cardSide,
    ], const {}).kinds;
    expect(bankSide.kind, TxKind.internal);
    expect(cardSide.kind, TxKind.internal);
    expect(cardSide.inflowLabel, kInternalTransfer);
    // With only the checking account linked, the payment is spending.
    AppTransaction.kindById = classifyTransactions([bankSide], const {}).kinds;
    expect(bankSide.expenseAmount, 330);
  });

  test('Zelle with a person and cash deposits still count', () {
    final zelleOut = _tx(
      id: 't1',
      amount: 71,
      name: 'Zelle payment to Austin Chin',
      pfcPrimary: 'TRANSFER_OUT',
      pfcDetailed: 'TRANSFER_OUT_ACCOUNT_TRANSFER',
      accountType: 'depository',
    );
    final zelleIn = _tx(
      id: 't2',
      amount: -67,
      name: 'Zelle payment from ALICE HU',
      pfcPrimary: 'TRANSFER_IN',
      pfcDetailed: 'TRANSFER_IN_ACCOUNT_TRANSFER',
      accountType: 'depository',
    );
    final cash = _tx(
      id: 't3',
      amount: -3000,
      name: 'ATM CASH DEPOSIT 10/12',
      pfcPrimary: 'TRANSFER_IN',
      pfcDetailed: 'TRANSFER_IN_DEPOSIT',
      accountType: 'depository',
    );
    expect(zelleOut.expenseAmount, 71);
    expect(zelleIn.incomeAmount, 67);
    expect(cash.incomeAmount, 3000);
  });

  test('a refund nets against the purchase it pays back', () {
    final purchase = _tx(
      id: 'buy',
      amount: 107.79,
      name: 'Bose Corporation',
      date: DateTime(2026, 10, 18),
      pfcPrimary: 'GENERAL_MERCHANDISE',
    );
    final refund = _tx(
      id: 'back',
      amount: -107.79,
      name: 'Bose Corporation',
      pfcPrimary: 'OTHER',
    );
    // Alone it reads as income; matched with the purchase it is a refund.
    expect(refund.ownKind(), TxKind.income);
    final result = classifyTransactions([purchase, refund], const {});
    AppTransaction.kindById = result.kinds;
    expect(refund.kind, TxKind.refund);
    expect(refund.expenseAmount, -107.79);
    expect(refund.incomeAmount, 0);
    expect(result.purchaseIdByRefundId, {'back': 'buy'});
  });

  test('a refund needs an earlier purchase on the same account', () {
    final purchase = _tx(
      id: 'buy',
      amount: 50,
      name: 'Bose Corporation',
      date: DateTime(2026, 10, 18),
      accountId: 'other-card',
      pfcPrimary: 'GENERAL_MERCHANDISE',
    );
    final money = _tx(id: 'in', amount: -50, name: 'Bose Corporation');
    final result = classifyTransactions([purchase, money], const {});
    expect(result.kinds['in'], TxKind.income);
  });

  test(
    'the user decides: Internal Transfer, Income, or a spending category',
    () {
      final zelleIn = _tx(
        id: 'z',
        amount: -40,
        name: 'Zelle payment from ALICE HU',
        pfcPrimary: 'TRANSFER_IN',
        accountType: 'depository',
      );
      final cash = _tx(
        id: 'c',
        amount: -3000,
        name: 'ATM CASH DEPOSIT',
        pfcPrimary: 'TRANSFER_IN',
        pfcDetailed: 'TRANSFER_IN_DEPOSIT',
        accountType: 'depository',
      );
      final savings = _tx(
        id: 's',
        amount: 100,
        name: 'GOLDMAN SACHS BA TRANSFER',
        pfcPrimary: 'TRANSFER_OUT',
        pfcDetailed: 'TRANSFER_OUT_ACCOUNT_TRANSFER',
        accountType: 'depository',
      );
      final kinds = classifyTransactions(
        [zelleIn, cash, savings],
        {'z': 'Food', 'c': kInternalTransfer, 's': 'Shopping'},
      ).kinds;
      // A friend paying back dinner lowers Food.
      expect(kinds['z'], TxKind.refund);
      expect(kinds['c'], TxKind.internal);
      expect(kinds['s'], TxKind.spend);
    },
  );

  test('the same amount leaving one linked account and arriving in another '
      'is a move between own accounts', () {
    final out = _tx(
      id: 'out',
      amount: 300,
      name: 'WITHDRAWAL 10/14',
      date: DateTime(2026, 10, 14),
      pfcPrimary: 'TRANSFER_OUT',
      pfcDetailed: 'TRANSFER_OUT_WITHDRAWAL',
      accountId: 'checking',
      accountType: 'depository',
    );
    final into = _tx(
      id: 'in',
      amount: -300,
      name: 'DEPOSIT',
      date: DateTime(2026, 10, 15),
      pfcPrimary: 'TRANSFER_IN',
      pfcDetailed: 'TRANSFER_IN_DEPOSIT',
      accountId: 'savings',
      accountType: 'depository',
    );
    final lunch = _tx(
      id: 'lunch',
      amount: 20,
      name: 'Chipotle',
      date: DateTime(2026, 10, 14),
      pfcPrimary: 'FOOD_AND_DRINK',
      accountId: 'checking',
    );
    final friend = _tx(
      id: 'friend',
      amount: -20,
      name: 'Zelle payment from ALICE HU',
      date: DateTime(2026, 10, 14),
      pfcPrimary: 'TRANSFER_IN',
      accountId: 'savings',
      accountType: 'depository',
    );
    final kinds = classifyTransactions([
      out,
      into,
      lunch,
      friend,
    ], const {}).kinds;
    expect(kinds['out'], TxKind.internal);
    expect(kinds['in'], TxKind.internal);
    expect(kinds['lunch'], TxKind.spend);
    expect(kinds['friend'], TxKind.income);
  });

  test('each move pairs with the closest arrival, in any order', () {
    AppTransaction move(String id, String account, double amount, int day) =>
        _tx(
          id: id,
          amount: amount,
          name: 'ONLINE TRANSFER',
          date: DateTime(2026, 10, day),
          pfcPrimary: amount > 0 ? 'TRANSFER_OUT' : 'TRANSFER_IN',
          accountId: account,
          accountType: 'depository',
        );
    final rows = [
      move('in-late', 'savings', -500, 12),
      move('out-2', 'checking', 500, 11),
      move('in-early', 'savings', -500, 2),
      move('out-1', 'checking', 500, 1),
      move('out-3', 'checking', 500, 20),
    ];
    for (final order in [rows, rows.reversed.toList()]) {
      final kinds = classifyTransactions(order, const {}).kinds;
      expect(kinds['out-1'], TxKind.internal);
      expect(kinds['out-2'], TxKind.internal);
      expect(kinds['out-3'], TxKind.spend);
    }
  });

  test('p2pCounterparty reads the person after to or from', () {
    expect(
      AppTransaction.p2pCounterparty('Zelle payment to Hendrick Yang Conf# 12'),
      'hendrick yang',
    );
    expect(
      AppTransaction.p2pCounterparty('ZELLE PAYMENT FROM ALICE HUANG 3141'),
      'alice huang',
    );
    expect(AppTransaction.p2pCounterparty('VENMO PAYMENT 1023'), '');
  });
}
