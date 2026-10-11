import 'package:flutter/material.dart';

/// App-wide constants.
///
/// NOTE: the brand palette below is a placeholder. The real Campus Connect
/// logo colors (from Figma) should replace these once available.
abstract final class AppConstants {
  static const String appName = 'Campus Connect';
  static const String appTagline = 'Chat with people around you. No internet needed.';

  // Placeholder palette — replace with logo colors.
  static const Color background = Color(0xFF0B1220);
  static const Color surface = Color(0xFF131C33);
  static const Color primary = Color(0xFF6366F1);
  static const Color accent = Color(0xFFBEF264);
  static const Color textPrimary = Color(0xFFF1F5F9);
  static const Color textSecondary = Color(0xFF94A3B8);

  /// Peers not seen for longer than this are dropped from the nearby list.
  static const Duration peerStaleAfter = Duration(seconds: 30);

  /// How often the nearby list is pruned.
  static const Duration peerPruneInterval = Duration(seconds: 10);
}
