import 'dart:async';
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
import '../core/theme/chat_theme_store.dart';
import '../core/theme/chat_themes.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';
import 'forward_screen.dart';
import 'message_actions.dart';
import 'widgets/aurora_background.dart';
import 'widgets/glass_input_bar.dart';
import 'widgets/message_bubble.dart';

/// 1:1 chat with a nearby phone — glass app bar, bubbles and composer,
/// powered by the BLE transport underneath.
class ChatScreen extends StatefulWidget {
  final String peerUserId;
  final String peerName;

  const ChatScreen({
    super.key,
    required this.peerUserId,
    required this.peerName,
  });

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final _controller = TextEditingController();
  final _scroll = ScrollController();
  bool _sending = false;
  ChatMessage? _replyingTo;
  double? _distanceM;
  Timer? _distanceTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatRepository>().markOpen(widget.peerUserId);
      _refreshDistance();
    });
    // Live distance: re-read the smoothed RSSI estimate every 30 s.
    _distanceTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _refreshDistance(),
    );
  }

  @override
  void dispose() {
    _distanceTimer?.cancel();
    _controller.dispose();
    _scroll.dispose();
    context.read<ChatRepository>().clearOpen();
    super.dispose();
  }

  void _refreshDistance() {
    final d = context
        .read<BleChatService>()
        .distanceToUser(widget.peerUserId);
    if (mounted && d != _distanceM) {
      setState(() => _distanceM = d);
    }
  }

  /// Short text used when quoting a message in a reply.
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
      m.direction == MessageDirection.incoming ? widget.peerName : 'You';

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

    final packet = BlePacket.msg(
      from: identity.userId,
      name: identity.displayName,
      text: text,
      replyToId: replyingTo?.id,
      replyToText:
          replyingTo == null ? null : _quoteText(replyingTo),
      replyToSender:
          replyingTo == null ? null : _senderNameOf(replyingTo),
    );
    await repo.saveOutgoing(
      peerUserId: widget.peerUserId,
      peerName: widget.peerName,
      packet: packet,
    );
    final ok = await ble.sendTo(widget.peerUserId, packet);
    if (!ok) {
      await repo.markFailed(packet.id);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content:
                Text('Not in range — message kept, not delivered.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
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

  /// Picks an image or a file and sends it to the peer over BLE.
  /// Files are capped at 1 MB (see [FileTransferConfig]).
  ///
  /// Path-only picking: the old code passed `withData: true`, which
  /// pushes up to 1 MB of bytes through the Android binder (a
  /// TransactionTooLarge failure for larger picks) for bytes we then
  /// re-read from the path anyway. The profile-photo picker uses the
  /// same path-only pattern. Failures now surface a snackbar instead
  /// of silently doing nothing — the old `if (bytes == null) return`
  /// is why the button looked dead when a pick yielded no usable
  /// bytes/path (e.g. cloud-provider files).
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
    Uint8List bytes;
    try {
      bytes = await File(path).readAsBytes();
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
    await _sendFileBytes(
      bytes: bytes,
      fileName: picked.name,
      mimeType: mimeForFileName(picked.name),
      filePath: path,
      kind: MessageKind.file,
    );
  }

  /// Sends a recorded voice note to the peer over BLE, as a voice
  /// message (same file transfer, audio mime type).
  Future<void> _sendVoice(File file) async {
    final bytes = await file.readAsBytes();
    await _sendFileBytes(
      bytes: bytes,
      fileName: 'voice.m4a',
      mimeType: 'audio/m4a',
      filePath: file.path,
      kind: MessageKind.voice,
    );
  }

  /// Shared send path for picked files and voice notes.
  Future<void> _sendFileBytes({
    required Uint8List bytes,
    required String fileName,
    required String mimeType,
    required String filePath,
    required MessageKind kind,
  }) async {
    if (bytes.length > FileTransferConfig.maxFileSize) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File too big — 1 MB max over Bluetooth.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }

    final identity = context.read<IdentityStore>();
    final ble = context.read<BleChatService>();
    final repo = context.read<ChatRepository>();
    final transferId = const Uuid().v4();

    await repo.saveOutgoingFile(
      peerUserId: widget.peerUserId,
      peerName: widget.peerName,
      transferId: transferId,
      fileName: fileName,
      fileSize: bytes.length,
      mimeType: mimeType,
      filePath: filePath,
      ts: DateTime.now().millisecondsSinceEpoch,
      kind: kind,
    );
    try {
      await FileTransferService.sendFile(
        send: (packet) => ble.sendTo(widget.peerUserId, packet),
        from: identity.userId,
        name: identity.displayName,
        transferId: transferId,
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        onProgress: (p) => repo.updateFileProgress(transferId, p),
      );
      await repo.markDelivered(transferId);
    } catch (_) {
      await repo.markFailed(transferId);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File not delivered — peer may be out of range.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
    if (mounted) _scrollToBottom();
  }

  // ─── Resend ─────────────────────────────────────────────

  /// Resends a failed outgoing message (tap on its bubble). The
  /// failed row is removed first and a fresh message is sent with the
  /// same text / file / reply / forwarded fields, so the peer can
  /// never receive a duplicate of the same id.
  Future<void> _resend(ChatMessage message) async {
    final repo = context.read<ChatRepository>();
    final text = message.text;
    final kind = message.kind;
    final fileName = message.fileName;
    final mimeType = message.mimeType;
    final filePath = message.filePath;
    final replyToId = message.replyToId;
    final replyToText = message.replyToText;
    final replyToSender = message.replyToSender;
    final forwarded = message.forwarded;
    await repo.deleteMessageLocal(message.id);

    if (kind == MessageKind.text) {
      final identity = context.read<IdentityStore>();
      final ble = context.read<BleChatService>();
      final packet = BlePacket.msg(
        from: identity.userId,
        name: identity.displayName,
        text: text,
        replyToId: replyToId,
        replyToText: replyToText,
        replyToSender: replyToSender,
        forwarded: forwarded,
      );
      await repo.saveOutgoing(
        peerUserId: widget.peerUserId,
        peerName: widget.peerName,
        packet: packet,
      );
      final ok = await ble.sendTo(widget.peerUserId, packet);
      if (!ok) {
        await repo.markFailed(packet.id);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Still out of range — tap the message to retry.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      }
      if (mounted) _scrollToBottom();
      return;
    }

    // File / voice: re-send the same local file.
    if (filePath == null || filePath.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Original file not found — cannot resend.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    try {
      final bytes = await File(filePath).readAsBytes();
      await _sendFileBytes(
        bytes: bytes,
        fileName: fileName ?? text,
        mimeType: mimeType ?? 'application/octet-stream',
        filePath: filePath,
        kind: kind,
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Original file not found — cannot resend.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    }
  }

  // ─── Message actions ──────────────────────────────────────

  void _showActions(ChatMessage message, Offset anchor) {
    final isOwn = message.direction == MessageDirection.outgoing;
    // Edit window: own text message, within 5 minutes of sending.
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
                final ble = context.read<BleChatService>();
                final packet = BlePacket.deleteMsg(
                  from: identity.userId,
                  name: identity.displayName,
                  deleteId: message.id,
                );
                await ble.sendTo(widget.peerUserId, packet);
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
    final ble = context.read<BleChatService>();
    final repo = context.read<ChatRepository>();
    await repo.toggleReaction(message.id, identity.userId, emoji);
    final packet = BlePacket.react(
      from: identity.userId,
      name: identity.displayName,
      reactId: message.id,
      emoji: emoji,
    );
    await ble.sendTo(widget.peerUserId, packet);
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
    final ble = context.read<BleChatService>();
    final repo = context.read<ChatRepository>();
    await repo.updateMessageText(message.id, newText);
    final packet = BlePacket.edit(
      from: identity.userId,
      name: identity.displayName,
      editId: message.id,
      text: newText,
    );
    await ble.sendTo(widget.peerUserId, packet);
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

    final identity = context.read<IdentityStore>();
    final ble = context.read<BleChatService>();
    final repo = context.read<ChatRepository>();

    if (message.kind == MessageKind.text) {
      if (target.group != null) {
        // Forward into a group: fan out a group message.
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
      return;
    }

    // Files and voice notes forward to 1:1 chats only.
    if (target.group != null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
                'Forwarding files to groups isn\'t supported yet.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    final path = message.filePath;
    if (path == null || path.isEmpty) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('File is not available to forward.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    final bytes = await File(path).readAsBytes();
    final peerUserId = target.peerUserId!;
    final transferId = const Uuid().v4();
    await repo.saveOutgoingFile(
      peerUserId: peerUserId,
      peerName: target.peerName ?? 'Chat',
      transferId: transferId,
      fileName: message.fileName ?? message.text,
      fileSize: bytes.length,
      mimeType: message.mimeType ?? 'application/octet-stream',
      filePath: path,
      ts: DateTime.now().millisecondsSinceEpoch,
      kind: message.kind,
    );
    try {
      await FileTransferService.sendFile(
        send: (packet) => ble.sendTo(peerUserId, packet),
        from: identity.userId,
        name: identity.displayName,
        transferId: transferId,
        fileName: message.fileName ?? message.text,
        bytes: bytes,
        mimeType: message.mimeType ?? 'application/octet-stream',
        onProgress: (p) => repo.updateFileProgress(transferId, p),
      );
      await repo.markDelivered(transferId);
    } catch (_) {
      await repo.markFailed(transferId);
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

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ChatRepository>();
    final ble = context.watch<BleChatService>();
    final theme = context
        .watch<ChatThemeStore>()
        .themeFor(widget.peerUserId);
    final connected = ble.linkForUser(widget.peerUserId) != null;

    return Scaffold(
      body: Stack(
        children: [
          const AuroraBackground(),
          // Per-chat theme: a tint wash over the shared background.
          Container(color: theme.backgroundTint),
          SafeArea(
            child: Column(
              children: [
                _appBar(connected, theme),
                Expanded(
                  child: FutureBuilder<List<ChatMessage>>(
                    future:
                        repo.messagesFor(widget.peerUserId),
                    builder: (context, snapshot) {
                      final messages =
                          snapshot.data ?? const <ChatMessage>[];
                      WidgetsBinding.instance
                          .addPostFrameCallback(
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
                                    gradient:
                                        CcColors.aquaGradient,
                                    boxShadow:
                                        CcColors.cyanGlow,
                                  ),
                                  child: Center(
                                    child: Text(
                                      widget.peerName.isEmpty
                                          ? '?'
                                          : widget.peerName[0]
                                              .toUpperCase(),
                                      style: GoogleFonts.nunito(
                                        fontSize: 30,
                                        fontWeight:
                                            FontWeight.w800,
                                        color: Colors.white,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 16),
                                Text(
                                  'Say hi to ${widget.peerName}',
                                  style: GoogleFonts.nunito(
                                    fontSize: 17,
                                    fontWeight: FontWeight.w700,
                                    color:
                                        CcColors.textPrimary,
                                  ),
                                ),
                                const SizedBox(height: 6),
                                Text(
                                  'Messages travel straight to their phone over Bluetooth. No internet involved.',
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
                        padding: const EdgeInsets.fromLTRB(
                            12, 8, 12, 12),
                        itemCount: messages.length,
                        itemBuilder: (_, i) {
                          final m = messages[i];
                          return MessageBubble(
                            message: m,
                            progress: repo.fileProgress[m.id],
                            outgoingGradient: theme.bubbleGradient,
                            outgoingBorderColor: theme.accent,
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
                GlassInputBar(
                  controller: _controller,
                  onSend: _send,
                  isSending: _sending,
                  onAttachImage: () => _pickAndSendFile(FileType.image),
                  onAttachFile: () => _pickAndSendFile(FileType.any),
                  onVoiceMessage: (file) => _sendVoice(file),
                ),
              ],
            ),
          ),
        ],
      ),
    );
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

  /// Manual reconnect from the "Out of range" subtitle.
  Future<void> _reconnect() async {
    final ok = await context
        .read<BleChatService>()
        .reconnectTo(widget.peerUserId);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ok
              ? 'Reconnected to ${widget.peerName}.'
              : 'Still out of range — move closer and try again.'),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  /// Per-chat theme picker: swatches for the six themes. The choice
  /// is stored per peer and changes only this chat's background tint
  /// and own-bubble gradient.
  void _showThemePicker(ChatTheme current) {
    final store = context.read<ChatThemeStore>();
    showModalBottomSheet(
      context: context,
      backgroundColor: CcColors.deepSea,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(height: 16),
              Text(
                'Chat theme',
                style: GoogleFonts.nunito(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: CcColors.textPrimary,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                'Only this chat changes.',
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  color: CcColors.textMuted,
                ),
              ),
              const SizedBox(height: 20),
              Wrap(
                spacing: 14,
                runSpacing: 14,
                children: chatThemes.map((t) {
                  final selected = t.id == current.id;
                  return GestureDetector(
                    onTap: () async {
                      await store.setTheme(widget.peerUserId, t.id);
                      if (sheetContext.mounted) {
                        Navigator.of(sheetContext).pop();
                      }
                    },
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Container(
                          width: 56,
                          height: 56,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            gradient: t.bubbleGradient,
                            border: Border.all(
                              color: selected
                                  ? Colors.white
                                  : Colors.white.withValues(alpha: 0.2),
                              width: selected ? 2.5 : 1,
                            ),
                          ),
                          child: selected
                              ? const Icon(Icons.check_rounded,
                                  color: Colors.white)
                              : null,
                        ),
                        const SizedBox(height: 6),
                        Text(
                          t.name,
                          style: GoogleFonts.dmSans(
                            fontSize: 12,
                            color: selected
                                ? CcColors.textPrimary
                                : CcColors.textMuted,
                          ),
                        ),
                      ],
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _appBar(bool connected, ChatTheme theme) {
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
                widget.peerName.isEmpty
                    ? '?'
                    : widget.peerName[0].toUpperCase(),
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
                  widget.peerName,
                  style: GoogleFonts.nunito(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: CcColors.textPrimary,
                  ),
                ),
                GestureDetector(
                  onTap: connected ? null : _reconnect,
                  child: Text(
                    connected
                        ? _distanceM != null
                            ? 'Nearby · ${_distanceM!.toStringAsFixed(3)} m away'
                            : 'Nearby · connected'
                        : 'Out of range · Tap to reconnect',
                    style: GoogleFonts.dmSans(
                      fontSize: 12,
                      color: connected
                          ? CcColors.onlineGreen
                          : CcColors.textMuted,
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (connected)
            Container(
              width: 10,
              height: 10,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: CcColors.onlineGreen,
              ),
            ),
          IconButton(
            onPressed: () => _showThemePicker(theme),
            icon: const Icon(Icons.palette_outlined,
                color: CcColors.textPrimary),
            tooltip: 'Chat theme',
          ),
        ],
      ),
    );
  }
}
