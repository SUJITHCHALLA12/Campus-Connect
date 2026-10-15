/// Plain data models for the chat layer. Persistence lives in
/// [AppDatabase]/[ChatRepository]; the BLE layer never touches these.
import 'dart:convert';
enum MessageDirection { outgoing, incoming }

enum MessageStatus {
  sending, // queued, no link yet
  sent, // written to the peer's GATT characteristic
  delivered, // peer acknowledged
  failed, // no link / write error
}

/// Text messages carry [text]; file messages carry the file metadata and
/// the local [filePath] (sender side: the picked file; receiver side:
/// the saved copy under the app documents folder).
enum MessageKind { text, file, voice }

class ChatMessage {
  final String id;
  final String conversationId; // peer user id
  final String senderId;
  final String text;
  final int ts; // epoch millis
  final MessageDirection direction;
  final MessageStatus status;
  final MessageKind kind;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final String? filePath;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.text,
    required this.ts,
    required this.direction,
    required this.status,
    this.kind = MessageKind.text,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.filePath,
  });

  /// Copies the message, replacing only the given fields. Used when a
  /// status flips (sent → delivered / failed) so file metadata survives.
  ChatMessage copyWith({MessageStatus? status}) => ChatMessage(
        id: id,
        conversationId: conversationId,
        senderId: senderId,
        text: text,
        ts: ts,
        direction: direction,
        status: status ?? this.status,
        kind: kind,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
        filePath: filePath,
      );

  Map<String, Object?> toMap() => {
        'id': id,
        'conversation_id': conversationId,
        'sender_id': senderId,
        'text': text,
        'ts': ts,
        'direction': direction.index,
        'status': status.index,
        'kind': kind.index,
        'file_name': fileName,
        'file_size': fileSize,
        'mime_type': mimeType,
        'file_path': filePath,
      };

  factory ChatMessage.fromMap(Map<String, Object?> m) => ChatMessage(
        id: m['id'] as String,
        conversationId: m['conversation_id'] as String,
        senderId: m['sender_id'] as String,
        text: m['text'] as String,
        ts: (m['ts'] as num).toInt(),
        direction: MessageDirection.values[(m['direction'] as num).toInt()],
        status: MessageStatus.values[(m['status'] as num).toInt()],
        kind: MessageKind.values[(m['kind'] as num?)?.toInt() ?? 0],
        fileName: m['file_name'] as String?,
        fileSize: (m['file_size'] as num?)?.toInt(),
        mimeType: m['mime_type'] as String?,
        filePath: m['file_path'] as String?,
      );
}

/// A group chat: one shared conversation across several phones.
///
/// Group messages travel as fan-out: the sender writes the same
/// `groupMsg` packet to each member over their 1:1 BLE link. [members]
/// maps every member's user id to their display name (excluding self);
/// it arrives inside `groupMsg` packets so a receiver who has never
/// seen the group can create it locally.
class Group {
  final String id;
  final String name;
  final Map<String, String> members;
  final String? lastMessage;
  final int lastTs;
  final int unread;

  Group({
    required this.id,
    required this.name,
    required this.members,
    this.lastMessage,
    required this.lastTs,
    required this.unread,
  });

  Map<String, Object?> toMap() => {
        'group_id': id,
        'name': name,
        'members': jsonEncode(members),
        'last_message': lastMessage,
        'last_ts': lastTs,
        'unread': unread,
      };

  factory Group.fromMap(Map<String, Object?> m) {
    final raw = m['members'];
    final decoded =
        raw == null ? <String, dynamic>{} : jsonDecode(raw as String);
    return Group(
      id: m['group_id'] as String,
      name: m['name'] as String,
      members: (decoded as Map)
          .map((k, v) => MapEntry(k.toString(), v.toString())),
      lastMessage: m['last_message'] as String?,
      lastTs: (m['last_ts'] as num).toInt(),
      unread: (m['unread'] as num).toInt(),
    );
  }

  /// Display names of everyone in the group, including self handled by
  /// the caller (self is not stored in [members]).
  List<String> get memberNames => members.values.toList();
}

class Conversation {  final String peerUserId;
  final String peerName;
  final String? lastMessage;
  final int lastTs;
  final int unread;

  Conversation({
    required this.peerUserId,
    required this.peerName,
    this.lastMessage,
    required this.lastTs,
    required this.unread,
  });

  factory Conversation.fromMap(Map<String, Object?> m) => Conversation(
        peerUserId: m['peer_user_id'] as String,
        peerName: m['peer_name'] as String,
        lastMessage: m['last_message'] as String?,
        lastTs: (m['last_ts'] as num).toInt(),
        unread: (m['unread'] as num).toInt(),
      );
}
