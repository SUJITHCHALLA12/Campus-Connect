import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../ble/ble_transport.dart';
import '../core/constants.dart';
import '../core/format.dart';
import '../core/identity.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';
import 'chat_screen.dart';
import 'widgets/aurora_background.dart';
import 'widgets/radar_pulse.dart';

/// Home shell: bottom-tab navigation across Chats, Nearby and Settings —
/// the same three zones Ripple's nav exposes, rebuilt for BLE.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  int _tab = 0;
  bool _starting = true;
  String? _error;

  @override
  void initState() {
    super.initState();
    _boot();
  }

  Future<void> _boot() async {
    final granted = await _ensurePermissions();
    if (!granted) {
      setState(() {
        _starting = false;
        _error =
            'Bluetooth permissions are needed to find nearby phones.';
      });
      return;
    }
    try {
      await context.read<BleChatService>().start();
    } catch (e) {
      _error = 'Could not start Bluetooth: $e';
    }
    if (mounted) setState(() => _starting = false);
  }

  Future<bool> _ensurePermissions() async {
    final requests = <Permission>[
      Permission.bluetoothScan,
      Permission.bluetoothAdvertise,
      Permission.bluetoothConnect,
    ];
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt <= 30) {
        requests.add(Permission.locationWhenInUse);
      }
    }
    final statuses = await requests.request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const AuroraBackground(),
          SafeArea(
            child: _starting
                ? const Center(
                    child: CircularProgressIndicator(
                        color: CcColors.aquaCyan))
                : _error != null
                    ? _errorView()
                    : IndexedStack(
                        index: _tab,
                        children: const [
                          _ChatsTab(),
                          _NearbyTab(),
                          _SettingsTab(),
                        ],
                      ),
          ),
        ],
      ),
      bottomNavigationBar: _starting || _error != null
          ? null
          : Container(
              decoration: BoxDecoration(
                color: CcColors.abyss.withValues(alpha: 0.85),
                border: Border(
                  top: BorderSide(
                    color:
                        CcColors.glassBorder.withValues(alpha: 0.5),
                    width: 1,
                  ),
                ),
              ),
              child: BottomNavigationBar(
                currentIndex: _tab,
                onTap: (i) => setState(() => _tab = i),
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.chat_bubble_outline_rounded),
                    activeIcon:
                        Icon(Icons.chat_bubble_rounded),
                    label: 'Chats',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.radar_outlined),
                    activeIcon: Icon(Icons.radar),
                    label: 'Nearby',
                  ),
                  BottomNavigationBarItem(
                    icon:
                        Icon(Icons.settings_outlined),
                    activeIcon: Icon(Icons.settings_rounded),
                    label: 'Settings',
                  ),
                ],
              ),
            ),
    );
  }

  Widget _errorView() => Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.bluetooth_disabled,
                  size: 48, color: CcColors.textMuted),
              const SizedBox(height: 16),
              Text(
                _error ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style: GoogleFonts.dmSans(
                    color: CcColors.textSecondary),
              ),
              const SizedBox(height: 16),
              GestureDetector(
                onTap: () {
                  setState(() {
                    _starting = true;
                    _error = null;
                  });
                  _boot();
                },
                child: Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 28, vertical: 14),
                  decoration:
                      CcGlass.buttonPrimary(radius: 14),
                  child: Text('Try again',
                      style: GoogleFonts.nunito(
                          fontWeight: FontWeight.w700,
                          color: Colors.white)),
                ),
              ),
            ],
          ),
        ),
      );
}

// ─── Shared bits ─────────────────────────────────────────

class _Avatar extends StatelessWidget {
  final String name;
  final double size;

  const _Avatar({required this.name, this.size = 52});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: CcColors.aquaGradient,
        boxShadow: CcColors.cyanGlow,
      ),
      child: Center(
        child: Text(
          name.isEmpty ? '?' : name[0].toUpperCase(),
          style: GoogleFonts.nunito(
            fontSize: size * 0.42,
            fontWeight: FontWeight.w800,
            color: Colors.white,
          ),
        ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 4, 12),
      child: Text(
        title,
        style: GoogleFonts.nunito(
          fontSize: 26,
          fontWeight: FontWeight.w800,
          color: CcColors.textPrimary,
        ),
      ),
    );
  }
}

// ─── Chats tab ───────────────────────────────────────────

class _ChatsTab extends StatelessWidget {
  const _ChatsTab();

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ChatRepository>();
    final ble = context.watch<BleChatService>();
    final convos = repo.conversations;

    return RefreshIndicator(
      color: CcColors.aquaCyan,
      backgroundColor: CcColors.deepSea,
      onRefresh: () async {
        await context.read<BleChatService>().stop();
        await context.read<BleChatService>().start();
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
        children: [
          const _SectionTitle('Chats'),
          if (convos.isEmpty)
            Container(
              margin: const EdgeInsets.only(top: 32),
              padding: const EdgeInsets.symmetric(
                  vertical: 36, horizontal: 24),
              decoration: CcGlass.panel(),
              child: Column(
                children: [
                  const Icon(Icons.waves_rounded,
                      size: 40, color: CcColors.aquaCyan),
                  const SizedBox(height: 12),
                  Text(
                    'No chats yet',
                    style: GoogleFonts.nunito(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: CcColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    'Head to the Nearby tab — when a phone connects, tap it to start chatting.',
                    textAlign: TextAlign.center,
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      color: CcColors.textMuted,
                    ),
                  ),
                ],
              ),
            )
          else
            ...convos.map((c) {
              final online =
                  ble.linkForUser(c.peerUserId) != null;
              return _chatTile(context, c, online);
            }),
        ],
      ),
    );
  }

  Widget _chatTile(
      BuildContext context, Conversation c, bool online) {
    return GestureDetector(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ChatScreen(
              peerUserId: c.peerUserId,
              peerName: c.peerName),
        ),
      ),
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: CcGlass.panel(radius: 20),
        child: Row(
          children: [
            Stack(
              children: [
                _Avatar(name: c.peerName),
                if (online)
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: CcColors.onlineGreen,
                        border: Border.all(
                            color: CcColors.abyss, width: 2),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.peerName,
                    style: GoogleFonts.nunito(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: CcColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    c.lastMessage ?? '',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: GoogleFonts.dmSans(
                      fontSize: 13,
                      color: CcColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  formatListTime(c.lastTs),
                  style: GoogleFonts.dmSans(
                    fontSize: 11,
                    color: CcColors.textMuted,
                  ),
                ),
                if (c.unread > 0) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      gradient: CcColors.aquaGradient,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '${c.unread}',
                      style: GoogleFonts.nunito(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Nearby tab ──────────────────────────────────────────

class _NearbyTab extends StatelessWidget {
  const _NearbyTab();

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleChatService>();
    final peers = ble.peers;
    final btOff =
        ble.btState != BluetoothLowEnergyState.poweredOn;

    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const _SectionTitle('Nearby'),
        Center(
          child: Column(
            children: [
              const SizedBox(height: 8),
              const RadarPulse(size: 150),
              const SizedBox(height: 12),
              Text(
                btOff
                    ? 'Bluetooth is off'
                    : peers.isEmpty
                        ? 'Scanning for nearby phones…'
                        : '${peers.length} phone${peers.length == 1 ? '' : 's'} in range',
                style: GoogleFonts.dmSans(
                  fontSize: 14,
                  color: CcColors.textSecondary,
                ),
              ),
              if (!btOff && peers.isEmpty)
                Padding(
                  padding:
                      const EdgeInsets.only(top: 6),
                  child: Text(
                    'Ask a friend to open Campus Connect too.',
                    style: GoogleFonts.dmSans(
                      fontSize: 12,
                      color: CcColors.textMuted,
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 20),
        ...peers.map((p) => _peerTile(context, p)),
      ],
    );
  }

  Widget _peerTile(BuildContext context, NearbyPeer peer) {
    final ble = context.read<BleChatService>();
    final link =
        ble.links.where((l) => l.shortId == peer.shortId);
    final PeerLink? pl = link.isEmpty ? null : link.first;
    final userId = pl?.userId;

    return GestureDetector(
      onTap: () {
        if (userId != null && pl != null) {
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                peerUserId: userId,
                peerName: pl.displayName,
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                  'Still connecting — try again in a moment.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: CcGlass.panel(radius: 20),
        child: Row(
          children: [
            _Avatar(name: peer.displayName, size: 48),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    peer.displayName,
                    style: GoogleFonts.nunito(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: CcColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    peer.linkUp
                        ? 'Connected'
                        : 'In range · ${peer.rssi} dBm',
                    style: GoogleFonts.dmSans(
                      fontSize: 12,
                      color: peer.linkUp
                          ? CcColors.onlineGreen
                          : CcColors.textMuted,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              peer.linkUp
                  ? Icons.check_circle_rounded
                  : Icons.chevron_right_rounded,
              color: peer.linkUp
                  ? CcColors.onlineGreen
                  : CcColors.textMuted,
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Settings tab ────────────────────────────────────────

class _SettingsTab extends StatelessWidget {
  const _SettingsTab();

  @override
  Widget build(BuildContext context) {
    final identity = context.watch<IdentityStore>();
    final ble = context.watch<BleChatService>();
    final btOn =
        ble.btState == BluetoothLowEnergyState.poweredOn;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const _SectionTitle('Settings'),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: CcGlass.panel(),
          child: Row(
            children: [
              _Avatar(
                  name: identity.displayName, size: 60),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment:
                      CrossAxisAlignment.start,
                  children: [
                    Text(
                      identity.displayName,
                      style: GoogleFonts.nunito(
                        fontSize: 19,
                        fontWeight: FontWeight.w800,
                        color: CcColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'ID ${identity.shortId} · Bluetooth ${btOn ? 'on' : 'off'}',
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
        ),
        const SizedBox(height: 16),
        _option(
          context,
          icon: Icons.edit_rounded,
          title: 'Edit display name',
          onTap: () => _editName(context, identity),
        ),
        _option(
          context,
          icon: Icons.info_outline_rounded,
          title: 'About Campus Connect',
          onTap: () => _about(context),
        ),
        _option(
          context,
          icon: Icons.refresh_rounded,
          title: 'Reset identity',
          subtitle: 'Forget this name and start fresh',
          danger: true,
          onTap: () => _resetIdentity(context, identity),
        ),
        const SizedBox(height: 24),
        Center(
          child: Text(
            'Campus Connect v0.2 · BLE-first · plaintext v1',
            style: GoogleFonts.dmSans(
              fontSize: 11,
              color: CcColors.textMuted,
            ),
          ),
        ),
      ],
    );
  }

  Widget _option(
    BuildContext context, {
    required IconData icon,
    required String title,
    String? subtitle,
    bool danger = false,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.symmetric(
            horizontal: 16, vertical: 14),
        decoration: CcGlass.panel(radius: 18),
        child: Row(
          children: [
            Icon(icon,
                color: danger
                    ? CcColors.errorRed
                    : CcColors.aquaCyan,
                size: 22),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment:
                    CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.nunito(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: danger
                          ? CcColors.errorRed
                          : CcColors.textPrimary,
                    ),
                  ),
                  if (subtitle != null)
                    Text(
                      subtitle,
                      style: GoogleFonts.dmSans(
                        fontSize: 12,
                        color: CcColors.textMuted,
                      ),
                    ),
                ],
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: CcColors.textMuted),
          ],
        ),
      ),
    );
  }

  void _editName(
      BuildContext context, IdentityStore identity) {
    final controller =
        TextEditingController(text: identity.displayName);
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CcColors.deepSea,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Display name',
            style: GoogleFonts.nunito(
                fontWeight: FontWeight.w700,
                color: CcColors.textPrimary)),
        content: TextField(
          controller: controller,
          maxLength: 24,
          style: GoogleFonts.dmSans(
              color: CcColors.textPrimary),
          decoration: const InputDecoration(
              counterText: '', hintText: 'Your name'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await identity
                  .setDisplayName(controller.text);
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  void _about(BuildContext context) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CcColors.deepSea,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Campus Connect',
            style: GoogleFonts.nunito(
                fontWeight: FontWeight.w800,
                color: CcColors.textPrimary)),
        content: Text(
          'Nearby-first campus messaging over Bluetooth Low Energy. '
          'Chat with phones around you — no internet, no servers, no accounts.\n\n'
          'v0.2 messages are plaintext over the air; per-conversation '
          'encryption is on the roadmap.',
          style: GoogleFonts.dmSans(
              color: CcColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _resetIdentity(
      BuildContext context, IdentityStore identity) {
    showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CcColors.deepSea,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Reset identity?',
            style: GoogleFonts.nunito(
                fontWeight: FontWeight.w700,
                color: CcColors.errorRed)),
        content: Text(
          'This forgets your name and ID on this phone. Your chat history stays, but nearby phones will see you as someone new.',
          style: GoogleFonts.dmSans(
              color: CcColors.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              await identity.clear();
              if (context.mounted) {
                Navigator.of(context).pop();
              }
            },
            child: const Text('Reset',
                style:
                    TextStyle(color: CcColors.errorRed)),
          ),
        ],
      ),
    );
  }
}
