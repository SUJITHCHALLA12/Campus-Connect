import 'package:flutter/material.dart';

import 'cc_colors.dart';

/// Glass-morphism decoration helpers — the "liquid glass" half of the
/// design language. All panels, bubbles and inputs are built from these.
abstract final class CcGlass {
  CcGlass._();

  /// Frosted panel used for cards, list tiles and sheets.
  static BoxDecoration panel({double radius = 24}) => BoxDecoration(
        color: CcColors.glassPanel,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: CcColors.glassBorder, width: 1),
      );

  /// Incoming message bubble: frosted, sharp top-left corner.
  static BoxDecoration bubbleIncoming() => BoxDecoration(
        color: CcColors.msgIn,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(4),
          topRight: Radius.circular(20),
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
        border: Border.all(
          color: CcColors.glassBorder.withValues(alpha: 0.3),
          width: 0.5,
        ),
      );

  /// Outgoing message bubble: aqua gradient with a soft glow.
  /// [gradient] / [borderColor] override the defaults for per-chat
  /// themes; null keeps the app-wide Ocean look.
  static BoxDecoration bubbleOutgoing({
    LinearGradient? gradient,
    Color? borderColor,
  }) =>
      BoxDecoration(
        gradient: gradient ?? CcColors.msgOutGradient,
        borderRadius: const BorderRadius.only(
          topLeft: Radius.circular(20),
          topRight: Radius.circular(4),
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
        border: Border.all(
          color: (borderColor ?? CcColors.aquaCore).withValues(alpha: 0.4),
          width: 0.5,
        ),
        boxShadow: [
          BoxShadow(
            color: (borderColor ?? CcColors.aquaCore)
                .withValues(alpha: 0.15),
            blurRadius: 12,
            offset: const Offset(0, 4),
          ),
        ],
      );

  /// Primary gradient button (send, CTA).
  static BoxDecoration buttonPrimary({double radius = 14}) => BoxDecoration(
        gradient: CcColors.buttonGradient,
        borderRadius: BorderRadius.circular(radius),
        boxShadow: CcColors.aquaGlow,
      );

  /// Frosted text input.
  static BoxDecoration input({double radius = 16}) => BoxDecoration(
        color: CcColors.glassPanel.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(
          color: CcColors.glassBorder.withValues(alpha: 0.5),
          width: 1,
        ),
      );

  /// Circular avatar with aqua ring.
  static BoxDecoration avatarRing({double radius = 28}) => BoxDecoration(
        shape: BoxShape.circle,
        gradient: CcColors.aquaGradient,
        boxShadow: CcColors.cyanGlow,
      );
}
