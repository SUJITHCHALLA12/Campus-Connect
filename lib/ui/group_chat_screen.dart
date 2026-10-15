import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../ble/ble_protocol.dart';
import '../ble/ble_transport.dart';
import '../core/constants.dart';
import '../core/identity.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';
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
    setState(() => _sending = true);
    _controller.clear();

    final identity = context.read<IdentityStore>();
    final ble = context.read<BleChatService>();
    final repo = context.read<ChatRepository>();

    // The packet carries the full roster (including self) so receivers
    // who have never seen this group can create it with all names.
    final members = Map<String, String>.from(widget.group.members)
      ..[identity.userId] = identity.displayName;
    final packet = BlePacket.groupMsg(
      from: identity.userId,
      name: identity.displayName,
      text: text,
      groupId: widget.group.id,
      groupName: widget.group.name,
      members: members,
    );
    await repo.saveOutgoingGroupMsg(group: widget.group, packet: packet);

    var delivered = 0;
    for (final memberId in widget.group.members.keys) {
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

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ChatRepository>();
    final group =
        repo.groupById(widget.group.id) ?? widget.group;
    final memberCount = group.members.length + 1;

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
                          );
                        },
                      );
                    },
                  ),
                ),
                GlassInputBar(
                  controller: _controller,
                  onSend: _send,
                  isSending: _sending,
                ),
              ],
            ),
          ),
        ],
      ),
    );
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
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: CcColors.aquaGradient,
            ),
            child: Center(
              child: Text(
                group.name.isEmpty
                    ? '?'
                    : group.name[0].toUpperCase(),
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
    );
  }
}
