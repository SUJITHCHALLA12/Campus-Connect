import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'app.dart';
import 'ble/ble_transport.dart';
import 'core/identity.dart';
import 'data/chat_repository.dart';
import 'data/database.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final db = await AppDatabase.open();

  final identity = IdentityStore();
  await identity.load();

  final repository = ChatRepository();
  await repository.init(db);

  final ble = BleChatService(identity);
  repository.bind(ble, identity);

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: identity),
        ChangeNotifierProvider.value(value: repository),
        ChangeNotifierProvider.value(value: ble),
      ],
      child: const CampusConnectApp(),
    ),
  );
}
