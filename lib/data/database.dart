import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local SQLite store. Everything here stays on the device — v1 has no
/// server, so the database IS the message store.
class AppDatabase {
  static Future<Database> open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'campus_connect.db'),
      version: 3,
      onCreate: (db, version) async {
        await db.execute('''
          CREATE TABLE conversations(
            peer_user_id TEXT PRIMARY KEY,
            peer_name TEXT NOT NULL,
            last_message TEXT,
            last_ts INTEGER NOT NULL DEFAULT 0,
            unread INTEGER NOT NULL DEFAULT 0
          )
        ''');
        await db.execute('''
          CREATE TABLE messages(
            id TEXT PRIMARY KEY,
            conversation_id TEXT NOT NULL,
            sender_id TEXT NOT NULL,
            text TEXT NOT NULL,
            ts INTEGER NOT NULL,
            direction INTEGER NOT NULL,
            status INTEGER NOT NULL,
            kind INTEGER NOT NULL DEFAULT 0,
            file_name TEXT,
            file_size INTEGER,
            mime_type TEXT,
            file_path TEXT,
            FOREIGN KEY(conversation_id) REFERENCES conversations(peer_user_id)
          )
        ''');
        await db.execute(
            'CREATE INDEX idx_messages_conv ON messages(conversation_id, ts)');
        await db.execute('''
          CREATE TABLE groups(
            group_id TEXT PRIMARY KEY,
            name TEXT NOT NULL,
            members TEXT NOT NULL DEFAULT '{}',
            last_message TEXT,
            last_ts INTEGER NOT NULL DEFAULT 0,
            unread INTEGER NOT NULL DEFAULT 0
          )
        ''');
      },
      onUpgrade: (db, oldVersion, newVersion) async {
        if (oldVersion < 2) {
          // v2: file messages — new columns, all nullable / defaulted so
          // existing text chats survive the upgrade untouched.
          await db.execute(
              'ALTER TABLE messages ADD COLUMN kind INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE messages ADD COLUMN file_name TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN file_size INTEGER');
          await db.execute('ALTER TABLE messages ADD COLUMN mime_type TEXT');
          await db.execute('ALTER TABLE messages ADD COLUMN file_path TEXT');
        }
        if (oldVersion < 3) {
          // v3: group chats.
          await db.execute('''
            CREATE TABLE groups(
              group_id TEXT PRIMARY KEY,
              name TEXT NOT NULL,
              members TEXT NOT NULL DEFAULT '{}',
              last_message TEXT,
              last_ts INTEGER NOT NULL DEFAULT 0,
              unread INTEGER NOT NULL DEFAULT 0
            )
          ''');
        }
      },
    );
  }
}
