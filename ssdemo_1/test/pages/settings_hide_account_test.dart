// Swipe a bank row left in Settings to hide the account; show it again from
// the Hidden list. Nothing is deleted.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/pages/settings_page.dart';

const _checking = AccountOption(
  accountId: 'a1',
  label: 'Checking ••••1234',
  ending: '1234',
  balance: 1,
  txCount: 1,
  linkedAccountIds: ['a1'],
);
const _card = AccountOption(
  accountId: 'a2',
  label: 'Card ••••4191',
  ending: '4191',
  balance: 2,
  txCount: 1,
  linkedAccountIds: ['a2'],
);

Widget _settings({
  required List<AccountOption> shown,
  List<AccountOption> hidden = const [],
  List<String>? hid,
  List<String>? showed,
}) {
  return MaterialApp(
    home: SettingsPage(
      accountOptions: shown,
      hiddenAccounts: hidden,
      onHideAccount: (a) => hid?.add(a.accountId),
      onShowAccount: (a) => showed?.add(a.accountId),
      syncing: false,
      syncStatus: 'status',
      onReconnect: () {},
      onAddBank: () {},
      onRefresh: () {},
      onClear: () {},
      onSignOut: () async {},
    ),
  );
}

void main() {
  testWidgets('a short swipe left reveals Hide; tapping it hides', (
    tester,
  ) async {
    final hid = <String>[];
    await tester.pumpWidget(_settings(shown: [_checking, _card], hid: hid));
    expect(find.text('Hide'), findsNothing);

    await tester.drag(
      find.byKey(const ValueKey('settings-account-a2')),
      const Offset(-90, 0),
    );
    await tester.pumpAndSettle();
    expect(find.text('Hide'), findsOneWidget);
    expect(hid, isEmpty);

    await tester.tap(find.text('Hide'));
    await tester.pumpAndSettle();
    expect(hid, ['a2']);
  });

  testWidgets('hidden accounts are listed with Show', (tester) async {
    final showed = <String>[];
    await tester.pumpWidget(
      _settings(shown: [_checking], hidden: [_card], showed: showed),
    );
    expect(find.text('HIDDEN'), findsOneWidget);
    await tester.tap(find.text('Show'));
    expect(showed, ['a2']);
  });
}
