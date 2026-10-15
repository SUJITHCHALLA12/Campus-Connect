import 'package:flutter/material.dart';

/// Campus Connect color system — logo-derived palette.
///
/// Primary: neon cyan from the logo hexagon. Secondary accent: the
/// logo's violet. Background: the logo's near-black navy. Every screen
/// reads these tokens, so the whole app follows the logo colours.
abstract final class CcColors {
  CcColors._();

  // ─── Brand ─────────────────────────────────────────────
  /// Logo cyan — primary accent (hexagon outline, "C").
  static const Color aquaCore = Color(0xFF00C2FF);

  /// Logo violet — secondary accent (inner hexagon).
  static const Color aquaCyan = Color(0xFFA855F7);

  /// Deep navy from the logo background.
  static const Color deepSea = Color(0xFF0A1128);

  /// Bright cyan for glows and highlights.
  static const Color biolume = Color(0xFF38E1FF);

  // ─── Background ────────────────────────────────────────
  static const Color abyss = Color(0xFF050816);

  // ─── Text ──────────────────────────────────────────────
  static const Color textPrimary = Colors.white;
  static const Color textSecondary = Color(0xCCFFFFFF);
  static const Color textMuted = Color(0x80FFFFFF);

  // ─── Glass ─────────────────────────────────────────────
  static const Color glassPanel = Color(0x1AFFFFFF); // 10% white
  static const Color glassBorder = Color(0x33FFFFFF); // 20% white

  // ─── Status ────────────────────────────────────────────
  static const Color onlineGreen = Color(0xFF4ADE80);
  static const Color offlineGray = Color(0xFF94A3B8);
  static const Color errorRed = Color(0xFFF87171);
  static const Color warningAmber = Color(0xFFFBBF24);

  // ─── Message bubbles ───────────────────────────────────
  static const Color msgIn = Color(0x1AFFFFFF);

  // ─── Gradients ─────────────────────────────────────────
  /// Logo gradient: cyan → violet.
  static const LinearGradient aquaGradient = LinearGradient(
    colors: [aquaCore, aquaCyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient msgOutGradient = LinearGradient(
    colors: [Color(0x6600C2FF), Color(0x4DA855F7)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient buttonGradient = LinearGradient(
    colors: [Color(0xFF00C2FF), Color(0xFF8B5CF6)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  // ─── Glows ─────────────────────────────────────────────
  static List<BoxShadow> get aquaGlow => [
        BoxShadow(
          color: aquaCore.withValues(alpha: 0.25),
          blurRadius: 24,
          spreadRadius: -2,
        ),
      ];

  static List<BoxShadow> get cyanGlow => [
        BoxShadow(
          color: aquaCyan.withValues(alpha: 0.35),
          blurRadius: 20,
          spreadRadius: -1,
        ),
      ];
}
