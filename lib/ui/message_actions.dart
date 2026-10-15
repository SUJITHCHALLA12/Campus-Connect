import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../core/constants.dart';
import '../data/models.dart';

/// Callbacks for the long-press message actions menu.
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

/// WhatsApp-style long-press menu: a compact popup anchored at the
/// pressed message (not a bottom sheet), with a quick-reaction row on
/// top — six emojis plus a "+" that opens the full reaction grid —
/// then Reply / Copy / React / Edit / Forward / Info / Delete.
/// Edit is only offered when [canEdit] is true (own text message,
/// within 5 minutes of sending); delete-for-everyone only for own
/// messages. [anchor] is the global position of the long-press.
Future<void> showMessageActionsMenu(
  BuildContext context, {
  required Offset anchor,
  required ChatMessage message,
  required bool isOwn,
  required bool canEdit,
  required MessageActionCallbacks callbacks,
}) {
  final overlay =
      Overlay.of(context).context.findRenderObject() as RenderBox;
  final position = RelativeRect.fromRect(
    Rect.fromPoints(anchor, anchor),
    Offset.zero & overlay.size,
  );
  const reactions = ['👍', '❤️', '😂', '😮', '😢', '🙏'];

  return showMenu<void>(
    context: context,
    position: position,
    color: CcColors.deepSea,
    elevation: 12,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
    ),
    items: [
      // Quick reactions: tap an emoji to react at once; "+" opens
      // the full reaction grid. Tapping the row itself just closes.
      PopupMenuItem<void>(
        padding:
            const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
          children: [
            for (final emoji in reactions)
              _reactionButton(
                context,
                emoji: emoji,
                onReact: callbacks.onReact,
              ),
            _reactionButton(
              context,
              emoji: '+',
              onReact: (_) {
                Future.microtask(
                  () => _showReactionGrid(context, callbacks.onReact),
                );
              },
            ),
          ],
        ),
      ),
      const PopupMenuDivider(height: 4),
      _menuItem(
        icon: Icons.reply_rounded,
        label: 'Reply',
        onTap: callbacks.onReply,
      ),
      if (message.kind == MessageKind.text && callbacks.onCopy != null)
        _menuItem(
          icon: Icons.copy_rounded,
          label: 'Copy',
          onTap: () => callbacks.onCopy?.call(),
        ),
      _menuItem(
        icon: Icons.emoji_emotions_outlined,
        label: 'React',
        onTap: () {
          Future.microtask(
            () => _showReactionGrid(context, callbacks.onReact),
          );
        },
      ),
      if (canEdit)
        _menuItem(
          icon: Icons.edit_rounded,
          label: 'Edit',
          onTap: () => callbacks.onEdit?.call(),
        ),
      _menuItem(
        icon: Icons.forward_rounded,
        label: 'Forward',
        onTap: callbacks.onForward,
      ),
      _menuItem(
        icon: Icons.info_outline_rounded,
        label: 'Info',
        onTap: callbacks.onInfo,
      ),
      _menuItem(
        icon: Icons.delete_outline_rounded,
        label: 'Delete for me',
        onTap: callbacks.onDeleteForMe,
      ),
      if (isOwn && callbacks.onDeleteForEveryone != null)
        _menuItem(
          icon: Icons.delete_forever_rounded,
          label: 'Delete for everyone',
          danger: true,
          onTap: () => callbacks.onDeleteForEveryone?.call(),
        ),
    ],
  );
}

/// One emoji in the quick-reaction row. Pops the menu, then reacts.
/// The "+" tile reuses this: its [onReact] opens the full grid.
Widget _reactionButton(
  BuildContext context, {
  required String emoji,
  required ValueChanged<String> onReact,
}) {
  final isPlus = emoji == '+';
  return GestureDetector(
    onTap: () {
      Navigator.of(context).pop();
      onReact(emoji);
    },
    child: Container(
      width: 34,
      height: 34,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        color: isPlus
            ? Colors.white.withValues(alpha: 0.10)
            : Colors.transparent,
      ),
      child: Center(
        child: Text(
          emoji,
          style: TextStyle(
            fontSize: isPlus ? 20 : 24,
            color: isPlus ? CcColors.textPrimary : null,
            fontWeight: isPlus ? FontWeight.w700 : null,
          ),
        ),
      ),
    ),
  );
}

PopupMenuItem<void> _menuItem({
  required IconData icon,
  required String label,
  bool danger = false,
  required VoidCallback onTap,
}) {
  return PopupMenuItem<void>(
    onTap: onTap,
    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
    child: Row(
      children: [
        Icon(
          icon,
          color: danger ? CcColors.errorRed : CcColors.aquaCyan,
          size: 21,
        ),
        const SizedBox(width: 12),
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
  );
}

/// Full reaction grid: every emoji beyond the six quick ones.
Future<void> _showReactionGrid(
  BuildContext context,
  ValueChanged<String> onReact,
) {
  const emojis = [
    '👍', '❤️', '😂', '😮', '😢', '🙏',
    '🔥', '🎉', '👏', '😍', '😡', '🤔',
    '👀', '💯', '🙌', '😅', '🥳', '😴',
    '🤝', '👌', '💪', '🫡', '😇', '🤯',
  ];
  return showDialog(
    context: context,
    builder: (dialogContext) => AlertDialog(
      backgroundColor: CcColors.deepSea,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(20),
      ),
      title: Text(
        'React',
        style: GoogleFonts.nunito(
          fontWeight: FontWeight.w700,
          color: CcColors.textPrimary,
        ),
      ),
      content: SizedBox(
        width: double.maxFinite,
        child: GridView.count(
          crossAxisCount: 6,
          shrinkWrap: true,
          mainAxisSpacing: 8,
          crossAxisSpacing: 8,
          children: emojis
              .map(
                (emoji) => GestureDetector(
                  onTap: () {
                    Navigator.of(dialogContext).pop();
                    onReact(emoji);
                  },
                  child: Center(
                    child: Text(
                      emoji,
                      style: const TextStyle(fontSize: 26),
                    ),
                  ),
                ),
              )
              .toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(dialogContext).pop(),
          child: const Text('Cancel'),
        ),
      ],
    ),
  );
}
