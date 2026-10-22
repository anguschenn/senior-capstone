import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/constants/app_constants.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/pages/home_page.dart';
import 'package:ssdemo_1/pages/settings_page.dart';

const _accounts = [
  AccountOption(
    accountId: 'a1',
    label: 'Checking ••••1234',
    ending: '1234',
    balance: 1,
    txCount: 1,
    linkedAccountIds: ['a1'],
  ),
];

Widget _home({
  bool syncing = false,
  bool bankSyncBusy = false,
  List<String>? switched,
}) {
  return MaterialApp(
    home: Scaffold(
      body: HomePage(
        transactions: const [],
        lowConfidenceTransactions: const [],
        subscriptions: const [],
        monthlySubscriptionTotal: 0,
        stats: const DashboardStats(
          totalBalance: 0,
          monthlyIncome: 0,
          monthlyExpenses: 0,
          netThisMonth: 0,
        ),
        syncing: syncing,
        bankSyncBusy: bankSyncBusy,
        onAddBank: () {},
        accountOptions: _accounts,
        selectedAccountId: kAllAccountsId,
        selectedMonth: DateTime(2026, 9, 1),
        monthOptions: [DateTime(2026, 9, 1)],
        onMonthChanged: (_) {},
        reviewedCategoryByTxId: const {},
        manualReviewedTxIds: const {},
        confirmedReviewTxIds: const {},
        lowConfidenceReviewTxIds: const {},
        onAccountChanged: (id) => switched?.add(id),
        onTransactionCategorySelected: (tx, category) {},
        onReviewConfirm: (txId) async {},
      ),
    ),
  );
}

Widget _settings({bool syncing = false, bool bankSyncBusy = false}) {
  return MaterialApp(
    home: SettingsPage(
      accountOptions: _accounts,
      syncing: syncing,
      bankSyncBusy: bankSyncBusy,
      syncStatus: 'status',
      onReconnect: () {},
      onAddBank: () {},
      onRefresh: () {},
      onClear: () {},
      onSignOut: () async {},
    ),
  );
}

bool _enabled(WidgetTester tester, String key) {
  final ink = tester.widget<InkWell>(
    find
        .descendant(
          of: find.byKey(ValueKey(key)),
          matching: find.byType(InkWell),
          matchRoot: true,
        )
        .first,
  );
  return ink.onTap != null;
}

Future<void> _tapCard(WidgetTester tester, String id) async {
  // Cards behind the front one only show their top strip.
  final topLeft = tester.getTopLeft(find.byKey(ValueKey('wallet-card-$id')));
  await tester.tapAt(topLeft + const Offset(40, 20));
  await tester.pump();
}

void main() {
  // Tall enough that the whole Settings page is on screen.
  setUp(() {
    final view =
        TestWidgetsFlutterBinding.instance.platformDispatcher.views.first;
    view.physicalSize = const Size(800, 1200);
    view.devicePixelRatio = 1;
  });
  tearDown(
    () => TestWidgetsFlutterBinding.instance.platformDispatcher.views.first
        .reset(),
  );

  testWidgets('idle: bank actions and account cards are all usable', (
    tester,
  ) async {
    final switched = <String>[];
    await tester.pumpWidget(_home(switched: switched));
    expect(_enabled(tester, 'wallet-add-bank'), isTrue);
    await _tapCard(tester, 'a1');
    expect(switched, ['a1']);

    await tester.pumpWidget(_settings());
    expect(find.text('Add Bank'), findsOneWidget);
    for (final key in [
      'settings-add-bank',
      'settings-reconnect',
      'settings-refresh',
      'settings-clear',
    ]) {
      expect(_enabled(tester, key), isTrue, reason: key);
    }
  });

  testWidgets('background bank refresh: actions wait, cards still switch', (
    tester,
  ) async {
    final switched = <String>[];
    await tester.pumpWidget(_home(bankSyncBusy: true, switched: switched));
    expect(_enabled(tester, 'wallet-add-bank'), isFalse);
    await _tapCard(tester, 'a1');
    expect(switched, ['a1']);

    await tester.pumpWidget(_settings(bankSyncBusy: true));
    expect(find.text('Syncing'), findsOneWidget);
    for (final key in [
      'settings-add-bank',
      'settings-reconnect',
      'settings-refresh',
      'settings-clear',
    ]) {
      expect(_enabled(tester, key), isFalse, reason: key);
    }
  });

  testWidgets('a blocking sync still locks everything, as before', (
    tester,
  ) async {
    final switched = <String>[];
    await tester.pumpWidget(_home(syncing: true, switched: switched));
    await _tapCard(tester, 'a1');
    expect(switched, isEmpty);

    await tester.pumpWidget(_settings(syncing: true));
    expect(_enabled(tester, 'settings-refresh'), isFalse);
  });
}
