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

/// The app is laid out for a phone. In a wide window (Chrome on a laptop)
/// keep it phone-width and centred instead of stretching every card.
class _PhoneWidth extends StatelessWidget {
  const _PhoneWidth({required this.child});

  final Widget child;
  static const double _maxWidth = 500;

  @override
  Widget build(BuildContext context) {
    final media = MediaQuery.of(context);
    if (media.size.width <= _maxWidth) return child;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: SizedBox(
          width: _maxWidth,
          child: MediaQuery(
            data: media.copyWith(size: Size(_maxWidth, media.size.height)),
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
        if (snapshot.connectionState != ConnectionState.done) {
          return const Scaffold(
            body: Center(child: CircularProgressIndicator()),
          );
        }
        return StreamBuilder(
          stream: AuthService.instance.authStateChanges,
          builder: (context, _) {
            final user = AuthService.instance.currentUser;
            if (user == null) return const AuthPage();
            return const MainScreen();
          },
        );
      },
    );
  }
}
