import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'chat_themes.dart';

/// Per-1:1-chat themes, persisted in SharedPreferences keyed by peer
/// user id (`cc_chat_theme_<peerUserId>` → theme id). Same pattern as
/// the profile photo: local-only, never sent to peers.
class ChatThemeStore extends ChangeNotifier {
  static const _kPrefix = 'cc_chat_theme_';

  final Map<String, String> _ids = {};
  bool _loaded = false;

  Future<void> load() async {
    if (_loaded) return;
    final prefs = await SharedPreferences.getInstance();
    for (final key in prefs.getKeys()) {
      if (!key.startsWith(_kPrefix)) continue;
      final value = prefs.getString(key);
      if (value != null) {
        _ids[key.substring(_kPrefix.length)] = value;
      }
    }
    _loaded = true;
    notifyListeners();
  }

  /// This chat's theme (Ocean when nothing was picked yet).
  ChatTheme themeFor(String peerUserId) =>
      chatThemeById(_ids[peerUserId]);

  Future<void> setTheme(String peerUserId, String themeId) async {
    final prefs = await SharedPreferences.getInstance();
    _ids[peerUserId] = themeId;
    await prefs.setString('$_kPrefix$peerUserId', themeId);
    notifyListeners();
  }
}
