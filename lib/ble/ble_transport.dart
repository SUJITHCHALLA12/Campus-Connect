import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:flutter/foundation.dart';

import '../core/constants.dart';
import '../core/identity.dart';
import 'ble_protocol.dart';
import 'file_transfer.dart';

/// A nearby phone heard advertising the Campus Connect service.
class NearbyPeer {
  final String shortId;
  String displayName;
  final Peripheral peripheral;
  int rssi;
  DateTime lastSeen;
  bool linkUp;

  NearbyPeer({
    required this.shortId,
    required this.displayName,
    required this.peripheral,
    required this.rssi,
    required this.lastSeen,
    this.linkUp = false,
  });
}

/// One logical chat link to a nearby phone.
///
/// Exactly one link exists per pair of phones (see [BleProtocol] tie-break).
/// The link is keyed by the peer's advertised short id until the HELLO
/// handshake reveals the full user id.
class PeerLink {
  final String shortId;
  String? userId;
  String displayName;
  final bool iAmCentral;
  final Peripheral? peripheral; // set when iAmCentral
  final Central? central; // set when !iAmCentral
  GATTCharacteristic? rxChar; // central-side write target
  GATTCharacteristic? txChar; // central-side notify source
  int chunkSize;
  final FrameReassembler reassembler = FrameReassembler();

  PeerLink({
    required this.shortId,
    this.userId,
    required this.displayName,
    required this.iAmCentral,
    this.peripheral,
    this.central,
    this.rxChar,
    this.txChar,
    this.chunkSize = 64,
  });
}

/// Owns the whole BLE layer: advertising + GATT server (peripheral role),
/// scanning + connections (central role), framing, and packet routing.
///
/// Incoming `msg`/`ack` packets are exposed on [incoming]; the chat
/// repository subscribes and persists them. UI observes [peers], [links]
/// and [btState] via [ChangeNotifier].
class BleChatService extends ChangeNotifier {
  final IdentityStore identity;

  final CentralManager _central = CentralManager();
  final PeripheralManager _peripheral = PeripheralManager();

  final Map<String, NearbyPeer> _peers = {}; // key: peripheral uuid
  final Map<String, PeerLink> _links = {}; // key: peer shortId
  final Map<String, String> _userIdToShortId = {};
  final Set<String> _connecting = {};
  final Map<String, FrameReassembler> _incomingReassemblers = {};

  final StreamController<BlePacket> _incoming =
      StreamController<BlePacket>.broadcast();
  Stream<BlePacket> get incoming => _incoming.stream;

  final List<StreamSubscription> _subs = [];
  Timer? _pruneTimer;
  Timer? _reconnectTimer;

  /// Collects incoming file-transfer packets (fileStart/fileChunk/
  /// fileEnd) and assembles the file bytes.
  final FileReceiver fileReceiver = FileReceiver();

  late GATTCharacteristic _hostRxChar; // peripheral-side RX
  late GATTCharacteristic _hostTxChar; // peripheral-side TX

  bool _running = false;
  bool get isRunning => _running;

  BluetoothLowEnergyState _btState = BluetoothLowEnergyState.unknown;
  BluetoothLowEnergyState get btState => _btState;

  List<NearbyPeer> get peers {
    final list = _peers.values.toList()
      ..sort((a, b) => b.rssi.compareTo(a.rssi));
    return list;
  }

  /// Smoothed RSSI per peer (exponential moving average, keyed by
  /// shortId). Raw RSSI jumps several dBm scan to scan as the phone
  /// moves or the signal reflects; the EMA steadies the distance
  /// estimate without hiding real movement.
  final Map<String, double> _smoothedRssi = {};

  /// Rough distance estimate in metres from an RSSI reading, via the
  /// log-distance path-loss model: d = 10 ^ ((txPower − rssi) / 10n).
  /// txPower −59 dBm ≈ RSSI at 1 m, n = 2.0 (free-space-ish). BLE
  /// cannot measure true distance — walls, bodies and reflections
  /// shift RSSI by metres — so treat the number as an estimate.
  static double estimateDistanceMeters(int rssi) {
    const txPower = -59.0;
    const pathLossExponent = 2.0;
    return math.pow(10, (txPower - rssi) / (10 * pathLossExponent))
        .toDouble();
  }

  /// Estimated distance in metres to a connected peer, from their
  /// smoothed advertisement RSSI. Null when no recent advertisement
  /// is known (e.g. the peer is linked but their ads stopped).
  double? distanceToUser(String userId) {
    final shortId = _userIdToShortId[userId];
    if (shortId == null) return null;
    final smoothed = _smoothedRssi[shortId];
    if (smoothed == null) return null;
    return estimateDistanceMeters(smoothed.round());
  }

  List<PeerLink> get links => _links.values.toList();

  PeerLink? linkForUser(String userId) {
    final short = _userIdToShortId[userId];
    return short == null ? null : _links[short];
  }

  BleChatService(this.identity);

  // ---------------------------------------------------------------- start

  Future<void> start() async {
    if (_running) return;

    _btState = _central.state;
    _subs.add(_central.stateChanged.listen((e) {
      _btState = e.state;
      notifyListeners();
    }));

    // ---- peripheral role: host the service, advertise it ----
    _hostRxChar = GATTCharacteristic.mutable(
      uuid: BleProtocol.rxUuid,
      properties: [
        GATTCharacteristicProperty.write,
        GATTCharacteristicProperty.writeWithoutResponse,
      ],
      permissions: [GATTCharacteristicPermission.write],
      descriptors: [],
    );
    _hostTxChar = GATTCharacteristic.mutable(
      uuid: BleProtocol.txUuid,
      properties: [GATTCharacteristicProperty.notify],
      permissions: [GATTCharacteristicPermission.read],
      descriptors: [],
    );
    final service = GATTService(
      uuid: BleProtocol.serviceUuid,
      isPrimary: true,
      includedServices: [],
      characteristics: [_hostRxChar, _hostTxChar],
    );
    await _peripheral.addService(service);
    _subs.add(
        _peripheral.characteristicWriteRequested.listen(_onWriteRequested));
    _subs.add(_peripheral.connectionStateChanged.listen(_onPeripheralConn));

    await _startAdvertising();

    // ---- central role: scan for the service ----
    _subs.add(_central.discovered.listen(_onDiscovered));
    _subs.add(_central.connectionStateChanged.listen(_onCentralConn));
    _subs.add(_central.characteristicNotified.listen(_onNotified));
    await _central.startDiscovery(
        serviceUUIDs: [BleProtocol.serviceUuid]);

    _pruneTimer =
        Timer.periodic(AppConstants.peerPruneInterval, (_) => _prunePeers());
    // Auto-reconnect sweep: retry unlinked peers that are still
    // advertising (covers discovery events the scan may have missed).
    _reconnectTimer = Timer.periodic(
      const Duration(seconds: 10),
      (_) => _retryPendingLinks(),
    );

    _running = true;
    notifyListeners();
  }

  Future<void> stop() async {
    if (!_running) return;
    _running = false;
    _pruneTimer?.cancel();
    _reconnectTimer?.cancel();
    for (final s in _subs) {
      await s.cancel();
    }
    _subs.clear();
    try {
      await _central.stopDiscovery();
    } catch (_) {}
    try {
      await _peripheral.stopAdvertising();
    } catch (_) {}
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(stop());
    unawaited(_incoming.close());
    super.dispose();
  }

  /// (Re)starts advertising our presence. Called at startup and
  /// again after a peripheral-side disconnect: a peripheral stops
  /// advertising while connected and does NOT resume on its own, so
  /// without this the other phone could never re-discover us and
  /// auto-reconnect would be dead.
  Future<void> _startAdvertising() async {
    try {
      await _peripheral.startAdvertising(Advertisement(
        name: BleProtocol.advName(identity.shortId, identity.displayName),
        serviceUUIDs: [BleProtocol.serviceUuid],
        serviceData: {},
        manufacturerSpecificData: [],
      ));
    } catch (_) {
      // Already advertising (or Bluetooth off) — the sweep and the
      // next discovery round will pick it up.
    }
  }

  /// Retries links to peers that are still advertising but unlinked.
  /// Only the tie-break winner (larger shortId) initiates, so exactly
  /// one side dials.
  void _retryPendingLinks() {
    if (!_running) return;
    final cutoff = DateTime.now().subtract(const Duration(seconds: 60));
    for (final peer in _peers.values) {
      if (peer.linkUp) continue;
      if (peer.lastSeen.isBefore(cutoff)) continue;
      if (identity.shortId.compareTo(peer.shortId) <= 0) continue;
      unawaited(_connectAsCentral(peer));
    }
  }

  /// Manual reconnect to a peer by user id. Returns true when the
  /// link is up afterwards. False when the peer is not nearby
  /// (no recent advertisement) or the connect failed.
  Future<bool> reconnectTo(String userId) async {
    final shortId = _userIdToShortId[userId];
    if (shortId == null) return false;
    NearbyPeer? peer;
    for (final p in _peers.values) {
      if (p.shortId == shortId) {
        peer = p;
        break;
      }
    }
    if (peer == null) return false;
    await _connectAsCentral(peer);
    return _links.containsKey(shortId);
  }

  void _onDiscovered(DiscoveredEventArgs e) {
    final parsed = BleProtocol.parseAdvName(e.advertisement.name);
    if (parsed == null) return;
    if (parsed.shortId == identity.shortId) return; // our own advertisement

    final key = e.peripheral.uuid.toString();
    // Smooth the RSSI: raw readings jitter by several dBm per scan.
    final previous = _smoothedRssi[parsed.shortId];
    _smoothedRssi[parsed.shortId] = previous == null
        ? e.rssi.toDouble()
        : previous * 0.7 + e.rssi * 0.3;
    final existing = _peers[key];
    if (existing != null) {
      existing.rssi = e.rssi;
      existing.lastSeen = DateTime.now();
      if (parsed.displayName.isNotEmpty) {
        existing.displayName = parsed.displayName;
      }
    } else {
      _peers[key] = NearbyPeer(
        shortId: parsed.shortId,
        displayName:
            parsed.displayName.isEmpty ? 'Campus user' : parsed.displayName,
        peripheral: e.peripheral,
        rssi: e.rssi,
        lastSeen: DateTime.now(),
        linkUp: _links.containsKey(parsed.shortId),
      );
    }

    // Deterministic tie-break: the larger short id connects as central.
    if (identity.shortId.compareTo(parsed.shortId) > 0) {
      unawaited(_connectAsCentral(_peers[key]!));
    }
    notifyListeners();
  }

  void _prunePeers() {
    final cutoff =
        DateTime.now().subtract(AppConstants.peerStaleAfter);
    final removedShortIds = <String>{};
    _peers.removeWhere((_, p) {
      final stale = p.lastSeen.isBefore(cutoff) && !p.linkUp;
      if (stale) removedShortIds.add(p.shortId);
      return stale;
    });
    // Drop user-id mappings that point at pruned peers so
    // reconnectTo() reports "not nearby" instead of chasing ghosts.
    _userIdToShortId
        .removeWhere((_, shortId) => removedShortIds.contains(shortId));
    notifyListeners();
  }

  // ------------------------------------------------------- central role TX

  Future<void> _connectAsCentral(NearbyPeer peer) async {
    final pkey = peer.peripheral.uuid.toString();
    if (_connecting.contains(pkey) || _links.containsKey(peer.shortId)) return;
    _connecting.add(pkey);
    try {
      await _central.connect(peer.peripheral);
      try {
        await _central.requestMTU(peer.peripheral, mtu: 512);
      } catch (_) {
        // MTU negotiation is best-effort; chunking still works at 23.
      }
      final services = await _central.discoverGATT(peer.peripheral);
      final svcUuid = BleProtocol.serviceUuid.toString();
      final svc = services.firstWhere(
        (s) => s.uuid.toString() == svcUuid,
        orElse: () => throw StateError('Campus Connect service not found'),
      );
      final rxUuid = BleProtocol.rxUuid.toString();
      final txUuid = BleProtocol.txUuid.toString();
      final rx = svc.characteristics
          .firstWhere((c) => c.uuid.toString() == rxUuid);
      final tx = svc.characteristics
          .firstWhere((c) => c.uuid.toString() == txUuid);

      await _central.setCharacteristicNotifyState(peer.peripheral, tx,
          state: true);

      var chunk = 64;
      try {
        final maxWrite = await _central.getMaximumWriteLength(
          peer.peripheral,
          type: GATTCharacteristicWriteType.withResponse,
        );
        chunk = (maxWrite - BleProtocol.frameHeaderLength).clamp(16, 512).toInt();
      } catch (_) {}

      final link = PeerLink(
        shortId: peer.shortId,
        displayName: peer.displayName,
        iAmCentral: true,
        peripheral: peer.peripheral,
        rxChar: rx,
        txChar: tx,
        chunkSize: chunk,
      );
      _links[peer.shortId] = link;
      peer.linkUp = true;

      await _writeToLink(
          link,
          BlePacket.hello(
            from: identity.userId,
            name: identity.displayName,
            shortId: identity.shortId,
          ));
      notifyListeners();
    } catch (_) {
      // Link failed; the next discovery round will retry.
      try {
        await _central.disconnect(peer.peripheral);
      } catch (_) {}
    } finally {
      _connecting.remove(pkey);
    }
  }

  void _onCentralConn(PeripheralConnectionStateChangedEventArgs e) {
    if (e.state == ConnectionState.disconnected) {
      final pkey = e.peripheral.uuid.toString();
      PeerLink? dead;
      for (final link in _links.values) {
        if (link.iAmCentral &&
            link.peripheral?.uuid.toString() == pkey) {
          dead = link;
          break;
        }
      }
      if (dead != null) {
        _links.remove(dead.shortId);
        // Keep the userId → shortId mapping: reconnectTo() needs it
        // to find this peer again. _prunePeers clears it once the
        // peer is gone for good.
        for (final peer in _peers.values) {
          if (peer.shortId == dead.shortId) peer.linkUp = false;
        }
        notifyListeners();
      }
    }
  }

  void _onNotified(GATTCharacteristicNotifiedEventArgs e) {
    if (e.characteristic.uuid.toString() != BleProtocol.txUuid.toString()) {
      return;
    }
    final pkey = e.peripheral.uuid.toString();
    PeerLink? link;
    for (final l in _links.values) {
      if (l.iAmCentral && l.peripheral?.uuid.toString() == pkey) {
        link = l;
        break;
      }
    }
    if (link == null) return;
    final payload = link.reassembler.add(e.value);
    if (payload != null) _handlePacket(link, payload);
  }

  // ---------------------------------------------------- peripheral role RX

  Future<void> _onWriteRequested(
      GATTCharacteristicWriteRequestedEventArgs e) async {
    try {
      await _peripheral.respondWriteRequest(e.request);
    } catch (_) {
      // Best effort: a failed response just means the central retries.
    }
    if (e.characteristic.uuid.toString() != BleProtocol.rxUuid.toString()) {
      return;
    }
    final ckey = e.central.uuid.toString();
    final reassembler =
        _incomingReassemblers.putIfAbsent(ckey, () => FrameReassembler());
    final payload = reassembler.add(e.request.value);
    if (payload == null) return;

    BlePacket packet;
    try {
      packet = BlePacket.decode(payload);
    } catch (_) {
      return;
    }
    if (packet.from == identity.userId) return;

    var link = _linkForCentral(ckey);
    if (link == null) {
      // First contact on this link must be a HELLO carrying the short id.
      if (packet.type != 'hello' ||
          packet.shortId == null ||
          packet.shortId!.isEmpty) {
        return;
      }
      var chunk = 64;
      try {
        final maxNotify =
            await _peripheral.getMaximumNotifyLength(e.central);
        chunk = (maxNotify - BleProtocol.frameHeaderLength).clamp(16, 512).toInt();
      } catch (_) {}
      link = PeerLink(
        shortId: packet.shortId!,
        userId: packet.from,
        displayName: packet.name.isEmpty ? 'Campus user' : packet.name,
        iAmCentral: false,
        central: e.central,
        chunkSize: chunk,
      );
      _links[link.shortId] = link;
      _userIdToShortId[packet.from] = link.shortId;
      // Answer the handshake so the central learns our full identity.
      await _writeToLink(
          link,
          BlePacket.hello(
            from: identity.userId,
            name: identity.displayName,
            shortId: identity.shortId,
          ));
      notifyListeners();
    }
    _handlePacket(link, payload);
  }

  PeerLink? _linkForCentral(String centralKey) {
    for (final link in _links.values) {
      if (!link.iAmCentral && link.central?.uuid.toString() == centralKey) {
        return link;
      }
    }
    return null;
  }

  void _onPeripheralConn(CentralConnectionStateChangedEventArgs e) {
    if (e.state == ConnectionState.disconnected) {
      final ckey = e.central.uuid.toString();
      final link = _linkForCentral(ckey);
      if (link != null) {
        _links.remove(link.shortId);
        // Keep the userId → shortId mapping (see _onCentralConn):
        // reconnectTo() needs it to find this peer again.
        _incomingReassemblers.remove(ckey);
        for (final peer in _peers.values) {
          if (peer.shortId == link.shortId) peer.linkUp = false;
        }
        // Restart advertising: a peripheral stops advertising while
        // connected and does not resume on its own. Without this the
        // other phone can never re-discover us.
        unawaited(_startAdvertising());
        notifyListeners();
      }
    }
  }

  // -------------------------------------------------------------- packets

  void _handlePacket(PeerLink link, Uint8List payload) {
    late BlePacket packet;
    try {
      packet = BlePacket.decode(payload);
    } catch (_) {
      return;
    }
    if (packet.from == identity.userId) return; // ignore our own echo

    // Learn / refresh the peer's full identity.
    if (link.userId == null) {
      link.userId = packet.from;
      _userIdToShortId[packet.from] = link.shortId;
    }
    if (packet.name.isNotEmpty && packet.name != link.displayName) {
      link.displayName = packet.name;
    }

    switch (packet.type) {
      case 'hello':
        break; // identity already recorded above
      case 'msg':
        _incoming.add(packet);
        unawaited(_writeToLink(
            link,
            BlePacket.ack(
              forId: packet.id,
              from: identity.userId,
              name: identity.displayName,
            )));
        break;
      case 'ack':
        _incoming.add(packet);
        break;
      case 'bye':
        break;
      case 'fileStart':
        fileReceiver.handleStart(packet);
        break;
      case 'fileChunk':
        fileReceiver.handleChunk(packet);
        break;
      case 'fileEnd':
        unawaited(_finishIncomingFile(link, packet));
        break;
      case 'groupMsg':
        _incoming.add(packet);
        unawaited(_writeToLink(
            link,
            BlePacket.ack(
              forId: packet.id,
              from: identity.userId,
              name: identity.displayName,
            )));
        break;
      case 'edit':
      case 'delete':
      case 'react':
        // Message actions: apply on the receiver, ack like a message.
        _incoming.add(packet);
        unawaited(_writeToLink(
            link,
            BlePacket.ack(
              forId: packet.id,
              from: identity.userId,
              name: identity.displayName,
            )));
        break;
    }
    notifyListeners();
  }

  /// Assembles an incoming file transfer, saves it, emits a synthetic
  /// `file` packet for the repository, and acks the transfer id so the
  /// sender can mark its file message delivered.
  Future<void> _finishIncomingFile(PeerLink link, BlePacket packet) async {
    final completed = fileReceiver.handleEnd(packet);
    if (completed == null) return; // incomplete or corrupt transfer
    late final String path;
    try {
      path = await FileStorage.saveIncoming(
        fileName: completed.fileName,
        bytes: completed.bytes,
      );
    } catch (_) {
      return;
    }
    _incoming.add(BlePacket.file(
      transferId: packet.id,
      from: completed.from,
      name: completed.name,
      ts: completed.ts,
      fileName: completed.fileName,
      fileSize: completed.fileSize,
      mimeType: completed.mimeType,
      filePath: path,
    ));
    await _writeToLink(
        link,
        BlePacket.ack(
          forId: packet.id,
          from: identity.userId,
          name: identity.displayName,
        ));
  }

  Future<void> _writeToLink(PeerLink link, BlePacket packet) async {
    final frames =
        FrameCodec.encode(packet.encode(), chunkSize: link.chunkSize);
    if (link.iAmCentral) {
      final peripheral = link.peripheral!;
      final rx = link.rxChar!;
      for (final frame in frames) {
        await _central.writeCharacteristic(
          peripheral,
          rx,
          value: frame,
          type: GATTCharacteristicWriteType.withResponse,
        );
      }
    } else {
      final central = link.central!;
      for (final frame in frames) {
        await _peripheral.notifyCharacteristic(
          central,
          _hostTxChar,
          value: frame,
        );
      }
    }
  }

  /// Sends [packet] to the phone owned by [userId].
  /// Returns false when there is no live link to that user.
  Future<bool> sendTo(String userId, BlePacket packet) async {
    final link = linkForUser(userId);
    if (link == null) return false;
    try {
      await _writeToLink(link, packet);
      return true;
    } catch (_) {
      return false;
    }
  }
}
