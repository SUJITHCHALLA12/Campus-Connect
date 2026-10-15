import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../ble/file_transfer.dart';
import '../../core/theme/cc_colors.dart';
import '../../core/theme/cc_glass.dart';
import '../../data/models.dart';

/// Chat message bubble: frosted incoming, gradient outgoing, with
/// timestamp + delivery ticks tucked in the corner.
///
/// File messages render a tappable file tile (name, size, open with the
/// platform viewer) plus a send-progress bar while uploading. Voice
/// messages render a play button + progress bar.
///
/// Interactions: long-press opens the message actions sheet, and a
/// horizontal swipe starts a reply (slide to reply). Replies show a
/// quote block, forwarded messages a "Forwarded" label, edited
/// messages an "Edited" tag, and reactions as emoji pills below.
class MessageBubble extends StatefulWidget {
  final ChatMessage message;

  /// Live send progress for outgoing file messages (0.0–1.0), null when
  /// not sending. Supplied by the chat screen from the repository.
  final double? progress;

  /// Sender's display name, shown above incoming messages in group
  /// chats. Null in 1:1 chats.
  final String? senderName;

  /// Long-press → actions sheet (reply / react / edit / copy /
  /// forward / info / delete).
  final VoidCallback? onLongPress;

  /// Slide-to-reply gesture completed.
  final VoidCallback? onSwipeReply;

  /// Tapping the reactions row → reaction picker.
  final VoidCallback? onReactionTap;

  const MessageBubble({
    super.key,
    required this.message,
    this.progress,
    this.senderName,
    this.onLongPress,
    this.onSwipeReply,
    this.onReactionTap,
  });

  @override
  State<MessageBubble> createState() => _MessageBubbleState();
}

class _MessageBubbleState extends State<MessageBubble> {
  double _dragDx = 0;

  @override
  Widget build(BuildContext context) {
    final message = widget.message;
    final outgoing = message.direction == MessageDirection.outgoing;
    final dragOpacity = (_dragDx.abs() / 50).clamp(0.0, 1.0);
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: GestureDetector(
        onLongPress: widget.onLongPress,
        onHorizontalDragUpdate: (details) {
          setState(() {
            _dragDx = (_dragDx + details.delta.dx).clamp(-90.0, 90.0);
          });
        },
        onHorizontalDragEnd: (_) {
          final triggered = _dragDx.abs() > 50;
          setState(() => _dragDx = 0);
          if (triggered) widget.onSwipeReply?.call();
        },
        onHorizontalDragCancel: () => setState(() => _dragDx = 0),
        child: Transform.translate(
          offset: Offset(_dragDx, 0),
          child: Column(
            crossAxisAlignment: outgoing
                ? CrossAxisAlignment.end
                : CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    margin: const EdgeInsets.symmetric(vertical: 3),
                    padding: const EdgeInsets.symmetric(
                        horizontal: 14, vertical: 10),
                    constraints: BoxConstraints(
                      maxWidth:
                          MediaQuery.of(context).size.width * 0.75,
                    ),
                    decoration: outgoing
                        ? CcGlass.bubbleOutgoing()
                        : CcGlass.bubbleIncoming(),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (widget.senderName != null &&
                            message.direction ==
                                MessageDirection.incoming)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 2),
                              child: Text(
                                widget.senderName!,
                                style: GoogleFonts.nunito(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w800,
                                  color: CcColors.aquaCore,
                                ),
                              ),
                            ),
                          ),
                        if (message.forwarded)
                          Align(
                            alignment: Alignment.centerLeft,
                            child: Padding(
                              padding:
                                  const EdgeInsets.only(bottom: 2),
                              child: Text(
                                'Forwarded',
                                style: GoogleFonts.dmSans(
                                  fontSize: 12,
                                  fontStyle: FontStyle.italic,
                                  color: CcColors.textPrimary
                                      .withValues(alpha: 0.6),
                                ),
                              ),
                            ),
                          ),
                        if (message.replyToText != null)
                          _quoteBlock(message),
                        if (message.kind == MessageKind.voice)
                          _VoiceBubble(message: message)
                        else if (message.kind == MessageKind.file)
                          _fileContent(outgoing)
                        else
                          Text(
                            message.text,
                            style: GoogleFonts.dmSans(
                              color: CcColors.textPrimary,
                              fontSize: 15,
                            ),
                          ),
                        const SizedBox(height: 4),
                        Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (message.edited)
                              Padding(
                                padding:
                                    const EdgeInsets.only(right: 4),
                                child: Text(
                                  'Edited',
                                  style: GoogleFonts.dmSans(
                                    fontSize: 10,
                                    fontStyle: FontStyle.italic,
                                    color: CcColors.textPrimary
                                        .withValues(alpha: 0.6),
                                  ),
                                ),
                              ),
                            Text(
                              _formatTime(message.ts),
                              style: GoogleFonts.dmSans(
                                fontSize: 10,
                                color: CcColors.textPrimary
                                    .withValues(alpha: 0.65),
                              ),
                            ),
                            if (outgoing) ...[
                              const SizedBox(width: 4),
                              Icon(
                                message.status ==
                                        MessageStatus.delivered
                                    ? Icons.done_all
                                    : message.status ==
                                            MessageStatus.failed
                                        ? Icons.error_outline
                                        : Icons.done,
                                size: 14,
                                color: message.status ==
                                        MessageStatus.failed
                                    ? CcColors.errorRed
                                    : message.status ==
                                            MessageStatus.delivered
                                        ? CcColors.aquaCyan
                                        : CcColors.textPrimary
                                            .withValues(alpha: 0.65),
                              ),
                            ],
                          ],
                        ),
                      ],
                    ),
                  ),
                  if (dragOpacity > 0)
                    Positioned(
                      top: 14,
                      left: outgoing ? -30 : null,
                      right: outgoing ? null : -30,
                      child: Opacity(
                        opacity: dragOpacity,
                        child: Container(
                          width: 24,
                          height: 24,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: CcColors.aquaCore,
                          ),
                          child: const Icon(Icons.reply_rounded,
                              color: Colors.white, size: 14),
                        ),
                      ),
                    ),
                ],
              ),
              if (message.reactions.isNotEmpty)
                _reactionsRow(message),
            ],
          ),
        ),
      ),
    );
  }

  Widget _quoteBlock(ChatMessage message) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding:
          const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(8),
        border: const Border(
          left: BorderSide(color: CcColors.aquaCore, width: 3),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            message.replyToSender ?? 'Someone',
            style: GoogleFonts.nunito(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: CcColors.aquaCore,
            ),
          ),
          const SizedBox(height: 1),
          Text(
            message.replyToText ?? '',
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.dmSans(
              fontSize: 13,
              color: CcColors.textPrimary.withValues(alpha: 0.8),
            ),
          ),
        ],
      ),
    );
  }

  Widget _reactionsRow(ChatMessage message) {
    final counts = <String, int>{};
    for (final emoji in message.reactions.values) {
      counts[emoji] = (counts[emoji] ?? 0) + 1;
    }
    return GestureDetector(
      onTap: widget.onReactionTap,
      child: Container(
        margin: const EdgeInsets.only(top: 1, bottom: 3),
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
        decoration: BoxDecoration(
          color: CcColors.deepSea,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: CcColors.glassBorder.withValues(alpha: 0.5),
          ),
        ),
        child: Text(
          counts.entries.map((e) => '${e.key} ${e.value}').join('  '),
          style: GoogleFonts.dmSans(
            fontSize: 12,
            color: CcColors.textPrimary,
          ),
        ),
      ),
    );
  }

  Widget _fileContent(bool outgoing) {
    final message = widget.message;
    final progress = widget.progress;
    final isSending =
        outgoing && message.status == MessageStatus.sending;
    final icon = _iconForMime(message.mimeType);
    final sizeLabel = message.fileSize == null
        ? ''
        : formatFileSize(message.fileSize!);
    final tile = Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Icon(icon, color: CcColors.textPrimary, size: 22),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message.fileName ?? message.text,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: GoogleFonts.dmSans(
                  color: CcColors.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 2),
              Text(
                isSending
                    ? 'Sending… ${((progress ?? 0) * 100).round()}%'
                    : message.status == MessageStatus.failed
                        ? 'Failed to send'
                        : sizeLabel,
                style: GoogleFonts.dmSans(
                  fontSize: 12,
                  color: CcColors.textPrimary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ],
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: message.filePath == null || message.filePath!.isEmpty
              ? null
              : () => FileStorage.open(message.filePath!),
          child: tile,
        ),
        if (isSending) ...[
          const SizedBox(height: 8),
          SizedBox(
            width: 160,
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white.withValues(alpha: 0.2),
              valueColor: const AlwaysStoppedAnimation<Color>(Colors.white),
            ),
          ),
        ],
      ],
    );
  }

  IconData _iconForMime(String? mime) {
    if (mime == null) return Icons.insert_drive_file_outlined;
    if (mime.startsWith('image/')) return Icons.image_outlined;
    if (mime.startsWith('video/')) return Icons.videocam_outlined;
    if (mime == 'application/pdf') return Icons.picture_as_pdf_outlined;
    return Icons.insert_drive_file_outlined;
  }

  String _formatTime(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }
}

/// Voice message bubble: play/pause button, progress bar, elapsed
/// time. The audio file lives at [ChatMessage.filePath] (recorded
/// locally for outgoing, saved under `received/` for incoming).
class _VoiceBubble extends StatefulWidget {
  final ChatMessage message;
  const _VoiceBubble({required this.message});

  @override
  State<_VoiceBubble> createState() => _VoiceBubbleState();
}

class _VoiceBubbleState extends State<_VoiceBubble> {
  late final AudioPlayer _player;
  bool _playing = false;
  bool _sourceSet = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;

  @override
  void initState() {
    super.initState();
    _player = AudioPlayer();
    _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _playing = false;
          _sourceSet = false;
          _position = Duration.zero;
        });
      }
    });
  }

  @override
  void dispose() {
    _player.dispose();
    super.dispose();
  }

  Future<void> _toggle() async {
    final path = widget.message.filePath;
    if (path == null ||
        path.isEmpty ||
        !await File(path).exists()) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Voice file is gone.'),
            duration: Duration(seconds: 2),
          ),
        );
      }
      return;
    }
    if (_playing) {
      await _player.pause();
      if (mounted) setState(() => _playing = false);
    } else {
      if (!_sourceSet) {
        await _player.setSource(DeviceFileSource(path));
        _sourceSet = true;
      }
      await _player.resume();
      if (mounted) setState(() => _playing = true);
    }
  }

  String _fmt(Duration d) {
    final m = d.inMinutes;
    final s = d.inSeconds % 60;
    return '$m:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final total = _duration.inMilliseconds;
    final progress = total == 0
        ? 0.0
        : (_position.inMilliseconds / total).clamp(0.0, 1.0);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: _toggle,
          child: Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: CcColors.aquaGradient,
            ),
            child: Icon(
              _playing ? Icons.pause_rounded : Icons.play_arrow_rounded,
              color: Colors.white,
              size: 22,
            ),
          ),
        ),
        const SizedBox(width: 10),
        Flexible(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 140,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(2),
                  child: LinearProgressIndicator(
                    value: progress,
                    minHeight: 3,
                    backgroundColor:
                        Colors.white.withValues(alpha: 0.25),
                    valueColor: const AlwaysStoppedAnimation<Color>(
                        Colors.white),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              Text(
                _duration == Duration.zero
                    ? 'Voice message'
                    : _fmt(_position),
                style: GoogleFonts.dmSans(
                  fontSize: 12,
                  color: CcColors.textPrimary.withValues(alpha: 0.7),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
