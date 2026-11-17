import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/services/budget_service.dart';
import 'package:ssdemo_1/services/category_service.dart';
import 'package:ssdemo_1/utils/app_helpers.dart';

AppTransaction _tx(String id, double amount) {
  return AppTransaction(
    dedupeKey: id,
    id: id,
    accountId: 'acc-1',
    accountName: 'Checking',
    name: 'Pet Store',
    description: 'Pet Store',
    transactionType: 'debit',
    category: 'GENERAL_MERCHANDISE_PET_SUPPLIES',
    primaryCategory: 'GENERAL_MERCHANDISE',
    date: DateTime(2026, 11, 5),
    amount: amount,
    accountType: 'depository',
    accountSubtype: 'checking',
    pending: false,
    confidence: 'high',
    userId: 'u1',
    rawMerchantName: 'Pet Store',
    rawPfcPrimary: 'GENERAL_MERCHANDISE',
    rawPfcDetailed: 'GENERAL_MERCHANDISE_PET_SUPPLIES',
  );
}

void main() {
  tearDown(() => CategoryService.customCategoryNames.value = const []);

  test('custom names leave out the built-in categories, once each', () {
    final names = CategoryService.customNamesFrom(const [
      CategoryOption(id: '1', name: 'Food'),
      CategoryOption(id: '2', name: 'Pets'),
      CategoryOption(id: '3', name: 'pets'),
      CategoryOption(id: '4', name: 'Other'),
      CategoryOption(id: '5', name: 'Travel'),
    ]);
    expect(names, ['Pets', 'Travel']);
  });

  test('a typed name is spelled like the category it already names', () {
    CategoryService.customCategoryNames.value = const ['Pets'];
    expect(existingCategoryName(' food '), 'Food');
    expect(existingCategoryName('PETS'), 'Pets');
    expect(existingCategoryName(' Gifts '), 'Gifts');
  });

  test('a transaction put in a custom category counts on its card', () {
    final progress = BudgetService.instance
        .buildZeroLimitProgressFromPresetCategories(
          [_tx('t1', 40), _tx('t2', 10)],
          DateTime(2026, 11, 17),
          false,
          const {'t1': 'Pets'},
          customCategories: const ['Pets'],
        );
    final pets = progress.singleWhere((p) => p.title == 'Pets');
    expect(pets.spent, 40);
    expect(progress.any((p) => p.title == 'Food'), isTrue);
  });
}
