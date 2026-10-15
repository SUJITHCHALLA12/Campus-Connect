import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/constants.dart';
import '../data/models.dart';

/// Callbacks for the long-press message actions sheet.
class MessageActionCallbacks {
  final VoidCallback onReply;
  final ValueChanged<String> onReact;
  final VoidCallback? onEdit;
  final VoidCallback? onCopy;
  final VoidCallback onForward;
  final VoidCallback onInfo;
  final VoidCallback onDeleteForMe;
  final VoidCallback? onDeleteForEveryone;

  const MessageActionCallbacks({
    required this.onReply,
    required this.onReact,
    this.onEdit,
    this.onCopy,
    required this.onForward,
    required this.onInfo,
    required this.onDeleteForMe,
    this.onDeleteForEveryone,
  });
}

/// WhatsApp-style long-press sheet: quick reactions on top, then
/// Reply / Edit / Copy / Forward / Info / Delete. Edit is only
/// offered when [canEdit] is true (own text message, within 5 minutes
/// of sending); delete-for-everyone only for own messages.
Future<void> showMessageActionsSheet(
  BuildContext context, {
  required ChatMessage message,
  required bool isOwn,
  required bool canEdit,
  required MessageActionCallbacks callbacks,
}) {
  const reactions = ['❤️', '😂', '😮', '😢', '🙏', '👍'];
  return showModalBottomSheet(
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
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: reactions.map((emoji) {
                return GestureDetector(
                  onTap: () {
                    Navigator.of(sheetContext).pop();
                    callbacks.onReact(emoji);
                  },
                  child: Text(
                    emoji,
                    style: const TextStyle(fontSize: 30),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 16),
            _option(
              sheetContext,
              icon: Icons.reply_rounded,
              label: 'Reply',
              onTap: () {
                Navigator.of(sheetContext).pop();
                callbacks.onReply();
              },
            ),
            if (canEdit)
              _option(
                sheetContext,
                icon: Icons.edit_rounded,
                label: 'Edit',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  callbacks.onEdit?.call();
                },
              ),
            if (message.kind == MessageKind.text &&
                callbacks.onCopy != null)
              _option(
                sheetContext,
                icon: Icons.copy_rounded,
                label: 'Copy',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  callbacks.onCopy?.call();
                },
              ),
            _option(
              sheetContext,
              icon: Icons.forward_rounded,
              label: 'Forward',
              onTap: () {
                Navigator.of(sheetContext).pop();
                callbacks.onForward();
              },
            ),
            _option(
              sheetContext,
              icon: Icons.info_outline_rounded,
              label: 'Info',
              onTap: () {
                Navigator.of(sheetContext).pop();
                callbacks.onInfo();
              },
            ),
            _option(
              sheetContext,
              icon: Icons.delete_outline_rounded,
              label: 'Delete for me',
              onTap: () {
                Navigator.of(sheetContext).pop();
                callbacks.onDeleteForMe();
              },
            ),
            if (isOwn && callbacks.onDeleteForEveryone != null)
              _option(
                sheetContext,
                icon: Icons.delete_forever_rounded,
                label: 'Delete for everyone',
                danger: true,
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  callbacks.onDeleteForEveryone?.call();
                },
              ),
          ],
        ),
      ),
    ),
  );
}

Widget _option(
  BuildContext context, {
  required IconData icon,
  required String label,
  bool danger = false,
  required VoidCallback onTap,
}) {
  return GestureDetector(
    onTap: onTap,
    child: Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: CcGlass.panel(radius: 16),
      child: Row(
        children: [
          Icon(
            icon,
            color: danger ? CcColors.errorRed : CcColors.aquaCyan,
            size: 22,
          ),
          const SizedBox(width: 14),
          Text(
            label,
            style: GoogleFonts.nunito(
              fontSize: 15,
              fontWeight: FontWeight.w700,
              color: danger ? CcColors.errorRed : CcColors.textPrimary,
            ),
          ),
        ],
      ),
    ),
  );
}
