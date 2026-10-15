// Re-exported for convenience.
export 'theme/cc_colors.dart';
export 'theme/cc_glass.dart';

/// App-wide constants. Visual tokens live in `core/theme/`.
abstract final class AppConstants {
  static const String appName = 'Campus Connect';
  static const String appTagline = 'Connect. Share. Campus.';

  /// Peers not seen for longer than this are dropped from the nearby list.
  static const Duration peerStaleAfter = Duration(seconds: 30);

  /// How often the nearby list is pruned.
  static const Duration peerPruneInterval = Duration(seconds: 10);
}
