import 'package:flutter/material.dart';

import '../pages/auth_page.dart';
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
      home: StreamBuilder(
        stream: AuthService.instance.authStateChanges,
        builder: (context, snapshot) {
          final user = AuthService.instance.currentUser;
          if (user == null) {
            return const AuthPage();
          }
          return const MainScreen();
        },
      ),
    );
  }
}
