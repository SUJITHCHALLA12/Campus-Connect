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

/// 1:1 chat with a nearby phone — Ripple-style glass app bar, bubbles
/// and composer, powered by the BLE transport underneath.
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
                            message: messages[i]),
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
