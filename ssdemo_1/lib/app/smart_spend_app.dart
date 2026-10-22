import 'package:flutter/material.dart';

import '../pages/auth_page.dart';
import '../core/config/env_config.dart';
import '../services/auth_service.dart';
import 'app_theme.dart';
import 'main_screen.dart';

class SmartSpendApp extends StatelessWidget {
  const SmartSpendApp({super.key});

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<ThemeMode>(
      valueListenable: AppearanceController.instance,
      builder: (context, mode, _) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'SmartSpend',
        theme: AppTheme.light(),
        darkTheme: AppTheme.dark(),
        themeMode: mode,
        builder: (context, child) => _PhoneWidth(child: child!),
        home: const _AuthGate(),
      ),
    );
  }
}

/// The app is laid out for a phone. In a big window (Chrome on a laptop)
/// show it at iPhone size, centred like a phone on the desk, instead of
/// stretching every card across the screen.
class _PhoneWidth extends StatelessWidget {
  const _PhoneWidth({required this.child});

  final Widget child;

  // iPhone 15/16 screen in points.
  static const Size _phone = Size(393, 852);

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    final screen = media.size;
    if (screen.width <= _phone.width + 40) return child;
    // Use the phone height when the window is tall enough, else fill it.
    final framed = screen.height >= _phone.height + 40;
    final size = Size(_phone.width, framed ? _phone.height : screen.height);
    final dark = Theme.of(context).brightness == Brightness.dark;
    return ColoredBox(
      color: dark ? const Color(0xFF0B0A09) : const Color(0xFFD8D1C6),
      child: Center(
        child: Container(
          width: size.width,
          height: size.height,
          clipBehavior: Clip.antiAlias,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(framed ? 44 : 0),
            boxShadow: framed
                ? const [
                    BoxShadow(
                      color: Color(0x55000000),
                      blurRadius: 40,
                      offset: Offset(0, 16),
                    ),
                  ]
                : null,
          ),
          child: MediaQuery(
            data: media.copyWith(
              size: size,
              padding: framed
                  ? const EdgeInsets.only(top: 20, bottom: 12)
                  : media.padding,
              viewPadding: framed
                  ? const EdgeInsets.only(top: 20, bottom: 12)
                  : media.viewPadding,
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _AuthGate extends StatefulWidget {
  const _AuthGate();

  @override
  State<_AuthGate> createState() => _AuthGateState();
}

class _AuthGateState extends State<_AuthGate> {
  Future<void>? _autoLoginFuture;

  @override
  void initState() {
    super.initState();
    _autoLoginFuture = _attemptAutoLoginIfNeeded();
  }

  Future<void> _attemptAutoLoginIfNeeded() async {
    if (AuthService.instance.currentUser != null) return;
    if (!EnvConfig.instance.hasAutoLoginCredentials) return;
    try {
      await AuthService.instance.signIn(
        email: EnvConfig.instance.autoLoginEmail,
        password: EnvConfig.instance.autoLoginPassword,
      );
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _autoLoginFuture,
      builder: (context, snapshot) {
        final ready = snapshot.connectionState == ConnectionState.done;
        return StreamBuilder(
          stream: AuthService.instance.authStateChanges,
          builder: (context, _) {
            final user = AuthService.instance.currentUser;
            final Widget page = !ready
                ? const Scaffold(
                    key: ValueKey('auth-loading'),
                    body: Center(child: CircularProgressIndicator()),
                  )
                : user == null
                ? const AuthPage(key: ValueKey('auth-page'))
                : const MainScreen(key: ValueKey('main-screen'));
            // Fade the next page in over the page colour. The old page is
            // dropped at once rather than faded out: after sign-out it
            // would rebuild with no user.
            return ColoredBox(
              color: context.colors.background,
              child: AnimatedSwitcher(
                duration: motionDuration(context, 300),
                switchInCurve: Curves.easeOutCubic,
                layoutBuilder: (current, _) =>
                    current ?? const SizedBox.shrink(),
                child: page,
              ),
            );
          },
        );
      },
    );
  }
}
