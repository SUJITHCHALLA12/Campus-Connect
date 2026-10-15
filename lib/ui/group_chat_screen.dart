import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';
import 'package:uuid/uuid.dart';

import '../ble/ble_protocol.dart';
import '../ble/ble_transport.dart';
import '../ble/file_transfer.dart';
import '../core/constants.dart';
import '../core/identity.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';
import '../transfer/fast_file_transfer.dart';
import 'forward_screen.dart';
import 'group_info_screen.dart';
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
    final identity = context.read<IdentityStore>();
    final group = _currentGroup();
    if (_isRestricted(group, identity.userId)) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Only the owner can send messages in this group.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    setState(() => _sending = true);
    _controller.clear();
    final replyingTo = _replyingTo;
    setState(() => _replyingTo = null);

    final ble = context.read<BleChatService>();
    final repo = context.read<ChatRepository>();

    // The packet carries the full roster (including self) so receivers
    // who have never seen this group can create it with all names.
    // Owner + settings ride along so they learn the correct ones.
    final members = Map<String, String>.from(group.members)
      ..[identity.userId] = identity.displayName;
    final packet = BlePacket.groupMsg(
      from: identity.userId,
      name: identity.displayName,
      text: text,
      groupId: group.id,
      groupName: group.name,
      members: members,
      replyToId: replyingTo?.id,
      replyToText:
          replyingTo == null ? null : _quoteText(replyingTo),
      replyToSender:
          replyingTo == null ? null : _senderNameOf(replyingTo),
      ownerId: group.ownerId,
      permissions: group.permissions,
    );
    await repo.saveOutgoingGroupMsg(group: group, packet: packet);

    var delivered = 0;
    for (final memberId in group.members.keys) {
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
    for (final memberId in _currentGroup().members.keys) {
      if (await ble.sendTo(memberId, packet)) delivered++;
    }
    return delivered;
  }

  /// Fresh copy of this group from the repository (the widget's copy
  /// goes stale when settings/photo change elsewhere).
  Group _currentGroup() =>
      context.read<ChatRepository>().groupById(widget.group.id) ??
      widget.group;

  /// True when this phone may not send in [group]: owner-only
  /// messaging is on and this phone is not the owner. Groups with no
  /// known owner (pre-v0.9) are never restricted.
  bool _isRestricted(Group group, String myUserId) =>
      group.permissions.sendMessagesOnlyOwner &&
      group.ownerId != null &&
      group.ownerId != myUserId;

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
          ? _currentGroup().members[m.senderId] ?? 'Someone'
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
    final group = _currentGroup();
    final members = Map<String, String>.from(group.members)
      ..[identity.userId] = identity.displayName;
    final packet = BlePacket.groupMsg(
      from: identity.userId,
      name: identity.displayName,
      text: text,
      groupId: group.id,
      groupName: group.name,
      members: members,
      replyToId: replyToId,
      replyToText: replyToText,
      replyToSender: replyToSender,
      forwarded: forwarded,
      ownerId: group.ownerId,
      permissions: group.permissions,
    );
    await repo.saveOutgoingGroupMsg(group: group, packet: packet);
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

  void _showActions(ChatMessage message, Offset anchor) {
    final isOwn = message.direction == MessageDirection.outgoing;
    final canEdit = isOwn &&
        message.kind == MessageKind.text &&
        message.status != MessageStatus.failed &&
        DateTime.now().millisecondsSinceEpoch - message.ts <
            5 * 60 * 1000;
    showMessageActionsMenu(
      context,
      anchor: anchor,
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
        ownerId: group.ownerId,
        permissions: group.permissions,
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
    final identity = context.watch<IdentityStore>();
    final group =
        repo.groupById(widget.group.id) ?? widget.group;
    final memberCount = group.members.length + 1;
    final restricted = _isRestricted(group, identity.userId);

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
                            progress: repo.fileProgress[m.id],
                            onLongPressStart: (pos) =>
                                _showActions(m, pos),
                            onTap: m.direction ==
                                        MessageDirection.outgoing &&
                                    m.status == MessageStatus.failed
                                ? () => _resend(m)
                                : null,
                            onSwipeReply: () =>
                                setState(() => _replyingTo = m),
                            onReactionTap: (pos) =>
                                _showActions(m, pos),
                          );
                        },
                      );
                    },
                  ),
                ),
                if (_replyingTo != null) _replyPreviewBar(),
                if (restricted) _restrictedNotice(),
                GlassInputBar(
                  controller: _controller,
                  onSend: _send,
                  isSending: _sending,
                  enabled: !restricted,
                  onAttachImage: () => _pickAndSendFile(FileType.image),
                  onAttachFile: () => _pickAndSendFile(FileType.any),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Notice shown above the composer when owner-only messaging is
  /// on and this phone is not the owner.
  Widget _restrictedNotice() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
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
          const Icon(Icons.lock_outline_rounded,
              color: CcColors.textMuted, size: 18),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Only the owner can send messages in this group.',
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: CcColors.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ─── File sending ───────────────────────────────────────

  /// Picks an image or a file and fans it out to every member.
  /// Same path-only picker fix as the 1:1 chat (see ChatScreen):
  /// no `withData` (binder risk), failures surface a snackbar.
  Future<void> _pickAndSendFile(FileType type) async {
    FilePickerResult? result;
    try {
      result = await FilePicker.platform.pickFiles(
        type: type,
        allowMultiple: false,
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not open the file picker: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;

    final path = picked.path;
    if (path == null || path.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Could not read that file — try one stored on this phone.'),
            duration: Duration(seconds: 3),
          ),
        );
      }
      return;
    }
    // The file is stat'ed + read inside _sendFileBytes (bytes are
    // only loaded for the 1 MB BLE fallback).
    await _sendFileBytes(
      filePath: path,
      fileName: picked.name,
      mimeType: mimeForFileName(picked.name),
    );
  }

  /// Fans one file transfer out to every member. One outgoing file
  /// message is stored in the group conversation; members who are out
  /// of range simply miss the file (same as group text).
  ///
  /// Each member gets the fast path (Nearby → Wi-Fi Direct → BLE),
  /// same as 1:1 files — see [FastFileTransferService].
  Future<void> _sendFileBytes({
    required String filePath,
    required String fileName,
    required String mimeType,
  }) async {
    final file = File(filePath);
    int fileSize;
    try {
      fileSize = await file.length();
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Could not read that file.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    if (fileSize > FastTransferConfig.fastMaxFileSize) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File too big — 100 MB max.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    // Bytes are only needed for the BLE fallback (1 MB cap).
    Uint8List? bytes;
    if (fileSize <= FileTransferConfig.maxFileSize) {
      try {
        bytes = await file.readAsBytes();
      } catch (_) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Could not read that file.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
        return;
      }
    }

    final repo = context.read<ChatRepository>();
    final fast = context.read<FastFileTransferService>();
    final group = _currentGroup();
    final transferId = const Uuid().v4();

    await repo.saveOutgoingGroupFile(
      group: group,
      transferId: transferId,
      fileName: fileName,
      fileSize: fileSize,
      mimeType: mimeType,
      filePath: filePath,
      ts: DateTime.now().millisecondsSinceEpoch,
    );
    var delivered = 0;
    for (final memberId in group.members.keys) {
      try {
        final ok = await fast.sendFile(
          peerUserId: memberId,
          filePath: filePath,
          fileName: fileName,
          mimeType: mimeType,
          transferId: transferId,
          fileSize: fileSize,
          bytes: bytes,
          groupId: group.id,
          onProgress: (p) => repo.updateFileProgress(transferId, p),
        );
        if (ok) delivered++;
      } catch (_) {
        // This member missed the file; the others still get it.
      }
    }
    if (delivered == 0) {
      await repo.markFailed(transferId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File not delivered — no members in range.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } else {
      await repo.markDelivered(transferId);
    }
    if (mounted) _scrollToBottom();
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
          Expanded(
            child: GestureDetector(
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => GroupInfoScreen(group: group),
                ),
              ),
              child: Row(
                children: [
                  _groupAvatar(group),
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
            ),
          ),
        ],
      ),
    );
  }

  /// Group avatar: the group photo when one is set, otherwise the
  /// initial. The photo is local-only (see GroupInfoScreen).
  Widget _groupAvatar(Group group) {
    final photoPath = group.photoPath;
    if (photoPath != null && File(photoPath).existsSync()) {
      return Container(
        width: 42,
        height: 42,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          image: DecorationImage(
            image: FileImage(File(photoPath)),
            fit: BoxFit.cover,
          ),
        ),
      );
    }
    return Container(
      width: 42,
      height: 42,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: CcColors.aquaGradient,
      ),
      child: Center(
        child: Text(
          group.name.isEmpty ? '?' : group.name[0].toUpperCase(),
          style: GoogleFonts.nunito(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}
