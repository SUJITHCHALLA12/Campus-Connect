import 'dart:io';

import 'package:android_intent_plus/android_intent.dart';
import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';

import '../ble/ble_transport.dart';
import '../core/constants.dart';
import '../core/format.dart';
import '../core/identity.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';
import '../services/update_checker.dart';
import '../transfer/fast_file_transfer.dart';
import 'chat_screen.dart';
import 'create_group_screen.dart';
import 'group_chat_screen.dart';
import 'nearby_sheet.dart';
import 'widgets/aurora_background.dart';
import 'widgets/radar_pulse.dart';

/// Home shell: bottom navigation across Home, Chats, Groups and
/// Profile, with a centre + button that pairs with nearby phones or
/// creates a group chat. Rebuilt for BLE.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen>
    with WidgetsBindingObserver {
  int _bottom = 1; // Start on Chats, like the mock.
  bool _starting = true;
  String? _error;
  bool _searching = false;
  String _query = '';
  bool _bleStarted = false;
  bool _bluetoothOff = false;
  bool _updateChecked = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _boot();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// The user may have flipped Bluetooth on in system settings while
  /// we were away — start BLE when we come back and it is on.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) return;
    if (_bleStarted || _error != null) return;
    if (CentralManager().state != BluetoothLowEnergyState.poweredOn) {
      return;
    }
    _startBle();
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

    // Bluetooth on/off popup: ask before starting BLE, like other
    // apps ask at launch. If Bluetooth is off, offer to turn it on;
    // "Not now" keeps the app usable, with an off-banner on top.
    if (CentralManager().state == BluetoothLowEnergyState.poweredOff) {
      final turnOn = await _showBluetoothDialog();
      if (turnOn == true) {
        await _openBluetoothSettings();
        // Don't start BLE yet — the resume handler starts it once
        // the user is back and Bluetooth is on.
        if (mounted) {
          setState(() {
            _starting = false;
            _bluetoothOff = true;
          });
        }
        _checkForUpdate();
        return;
      }
      if (mounted) {
        setState(() {
          _starting = false;
          _bluetoothOff = true;
        });
      }
      _checkForUpdate();
      return;
    }

    await _startBle();
    _checkForUpdate();
  }

  Future<void> _startBle() async {
    try {
      await context.read<BleChatService>().start();
      _bleStarted = true;
      // Fast file transfer (Nearby + Wi-Fi Direct receivers) starts
      // alongside BLE. Best effort: a failure here must never break
      // chat — file sending falls back to BLE on its own.
      try {
        await context.read<FastFileTransferService>().start();
      } catch (_) {}
      if (mounted) {
        setState(() {
          _starting = false;
          _bluetoothOff = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _starting = false;
          _error = 'Could not start Bluetooth: $e';
        });
      }
    }
  }

  /// "Turn on Bluetooth?" popup. Returns true for Turn on,
  /// false for Not now.
  Future<bool?> _showBluetoothDialog() {
    return showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        backgroundColor: CcColors.deepSea,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Turn on Bluetooth',
            style: GoogleFonts.nunito(
                fontWeight: FontWeight.w700,
                color: CcColors.textPrimary)),
        content: Text(
          'Campus Connect finds nearby phones over Bluetooth — no '
          'internet needed. Turn Bluetooth on to start chatting.',
          style: GoogleFonts.dmSans(color: CcColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: Text('Not now',
                style: GoogleFonts.nunito(color: CcColors.textMuted)),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: Text('Turn on',
                style: GoogleFonts.nunito(
                    fontWeight: FontWeight.w800,
                    color: CcColors.aquaCyan)),
          ),
        ],
      ),
    );
  }

  Future<void> _openBluetoothSettings() async {
    try {
      await AndroidIntent(
        action: 'android.settings.BLUETOOTH_SETTINGS',
      ).launch();
    } catch (_) {
      // If the settings screen can't open, the user can flip
      // Bluetooth on manually; the banner stays until it is on.
    }
  }

  /// One-shot update check: if a newer release is out, offer it.
  Future<void> _checkForUpdate() async {
    if (_updateChecked) return;
    _updateChecked = true;
    final update = await checkForUpdate();
    if (update == null || !mounted) return;
    await showDialog(
      context: context,
      builder: (_) => AlertDialog(
        backgroundColor: CcColors.deepSea,
        shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(20)),
        title: Text('Update available',
            style: GoogleFonts.nunito(
                fontWeight: FontWeight.w700,
                color: CcColors.textPrimary)),
        content: Text(
          'Version ${update.remoteVersion} is out — you\'re on '
          '${update.currentVersion}. Get the latest fixes and '
          'features.',
          style: GoogleFonts.dmSans(color: CcColors.textSecondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text('Later',
                style: GoogleFonts.nunito(color: CcColors.textMuted)),
          ),
          TextButton(
            onPressed: () async {
              Navigator.of(context).pop();
              await launchUrl(
                Uri.parse(update.url),
                mode: LaunchMode.externalApplication,
              );
            },
            child: Text('Update',
                style: GoogleFonts.nunito(
                    fontWeight: FontWeight.w800,
                    color: CcColors.aquaCyan)),
          ),
        ],
      ),
    );
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

  void _showPlusSheet() {
    showModalBottomSheet(
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
              _sheetOption(
                context: sheetContext,
                icon: Icons.bluetooth_rounded,
                title: 'Pair with nearby',
                subtitle: 'Find phones around you and start chatting',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  showNearbySheet(context);
                },
              ),
              _sheetOption(
                context: sheetContext,
                icon: Icons.group_add_rounded,
                title: 'Create group chat',
                subtitle: 'Chat with several people at once',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => const CreateGroupScreen(),
                    ),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _sheetOption({
    required BuildContext context,
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(14),
        decoration: CcGlass.panel(radius: 18),
        child: Row(
          children: [
            Container(
              width: 46,
              height: 46,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: CcColors.aquaGradient,
              ),
              child: Icon(icon, color: Colors.white, size: 24),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: GoogleFonts.nunito(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: CcColors.textPrimary,
                    ),
                  ),
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          const AuroraBackground(),
          SafeArea(
            child: Column(
              children: [
                if (_bottom != 0) _header(),
                if (_bluetoothOff) _bluetoothBanner(),
                Expanded(
                  child: _starting
                      ? const Center(
                          child: CircularProgressIndicator(
                              color: CcColors.aquaCyan))
                      : _error != null
                          ? _errorView()
                          : IndexedStack(
                              index: _bottom,
                              children: [
                                const _HomePage(),
                                _ChatsPage(query: _query),
                                _GroupsPage(query: _query),
                                const _ProfilePage(),
                              ],
                            ),
                ),
              ],
            ),
          ),
        ],
      ),
      bottomNavigationBar: _starting || _error != null
          ? null
          : _bottomNav(),
    );
  }

  /// Slim banner while Bluetooth is off, after the user tapped
  /// "Not now". Tapping it opens Bluetooth settings.
  Widget _bluetoothBanner() {
    return GestureDetector(
      onTap: _openBluetoothSettings,
      child: Container(
        margin: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        padding:
            const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: CcColors.deepSea,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: CcColors.glassBorder.withValues(alpha: 0.5),
          ),
        ),
        child: Row(
          children: [
            const Icon(Icons.bluetooth_disabled_rounded,
                color: CcColors.textMuted, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                'Bluetooth is off — nearby chat needs it. Tap to turn on.',
                style: GoogleFonts.dmSans(
                  fontSize: 13,
                  color: CcColors.textSecondary,
                ),
              ),
            ),
            const Icon(Icons.chevron_right_rounded,
                color: CcColors.textMuted, size: 20),
          ],
        ),
      ),
    );
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.fromLTRB(20, 8, 12, 8),
      decoration: BoxDecoration(
        color: CcColors.abyss.withValues(alpha: 0.7),
        border: Border(
          bottom: BorderSide(
            color: CcColors.glassBorder.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  'Campus Connect',
                  style: GoogleFonts.nunito(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: CcColors.textPrimary,
                  ),
                ),
              ),
              IconButton(
                onPressed: () => setState(() {
                  _searching = !_searching;
                  if (!_searching) _query = '';
                }),
                icon: Icon(
                  _searching ? Icons.close_rounded : Icons.search_rounded,
                  color: CcColors.textPrimary,
                ),
              ),
            ],
          ),
          if (_searching)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Container(
                decoration: CcGlass.input(radius: 14),
                child: TextField(
                  autofocus: true,
                  style: GoogleFonts.dmSans(color: CcColors.textPrimary),
                  decoration: InputDecoration(
                    hintText: 'Search chats…',
                    hintStyle:
                        GoogleFonts.dmSans(color: CcColors.textMuted),
                    border: InputBorder.none,
                    contentPadding: const EdgeInsets.symmetric(
                        horizontal: 16, vertical: 12),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _bottomNav() {
    return Container(
      decoration: BoxDecoration(
        color: CcColors.abyss.withValues(alpha: 0.9),
        border: Border(
          top: BorderSide(
            color: CcColors.glassBorder.withValues(alpha: 0.5),
            width: 1,
          ),
        ),
      ),
      child: SafeArea(
        top: false,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceAround,
            children: [
              _navItem(Icons.home_outlined, Icons.home_rounded, 'Home',
                  0),
              _navItem(
                  Icons.chat_bubble_outline_rounded,
                  Icons.chat_bubble_rounded,
                  'Chats',
                  1),
              Transform.translate(
                offset: const Offset(0, -14),
                child: GestureDetector(
                  onTap: _showPlusSheet,
                  child: Container(
                    width: 54,
                    height: 54,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      gradient: CcColors.aquaGradient,
                      boxShadow: CcColors.cyanGlow,
                    ),
                    child: const Icon(Icons.add_rounded,
                        color: Colors.white, size: 30),
                  ),
                ),
              ),
              _navItem(Icons.group_outlined, Icons.group_rounded,
                  'Groups', 2),
              _navItem(Icons.person_outline_rounded,
                  Icons.person_rounded, 'Profile', 3),
            ],
          ),
        ),
      ),
    );
  }

  Widget _navItem(
      IconData icon, IconData activeIcon, String label, int index) {
    final active = _bottom == index;
    return GestureDetector(
      onTap: () => setState(() => _bottom = index),
      child: Container(
        color: Colors.transparent,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              active ? activeIcon : icon,
              color: active
                  ? CcColors.aquaCore
                  : CcColors.textMuted,
              size: 26,
            ),
            const SizedBox(height: 2),
            Text(
              label,
              style: GoogleFonts.dmSans(
                fontSize: 11,
                color: active
                    ? CcColors.aquaCore
                    : CcColors.textMuted,
              ),
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
                  decoration: CcGlass.buttonPrimary(radius: 14),
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

/// Avatar colours from the mock: blue, violet, green, orange, pink,
/// teal — picked by a hash of the name so the same name always gets
/// the same colour.
const _avatarPalette = [
  Color(0xFF2196F3),
  Color(0xFF9C27B0),
  Color(0xFF4CAF50),
  Color(0xFFFF9800),
  Color(0xFFE91E63),
  Color(0xFF00BCD4),
];

Color _avatarColor(String seed) =>
    _avatarPalette[seed.hashCode.abs() % _avatarPalette.length];

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
        color: _avatarColor(name),
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

/// One row in the Chats / Groups lists: coloured avatar, name,
/// last-message snippet, time, unread badge. [imagePath] shows a photo
/// (group photo) instead of the initial avatar when set.
class _ConversationTile extends StatelessWidget {
  final String title;
  final String? subtitle;
  final int lastTs;
  final int unread;
  final bool online;
  final VoidCallback onTap;
  final String? imagePath;

  const _ConversationTile({
    required this.title,
    required this.subtitle,
    required this.lastTs,
    required this.unread,
    required this.online,
    required this.onTap,
    this.imagePath,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: CcGlass.panel(radius: 20),
        child: Row(
          children: [
            Stack(
              children: [
                _tileAvatar(),
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
                    title,
                    style: GoogleFonts.nunito(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: CcColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    subtitle ?? '',
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
                  formatListTime(lastTs),
                  style: GoogleFonts.dmSans(
                    fontSize: 11,
                    color: CcColors.textMuted,
                  ),
                ),
                if (unread > 0) ...[
                  const SizedBox(height: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 8, vertical: 3),
                    decoration: BoxDecoration(
                      color: const Color(0xFF2196F3),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$unread',
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

  /// List avatar: the photo when one is set (group photo),
  /// otherwise the initials avatar.
  Widget _tileAvatar() {
    final path = imagePath;
    if (path != null && File(path).existsSync()) {
      return Container(
        width: 52,
        height: 52,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          image: DecorationImage(
            image: FileImage(File(path)),
            fit: BoxFit.cover,
          ),
        ),
      );
    }
    return _Avatar(name: title);
  }
}

// ─── Home page ───────────────────────────────────────────

class _HomePage extends StatelessWidget {
  const _HomePage();

  @override
  Widget build(BuildContext context) {
    final identity = context.watch<IdentityStore>();
    final ble = context.watch<BleChatService>();
    final repo = context.watch<ChatRepository>();
    final peers = ble.peers;
    final btOff = ble.btState != BluetoothLowEnergyState.poweredOn;
    final recent = repo.conversations.take(3).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const SizedBox(height: 8),
        Text(
          'Hi, ${identity.displayName}',
          style: GoogleFonts.nunito(
            fontSize: 26,
            fontWeight: FontWeight.w800,
            color: CcColors.textPrimary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Connect with people around you.',
          style: GoogleFonts.dmSans(
            fontSize: 14,
            color: CcColors.textMuted,
          ),
        ),
        const SizedBox(height: 20),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: CcGlass.panel(),
          child: Row(
            children: [
              const RadarPulse(size: 72),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      btOff
                          ? 'Bluetooth is off'
                          : peers.isEmpty
                              ? 'Scanning for nearby phones…'
                              : '${peers.length} phone${peers.length == 1 ? '' : 's'} in range',
                      style: GoogleFonts.nunito(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: CcColors.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'Tap Pair to see who is around.',
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
        Row(
          children: [
            Expanded(
              child: _quickAction(
                context,
                icon: Icons.bluetooth_rounded,
                label: 'Pair with nearby',
                onTap: () => showNearbySheet(context),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: _quickAction(
                context,
                icon: Icons.group_add_rounded,
                label: 'New group',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => const CreateGroupScreen(),
                  ),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 24),
        Text(
          'Recent chats',
          style: GoogleFonts.nunito(
            fontSize: 18,
            fontWeight: FontWeight.w800,
            color: CcColors.textPrimary,
          ),
        ),
        const SizedBox(height: 12),
        if (recent.isEmpty)
          Container(
            padding: const EdgeInsets.symmetric(
                vertical: 24, horizontal: 20),
            decoration: CcGlass.panel(),
            child: Text(
              'No chats yet — pair with a nearby phone from the + button to start.',
              textAlign: TextAlign.center,
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: CcColors.textMuted,
              ),
            ),
          )
        else
          ...recent.map((c) {
            final online = ble.linkForUser(c.peerUserId) != null;
            return _ConversationTile(
              title: c.peerName,
              subtitle: c.lastMessage,
              lastTs: c.lastTs,
              unread: c.unread,
              online: online,
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => ChatScreen(
                    peerUserId: c.peerUserId,
                    peerName: c.peerName,
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  Widget _quickAction(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 16),
        decoration: BoxDecoration(
          gradient: CcColors.aquaGradient,
          borderRadius: BorderRadius.circular(18),
          boxShadow: CcColors.cyanGlow,
        ),
        child: Column(
          children: [
            Icon(icon, color: Colors.white, size: 26),
            const SizedBox(height: 6),
            Text(
              label,
              style: GoogleFonts.nunito(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ─── Chats page: Chats / Groups / Updates tabs ───────────

class _ChatsPage extends StatefulWidget {
  final String query;
  const _ChatsPage({required this.query});

  @override
  State<_ChatsPage> createState() => _ChatsPageState();
}

class _ChatsPageState extends State<_ChatsPage> {
  int _tab = 0;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              _tabButton('Chats', 0),
              _tabButton('Groups', 1),
              _tabButton('Updates', 2),
            ],
          ),
        ),
        Expanded(
          child: switch (_tab) {
            0 => _ChatsList(query: widget.query),
            1 => _GroupsList(query: widget.query),
            _ => const _UpdatesList(),
          },
        ),
      ],
    );
  }

  Widget _tabButton(String label, int index) {
    final active = _tab == index;
    return Expanded(
      child: GestureDetector(
        onTap: () => setState(() => _tab = index),
        child: Container(
          margin: const EdgeInsets.symmetric(horizontal: 3),
          padding: const EdgeInsets.symmetric(vertical: 10),
          decoration: BoxDecoration(
            gradient: active ? CcColors.aquaGradient : null,
            color: active
                ? null
                : Colors.white.withValues(alpha: 0.06),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Center(
            child: Text(
              label,
              style: GoogleFonts.nunito(
                fontSize: 14,
                fontWeight: FontWeight.w700,
                color: active
                    ? Colors.white
                    : CcColors.textSecondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ChatsList extends StatelessWidget {
  final String query;
  const _ChatsList({required this.query});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ChatRepository>();
    final ble = context.watch<BleChatService>();
    final convos = repo.conversations.where((c) {
      if (query.isEmpty) return true;
      final q = query.toLowerCase();
      return c.peerName.toLowerCase().contains(q) ||
          (c.lastMessage ?? '').toLowerCase().contains(q);
    }).toList();

    return RefreshIndicator(
      color: CcColors.aquaCyan,
      backgroundColor: CcColors.deepSea,
      onRefresh: () async {
        await context.read<BleChatService>().stop();
        await context.read<BleChatService>().start();
      },
      child: ListView(
        physics: const AlwaysScrollableScrollPhysics(),
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        children: [
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
                    query.isEmpty ? 'No chats yet' : 'No matches',
                    style: GoogleFonts.nunito(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: CcColors.textPrimary,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    query.isEmpty
                        ? 'Tap + to pair with a nearby phone — when one connects, tap it to start chatting.'
                        : 'Try a different search.',
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
              final online = ble.linkForUser(c.peerUserId) != null;
              return _ConversationTile(
                title: c.peerName,
                subtitle: c.lastMessage,
                lastTs: c.lastTs,
                unread: c.unread,
                online: online,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ChatScreen(
                      peerUserId: c.peerUserId,
                      peerName: c.peerName,
                    ),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }
}

// ─── Groups list (shared by the Groups tab + Groups page) ─

class _GroupsList extends StatelessWidget {
  final String query;
  const _GroupsList({required this.query});

  @override
  Widget build(BuildContext context) {
    final repo = context.watch<ChatRepository>();
    final groups = repo.groups.where((g) {
      if (query.isEmpty) return true;
      final q = query.toLowerCase();
      return g.name.toLowerCase().contains(q) ||
          (g.lastMessage ?? '').toLowerCase().contains(q);
    }).toList();

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        if (groups.isEmpty)
          Container(
            margin: const EdgeInsets.only(top: 32),
            padding: const EdgeInsets.symmetric(
                vertical: 36, horizontal: 24),
            decoration: CcGlass.panel(),
            child: Column(
              children: [
                const Icon(Icons.group_rounded,
                    size: 40, color: CcColors.aquaCyan),
                const SizedBox(height: 12),
                Text(
                  query.isEmpty ? 'No groups yet' : 'No matches',
                  style: GoogleFonts.nunito(
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                    color: CcColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  query.isEmpty
                      ? 'Tap + → Create group chat to start one.'
                      : 'Try a different search.',
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
          ...groups.map((g) => _ConversationTile(
                title: g.name,
                subtitle: g.lastMessage,
                lastTs: g.lastTs,
                unread: g.unread,
                online: false,
                imagePath: g.photoPath,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => GroupChatScreen(group: g),
                  ),
                ),
              )),
      ],
    );
  }
}

class _GroupsPage extends StatelessWidget {
  final String query;
  const _GroupsPage({required this.query});

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Padding(
          padding: EdgeInsets.fromLTRB(20, 12, 16, 4),
          child: _SectionTitle('Groups'),
        ),
        Expanded(child: _GroupsList(query: query)),
      ],
    );
  }
}

// ─── Updates ─────────────────────────────────────────────

class _UpdatesList extends StatelessWidget {
  const _UpdatesList();

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
      children: [
        _updateCard(
          icon: Icons.group_rounded,
          title: 'Group chats are here',
          body: 'Create a group from the + button and chat with everyone at once — no server, just Bluetooth.',
        ),
        _updateCard(
          icon: Icons.attach_file_rounded,
          title: 'Send files over Bluetooth',
          body: 'Images and files up to 1 MB, straight from the chat composer. No internet needed.',
        ),
        _updateCard(
          icon: Icons.bluetooth_rounded,
          title: 'Stay in range',
          body: 'Bluetooth works best within about 10–30 m. Out of range? Messages wait until you are back.',
        ),
      ],
    );
  }

  Widget _updateCard({
    required IconData icon,
    required String title,
    required String body,
  }) {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(16),
      decoration: CcGlass.panel(radius: 20),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: CcColors.aquaGradient,
            ),
            child: Icon(icon, color: Colors.white, size: 22),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: GoogleFonts.nunito(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: CcColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: GoogleFonts.dmSans(
                    fontSize: 13,
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

// ─── Profile page ────────────────────────────────────────

class _ProfilePage extends StatelessWidget {
  const _ProfilePage();

  @override
  Widget build(BuildContext context) {
    final identity = context.watch<IdentityStore>();
    final ble = context.watch<BleChatService>();
    final btOn = ble.btState == BluetoothLowEnergyState.poweredOn;

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
      children: [
        const _SectionTitle('Profile'),
        Container(
          padding: const EdgeInsets.all(16),
          decoration: CcGlass.panel(),
          child: Row(
            children: [
              _profileAvatar(context, identity),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
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
          icon: Icons.photo_camera_rounded,
          title: 'Profile photo',
          subtitle: identity.profilePhotoPath == null
              ? 'Add a photo (only shown on this phone)'
              : 'Change or remove your photo',
          onTap: () => _photoSheet(context, identity),
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
            'Campus Connect v0.9 · BLE-first · plaintext v1',
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
                crossAxisAlignment: CrossAxisAlignment.start,
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

  /// Profile avatar: the photo when one is set, otherwise the
  /// initials gradient. Tapping opens the photo sheet.
  Widget _profileAvatar(BuildContext context, IdentityStore identity) {
    final photoPath = identity.profilePhotoPath;
    final hasPhoto = photoPath != null && File(photoPath).existsSync();
    return GestureDetector(
      onTap: () => _photoSheet(context, identity),
      child: Stack(
        children: [
          if (hasPhoto)
            Container(
              width: 60,
              height: 60,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                image: DecorationImage(
                  image: FileImage(File(photoPath)),
                  fit: BoxFit.cover,
                ),
              ),
            )
          else
            _Avatar(name: identity.displayName, size: 60),
          Positioned(
            right: 0,
            bottom: 0,
            child: Container(
              width: 20,
              height: 20,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: CcColors.aquaCore,
                border: Border.all(
                  color: CcColors.deepSea,
                  width: 2,
                ),
              ),
              child: const Icon(
                Icons.camera_alt_rounded,
                color: Colors.white,
                size: 11,
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _photoSheet(BuildContext context, IdentityStore identity) {
    final hasPhoto = identity.profilePhotoPath != null;
    showModalBottomSheet(
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
              _option(
                sheetContext,
                icon: Icons.photo_library_rounded,
                title: hasPhoto ? 'Change photo' : 'Choose photo',
                onTap: () {
                  Navigator.of(sheetContext).pop();
                  _changePhoto(context, identity);
                },
              ),
              if (hasPhoto)
                _option(
                  sheetContext,
                  icon: Icons.delete_outline_rounded,
                  title: 'Remove photo',
                  danger: true,
                  onTap: () async {
                    Navigator.of(sheetContext).pop();
                    await identity.clearProfilePhoto();
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Picks an image, copies it into app storage as profile_photo.jpg,
  /// and remembers it. The system picker needs no extra permission.
  Future<void> _changePhoto(
      BuildContext context, IdentityStore identity) async {
    try {
      final picked = await FilePicker.platform.pickFiles(
        type: FileType.image,
        allowMultiple: false,
      );
      final source = picked?.files.single.path;
      if (source == null) return;
      final dir = await getApplicationDocumentsDirectory();
      final dest = File(p.join(dir.path, 'profile_photo.jpg'));
      await File(source).copy(dest.path);
      await identity.setProfilePhoto(dest.path);
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Could not set photo: $e'),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    }
  }

  void _editName(BuildContext context, IdentityStore identity) {
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
          style: GoogleFonts.dmSans(color: CcColors.textPrimary),
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
              await identity.setDisplayName(controller.text);
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
          'v0.8 messages are plaintext over the air; per-conversation '
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

  void _resetIdentity(BuildContext context, IdentityStore identity) {
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
                style: TextStyle(color: CcColors.errorRed)),
          ),
        ],
      ),
    );
  }
}
