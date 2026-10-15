import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../core/constants.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';

/// Where a forwarded message goes: either a 1:1 chat or a group.
class ForwardTarget {
  final String? peerUserId;
  final String? peerName;
  final Group? group;

  const ForwardTarget.peer({required this.peerUserId, this.peerName})
      : group = null;

  const ForwardTarget.group({required this.group})
      : peerUserId = null,
        peerName = null;

  String get displayName => group?.name ?? peerName ?? 'Chat';
}

/// Pick a chat to forward a message to. Returns the chosen target,
/// or null when dismissed. The caller sends the copy.
class ForwardScreen extends StatelessWidget {
  const ForwardScreen({super.key});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ChatRepository>();
    final convos = repo.conversations;
    final groups = repo.groups;

    return Scaffold(
      backgroundColor: CcColors.abyss,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        elevation: 0,
        leading: IconButton(
          onPressed: () => Navigator.of(context).pop(),
          icon: const Icon(Icons.arrow_back_rounded),
        ),
        title: Text(
          'Forward to',
          style: GoogleFonts.nunito(
            fontWeight: FontWeight.w700,
            color: CcColors.textPrimary,
          ),
        ),
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
          if (convos.isNotEmpty) ...[
            _section('Chats'),
            ...convos.map((c) => _tile(
                  context,
                  name: c.peerName,
                  onTap: () => Navigator.of(context).pop(
                    ForwardTarget.peer(
                        peerUserId: c.peerUserId, peerName: c.peerName),
                  ),
                )),
          ],
          if (groups.isNotEmpty) ...[
            _section('Groups'),
            ...groups.map((g) => _tile(
                  context,
                  name: g.name,
                  onTap: () => Navigator.of(context)
                      .pop(ForwardTarget.group(group: g)),
                )),
          ],
          if (convos.isEmpty && groups.isEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 48),
              child: Text(
                'No chats to forward to yet.',
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(color: CcColors.textMuted),
              ),
            ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 12, 4, 8),
      child: Text(
        title,
        style: GoogleFonts.nunito(
          fontSize: 15,
          fontWeight: FontWeight.w800,
          color: CcColors.textSecondary,
        ),
      ),
    );
  }

  Widget _tile(
    BuildContext context, {
    required String name,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 8),
        padding: const EdgeInsets.all(12),
        decoration: CcGlass.panel(radius: 18),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: CcColors.aquaGradient,
              ),
              child: Center(
                child: Text(
                  name.isEmpty ? '?' : name[0].toUpperCase(),
                  style: GoogleFonts.nunito(
                    fontSize: 18,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                name,
                style: GoogleFonts.nunito(
                  fontSize: 16,
                  fontWeight: FontWeight.w700,
                  color: CcColors.textPrimary,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: CcColors.textMuted),
          ],
        ),
      ),
    );
  }
}
