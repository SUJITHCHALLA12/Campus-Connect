import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:sqflite/sqflite.dart';
import 'package:uuid/uuid.dart';

import '../ble/ble_protocol.dart';
import '../ble/ble_transport.dart';
import '../core/identity.dart';
import 'group_permissions.dart';
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

  List<Group> _groups = [];
  List<Group> get groups => _groups;

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
    await _reloadGroups();
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
        case 'groupMsg':
          await saveIncomingGroupMsg(packet);
          break;
        case 'groupUpdate':
          await applyGroupUpdate(packet);
          break;
        case 'edit':
          await applyRemoteEdit(packet);
          break;
        case 'delete':
          await applyRemoteDelete(packet);
          break;
        case 'react':
          await applyRemoteReaction(packet);
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

  Future<void> _reloadGroups() async {
    final rows = await _db.query(
      'groups',
      orderBy: 'last_ts DESC',
    );
    _groups = rows.map(Group.fromMap).toList();
    notifyListeners();
  }

  /// Creates a group with [memberIds] → display names (excluding self).
  /// The creator is the group owner (see [Group.ownerId]).
  /// Returns the stored group.
  Future<Group> createGroup({
    required String name,
    required Map<String, String> members,
  }) async {
    final group = Group(
      id: const Uuid().v4(),
      name: name,
      members: members,
      lastTs: DateTime.now().millisecondsSinceEpoch,
      unread: 0,
      ownerId: _identity!.userId,
    );
    await _db.insert('groups', group.toMap());
    await _reloadGroups();
    return group;
  }

  Group? groupById(String groupId) {
    for (final g in _groups) {
      if (g.id == groupId) return g;
    }
    return null;
  }

  Future<void> _updateGroupSnippet({
    required String groupId,
    required String lastMessage,
    required int ts,
    required int unreadDelta,
  }) async {
    await _db.rawUpdate(
      '''
      UPDATE groups
      SET last_message = ?, last_ts = ?, unread = unread + ?
      WHERE group_id = ?
      ''',
      [lastMessage, ts, unreadDelta, groupId],
    );
    await _reloadGroups();
  }

  /// Stores an outgoing group message as `sent`. The chat screen fans
  /// the packet out to each member and flips it to delivered / failed.
  Future<void> saveOutgoingGroupMsg({
    required Group group,
    required BlePacket packet,
  }) async {
    final message = ChatMessage(
      id: packet.id,
      conversationId: group.id,
      senderId: _identity!.userId,
      text: packet.text ?? '',
      ts: packet.ts,
      direction: MessageDirection.outgoing,
      status: MessageStatus.sent,
      replyToId: packet.replyToId,
      replyToText: packet.replyToText,
      replyToSender: packet.replyToSender,
      forwarded: packet.forwarded,
    );
    await _insertMessage(message);
    await _updateGroupSnippet(
      groupId: group.id,
      lastMessage: message.text,
      ts: message.ts,
      unreadDelta: 0,
    );
  }

  /// Stores a received group message, creating the group first when
  /// this phone has never seen it (name + members ride in the packet).
  /// Owner/permissions from the packet are applied for a new group
  /// outright; for a known group only when the sender IS the owner,
  /// so a non-owner member cannot spoof a settings change.
  Future<void> saveIncomingGroupMsg(BlePacket packet) async {
    final groupId = packet.groupId;
    if (groupId == null) return;
    var group = groupById(groupId);
    if (group == null) {
      final members = Map<String, String>.from(packet.members ?? {});
      members.remove(_identity!.userId);
      group = Group(
        id: groupId,
        name: packet.groupName ?? 'Group chat',
        members: members,
        lastTs: packet.ts,
        unread: 0,
        ownerId: packet.ownerId,
        permissions: packet.permissions,
      );
      await _db.insert('groups', group.toMap());
      await _reloadGroups();
    } else if (packet.ownerId != null &&
        packet.from == packet.ownerId &&
        (group.ownerId != packet.ownerId ||
            group.permissions != packet.permissions)) {
      await _db.update(
        'groups',
        {
          'owner_id': packet.ownerId,
          'perm_send':
              packet.permissions.sendMessagesOnlyOwner ? 1 : 0,
          'perm_edit':
              packet.permissions.editInfoOnlyOwner ? 1 : 0,
          'perm_add':
              packet.permissions.addMembersOnlyOwner ? 1 : 0,
        },
        where: 'group_id = ?',
        whereArgs: [groupId],
      );
      await _reloadGroups();
    }
    final message = ChatMessage(
      id: packet.id,
      conversationId: groupId,
      senderId: packet.from,
      text: packet.text ?? '',
      ts: packet.ts,
      direction: MessageDirection.incoming,
      status: MessageStatus.delivered,
      replyToId: packet.replyToId,
      replyToText: packet.replyToText,
      replyToSender: packet.replyToSender,
      forwarded: packet.forwarded,
    );
    await _insertMessage(message);
    await _updateGroupSnippet(
      groupId: groupId,
      lastMessage: message.text,
      ts: message.ts,
      unreadDelta: openConversationId == groupId ? 0 : 1,
    );
  }

  /// Stores an outgoing group file message as `sending`. The group
  /// chat screen fans the transfer out to each member and flips it
  /// to delivered / failed once the fan-out finishes.
  Future<void> saveOutgoingGroupFile({
    required Group group,
    required String transferId,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required String filePath,
    required int ts,
  }) async {
    final message = ChatMessage(
      id: transferId,
      conversationId: group.id,
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
    await _updateGroupSnippet(
      groupId: group.id,
      lastMessage: '📎 $fileName',
      ts: message.ts,
      unreadDelta: 0,
    );
  }

  /// Marks a group as read and records it as the open conversation.
  Future<void> markGroupOpen(String groupId) async {
    openConversationId = groupId;
    await _db.update(
      'groups',
      {'unread': 0},
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    await _reloadGroups();
  }

  // ─── Group permissions: owner + Everyone / Only-owner ───

  /// Applies an incoming `groupUpdate` packet. Only the owner may
  /// change group permissions, so the packet is applied only when the
  /// sender IS the claimed owner (`from == ownerId`).
  Future<void> applyGroupUpdate(BlePacket packet) async {
    final groupId = packet.groupId;
    final ownerId = packet.ownerId;
    if (groupId == null || ownerId == null) return;
    if (packet.from != ownerId) return; // not the owner — ignore
    final group = groupById(groupId);
    if (group == null) return;
    if (group.ownerId == ownerId &&
        group.permissions == packet.permissions) {
      return; // nothing changed
    }
    await _db.update(
      'groups',
      {
        'owner_id': ownerId,
        'perm_send': packet.permissions.sendMessagesOnlyOwner ? 1 : 0,
        'perm_edit': packet.permissions.editInfoOnlyOwner ? 1 : 0,
        'perm_add': packet.permissions.addMembersOnlyOwner ? 1 : 0,
      },
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    await _reloadGroups();
  }

  /// Persists the owner's own permission change locally. The caller
  /// fans a `groupUpdate` packet out to the members afterwards.
  Future<void> updateGroupPermissions({
    required String groupId,
    required GroupPermissions permissions,
  }) async {
    await _db.update(
      'groups',
      {
        'perm_send': permissions.sendMessagesOnlyOwner ? 1 : 0,
        'perm_edit': permissions.editInfoOnlyOwner ? 1 : 0,
        'perm_add': permissions.addMembersOnlyOwner ? 1 : 0,
      },
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    await _reloadGroups();
  }

  // ─── Group photo (local-only) ─────────────────────────────

  /// Remembers the group photo at [path]. The caller copies the
  /// picked image into app storage first (see GroupInfoScreen).
  /// The photo is never sent to peers — other phones keep the
  /// default group avatar.
  Future<void> setGroupPhotoPath(String groupId, String path) async {
    await _db.update(
      'groups',
      {'photo_path': path},
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    await _reloadGroups();
  }

  /// Forgets the group photo (the caller deletes the file).
  Future<void> clearGroupPhotoPath(String groupId) async {
    await _db.update(
      'groups',
      {'photo_path': null},
      where: 'group_id = ?',
      whereArgs: [groupId],
    );
    await _reloadGroups();
  }

  // ─── Message actions: edit / delete / react ───────────────────

  Future<ChatMessage?> messageById(String id) async {
    final rows = await _db.query(
      'messages',
      where: 'id = ?',
      whereArgs: [id],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return ChatMessage.fromMap(rows.first);
  }

  /// Edits the text of a message this phone authored. The caller
  /// enforces the 5-minute window; the receiver enforces authorship.
  Future<void> updateMessageText(String id, String newText) async {
    await _db.update(
      'messages',
      {'text': newText, 'edited': 1},
      where: 'id = ?',
      whereArgs: [id],
    );
    final message = await messageById(id);
    if (message != null) {
      await _refreshSnippet(message.conversationId);
    }
    notifyListeners();
  }

  /// Deletes a message from this phone only ("Delete for me").
  Future<void> deleteMessageLocal(String id) async {
    final message = await messageById(id);
    await _db.delete('messages', where: 'id = ?', whereArgs: [id]);
    if (message != null) {
      await _refreshSnippet(message.conversationId);
    }
    notifyListeners();
  }

  /// Applies an incoming edit: only the original author may edit, and
  /// only text messages are editable.
  Future<void> applyRemoteEdit(BlePacket packet) async {
    final editId = packet.editId;
    if (editId == null || packet.text == null) return;
    final message = await messageById(editId);
    if (message == null) return;
    if (message.senderId != packet.from) return; // not the author
    if (message.kind != MessageKind.text) return;
    await _db.update(
      'messages',
      {'text': packet.text, 'edited': 1},
      where: 'id = ?',
      whereArgs: [editId],
    );
    await _refreshSnippet(message.conversationId);
    notifyListeners();
  }

  /// Applies an incoming delete-for-everyone: only the original
  /// author may delete.
  Future<void> applyRemoteDelete(BlePacket packet) async {
    final deleteId = packet.deleteId;
    if (deleteId == null) return;
    final message = await messageById(deleteId);
    if (message == null) return;
    if (message.senderId != packet.from) return; // not the author
    await _db.delete('messages', where: 'id = ?', whereArgs: [deleteId]);
    await _refreshSnippet(message.conversationId);
    notifyListeners();
  }

  /// Toggles [senderId]'s reaction on a message: same emoji again
  /// removes it, a different emoji replaces it.
  Future<void> toggleReaction(
      String messageId, String senderId, String emoji) async {
    final message = await messageById(messageId);
    if (message == null) return;
    final reactions = Map<String, String>.from(message.reactions);
    if (reactions[senderId] == emoji) {
      reactions.remove(senderId);
    } else {
      reactions[senderId] = emoji;
    }
    await _db.update(
      'messages',
      {'reactions': jsonEncode(reactions)},
      where: 'id = ?',
      whereArgs: [messageId],
    );
    notifyListeners();
  }

  /// Applies an incoming reaction.
  Future<void> applyRemoteReaction(BlePacket packet) async {
    final reactId = packet.reactId;
    final emoji = packet.reactEmoji;
    if (reactId == null || emoji == null) return;
    await toggleReaction(reactId, packet.from, emoji);
  }

  /// Recomputes a conversation/group list snippet from its latest
  /// remaining message (used after edits and deletes).
  Future<void> _refreshSnippet(String conversationId) async {
    final rows = await _db.query(
      'messages',
      where: 'conversation_id = ?',
      whereArgs: [conversationId],
      orderBy: 'ts DESC',
      limit: 1,
    );
    final snippet =
        rows.isEmpty ? null : _snippetFor(ChatMessage.fromMap(rows.first));
    final ts = rows.isEmpty
        ? 0
        : (rows.first['ts'] as num).toInt();
    if (groupById(conversationId) != null) {
      await _db.update(
        'groups',
        {'last_message': snippet, 'last_ts': ts},
        where: 'group_id = ?',
        whereArgs: [conversationId],
      );
      await _reloadGroups();
    } else {
      await _db.update(
        'conversations',
        {'last_message': snippet, 'last_ts': ts},
        where: 'peer_user_id = ?',
        whereArgs: [conversationId],
      );
      await _reloadConversations();
    }
  }

  String _snippetFor(ChatMessage m) {
    switch (m.kind) {
      case MessageKind.voice:
        return '🎤 Voice message';
      case MessageKind.file:
        return '📎 ${m.fileName ?? m.text}';
      case MessageKind.text:
        return m.text;
    }
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
      replyToId: packet.replyToId,
      replyToText: packet.replyToText,
      replyToSender: packet.replyToSender,
      forwarded: packet.forwarded,
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
      replyToId: packet.replyToId,
      replyToText: packet.replyToText,
      replyToSender: packet.replyToSender,
      forwarded: packet.forwarded,
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
    MessageKind kind = MessageKind.file,
  }) async {
    final message = ChatMessage(
      id: transferId,
      conversationId: peerUserId,
      senderId: _identity!.userId,
      text: fileName,
      ts: ts,
      direction: MessageDirection.outgoing,
      status: MessageStatus.sending,
      kind: kind,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      filePath: filePath,
    );
    await _insertMessage(message);
    await _upsertConversation(
      peerUserId: peerUserId,
      peerName: peerName,
      lastMessage: kind == MessageKind.voice
          ? '🎤 Voice message'
          : '📎 $fileName',
      ts: message.ts,
      unreadDelta: 0,
    );
  }

  /// Stores a received file (the transport already saved the bytes and
  /// hands us the local path in the synthetic `file` packet). When the
  /// packet carries a known group id, the file lands in that group
  /// conversation; otherwise it lands in the 1:1 chat with the sender.
  Future<void> saveIncomingFile(BlePacket packet) async {
    // Voice notes travel as file transfers with an audio mime type —
    // they get the voice kind so the UI shows a player bubble.
    final kind = (packet.mimeType ?? '').startsWith('audio/')
        ? MessageKind.voice
        : MessageKind.file;
    final groupId = packet.groupId;
    final isGroupFile = groupId != null && groupById(groupId) != null;
    final conversationId = isGroupFile ? groupId! : packet.from;
    final message = ChatMessage(
      id: packet.id,
      conversationId: conversationId,
      senderId: packet.from,
      text: packet.fileName ?? 'File',
      ts: packet.ts,
      direction: MessageDirection.incoming,
      status: MessageStatus.delivered,
      kind: kind,
      fileName: packet.fileName,
      fileSize: packet.fileSize,
      mimeType: packet.mimeType,
      filePath: packet.filePath,
    );
    await _insertMessage(message);
    if (isGroupFile) {
      await _updateGroupSnippet(
        groupId: groupId!,
        lastMessage: kind == MessageKind.voice
            ? '🎤 Voice message'
            : '📎 ${message.text}',
        ts: message.ts,
        unreadDelta: openConversationId == groupId ? 0 : 1,
      );
      return;
    }
    await _upsertConversation(
      peerUserId: packet.from,
      peerName: packet.name.isEmpty ? 'Campus user' : packet.name,
      lastMessage: kind == MessageKind.voice
          ? '🎤 Voice message'
          : '📎 ${message.text}',
      ts: message.ts,
      unreadDelta: openConversationId == packet.from ? 0 : 1,
    );
  }

  /// Stores a file received over a fast path (Nearby / Wi-Fi
  /// Direct). Mirrors [saveIncomingFile], but takes explicit fields
  /// instead of a BLE packet — the fast paths are out-of-band from
  /// the BLE protocol, so there is no packet to unpack. The caller
  /// (FastFileTransferService) has already saved the bytes and
  /// hands us the local path. Group files land in the group
  /// conversation when the group is known, else the 1:1 chat.
  Future<void> saveIncomingFastFile({
    required String transferId,
    required String from,
    required String senderName,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required String filePath,
    required int ts,
    String? groupId,
    MessageKind kind = MessageKind.file,
  }) async {
    // Voice notes travel as file transfers with an audio mime type —
    // they get the voice kind so the UI shows a player bubble.
    final resolvedKind =
        (kind == MessageKind.voice || mimeType.startsWith('audio/'))
            ? MessageKind.voice
            : MessageKind.file;
    final isGroupFile = groupId != null && groupById(groupId) != null;
    final conversationId = isGroupFile ? groupId! : from;
    final message = ChatMessage(
      id: transferId,
      conversationId: conversationId,
      senderId: from,
      text: fileName,
      ts: ts,
      direction: MessageDirection.incoming,
      status: MessageStatus.delivered,
      kind: resolvedKind,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      filePath: filePath,
    );
    await _insertMessage(message);
    if (isGroupFile) {
      await _updateGroupSnippet(
        groupId: groupId!,
        lastMessage: resolvedKind == MessageKind.voice
            ? '🎤 Voice message'
            : '📎 ${message.text}',
        ts: message.ts,
        unreadDelta: openConversationId == groupId ? 0 : 1,
      );
      return;
    }
    await _upsertConversation(
      peerUserId: from,
      peerName: senderName.isEmpty ? 'Campus user' : senderName,
      lastMessage: resolvedKind == MessageKind.voice
          ? '🎤 Voice message'
          : '📎 ${message.text}',
      ts: message.ts,
      unreadDelta: openConversationId == from ? 0 : 1,
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
