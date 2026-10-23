import 'package:flutter/foundation.dart';

import '../ble/ble_transport.dart';
import '../data/chat_repository.dart';
import '../data/database.dart';
import 'identity.dart';
import 'theme/chat_theme_store.dart';

/// Runs the async startup work (database, identity, repository) after the
/// splash screen is already on screen, then notifies the app to switch
/// to the welcome / home screen.
///
/// Idempotent: repeated calls return the same future. A minimum display
/// time keeps the loading page visible instead of flashing past it.
class AppBootstrap extends ChangeNotifier {
  final IdentityStore identity;
  final ChatRepository repository;
  final BleChatService ble;
  final ChatThemeStore chatThemes;

  AppBootstrap({
    required this.identity,
    required this.repository,
    required this.ble,
    required this.chatThemes,
  });

  bool _ready = false;
  bool get ready => _ready;

  /// The error that stopped startup, if any. Startup failures (a
  /// database that can't open, corrupt preferences, …) are captured
  /// here and shown on an error screen instead of escaping as an
  /// unhandled async error — in a release build an unhandled error
  /// kills the app instantly, before anything renders.
  Object? _error;
  Object? get error => _error;

  Future<void>? _initFuture;

  Future<void> init() {
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  /// Re-runs startup after a failure (the error screen's Retry).
  Future<void> retry() {
    _initFuture = null;
    _error = null;
    notifyListeners();
    return init();
  }

  Future<void> _doInit() async {
    try {
      await Future.wait([
        _initWork(),
        // Minimum splash display time.
        Future.delayed(const Duration(milliseconds: 1200)),
      ]);
    } catch (e) {
      _error = e;
      notifyListeners();
      return;
    }
    _ready = true;
    notifyListeners();
  }

  Future<void> _initWork() async {
    final db = await AppDatabase.open();
    await identity.load();
    await chatThemes.load();
    await repository.init(db);
    repository.bind(ble, identity);
  }
}
