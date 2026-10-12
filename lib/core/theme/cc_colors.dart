import 'package:flutter/material.dart';

/// Campus Connect color system — aquatic "liquid glass" design language
/// adapted from the Ripple open-source chat app (Masthan008/Ripple).
///
/// Palette is still a placeholder until the real Campus Connect logo
/// colors arrive from Figma; the structure below makes that a one-file swap.
abstract final class CcColors {
  CcColors._();

  // ─── Brand ─────────────────────────────────────────────
  static const Color aquaCore = Color(0xFF0EA5E9);
  static const Color aquaCyan = Color(0xFF22D3EE);
  static const Color deepSea = Color(0xFF0C4A6E);
  static const Color biolume = Color(0xFF38BDF8);

  // ─── Background ────────────────────────────────────────
  static const Color abyss = Color(0xFF060D1A);

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
  static const LinearGradient aquaGradient = LinearGradient(
    colors: [aquaCore, aquaCyan],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient msgOutGradient = LinearGradient(
    colors: [Color(0x660EA5E9), Color(0x4D38BDF8)],
    begin: Alignment.topLeft,
    end: Alignment.bottomRight,
  );

  static const LinearGradient buttonGradient = LinearGradient(
    colors: [Color(0xFF0EA5E9), Color(0xFF0284C7)],
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
