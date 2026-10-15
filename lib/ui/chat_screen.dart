import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      context.read<ChatRepository>().markOpen(widget.peerUserId);
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

    final identity = context.read<IdentityStore>();
    final ble = context.read<BleChatService>();
    final repo = context.read<ChatRepository>();

    final packet = BlePacket.msg(
      from: identity.userId,
      name: identity.displayName,
      text: text,
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
  Future<void> _pickAndSendFile(FileType type) async {
    final result = await FilePicker.platform.pickFiles(
      type: type,
      allowMultiple: false,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final picked = result.files.single;

    Uint8List? bytes = picked.bytes;
    bytes ??= picked.path != null
        ? await File(picked.path!).readAsBytes()
        : null;
    if (bytes == null) return;
    await _sendFileBytes(
      bytes: bytes,
      fileName: picked.name,
      mimeType: mimeForFileName(picked.name),
      filePath: picked.path ?? '',
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

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ChatRepository>();
    final ble = context.watch<BleChatService>();
    final connected = ble.linkForUser(widget.peerUserId) != null;

    return Scaffold(
      body: Stack(
        children: [
          const AuroraBackground(),
          SafeArea(
            child: Column(
              children: [
                _appBar(connected),
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
                        itemBuilder: (_, i) => MessageBubble(
                              message: messages[i],
                              progress:
                                  repo.fileProgress[messages[i].id],
                            ),
                      );
                    },
                  ),
                ),
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

  Widget _appBar(bool connected) {
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
                Text(
                  connected
                      ? 'Nearby · connected'
                      : 'Out of range',
                  style: GoogleFonts.dmSans(
                    fontSize: 12,
                    color: connected
                        ? CcColors.onlineGreen
                        : CcColors.textMuted,
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
        ],
      ),
    );
  }
}
