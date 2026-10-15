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

  Future<void>? _initFuture;

  Future<void> init() {
    _initFuture ??= _doInit();
    return _initFuture!;
  }

  Future<void> _doInit() async {
    await Future.wait([
      _initWork(),
      // Minimum splash display time.
      Future.delayed(const Duration(milliseconds: 1200)),
    ]);
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
