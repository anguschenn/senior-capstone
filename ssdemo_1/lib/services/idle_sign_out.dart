import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// How long the app can go unused before it signs out. Supabase keeps the
/// session in the browser and refreshes it on every launch, so without this
/// whoever opens the browser next is signed in, however long it has been.
const kIdleSignOutAfter = Duration(hours: 1);

/// Whether a session last used at [lastActive] has been idle too long. No
/// record (a session from before this check) counts as idle.
bool isIdleTooLong(
  DateTime? lastActive,
  DateTime now, {
  Duration limit = kIdleSignOutAfter,
}) => lastActive == null || now.difference(lastActive) >= limit;

/// When this browser last saw the app used, shared by its open tabs.
class IdleActivityStore {
  const IdleActivityStore._();
  static const instance = IdleActivityStore._();

  static const _key = 'last_active_at_v1';

  Future<DateTime?> load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final millis = prefs.getInt(_key);
      return millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis);
    } catch (_) {
      return null;
    }
  }

  Future<void> save(DateTime at) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setInt(_key, at.millisecondsSinceEpoch);
    } catch (_) {
      // Best effort: this tab still tracks its own activity.
    }
  }
}

/// Wraps the signed-in app: taps and scrolls count as use, and [onIdle] runs
/// once the app has gone [limit] without any, in this tab or another. Checked
/// every minute, when the tab or app comes back, and on the next tap (a
/// background tab's timer may not have run).
class IdleSignOutGuard extends StatefulWidget {
  const IdleSignOutGuard({
    super.key,
    required this.child,
    required this.onIdle,
    this.limit = kIdleSignOutAfter,
    this.now = DateTime.now,
  });

  final Widget child;
  final VoidCallback onIdle;
  final Duration limit;
  final DateTime Function() now;

  @override
  State<IdleSignOutGuard> createState() => _IdleSignOutGuardState();
}

class _IdleSignOutGuardState extends State<IdleSignOutGuard>
    with WidgetsBindingObserver {
  static const _saveEvery = Duration(seconds: 30);

  Timer? _timer;
  late DateTime _lastActive;
  DateTime? _lastSaved;
  bool _idle = false;

  @override
  void initState() {
    super.initState();
    _lastActive = widget.now();
    _save(_lastActive);
    WidgetsBinding.instance.addObserver(this);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => _check());
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _check();
  }

  void _save(DateTime at) {
    _lastSaved = at;
    unawaited(IdleActivityStore.instance.save(at));
  }

  Future<void> _onActivity() async {
    if (_idle) return;
    final now = widget.now();
    // A tap after the limit signs out rather than reviving the session.
    if (_tooLong()) {
      await _check();
      if (_idle) return;
    }
    _lastActive = now;
    final saved = _lastSaved;
    if (saved == null || now.difference(saved) >= _saveEvery) _save(now);
  }

  bool _tooLong() =>
      isIdleTooLong(_lastActive, widget.now(), limit: widget.limit);

  Future<void> _check() async {
    if (_idle || !_tooLong()) return;
    // Another tab may have been in use meanwhile.
    final shared = await IdleActivityStore.instance.load();
    if (shared != null && shared.isAfter(_lastActive)) _lastActive = shared;
    if (_idle || !_tooLong()) return;
    _idle = true;
    widget.onIdle();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _onActivity(),
      onPointerSignal: (_) => _onActivity(),
      child: widget.child,
    );
  }
}
