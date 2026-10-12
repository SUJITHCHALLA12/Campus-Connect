import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// The local user's identity: a stable random user id plus a display name.
///
/// The full user id is exchanged with peers over the BLE HELLO handshake;
/// an 8-character prefix of it is also broadcast in the advertising name so
/// two phones can deterministically decide which one opens the connection.
class IdentityStore extends ChangeNotifier {
  static const _kUserId = 'cc_user_id';
  static const _kDisplayName = 'cc_display_name';

  String? _userId;
  String? _displayName;

  bool get hasIdentity => _userId != null && (_displayName?.isNotEmpty ?? false);

  String get userId => _userId!;
  String get displayName => _displayName ?? '';

  /// First 8 hex chars of the user id — used in advertising + tie-breaking.
  String get shortId => _userId!.replaceAll('-', '').substring(0, 8);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString(_kUserId);
    _displayName = prefs.getString(_kDisplayName);
    notifyListeners();
  }

  Future<void> setDisplayName(String name) async {
    final clean = name.trim();
    if (clean.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();
    _userId ??= const Uuid().v4();
    _displayName = clean;
    await prefs.setString(_kUserId, _userId!);
    await prefs.setString(_kDisplayName, _displayName!);
    notifyListeners();
  }

  /// Forgets this identity (used by "Reset" in Settings).
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserId);
    await prefs.remove(_kDisplayName);
    _userId = null;
    _displayName = null;
    notifyListeners();
  }
}
