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

  test('a transfer to own savings is neither spending nor income', () {
    final tx = _tx(
      id: 't1',
      amount: 100,
      name: 'GOLDMAN SACHS BA TRANSFER',
      pfcPrimary: 'TRANSFER_OUT',
      pfcDetailed: 'TRANSFER_OUT_ACCOUNT_TRANSFER',
      accountType: 'depository',
    );
    expect(tx.kind, TxKind.internal);
    expect(tx.expenseAmount, 0);
    expect(tx.incomeAmount, 0);
  });

  test('both sides of a card payment count as nothing', () {
    final bankSide = _tx(
      id: 't1',
      amount: 330,
      name: 'Payment to Chase card ending in 4191',
      pfcPrimary: 'LOAN_PAYMENTS',
      pfcDetailed: 'LOAN_PAYMENTS_CREDIT_CARD_PAYMENT',
      accountType: 'depository',
    );
    final cardSide = _tx(
      id: 't2',
      amount: -330,
      name: 'Payment Thank You-Mobile',
      pfcPrimary: 'LOAN_DISBURSEMENTS',
    );
    expect(bankSide.kind, TxKind.internal);
    expect(cardSide.kind, TxKind.internal);
    expect(cardSide.inflowLabel, kInternalTransfer);
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
}
