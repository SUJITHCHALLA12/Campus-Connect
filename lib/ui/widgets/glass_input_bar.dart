import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/theme/cc_colors.dart';
import '../../core/theme/cc_glass.dart';

/// Frosted-glass message composer: rounded input with image / file
/// attach buttons and a gradient send button. The attach buttons pick
/// a file and send it to the peer over BLE (1 MB cap).
class GlassInputBar extends StatelessWidget {
  final TextEditingController controller;
  final VoidCallback onSend;
  final bool isSending;
  final bool enabled;
  final VoidCallback? onAttachImage;
  final VoidCallback? onAttachFile;

  const GlassInputBar({
    super.key,
    required this.controller,
    required this.onSend,
    this.isSending = false,
    this.enabled = true,
    this.onAttachImage,
    this.onAttachFile,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(
        12,
        8,
        12,
        12 + MediaQuery.of(context).padding.bottom,
      ),
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
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Expanded(
            child: Container(
              decoration: CcGlass.input(radius: 24),
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  IconButton(
                    onPressed: null,
                    icon: const Icon(
                      Icons.emoji_emotions_outlined,
                      color: CcColors.textMuted,
                      size: 22,
                    ),
                  ),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      enabled: enabled,
                      minLines: 1,
                      maxLines: 4,
                      textCapitalization: TextCapitalization.sentences,
                      style: GoogleFonts.dmSans(
                          color: CcColors.textPrimary),
                      decoration: InputDecoration(
                        hintText: 'Message',
                        hintStyle: GoogleFonts.dmSans(
                            color: CcColors.textMuted),
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        contentPadding:
                            const EdgeInsets.symmetric(vertical: 12),
                      ),
                      onSubmitted: (_) => onSend(),
                    ),
                  ),
                  IconButton(
                    onPressed: onAttachImage,
                    icon: const Icon(
                      Icons.image_outlined,
                      color: CcColors.textSecondary,
                      size: 22,
                    ),
                  ),
                  IconButton(
                    onPressed: onAttachFile,
                    icon: const Icon(
                      Icons.attach_file,
                      color: CcColors.textSecondary,
                      size: 22,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          GestureDetector(
            onTap: isSending ? null : onSend,
            child: Container(
              width: 52,
              height: 52,
              decoration: CcGlass.buttonPrimary(radius: 26),
              child: isSending
                  ? const Padding(
                      padding: EdgeInsets.all(16),
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Icon(Icons.send_rounded,
                      color: Colors.white, size: 22),
            ),
          ),
        ],
      ),
    );
  }
}
