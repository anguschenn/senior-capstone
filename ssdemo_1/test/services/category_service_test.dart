import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/services/category_service.dart';

void main() {
  group('CategoryService classifyByPfcSignals', () {
    test('single hit becomes low confidence for review', () {
      final result = CategoryService.instance.classifyByPfcSignals(
        pfcPrimary: 'ENTERTAINMENT',
        pfcDetailed: '',
        merchantName: '',
        transactionName: '',
      );
      expect(result.category, 'Entertainment');
      expect(result.confidence, 'low');
    });

    test('conflicting multi-hit becomes low confidence for review', () {
      final result = CategoryService.instance.classifyByPfcSignals(
        pfcPrimary: 'ENTERTAINMENT',
        pfcDetailed: 'FOOD_AND_DRINK_RESTAURANT',
        merchantName: '',
        transactionName: 'City Gym',
      );
      expect(result.confidence, 'low');
    });

    test('two consistent hits become mid confidence', () {
      final result = CategoryService.instance.classifyByPfcSignals(
        pfcPrimary: 'ENTERTAINMENT',
        pfcDetailed: 'ENTERTAINMENT_MOVIES_AND_THEATER',
        merchantName: '',
        transactionName: '',
      );
      expect(result.category, 'Entertainment');
      expect(result.confidence, 'mid');
    });

    test('three consistent hits become high confidence', () {
      final result = CategoryService.instance.classifyByPfcSignals(
        pfcPrimary: 'TRANSFER_OUT',
        pfcDetailed: 'TRANSFER_OUT_ACCOUNT_TRANSFER',
        merchantName: 'Venmo',
        transactionName: 'Venmo payment to Austin',
      );
      expect(result.category, 'Fees & Transfers');
      expect(result.confidence, 'high');
    });

    test('OPENAI*CHATGPT SUBSCR with OTHER_OTHER maps to Subscriptions', () {
      final result = CategoryService.instance.classifyByPfcSignals(
        pfcPrimary: 'OTHER',
        pfcDetailed: 'OTHER_OTHER',
        merchantName: '',
        transactionName: 'OPENAI*CHATGPT SUBSCR',
      );
      expect(result.category, 'Subscriptions');
      expect(result.confidence, 'high');
    });

    test('PAYPAL TRANSFER PPD with OTHER_OTHER maps to Fees & Transfers', () {
      final result = CategoryService.instance.classifyByPfcSignals(
        pfcPrimary: 'OTHER',
        pfcDetailed: 'OTHER_OTHER',
        merchantName: 'PAYPAL',
        transactionName: 'PAYPAL TRANSFER PPD',
      );
      expect(result.category, 'Fees & Transfers');
      expect(result.confidence, 'high');
    });
  });
}
