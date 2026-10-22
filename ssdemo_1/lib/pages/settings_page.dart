import 'package:flutter/material.dart';

import '../app/app_theme.dart';
import '../models/app_models.dart';
import '../widgets/common/ui.dart';

/// Gear page on Wallet: banks, refresh, appearance, sign out.
class SettingsPage extends StatelessWidget {
  const SettingsPage({
    super.key,
    required this.accountOptions,
    required this.syncing,
    required this.syncStatus,
    required this.onReconnect,
    required this.onAddBank,
    required this.onRefresh,
    required this.onClear,
    required this.onSignOut,
    this.email,
    this.loginRequired = false,
    this.bankSyncBusy = false,
    this.subscriptionCount = 0,
    this.onOpenSubscriptions,
    this.hiddenAccounts = const [],
    this.onHideAccount,
    this.onShowAccount,
  });

  final String? email;
  final List<AccountOption> accountOptions;
  final bool loginRequired;
  final bool syncing;

  /// A background refresh is running: the bank buttons wait for it.
  final bool bankSyncBusy;
  final String syncStatus;
  final int subscriptionCount;
  final VoidCallback onReconnect;
  final VoidCallback onAddBank;
  final VoidCallback onRefresh;
  final VoidCallback onClear;
  final Future<void> Function() onSignOut;
  final VoidCallback? onOpenSubscriptions;

  /// Accounts the user hid; listed so they can be shown again.
  final List<AccountOption> hiddenAccounts;

  /// Swipe a bank row left to hide it. Nothing is deleted.
  final ValueChanged<AccountOption>? onHideAccount;
  final ValueChanged<AccountOption>? onShowAccount;

  static String appearanceLabel(ThemeMode mode) => switch (mode) {
    ThemeMode.light => 'Light',
    ThemeMode.dark => 'Dark',
    ThemeMode.system => 'System',
  };

  Future<void> _confirmClear(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Clear local data?'),
        content: const Text(
          'This removes the bank data saved on this device. '
          'Refresh Data downloads it again.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Clear', style: TextStyle(color: context.colors.bad)),
          ),
        ],
      ),
    );
    if (ok == true) onClear();
  }

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final busy = syncing || bankSyncBusy;
    Widget divider() => Padding(
      padding: const EdgeInsets.only(left: 58),
      child: Divider(height: 0.5, thickness: 0.5, color: c.line),
    );
    Widget row({
      Key? key,
      required IconData icon,
      required String title,
      String? subtitle,
      Widget? trailing,
      VoidCallback? onTap,
      Color? color,
      bool chevron = true,
    }) {
      return InkWell(
        key: key,
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 11),
          child: InfoRow(
            leading: Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: c.raised,
                shape: BoxShape.circle,
              ),
              child: Icon(
                icon,
                size: 18,
                color: onTap == null ? c.muted : (color ?? c.text),
              ),
            ),
            title: title,
            subtitle: subtitle,
            trailing: trailing,
            showChevron: chevron && onTap != null,
          ),
        ),
      );
    }

    Widget group(List<Widget> rows) => Section(
      padding: EdgeInsets.zero,
      child: Column(
        children: [
          for (final (i, r) in rows.indexed) ...[if (i > 0) divider(), r],
        ],
      ),
    );

    Widget label(String text) => Padding(
      padding: const EdgeInsets.fromLTRB(32, 16, 20, 6),
      child: Text(
        text,
        style: TextStyle(fontSize: 12.5, color: c.muted, letterSpacing: 0.4),
      ),
    );

    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 32),
          children: [
            const BackLink('Wallet'),
            const LargeTitle('Settings'),
            const SizedBox(height: 8),
            group([
              row(
                icon: Icons.person_outline,
                title: email ?? 'Signed in',
                subtitle: email == null ? null : 'Signed in',
                chevron: false,
              ),
            ]),
            label('BANKS'),
            group([
              for (final a in accountOptions)
                _SwipeToHide(
                  key: ValueKey('settings-account-${a.accountId}'),
                  enabled: onHideAccount != null,
                  onHide: () => onHideAccount?.call(a),
                  child: row(
                    icon: Icons.account_balance_outlined,
                    title: a.label,
                    subtitle: loginRequired ? 'Reconnect needed' : 'Connected',
                    trailing: loginRequired
                        ? Text(
                            'Reconnect',
                            style: TextStyle(
                              color: c.bad,
                              fontWeight: FontWeight.w600,
                            ),
                          )
                        : null,
                    onTap: loginRequired && !busy ? onReconnect : null,
                  ),
                ),
              row(
                key: const ValueKey('settings-add-bank'),
                icon: Icons.add_rounded,
                title: busy ? 'Syncing' : 'Add Bank',
                onTap: busy ? null : onAddBank,
              ),
              if (accountOptions.isNotEmpty)
                row(
                  key: const ValueKey('settings-reconnect'),
                  icon: Icons.link_rounded,
                  title: 'Reconnect',
                  subtitle: 'Sign in to your bank again',
                  onTap: busy ? null : onReconnect,
                ),
              row(
                key: const ValueKey('settings-refresh'),
                icon: Icons.refresh_rounded,
                title: 'Refresh Data',
                subtitle: syncStatus,
                onTap: busy ? null : onRefresh,
                chevron: false,
              ),
            ]),
            if (hiddenAccounts.isNotEmpty) ...[
              label('HIDDEN'),
              group([
                for (final a in hiddenAccounts)
                  row(
                    key: ValueKey('settings-hidden-${a.accountId}'),
                    icon: Icons.visibility_off_outlined,
                    title: a.label,
                    trailing: TextButton(
                      onPressed: onShowAccount == null
                          ? null
                          : () => onShowAccount!(a),
                      child: const Text('Show'),
                    ),
                    chevron: false,
                  ),
              ]),
            ],
            label('APP'),
            group([
              row(
                icon: Icons.autorenew_rounded,
                title: 'Subscriptions',
                trailing: Text(
                  '$subscriptionCount',
                  style: TextStyle(color: c.muted),
                ),
                onTap: onOpenSubscriptions,
              ),
              ValueListenableBuilder<ThemeMode>(
                valueListenable: AppearanceController.instance,
                builder: (context, mode, _) => row(
                  key: const ValueKey('settings-appearance'),
                  icon: Icons.contrast_rounded,
                  title: 'Appearance',
                  trailing: Text(
                    appearanceLabel(mode),
                    style: TextStyle(color: c.muted),
                  ),
                  onTap: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const AppearancePage(),
                    ),
                  ),
                ),
              ),
            ]),
            const SizedBox(height: 18),
            group([
              row(
                key: const ValueKey('settings-sign-out'),
                icon: Icons.logout_rounded,
                title: 'Sign Out',
                color: c.bad,
                onTap: onSignOut,
                chevron: false,
              ),
              row(
                key: const ValueKey('settings-clear'),
                icon: Icons.delete_outline_rounded,
                title: 'Clear Local Data',
                color: c.bad,
                onTap: busy ? null : () => _confirmClear(context),
                chevron: false,
              ),
            ]),
            const SizedBox(height: 14),
            Center(
              child: Text(
                'SmartSpend · Senior Capstone',
                style: TextStyle(fontSize: 12, color: c.muted),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Light / Dark previews, plus "Match iPhone setting" (the default).
class AppearancePage extends StatelessWidget {
  const AppearancePage({super.key});

  @override
  Widget build(BuildContext context) {
    final c = context.colors;
    final controller = AppearanceController.instance;
    return Scaffold(
      body: SafeArea(
        bottom: false,
        child: ValueListenableBuilder<ThemeMode>(
          valueListenable: controller,
          builder: (context, mode, _) {
            final system = mode == ThemeMode.system;
            final platformDark =
                MediaQuery.platformBrightnessOf(context) == Brightness.dark;
            final effectiveDark = system
                ? platformDark
                : mode == ThemeMode.dark;

            Widget option(bool dark) {
              final selected = effectiveDark == dark;
              final p = dark ? AppColors.dark : AppColors.light;
              return Expanded(
                child: Pressable(
                  hoverScale: 1.02,
                  pressScale: 0.97,
                  child: GestureDetector(
                    key: ValueKey(
                      dark ? 'appearance-dark' : 'appearance-light',
                    ),
                    onTap: () =>
                        controller.set(dark ? ThemeMode.dark : ThemeMode.light),
                    child: Column(
                      children: [
                        Container(
                          height: 150,
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: p.background,
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: selected ? c.text : c.line,
                              width: selected ? 2 : 1,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              Container(
                                height: 44,
                                decoration: BoxDecoration(
                                  color: AppPalette.walletAll,
                                  borderRadius: BorderRadius.circular(8),
                                ),
                              ),
                              const SizedBox(height: 8),
                              for (final w in [1.0, 0.7])
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 6),
                                  child: FractionallySizedBox(
                                    alignment: Alignment.centerLeft,
                                    widthFactor: w,
                                    child: Container(
                                      height: 22,
                                      decoration: BoxDecoration(
                                        color: p.card,
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                        const SizedBox(height: 8),
                        Text(
                          dark ? 'Dark' : 'Light',
                          style: const TextStyle(fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 4),
                        Icon(
                          selected
                              ? Icons.radio_button_checked
                              : Icons.radio_button_unchecked,
                          color: selected ? c.text : c.muted,
                          size: 22,
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }

            return ListView(
              children: [
                const BackLink('Settings'),
                const LargeTitle('Appearance'),
                Section(
                  margin: const EdgeInsets.fromLTRB(16, 12, 16, 10),
                  padding: const EdgeInsets.fromLTRB(16, 18, 16, 14),
                  child: Row(
                    children: [
                      option(false),
                      const SizedBox(width: 16),
                      option(true),
                    ],
                  ),
                ),
                Section(
                  padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
                  child: Row(
                    children: [
                      const Expanded(
                        child: Text(
                          'Match iPhone setting',
                          style: TextStyle(fontSize: 15.5),
                        ),
                      ),
                      Switch.adaptive(
                        key: const ValueKey('appearance-system'),
                        value: system,
                        activeTrackColor: c.good,
                        onChanged: (on) => controller.set(
                          on
                              ? ThemeMode.system
                              : (platformDark
                                    ? ThemeMode.dark
                                    : ThemeMode.light),
                        ),
                      ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(32, 0, 32, 0),
                  child: Text(
                    'When on, SmartSpend switches between light and dark with your iPhone. Your choice is saved on this device.',
                    style: TextStyle(fontSize: 12.5, color: c.muted),
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

/// Swipe left to reveal Hide, like iOS Mail: a short swipe opens it, a tap
/// hides. A long swipe hides straight away.
class _SwipeToHide extends StatefulWidget {
  const _SwipeToHide({
    super.key,
    required this.child,
    required this.onHide,
    this.enabled = true,
  });

  final Widget child;
  final VoidCallback onHide;
  final bool enabled;

  @override
  State<_SwipeToHide> createState() => _SwipeToHideState();
}

class _SwipeToHideState extends State<_SwipeToHide> {
  static const _actionWidth = 84.0;
  double _offset = 0;
  bool _dragging = false;

  void _settle(double width) {
    setState(() {
      _dragging = false;
      if (_offset < -width * 0.6) {
        _offset = 0;
        widget.onHide();
      } else {
        _offset = _offset < -_actionWidth / 2 ? -_actionWidth : 0;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) return widget.child;
    final c = context.colors;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        return GestureDetector(
          behavior: HitTestBehavior.translucent,
          onHorizontalDragStart: (_) => setState(() => _dragging = true),
          onHorizontalDragUpdate: (d) => setState(
            () => _offset = (_offset + d.delta.dx).clamp(-width, 0.0),
          ),
          onHorizontalDragEnd: (_) => _settle(width),
          child: ClipRect(
            child: Stack(
              children: [
                if (_offset < 0)
                  Positioned.fill(
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: SizedBox(
                        width: (-_offset).clamp(0.0, width),
                        child: Material(
                          color: c.bad,
                          child: InkWell(
                            key: const ValueKey('settings-hide-account'),
                            onTap: () {
                              setState(() => _offset = 0);
                              widget.onHide();
                            },
                            child: const Center(
                              child: Text(
                                'Hide',
                                maxLines: 1,
                                style: TextStyle(
                                  color: Colors.white,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                AnimatedContainer(
                  duration: _dragging
                      ? Duration.zero
                      : const Duration(milliseconds: 220),
                  curve: Curves.easeOutCubic,
                  transform: Matrix4.translationValues(_offset, 0, 0),
                  color: c.card,
                  child: widget.child,
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
