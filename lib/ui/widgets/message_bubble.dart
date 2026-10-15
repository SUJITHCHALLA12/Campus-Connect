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
/// platform viewer) plus a send-progress bar while uploading.
class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  /// Live send progress for outgoing file messages (0.0–1.0), null when
  /// not sending. Supplied by the chat screen from the repository.
  final double? progress;

  const MessageBubble({super.key, required this.message, this.progress});

  @override
  Widget build(BuildContext context) {
    final outgoing = message.direction == MessageDirection.outgoing;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration:
            outgoing ? CcGlass.bubbleOutgoing() : CcGlass.bubbleIncoming(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
            if (message.kind == MessageKind.file)
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
                Text(
                  _formatTime(message.ts),
                  style: GoogleFonts.dmSans(
                    fontSize: 10,
                    color: CcColors.textPrimary.withValues(alpha: 0.65),
                  ),
                ),
                if (outgoing) ...[
                  const SizedBox(width: 4),
                  Icon(
                    message.status == MessageStatus.delivered
                        ? Icons.done_all
                        : message.status == MessageStatus.failed
                            ? Icons.error_outline
                            : Icons.done,
                    size: 14,
                    color: message.status == MessageStatus.failed
                        ? CcColors.errorRed
                        : message.status == MessageStatus.delivered
                            ? CcColors.aquaCyan
                            : CcColors.textPrimary.withValues(alpha: 0.65),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _fileContent(bool outgoing) {
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
