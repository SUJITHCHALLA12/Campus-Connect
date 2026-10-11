import 'dart:io';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/material.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:provider/provider.dart';

import '../ble/ble_transport.dart';
import '../core/constants.dart';
import '../core/identity.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';
import 'chat_screen.dart';

/// Home: nearby phones (live BLE scan) on top, chat history below.
class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
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
        _error = 'Bluetooth permissions are needed to find nearby phones.';
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
    // Pre-Android-12 BLE scanning still needs location.
    if (Platform.isAndroid) {
      final info = await DeviceInfoPlugin().androidInfo;
      if (info.version.sdkInt <= 30) {
        requests.add(Permission.locationWhenInUse);
      }
    }
    final statuses = await requests.request();
    return statuses.values.every((s) => s.isGranted || s.isLimited);
  }

  String _formatTime(int ts) {
    final dt = DateTime.fromMillisecondsSinceEpoch(ts);
    final now = DateTime.now();
    if (now.difference(dt).inDays == 0) {
      final h = dt.hour % 12 == 0 ? 12 : dt.hour % 12;
      final m = dt.minute.toString().padLeft(2, '0');
      final ampm = dt.hour < 12 ? 'AM' : 'PM';
      return '$h:$m $ampm';
    }
    return '${dt.day}/${dt.month}';
  }

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleChatService>();
    final repo = context.watch<ChatRepository>();
    final identity = context.watch<IdentityStore>();

    return Scaffold(
      appBar: AppBar(
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              AppConstants.appName,
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 20),
            ),
            Text(
              'as ${identity.displayName}',
              style: const TextStyle(
                fontSize: 12,
                color: AppConstants.textSecondary,
              ),
            ),
          ],
        ),
        actions: [
          _bluetoothDot(ble.btState),
          const SizedBox(width: 16),
        ],
      ),
      body: _starting
          ? const Center(child: CircularProgressIndicator())
          : _error != null
              ? _errorView()
              : RefreshIndicator(
                  onRefresh: () async {
                    await context.read<BleChatService>().stop();
                    await context.read<BleChatService>().start();
                  },
                  child: ListView(
                    padding: const EdgeInsets.all(16),
                    children: [
                      if (ble.btState != BluetoothLowEnergyState.poweredOn)
                        _btOffBanner(),
                      _sectionTitle('Nearby phones'),
                      if (ble.peers.isEmpty)
                        _emptyNearby()
                      else
                        ...ble.peers.map(_peerTile),
                      const SizedBox(height: 24),
                      _sectionTitle('Chats'),
                      if (repo.conversations.isEmpty)
                        const Padding(
                          padding: EdgeInsets.symmetric(vertical: 24),
                          child: Text(
                            'No chats yet. When a nearby phone connects, '
                            'tap it above to start chatting.',
                            textAlign: TextAlign.center,
                            style: TextStyle(
                                color: AppConstants.textSecondary),
                          ),
                        )
                      else
                        ...repo.conversations.map(_chatTile),
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
                  size: 48, color: AppConstants.textSecondary),
              const SizedBox(height: 16),
              Text(
                _error ?? 'Something went wrong.',
                textAlign: TextAlign.center,
                style:
                    const TextStyle(color: AppConstants.textSecondary),
              ),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: () {
                  setState(() {
                    _starting = true;
                    _error = null;
                  });
                  _boot();
                },
                child: const Text('Try again'),
              ),
            ],
          ),
        ),
      );

  Widget _btOffBanner() => Container(
        margin: const EdgeInsets.only(bottom: 16),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: Colors.amber.withValues(alpha: 0.12),
          borderRadius: BorderRadius.circular(12),
        ),
        child: const Row(
          children: [
            Icon(Icons.bluetooth_disabled, color: Colors.amber),
            SizedBox(width: 12),
            Expanded(
              child: Text(
                'Bluetooth is off. Turn it on to discover nearby phones.',
                style: TextStyle(color: Colors.amber, fontSize: 13),
              ),
            ),
          ],
        ),
      );

  Widget _sectionTitle(String title) => Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Text(
          title,
          style: const TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: AppConstants.textSecondary,
            letterSpacing: 0.5,
          ),
        ),
      );

  Widget _emptyNearby() => Container(
        padding: const EdgeInsets.symmetric(vertical: 28, horizontal: 16),
        decoration: BoxDecoration(
          color: AppConstants.surface,
          borderRadius: BorderRadius.circular(14),
        ),
        child: const Column(
          children: [
            Icon(Icons.radar,
                size: 36, color: AppConstants.textSecondary),
            SizedBox(height: 8),
            Text(
              'Scanning for nearby phones…\nAsk a friend to open Campus Connect too.',
              textAlign: TextAlign.center,
              style:
                  TextStyle(color: AppConstants.textSecondary, fontSize: 13),
            ),
          ],
        ),
      );

  Widget _peerTile(NearbyPeer peer) {
    final linked = peer.linkUp;
    return Card(
      color: AppConstants.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppConstants.primary.withValues(alpha: 0.2),
          child: Text(
            peer.displayName.isEmpty
                ? '?'
                : peer.displayName[0].toUpperCase(),
            style: const TextStyle(
                color: AppConstants.primary,
                fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(
          peer.displayName,
          style: const TextStyle(color: AppConstants.textPrimary),
        ),
        subtitle: Text(
          linked ? 'Connected' : 'In range · ${peer.rssi} dBm',
          style: TextStyle(
            color: linked
                ? AppConstants.accent
                : AppConstants.textSecondary,
            fontSize: 12,
          ),
        ),
        trailing: linked
            ? const Icon(Icons.check_circle,
                color: AppConstants.accent)
            : const Icon(Icons.chevron_right,
                color: AppConstants.textSecondary),
        onTap: () {
          final link = context
              .read<BleChatService>()
              .links
              .where((l) => l.shortId == peer.shortId)
              .firstOrNullLink();
          final userId = link?.userId;
          if (userId != null) {
            _openChat(userId, link!.displayName);
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
      ),
    );
  }

  Widget _chatTile(Conversation conversation) {
    return Card(
      color: AppConstants.surface,
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14)),
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: AppConstants.primary.withValues(alpha: 0.2),
          child: Text(
            conversation.peerName.isEmpty
                ? '?'
                : conversation.peerName[0].toUpperCase(),
            style: const TextStyle(
                color: AppConstants.primary,
                fontWeight: FontWeight.bold),
          ),
        ),
        title: Text(
          conversation.peerName,
          style: const TextStyle(color: AppConstants.textPrimary),
        ),
        subtitle: Text(
          conversation.lastMessage ?? '',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style:
              const TextStyle(color: AppConstants.textSecondary),
        ),
        trailing: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Text(
              _formatTime(conversation.lastTs),
              style: const TextStyle(
                  color: AppConstants.textSecondary, fontSize: 11),
            ),
            if (conversation.unread > 0) ...[
              const SizedBox(height: 4),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 8, vertical: 2),
                decoration: const BoxDecoration(
                  color: AppConstants.accent,
                  shape: BoxShape.circle,
                ),
                child: Text(
                  '${conversation.unread}',
                  style: const TextStyle(
                      color: Colors.black,
                      fontSize: 11,
                      fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ],
        ),
        onTap: () =>
            _openChat(conversation.peerUserId, conversation.peerName),
      ),
    );
  }

  void _openChat(String peerUserId, String peerName) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ChatScreen(peerUserId: peerUserId, peerName: peerName),
      ),
    );
  }

  Widget _bluetoothDot(BluetoothLowEnergyState state) {
    final on = state == BluetoothLowEnergyState.poweredOn;
    return Tooltip(
      message: on ? 'Bluetooth on' : 'Bluetooth: $state',
      child: Icon(
        Icons.bluetooth,
        color: on ? AppConstants.accent : AppConstants.textSecondary,
      ),
    );
  }
}

/// Tiny helper to avoid pulling in package:collection for one call.
extension on Iterable<PeerLink> {
  PeerLink? firstOrNullLink() {
    for (final e in this) {
      return e;
    }
    return null;
  }
}
