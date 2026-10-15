import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:provider/provider.dart';

import '../ble/ble_transport.dart';
import '../core/constants.dart';
import 'chat_screen.dart';
import 'widgets/radar_pulse.dart';

/// Bottom sheet opened from the + button: scan + pair with a nearby
/// phone. Tapping a connected phone opens a 1:1 chat with them;
/// tapping one that is still connecting shows a "still connecting"
/// notice.
Future<void> showNearbySheet(BuildContext context) {
  return showModalBottomSheet(
    context: context,
    backgroundColor: CcColors.deepSea,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
    ),
    builder: (_) => const _NearbySheetContent(),
  );
}

class _NearbySheetContent extends StatelessWidget {
  const _NearbySheetContent();

  @override
  Widget build(BuildContext context) {
    final ble = context.watch<BleChatService>();
    final peers = ble.peers;
    final btOff = ble.btState != BluetoothLowEnergyState.poweredOn;

    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
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
            Text(
              'Pair with nearby',
              style: GoogleFonts.nunito(
                fontSize: 19,
                fontWeight: FontWeight.w800,
                color: CcColors.textPrimary,
              ),
            ),
            const SizedBox(height: 12),
            const RadarPulse(size: 90),
            const SizedBox(height: 8),
            Text(
              btOff
                  ? 'Bluetooth is off'
                  : peers.isEmpty
                      ? 'Scanning for nearby phones…'
                      : '${peers.length} phone${peers.length == 1 ? '' : 's'} in range',
              style: GoogleFonts.dmSans(
                fontSize: 13,
                color: CcColors.textSecondary,
              ),
            ),
            const SizedBox(height: 12),
            Flexible(
              child: ListView.builder(
                shrinkWrap: true,
                itemCount: peers.length,
                itemBuilder: (_, i) => _peerTile(context, peers[i]),
              ),
            ),
            if (!btOff && peers.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 8),
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
    );
  }

  Widget _peerTile(BuildContext context, NearbyPeer peer) {
    final ble = context.read<BleChatService>();
    final matches =
        ble.links.where((l) => l.shortId == peer.shortId);
    final PeerLink? link = matches.isEmpty ? null : matches.first;
    final userId = link?.userId;

    return GestureDetector(
      onTap: () {
        if (userId != null && link != null) {
          Navigator.of(context).pop();
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ChatScreen(
                peerUserId: userId,
                peerName: link.displayName,
              ),
            ),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Still connecting — try again in a moment.'),
              duration: Duration(seconds: 2),
            ),
          );
        }
      },
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
                  peer.displayName.isEmpty
                      ? '?'
                      : peer.displayName[0].toUpperCase(),
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
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    peer.displayName,
                    style: GoogleFonts.nunito(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      color: CcColors.textPrimary,
                    ),
                  ),
                  Text(
                    peer.linkUp
                        ? 'Connected — tap to chat'
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
