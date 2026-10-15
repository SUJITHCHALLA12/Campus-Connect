import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';

import '../ble/ble_protocol.dart';
import '../ble/ble_transport.dart';
import '../core/identity.dart';
import 'models.dart';

/// Persists chats and exposes them to the UI.
///
/// Subscribes to [BleChatService.incoming]: received `msg` packets are
/// stored (and the conversation's unread count bumped unless that chat is
/// open); `ack` packets flip the matching outgoing message to delivered;
/// `file` packets (emitted by the transport after an incoming file is
/// saved) are stored as file messages.
class ChatRepository extends ChangeNotifier {
  late Database _db;
  StreamSubscription<BlePacket>? _bleSub;
  IdentityStore? _identity;

  List<Conversation> _conversations = [];
  List<Conversation> get conversations => _conversations;

  final Map<String, List<ChatMessage>> _messageCache = {};

  /// Live send progress per outgoing file message id (0.0–1.0).
  /// The chat screen reads this to render the progress bar.
  final Map<String, double> fileProgress = {};

  void updateFileProgress(String messageId, double progress) {
    fileProgress[messageId] = progress;
    notifyListeners();
  }

  void clearFileProgress(String messageId) {
    fileProgress.remove(messageId);
    notifyListeners();
  }

  /// The conversation currently open on screen (null when none).
  /// Used to decide whether an incoming message bumps the unread counter.
  String? openConversationId;

  Future<void> init(Database db) async {
    _db = db;
    await _reloadConversations();
  }

  void bind(BleChatService ble, IdentityStore identity) {
    _identity = identity;
    _bleSub?.cancel();
    _bleSub = ble.incoming.listen((packet) async {
      switch (packet.type) {
        case 'msg':
          await saveIncoming(packet);
          break;
        case 'ack':
          await markDelivered(packet.id);
          break;
        case 'file':
          await saveIncomingFile(packet);
          break;
      }
    });
  }

  Future<void> _reloadConversations() async {
    final rows = await _db.query(
      'conversations',
      orderBy: 'last_ts DESC',
    );
    _conversations = rows.map(Conversation.fromMap).toList();
    notifyListeners();
  }

  Future<List<ChatMessage>> messagesFor(String peerUserId) async {
    final cached = _messageCache[peerUserId];
    if (cached != null) return cached;
    final rows = await _db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [peerUserId],
      orderBy: 'ts ASC',
      limit: 500,
    );
    final messages = rows.map(ChatMessage.fromMap).toList();
    _messageCache[peerUserId] = messages;
    return messages;
  }

  Future<void> _upsertConversation({
    required String peerUserId,
    required String peerName,
    required String lastMessage,
    required int ts,
    required int unreadDelta,
  }) async {
    await _db.insert(
      'conversations',
      {
        'peer_user_id': peerUserId,
        'peer_name': peerName,
        'last_message': lastMessage,
        'last_ts': ts,
        'unread': unreadDelta,
      },
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    // Merge with the existing row: refresh name/snippet/time, add unread.
    await _db.rawUpdate(
      '''
      UPDATE conversations
      SET peer_name = ?, last_message = ?, last_ts = ?,
          unread = unread + ?
      WHERE peer_user_id = ?
      ''',
      [peerName, lastMessage, ts, unreadDelta, peerUserId],
    );
    await _reloadConversations();
  }

  Future<void> _insertMessage(ChatMessage m) async {
    await _db.insert(
      'messages',
      m.toMap(),
      conflictAlgorithm: ConflictAlgorithm.ignore,
    );
    final list = await messagesFor(m.conversationId);
    if (!list.any((x) => x.id == m.id)) {
      list.add(m);
      // Ensure ordering even if clocks skew.
      list.sort((a, b) => a.ts.compareTo(b.ts));
    }
    notifyListeners();
  }

  /// Stores an outgoing message as `sent` (caller flips to failed if needed).
  Future<void> saveOutgoing({
    required String peerUserId,
    required String peerName,
    required BlePacket packet,
  }) async {
    final message = ChatMessage(
      id: packet.id,
      conversationId: peerUserId,
      senderId: _identity!.userId,
      text: packet.text ?? '',
      ts: packet.ts,
      direction: MessageDirection.outgoing,
      status: MessageStatus.sent,
    );
    await _insertMessage(message);
    await _upsertConversation(
      peerUserId: peerUserId,
      peerName: peerName,
      lastMessage: message.text,
      ts: message.ts,
      unreadDelta: 0,
    );
  }

  Future<void> saveIncoming(BlePacket packet) async {
    final message = ChatMessage(
      id: packet.id,
      conversationId: packet.from,
      senderId: packet.from,
      text: packet.text ?? '',
      ts: packet.ts,
      direction: MessageDirection.incoming,
      status: MessageStatus.delivered,
    );
    await _insertMessage(message);
    await _upsertConversation(
      peerUserId: packet.from,
      peerName: packet.name.isEmpty ? 'Campus user' : packet.name,
      lastMessage: message.text,
      ts: message.ts,
      unreadDelta: openConversationId == packet.from ? 0 : 1,
    );
  }

  /// Stores an outgoing file message as `sending`. The chat screen
  /// flips it to delivered / failed once the transfer finishes.
  Future<void> saveOutgoingFile({
    required String peerUserId,
    required String peerName,
    required String transferId,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required String filePath,
    required int ts,
  }) async {
    final message = ChatMessage(
      id: transferId,
      conversationId: peerUserId,
      senderId: _identity!.userId,
      text: fileName,
      ts: ts,
      direction: MessageDirection.outgoing,
      status: MessageStatus.sending,
      kind: MessageKind.file,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      filePath: filePath,
    );
    await _insertMessage(message);
    await _upsertConversation(
      peerUserId: peerUserId,
      peerName: peerName,
      lastMessage: '📎 $fileName',
      ts: message.ts,
      unreadDelta: 0,
    );
  }

  /// Stores a received file (the transport already saved the bytes and
  /// hands us the local path in the synthetic `file` packet).
  Future<void> saveIncomingFile(BlePacket packet) async {
    final message = ChatMessage(
      id: packet.id,
      conversationId: packet.from,
      senderId: packet.from,
      text: packet.fileName ?? 'File',
      ts: packet.ts,
      direction: MessageDirection.incoming,
      status: MessageStatus.delivered,
      kind: MessageKind.file,
      fileName: packet.fileName,
      fileSize: packet.fileSize,
      mimeType: packet.mimeType,
      filePath: packet.filePath,
    );
    await _insertMessage(message);
    await _upsertConversation(
      peerUserId: packet.from,
      peerName: packet.name.isEmpty ? 'Campus user' : packet.name,
      lastMessage: '📎 ${message.text}',
      ts: message.ts,
      unreadDelta: openConversationId == packet.from ? 0 : 1,
    );
  }

  Future<void> markDelivered(String packetId) async {
    await _db.update(
      'messages',
      {'status': MessageStatus.delivered.index},
      where: 'id = ? AND direction = ?',
      whereArgs: [packetId, MessageDirection.outgoing.index],
    );
    for (final entry in _messageCache.entries) {
      final i = entry.value.indexWhere((m) => m.id == packetId);
      if (i != -1) {
        entry.value[i] =
            entry.value[i].copyWith(status: MessageStatus.delivered);
      }
    }
    clearFileProgress(packetId);
    notifyListeners();
  }

  Future<void> markFailed(String packetId) async {
    await _db.update(
      'messages',
      {'status': MessageStatus.failed.index},
      where: 'id = ? AND direction = ?',
      whereArgs: [packetId, MessageDirection.outgoing.index],
    );
    for (final entry in _messageCache.entries) {
      final i = entry.value.indexWhere((m) => m.id == packetId);
      if (i != -1) {
        entry.value[i] =
            entry.value[i].copyWith(status: MessageStatus.failed);
      }
    }
    clearFileProgress(packetId);
    notifyListeners();
  }

  /// Marks a conversation as read and records it as the open one.
  Future<void> markOpen(String peerUserId) async {
    openConversationId = peerUserId;
    await _db.update(
      'conversations',
      {'unread': 0},
      where: 'peer_user_id = ?',
      whereArgs: [peerUserId],
    );
    await _reloadConversations();
  }

  void clearOpen() {
    openConversationId = null;
  }

  @override
  void dispose() {
    _bleSub?.cancel();
    super.dispose();
  }
}
