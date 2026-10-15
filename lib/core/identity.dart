import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:uuid/uuid.dart';

/// The local user's identity: a stable random user id plus a display name.
///
/// The full user id is exchanged with peers over the BLE HELLO handshake;
/// an 8-character prefix of it is also broadcast in the advertising name so
/// two phones can deterministically decide which one opens the connection.
///
/// The profile photo is local-only for now: it is stored under the app
/// documents directory and shown on the Profile tab. It is not sent to
/// peers yet, so other phones still see the initials avatar.
class IdentityStore extends ChangeNotifier {
  static const _kUserId = 'cc_user_id';
  static const _kDisplayName = 'cc_display_name';
  static const _kProfilePhoto = 'cc_profile_photo';

  String? _userId;
  String? _displayName;
  String? _profilePhotoPath;

  bool get hasIdentity => _userId != null && (_displayName?.isNotEmpty ?? false);

  String get userId => _userId!;
  String get displayName => _displayName ?? '';

  /// Absolute path of the profile photo, or null when none is set.
  String? get profilePhotoPath => _profilePhotoPath;

  /// First 8 hex chars of the user id — used in advertising + tie-breaking.
  String get shortId => _userId!.replaceAll('-', '').substring(0, 8);

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _userId = prefs.getString(_kUserId);
    _displayName = prefs.getString(_kDisplayName);
    _profilePhotoPath = prefs.getString(_kProfilePhoto);
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

  /// Remembers the profile photo at [path] (the caller copies the
  /// picked image into app storage first).
  Future<void> setProfilePhoto(String path) async {
    final prefs = await SharedPreferences.getInstance();
    _profilePhotoPath = path;
    await prefs.setString(_kProfilePhoto, path);
    notifyListeners();
  }

  /// Removes the profile photo (file + preference).
  Future<void> clearProfilePhoto() async {
    final prefs = await SharedPreferences.getInstance();
    final old = _profilePhotoPath;
    _profilePhotoPath = null;
    await prefs.remove(_kProfilePhoto);
    if (old != null) {
      try {
        final file = File(old);
        if (await file.exists()) await file.delete();
      } catch (_) {
        // A stale path is harmless — the preference is already gone.
      }
    }
    notifyListeners();
  }

  /// Forgets this identity (used by "Reset" in Settings).
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_kUserId);
    await prefs.remove(_kDisplayName);
    await prefs.remove(_kProfilePhoto);
    final old = _profilePhotoPath;
    _userId = null;
    _displayName = null;
    _profilePhotoPath = null;
    if (old != null) {
      try {
        final file = File(old);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    notifyListeners();
  }
}
