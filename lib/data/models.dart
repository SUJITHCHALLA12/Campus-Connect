/// Plain data models for the chat layer. Persistence lives in
/// [AppDatabase]/[ChatRepository]; the BLE layer never touches these.
enum MessageDirection { outgoing, incoming }

enum MessageStatus {
  sending, // queued, no link yet
  sent, // written to the peer's GATT characteristic
  delivered, // peer acknowledged
  failed, // no link / write error
}

class ChatMessage {
  final String id;
  final String conversationId; // peer user id
  final String senderId;
  final String text;
  final int ts; // epoch millis
  final MessageDirection direction;
  final MessageStatus status;

  ChatMessage({
    required this.id,
    required this.conversationId,
    required this.senderId,
    required this.text,
    required this.ts,
    required this.direction,
    required this.status,
  });

  Map<String, Object?> toMap() => {
        'id': id,
        'conversation_id': conversationId,
        'sender_id': senderId,
        'text': text,
        'ts': ts,
        'direction': direction.index,
        'status': status.index,
      };

  factory ChatMessage.fromMap(Map<String, Object?> m) => ChatMessage(
        id: m['id'] as String,
        conversationId: m['conversation_id'] as String,
        senderId: m['sender_id'] as String,
        text: m['text'] as String,
        ts: (m['ts'] as num).toInt(),
        direction: MessageDirection.values[(m['direction'] as num).toInt()],
        status: MessageStatus.values[(m['status'] as num).toInt()],
      );
}

class Conversation {
  final String peerUserId;
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
