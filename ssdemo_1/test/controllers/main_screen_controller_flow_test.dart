import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:ssdemo_1/controllers/main_screen_controller.dart';
import 'package:ssdemo_1/models/app_models.dart';
import 'package:ssdemo_1/services/sync_service.dart';

/// A [SyncResult] identifiable by its total balance.
SyncResult _result(double marker, {bool hasData = true}) => SyncResult(
  transactions: const [],
  subscriptions: const [],
  budgetProgress: const [],
  budgetProgressYear: const [],
  budgetProgressAll: const [],
  categoryOptions: const [],
  accountOptions: const [],
  stats: DashboardStats(
    totalBalance: marker,
    monthlyIncome: 0,
    monthlyExpenses: 0,
    netThisMonth: 0,
  ),
  hasData: hasData,
  autoReviewedCategoryByTxId: const {},
  autoLowConfidenceReviewTxIds: const {},
);

/// Sync service whose replies the test completes by hand, recording call order.
class _FakeSync implements SyncService {
  _FakeSync({this.cached});

  final CachedSyncResult? cached;
  final calls = <String>[];
  final supabaseReplies = <Completer<SyncResult>>[];
  final bankReply = Completer<void>();

  @override
  Future<CachedSyncResult?> loadCachedResult(
    Map<String, String> reviewedCategoryByTxId,
    DateTime selectedMonth,
  ) async {
    calls.add('cache');
    return cached;
  }

  @override
  Future<SyncResult> refreshFromSupabase(
    Map<String, String> reviewedCategoryByTxId,
    DateTime selectedMonth,
  ) {
    calls.add('supabase');
    final reply = Completer<SyncResult>();
    supabaseReplies.add(reply);
    return reply.future;
  }

  @override
  Future<void> triggerBankSync() {
    calls.add('bank');
    return bankReply.future;
  }

  @override
  Future<void> clearSavedData() async {
    calls.add('clear');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

CachedSyncResult _saved(double marker) => CachedSyncResult(
  result: _result(marker),
  savedAt: DateTime.now().subtract(const Duration(hours: 2)),
);

void main() {
  late _FakeSync sync;
  late MainScreenController controller;

  MainScreenController build({CachedSyncResult? cached}) {
    sync = _FakeSync(cached: cached);
    controller = MainScreenController(sync: sync);
    addTearDown(controller.dispose);
    return controller;
  }

  group('launch: loadCachedThenRefresh', () {
    test('paints saved data before Supabase or the bank respond', () async {
      build(cached: _saved(1));

      final done = controller.loadCachedThenRefresh();
      await pumpEventQueue();

      // Supabase is still pending, the bank has not even been asked.
      expect(controller.liveStats.totalBalance, 1);
      expect(controller.syncStatus, contains('Showing saved data'));
      expect(controller.syncStatus, contains('2h ago'));
      expect(sync.calls, ['cache', 'supabase']);

      sync.supabaseReplies[0].complete(_result(2));
      await pumpEventQueue();
      sync.bankReply.complete();
      await pumpEventQueue();
      sync.supabaseReplies[1].complete(_result(3));
      await done;
    });

    test('reads Supabase before the bank, then again after it', () async {
      build(cached: _saved(1));

      final done = controller.loadCachedThenRefresh();
      await pumpEventQueue();
      sync.supabaseReplies[0].complete(_result(2));
      await pumpEventQueue();

      // Fresh data is already on screen while the bank sync is still running.
      expect(controller.liveStats.totalBalance, 2);
      expect(controller.syncStatus, 'Syncing with bank...');
      expect(sync.calls, ['cache', 'supabase', 'bank']);

      sync.bankReply.complete();
      await pumpEventQueue();
      sync.supabaseReplies[1].complete(_result(3));
      await done;

      expect(controller.liveStats.totalBalance, 3);
      expect(controller.syncStatus, 'Updated');
      expect(sync.calls, ['cache', 'supabase', 'bank', 'supabase']);
    });

    test('first launch with nothing saved shows Loading, then data', () async {
      build();

      final done = controller.loadCachedThenRefresh();
      await pumpEventQueue();
      expect(controller.syncStatus, 'Loading...');
      expect(controller.liveStats.totalBalance, 0);

      sync.supabaseReplies[0].complete(_result(2));
      await pumpEventQueue();
      expect(controller.liveStats.totalBalance, 2);

      sync.bankReply.complete();
      await pumpEventQueue();
      sync.supabaseReplies[1].complete(_result(3, hasData: false));
      await done;
      expect(controller.syncStatus, 'No data found');
    });

    test('does not lock the screen while it runs', () async {
      build(cached: _saved(1));

      final done = controller.loadCachedThenRefresh();
      await pumpEventQueue();

      expect(controller.refreshingInBackground, isTrue);
      expect(controller.syncing, isFalse);

      sync.supabaseReplies[0].complete(_result(2));
      await pumpEventQueue();
      sync.bankReply.complete();
      await pumpEventQueue();
      sync.supabaseReplies[1].complete(_result(3));
      await done;

      expect(controller.refreshingInBackground, isFalse);
      expect(controller.syncing, isFalse);
    });

    test('a manual refresh is ignored while the launch refresh runs', () async {
      build(cached: _saved(1));

      final done = controller.loadCachedThenRefresh();
      await pumpEventQueue();
      await controller.refreshLiveDataOnly();
      await controller.loadCachedThenRefresh();

      expect(sync.calls, ['cache', 'supabase']);

      sync.supabaseReplies[0].complete(_result(2));
      await pumpEventQueue();
      sync.bankReply.complete();
      await pumpEventQueue();
      sync.supabaseReplies[1].complete(_result(3));
      await done;
    });

    test('expired bank login keeps the data and raises the banner', () async {
      build(cached: _saved(1));

      final done = controller.loadCachedThenRefresh();
      await pumpEventQueue();
      sync.supabaseReplies[0].complete(_result(2));
      await pumpEventQueue();
      sync.bankReply.completeError(const ItemLoginRequiredException());
      await done;

      expect(controller.loginRequired, isTrue);
      expect(controller.liveStats.totalBalance, 2);
      expect(controller.refreshingInBackground, isFalse);
    });

    test('a Supabase failure keeps the saved data on screen', () async {
      build(cached: _saved(1));

      final done = controller.loadCachedThenRefresh();
      await pumpEventQueue();
      sync.supabaseReplies[0].completeError(Exception('offline'));
      await done;

      expect(controller.liveStats.totalBalance, 1);
      expect(controller.syncStatus, startsWith('Refresh failed'));
      expect(sync.calls, ['cache', 'supabase']); // no bank sync attempted
      expect(controller.refreshingInBackground, isFalse);
    });

    test('a slow older result never overwrites newer data', () async {
      build(cached: _saved(1));

      final done = controller.loadCachedThenRefresh();
      await pumpEventQueue();
      // clearLiveData starts a newer "generation" while Supabase is in flight.
      controller.clearLiveData();
      sync.supabaseReplies[0].complete(_result(2));
      await pumpEventQueue();

      expect(controller.liveStats.totalBalance, 0);
      expect(sync.calls, contains('clear'));

      sync.bankReply.complete();
      await pumpEventQueue();
      sync.supabaseReplies[1].complete(_result(3));
      await done;
    });
  });

  group('clearLiveData', () {
    test('also forgets the on-device copy', () {
      build(cached: _saved(1));
      controller.clearLiveData();
      expect(sync.calls, ['clear']);
    });
  });
}
