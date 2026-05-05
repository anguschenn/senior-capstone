import 'package:flutter/material.dart';

import '../pages/auth_page.dart';
import '../core/config/env_config.dart';
import '../services/auth_service.dart';
import 'main_screen.dart';

class SmartSpendApp extends StatelessWidget {
  const SmartSpendApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SmartSpend',
      theme: ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.green),
      ),
      home: const _AuthGate(),
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
