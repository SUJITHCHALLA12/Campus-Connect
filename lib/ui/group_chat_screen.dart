import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../ble/ble_protocol.dart';
import '../ble/ble_transport.dart';
import '../core/constants.dart';
import '../core/identity.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';
import 'forward_screen.dart';
import 'message_actions.dart';
import 'widgets/aurora_background.dart';
import 'widgets/glass_input_bar.dart';
import 'widgets/message_bubble.dart';

/// Group chat screen: same look as 1:1 chat, but messages fan out to
/// every member over their 1:1 BLE link, and incoming messages show
/// who sent them.
class GroupChatScreen extends StatefulWidget {
  final Group group;

  const GroupChatScreen({super.key, required this.group});

  @override
  State<GroupChatScreen> createState() => _GroupChatScreenState();
}

class _GroupChatScreenState extends State<GroupChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  ChatMessage? _replyingTo;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatRepository>().markGroupOpen(widget.group.id);
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    _scroll.dispose();
    context.read<ChatRepository>().clearOpen();
    super.dispose();
  }

  Future<void> _send() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _sending) return;
    setState(() => _sending = true);
    _controller.clear();
    final replyingTo = _replyingTo;
    setState(() => _replyingTo = null);

    final identity = context.read<IdentityStore>();
    final ble = context.read<BleChatService>();
    final repo = context.read<ChatRepository>();

    // The packet carries the full roster (including self) so receivers
    // who have never seen this group can create it with all names.
    final members = Map<String, String>.from(widget.group.members)
      ..[identity.userId] = identity.displayName;
    final packet = BlePacket.groupMsg(
      from: identity.userId,
      name: identity.displayName,
      text: text,
      groupId: widget.group.id,
      groupName: widget.group.name,
      members: members,
      replyToId: replyingTo?.id,
      replyToText:
          replyingTo == null ? null : _quoteText(replyingTo),
      replyToSender:
          replyingTo == null ? null : _senderNameOf(replyingTo),
    );
    await repo.saveOutgoingGroupMsg(group: widget.group, packet: packet);

    var delivered = 0;
    for (final memberId in widget.group.members.keys) {
      if (await ble.sendTo(memberId, packet)) delivered++;
    }
    if (delivered == 0) {
      await repo.markFailed(packet.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('No members in range — message kept, not delivered.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      await repo.markDelivered(packet.id);
    }
    if (mounted) {
      setState(() => _sending = false);
      _scrollToBottom();
    }
  }

  void _scrollToBottom() {
    if (!_scroll.hasClients) return;
    _scroll.animateTo(
      _scroll.position.maxScrollExtent,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
  }

  /// Sends one packet to every member over their 1:1 link.
  Future<int> _fanOut(BlePacket packet) async {
    final ble = context.read<BleChatService>();
    var delivered = 0;
    for (final memberId in widget.group.members.keys) {
      if (await ble.sendTo(memberId, packet)) delivered++;
    }
    return delivered;
  }

  String _quoteText(ChatMessage m) {
    switch (m.kind) {
      case MessageKind.voice:
        return '🎤 Voice message';
      case MessageKind.file:
        return m.fileName ?? m.text;
      case MessageKind.text:
        return m.text;
    }
  }

  String _senderNameOf(ChatMessage m) =>
      m.direction == MessageDirection.incoming
          ? widget.group.members[m.senderId] ?? 'Someone'
          : 'You';

  // ─── Resend ─────────────────────────────────────────────

  /// Resends a failed outgoing group message (tap on its bubble).
  /// The failed row is removed first and a fresh message is fanned
  /// out, so members can never receive a duplicate of the same id.
  Future<void> _resend(ChatMessage message) async {
    final repo = context.read<ChatRepository>();
    final text = message.text;
    final replyToId = message.replyToId;
    final replyToText = message.replyToText;
    final replyToSender = message.replyToSender;
    final forwarded = message.forwarded;
    await repo.deleteMessageLocal(message.id);

    final identity = context.read<IdentityStore>();
    final members = Map<String, String>.from(widget.group.members)
      ..[identity.userId] = identity.displayName;
    final packet = BlePacket.groupMsg(
      from: identity.userId,
      name: identity.displayName,
      text: text,
      groupId: widget.group.id,
      groupName: widget.group.name,
      members: members,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSender: replyToSender,
      forwarded: forwarded,
    );
    await repo.saveOutgoingGroupMsg(group: widget.group, packet: packet);
    final delivered = await _fanOut(packet);
    if (delivered == 0) {
      await repo.markFailed(packet.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Still out of range — tap the message to retry.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      await repo.markDelivered(packet.id);
    }
    if (mounted) _scrollToBottom();
  }

  // ─── Message actions ──────────────────────────────────────

  void _showActions(ChatMessage message) {
    final isOwn = message.direction == MessageDirection.outgoing;
    final canEdit = isOwn &&
        message.kind == MessageKind.text &&
        message.status != MessageStatus.failed &&
        DateTime.now().millisecondsSinceEpoch - message.ts <
            5 * 60 * 1000;
    showMessageActionsSheet(
      context,
      message: message,
      isOwn: isOwn,
      canEdit: canEdit,
      callbacks: MessageActionCallbacks(
        onReply: () => setState(() => _replyingTo = message),
        onReact: (emoji) => _react(message, emoji),
        onEdit: canEdit ? () => _editMessage(message) : null,
        onCopy: message.kind == MessageKind.text
            ? () async {
                await Clipboard.setData(
                    ClipboardData(text: message.text));
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(
                      content: Text('Copied'),
                      duration: Duration(seconds: 1),
                    ),
                  );
                }
              }
            : null,
        onForward: () => _forwardMessage(message),
        onInfo: () => _showInfo(message),
        onDeleteForMe: () =>
            context.read<ChatRepository>().deleteMessageLocal(message.id),
        onDeleteForEveryone: isOwn
            ? () async {
                final identity = context.read<IdentityStore>();
                final packet = BlePacket.deleteMsg(
                  from: identity.userId,
                  name: identity.displayName,
                  deleteId: message.id,
                  groupId: widget.group.id,
                );
                await _fanOut(packet);
                await context
                    .read<ChatRepository>()
                    .deleteMessageLocal(message.id);
              }
            : null,
      ),
    );
  }

  Future<void> _react(ChatMessage message, String emoji) async {
    final identity = context.read<IdentityStore>();
    final repo = context.read<ChatRepository>();
    await repo.toggleReaction(message.id, identity.userId, emoji);
    final packet = BlePacket.react(
      from: identity.userId,
      name: identity.displayName,
      reactId: message.id,
      emoji: emoji,
      groupId: widget.group.id,
    );
    await _fanOut(packet);
  }

  Future<void> _editMessage(ChatMessage message) async {
    final controller = TextEditingController(text: message.text);
    final newText = await showDialog<String>(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CcColors.deepSea,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Edit message',
            style: GoogleFonts.nunito(
                fontWeight: FontWeight.w700,
                color: CcColors.textPrimary)),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 4,
          style: GoogleFonts.dmSans(color: CcColors.textPrimary),
          decoration: const InputDecoration(hintText: 'Message'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.of(context).pop(controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    if (newText == null || newText.isEmpty || newText == message.text) {
      return;
    }
    final identity = context.read<IdentityStore>();
    final repo = context.read<ChatRepository>();
    await repo.updateMessageText(message.id, newText);
    final packet = BlePacket.edit(
      from: identity.userId,
      name: identity.displayName,
      editId: message.id,
      text: newText,
      groupId: widget.group.id,
    );
    await _fanOut(packet);
  }

  void _showInfo(ChatMessage message) {
    final sent = DateTime.fromMillisecondsSinceEpoch(message.ts);
    final sentLabel =
        '${sent.hour % 12 == 0 ? 12 : sent.hour % 12}:${sent.minute.toString().padLeft(2, '0')} ${sent.hour < 12 ? 'AM' : 'PM'}';
    final statusLabel = switch (message.status) {
      MessageStatus.delivered => 'Delivered',
      MessageStatus.failed => 'Failed',
      MessageStatus.sending => 'Sending…',
      MessageStatus.sent => 'Sent',
    };
    final typeLabel = switch (message.kind) {
      MessageKind.text => 'Text',
      MessageKind.file => 'File',
      MessageKind.voice => 'Voice',
    };
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CcColors.deepSea,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Message info',
            style: GoogleFonts.nunito(
                fontWeight: FontWeight.w700,
                color: CcColors.textPrimary)),
        content: Text(
          'Type: $typeLabel\nSent: $sentLabel\nStatus: $statusLabel\n'
          '${message.edited ? 'Edited: yes' : ''}',
          style: GoogleFonts.dmSans(
              color: CcColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _forwardMessage(ChatMessage message) async {
    final target = await Navigator.of(context).push<ForwardTarget>(
      MaterialPageRoute(builder: (_) => const ForwardScreen()),
    );
    if (target == null || !mounted) return;
    if (message.kind != MessageKind.text) {
      // Files/voice forward to 1:1 chats only (group file transfer
      // is not built yet) — and this screen has no file sender.
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Forwarding files from groups isn\'t supported yet.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final identity = context.read<IdentityStore>();
    final ble = context.read<BleChatService>();
    final repo = context.read<ChatRepository>();
    if (target.group != null) {
      final group = target.group!;
      final members = Map<String, String>.from(group.members)
        ..[identity.userId] = identity.displayName;
      final packet = BlePacket.groupMsg(
        from: identity.userId,
        name: identity.displayName,
        text: message.text,
        groupId: group.id,
        groupName: group.name,
        members: members,
        forwarded: true,
      );
      await repo.saveOutgoingGroupMsg(group: group, packet: packet);
      for (final memberId in group.members.keys) {
        await ble.sendTo(memberId, packet);
      }
      await repo.markDelivered(packet.id);
    } else {
      final packet = BlePacket.msg(
        from: identity.userId,
        name: identity.displayName,
        text: message.text,
        forwarded: true,
      );
      await repo.saveOutgoing(
        peerUserId: target.peerUserId!,
        peerName: target.peerName ?? 'Chat',
        packet: packet,
      );
      await ble.sendTo(target.peerUserId!, packet);
    }
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Forwarded to ${target.displayName}'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Widget _replyPreviewBar() {
    final replyingTo = _replyingTo;
    if (replyingTo == null) return const SizedBox.shrink();
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 10, 8, 10),
      decoration: BoxDecoration(
        color: CcColors.abyss.withValues(alpha: 0.7),
        border: Border(
          top: BorderSide(
            color: CcColors.glassBorder.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 34,
            decoration: BoxDecoration(
              color: CcColors.aquaCore,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Replying to ${_senderNameOf(replyingTo)}',
                  style: GoogleFonts.nunito(
                    fontSize: 13,
                    fontWeight: FontWeight.w800,
                    color: CcColors.aquaCore,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  _quoteText(replyingTo),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: GoogleFonts.dmSans(
                    fontSize: 13,
                    color: CcColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
          IconButton(
            onPressed: () => setState(() => _replyingTo = null),
            icon: const Icon(
              Icons.close_rounded,
              color: CcColors.textMuted,
              size: 20,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ChatRepository>();
    final group =
        repo.groupById(widget.group.id) ?? widget.group;
    final memberCount = group.members.length + 1;

    return Scaffold(
      body: Stack(
        children: [
          const AuroraBackground(),
          SafeArea(
            child: Column(
              children: [
                _appBar(group, memberCount),
                Expanded(
                  child: FutureBuilder<List<ChatMessage>>(
                    future: repo.messagesFor(group.id),
                    builder: (context, snapshot) {
                      final messages =
                          snapshot.data ?? const <ChatMessage>[];
                      WidgetsBinding.instance.addPostFrameCallback(
                          (_) => _scrollToBottom());
                      if (messages.isEmpty) {
                        return Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Container(
                                  width: 72,
                                  height: 72,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: CcColors.aquaGradient,
                                    boxShadow: CcColors.cyanGlow,
                                  ),
                                  child: const Icon(
                                    Icons.group_rounded,
                                    size: 34,
                                    color: Colors.white,
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'Say hi to ${group.name}',
                                  style: GoogleFonts.nunito(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color: CcColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Messages go to all $memberCount members over Bluetooth. Anyone out of range misses this one.',
                                  textAlign: TextAlign.center,
                                  style: GoogleFonts.dmSans(
                                    fontSize: 13,
                                    color: CcColors.textMuted,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        );
                      }
                      return ListView.builder(
                        controller: _scroll,
                        padding:
                            const EdgeInsets.fromLTRB(12, 8, 12, 12),
                        itemCount: messages.length,
                        itemBuilder: (_, i) {
                          final m = messages[i];
                          final senderName =
                              m.direction == MessageDirection.incoming
                                  ? group.members[m.senderId] ?? 'Someone'
                                  : null;
                          return MessageBubble(
                            message: m,
                            senderName: senderName,
                            onLongPress: () => _showActions(m),
                            onTap: m.direction ==
                                        MessageDirection.outgoing &&
                                    m.status == MessageStatus.failed
                                ? () => _resend(m)
                                : null,
                            onSwipeReply: () =>
                                setState(() => _replyingTo = m),
                            onReactionTap: () => _showActions(m),
                          );
                        },
                      );
                    },
                  ),
                ),
                if (_replyingTo != null) _replyPreviewBar(),
                GlassInputBar(
                  controller: _controller,
                  onSend: _send,
                  isSending: _sending,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _appBar(Group group, int memberCount) {
    return Container(
      padding: const EdgeInsets.fromLTRB(4, 8, 12, 8),
      decoration: BoxDecoration(
        color: CcColors.abyss.withValues(alpha: 0.7),
        border: Border(
          bottom: BorderSide(
            color: CcColors.glassBorder.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: Row(
        children: [
          IconButton(
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.arrow_back_rounded,
                color: CcColors.textPrimary),
          ),
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: CcColors.aquaGradient,
            ),
            child: Center(
              child: Text(
                group.name.isEmpty
                    ? '?'
                    : group.name[0].toUpperCase(),
                style: GoogleFonts.nunito(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                ),
              ),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.name,
                  style: GoogleFonts.nunito(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: CcColors.textPrimary,
                  ),
                ),
                Text(
                  '$memberCount members',
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    color: CcColors.textMuted,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
