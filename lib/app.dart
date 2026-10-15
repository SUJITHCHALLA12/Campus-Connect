import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import 'core/constants.dart';
import 'core/identity.dart';
import 'ui/home_screen.dart';
import 'ui/welcome_screen.dart';

/// Root widget — aquatic "liquid glass" theme, wired to the
/// BLE-first Campus Connect core.
class CampusConnectApp extends StatelessWidget {
  const CampusConnectApp({super.key});

  @override
  Widget build(BuildContext context) {
    final identity = context.watch<IdentityStore>();

    final base = ThemeData.dark(useMaterial3: true);
    return MaterialApp(
      title: AppConstants.appName,
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        brightness: Brightness.dark,
        scaffoldBackgroundColor: CcColors.abyss,
        primaryColor: CcColors.aquaCore,
        colorScheme: const ColorScheme.dark(
          primary: CcColors.aquaCore,
          secondary: CcColors.aquaCyan,
          surface: CcColors.abyss,
          error: CcColors.errorRed,
        ),
        textTheme: GoogleFonts.dmSansTextTheme(base.textTheme).apply(
          bodyColor: CcColors.textPrimary,
          displayColor: CcColors.textPrimary,
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.transparent,
          elevation: 0,
          systemOverlayStyle: SystemUiOverlayStyle.light,
          titleTextStyle: GoogleFonts.nunito(
            fontSize: 20,
            fontWeight: FontWeight.w700,
            color: CcColors.textPrimary,
          ),
          iconTheme: const IconThemeData(color: CcColors.textPrimary),
        ),
        cardTheme: CardThemeData(
          color: CcColors.glassPanel,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
            side: const BorderSide(color: CcColors.glassBorder, width: 1),
          ),
        ),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          fillColor: CcColors.glassPanel,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: CcColors.glassBorder),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide: const BorderSide(color: CcColors.glassBorder),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(16),
            borderSide:
                const BorderSide(color: CcColors.aquaCore, width: 1.5),
          ),
          hintStyle: GoogleFonts.dmSans(
            color: CcColors.textMuted,
            fontSize: 14,
          ),
        ),
        bottomNavigationBarTheme: const BottomNavigationBarThemeData(
          backgroundColor: Colors.transparent,
          selectedItemColor: CcColors.aquaCyan,
          unselectedItemColor: CcColors.textMuted,
          type: BottomNavigationBarType.fixed,
          elevation: 0,
        ),
        snackBarTheme: SnackBarThemeData(
          backgroundColor: CcColors.deepSea,
          contentTextStyle: GoogleFonts.dmSans(color: CcColors.textPrimary),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          behavior: SnackBarBehavior.floating,
        ),
      ),
      home: identity.hasIdentity
          ? const HomeScreen()
          : const WelcomeScreen(),
    );
  }
}
