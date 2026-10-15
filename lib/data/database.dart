import 'package:path/path.dart' as p;
import 'package:sqflite/sqflite.dart';

/// Local SQLite store. Everything here stays on the device — v1 has no
/// server, so the database IS the message store.
class AppDatabase {
  static Future<Database> open() async {
    final dir = await getDatabasesPath();
    return openDatabase(
      p.join(dir, 'campus_connect.db'),
      version: 5,
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
            edited INTEGER NOT NULL DEFAULT 0,
            reactions TEXT NOT NULL DEFAULT '{}',
            reply_to_id TEXT,
            reply_to_text TEXT,
            reply_to_sender TEXT,
            forwarded INTEGER NOT NULL DEFAULT 0,
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
            unread INTEGER NOT NULL DEFAULT 0,
            owner_id TEXT,
            perm_send INTEGER NOT NULL DEFAULT 0,
            perm_edit INTEGER NOT NULL DEFAULT 0,
            perm_add INTEGER NOT NULL DEFAULT 0,
            photo_path TEXT
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
        if (oldVersion < 4) {
          // v4: message actions — edit, reactions, reply quotes, forward.
          await db.execute(
              'ALTER TABLE messages ADD COLUMN edited INTEGER NOT NULL DEFAULT 0');
          await db.execute(
              "ALTER TABLE messages ADD COLUMN reactions TEXT NOT NULL DEFAULT '{}'");
          await db.execute('ALTER TABLE messages ADD COLUMN reply_to_id TEXT');
          await db
              .execute('ALTER TABLE messages ADD COLUMN reply_to_text TEXT');
          await db.execute(
              'ALTER TABLE messages ADD COLUMN reply_to_sender TEXT');
          await db.execute(
              'ALTER TABLE messages ADD COLUMN forwarded INTEGER NOT NULL DEFAULT 0');
        }
        if (oldVersion < 5) {
          // v5: group owner + group permissions + group photo.
          // All nullable / defaulted (Everyone-can) so existing groups
          // keep working; pre-v0.9 groups simply have no owner until
          // they learn one from a groupMsg / groupUpdate packet.
          await db.execute('ALTER TABLE groups ADD COLUMN owner_id TEXT');
          await db.execute(
              'ALTER TABLE groups ADD COLUMN perm_send INTEGER NOT NULL DEFAULT 0');
          await db.execute(
              'ALTER TABLE groups ADD COLUMN perm_edit INTEGER NOT NULL DEFAULT 0');
          await db.execute(
              'ALTER TABLE groups ADD COLUMN perm_add INTEGER NOT NULL DEFAULT 0');
          await db.execute('ALTER TABLE groups ADD COLUMN photo_path TEXT');
        }
      },
    );
  }
}
