import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'ble/ble_transport.dart';
import 'core/bootstrap.dart';
import 'core/identity.dart';
import 'data/chat_repository.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Instances are created up front; the heavy async work (database,
  // identity load) runs after the splash screen is on screen, via
  // AppBootstrap, so startup shows the loading page immediately.
  final identity = IdentityStore();
  final repository = ChatRepository();
  final ble = BleChatService(identity);
  final bootstrap = AppBootstrap(
    identity: identity,
    repository: repository,
    ble: ble,
  );

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: identity),
        ChangeNotifierProvider.value(value: repository),
        ChangeNotifierProvider.value(value: ble),
        ChangeNotifierProvider.value(value: bootstrap),
      ],
      child: const CampusConnectApp(),
    ),
  );
}
