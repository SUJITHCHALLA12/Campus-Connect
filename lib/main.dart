import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'ble/ble_transport.dart';
import 'core/bootstrap.dart';
import 'core/identity.dart';
import 'core/theme/chat_theme_store.dart';
import 'data/chat_repository.dart';
import 'transfer/fast_file_transfer.dart';

Future<void> main() async {
  // Safety net: an unhandled async error in a release build kills
  // the process instantly (the app "opens" and comes straight back).
  // Log stray errors instead of dying on them; startup's own work is
  // additionally guarded inside AppBootstrap, which surfaces real
  // failures on an error screen.
  runZonedGuarded(() async {
    WidgetsFlutterBinding.ensureInitialized();
    await _startApp();
  }, (error, stack) {
    if (kDebugMode) {
      // ignore: avoid_print
      print('Campus Connect unhandled error: $error\n$stack');
    }
  });
}

Future<void> _startApp() async {

  // Instances are created up front; the heavy async work (database,
  // identity load) runs after the splash screen is on screen, via
  // AppBootstrap, so startup shows the loading page immediately.
  final identity = IdentityStore();
  final repository = ChatRepository();
  final ble = BleChatService(identity);
  final chatThemes = ChatThemeStore();
  // Fast file transfer (Nearby → Wi-Fi Direct → BLE). Created here
  // so the chat screens can read it; started from the home screen
  // once the identity exists (see HomeScreen._startBle).
  final fastTransfer = FastFileTransferService(
    identity: identity,
    repository: repository,
    ble: ble,
  );
  final bootstrap = AppBootstrap(
    identity: identity,
    repository: repository,
    ble: ble,
    chatThemes: chatThemes,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: identity),
        ChangeNotifierProvider.value(value: repository),
        ChangeNotifierProvider.value(value: ble),
        ChangeNotifierProvider.value(value: bootstrap),
        ChangeNotifierProvider.value(value: chatThemes),
        // Plain provider: the service holds no UI state of its own.
        Provider.value(value: fastTransfer),
      ],
      child: const CampusConnectApp(),
    ),
  );
}
