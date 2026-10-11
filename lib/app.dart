import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'core/constants.dart';
import 'core/identity.dart';
import 'ui/home_screen.dart';
import 'ui/onboarding_screen.dart';

class CampusConnectApp extends StatelessWidget {
  const CampusConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    final identity = context.watch<IdentityStore>();
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: AppConstants.background,
        colorScheme: const ColorScheme.dark(
          primary: AppConstants.primary,
          secondary: AppConstants.accent,
          surface: AppConstants.surface,
        ),
        appBarTheme: const AppBarTheme(
          backgroundColor: AppConstants.background,
          foregroundColor: AppConstants.textPrimary,
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: AppConstants.surface,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
          hintStyle: const TextStyle(color: AppConstants.textSecondary),
        ),
      ),
      home: identity.hasIdentity
          ? const HomeScreen()
          : const OnboardingScreen(),
    );
  }
}
