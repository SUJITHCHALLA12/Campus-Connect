import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/cc_colors.dart';
import '../../core/theme/cc_glass.dart';
import '../../data/models.dart';

/// Chat message bubble in Ripple's style: frosted incoming, aqua-gradient
/// outgoing, with timestamp + delivery ticks tucked in the corner.
class MessageBubble extends StatelessWidget {
  final ChatMessage message;

  const MessageBubble({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    final outgoing = message.direction == MessageDirection.outgoing;
    return Align(
      alignment: outgoing ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        constraints: BoxConstraints(
          maxWidth: MediaQuery.of(context).size.width * 0.75,
        ),
        decoration: outgoing
            ? CcGlass.bubbleOutgoing()
            : CcGlass.bubbleIncoming(),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.end,
          mainAxisSize: MainAxisSize.min,
          children: [
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
                            : CcColors.textPrimary
                                .withValues(alpha: 0.65),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }

  String _formatTime(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
    final m = dt.minute.toString().padLeft(2, '0');
    return '$h:$m ${dt.hour < 12 ? 'AM' : 'PM'}';
  }
}
