import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:flutter/services.dart';
import 'package:nearby_connections/nearby_connections.dart';
import 'package:permission_handler/permission_handler.dart';

import '../ble/ble_transport.dart';
import '../ble/file_transfer.dart';
import '../core/identity.dart';
import '../data/chat_repository.dart';
import '../data/models.dart';

/// Fast file transfer: Nearby Connections first, raw Wi-Fi Direct
/// second, BLE last. Chat text, reactions and all signalling stay on
/// BLE — only file bytes move over the fast paths.
///
/// Why three paths: BLE file transfer is slow (each frame is a separate
/// GATT write, 1 MB cap). Nearby Connections is the same transport
/// Quick Share uses — BLE for discovery/handshake, then an automatic
/// upgrade to a high-throughput Wi-Fi / Bluetooth socket for the
/// bytes. Raw Wi-Fi Direct is the fallback when Nearby is unavailable
/// or fails. BLE stays the last resort so file sending never breaks
/// outright.
///
/// Caps: fast paths allow up to 100 MB; BLE fallback keeps the 1 MB
/// cap, so a big file whose fast paths both fail is reported as
/// failed rather than silently truncated.
///
/// Trust model: same as the BLE chat — any nearby phone running the
/// app can connect (Nearby connections are auto-accepted; the
/// authentication token is NOT verified, matching the plaintext v1
/// posture). Incoming files are stored in the conversation of the
/// sender id carried in the transfer metadata.
abstract final class FastTransferConfig {
  /// Fast-path cap: 100 MB. Enforced on the sender before any byte
  /// moves. BLE fallback keeps the 1 MB cap (see [FileTransferConfig]).
  static const int fastMaxFileSize = 100 * 1024 * 1024;

  /// Nearby Connections service id — must match on both phones.
  static const String serviceId = 'com.sujithchalla.campusconnect';

  /// MethodChannel for the raw Wi-Fi Direct fallback (see
  /// WifiDirectHelper.kt). Same value on both sides of the channel.
  static const String wifiDirectChannel =
      'com.sujithchalla.campusconnect/wifi_direct';

  /// How long the sender waits for the peer's Nearby endpoint to
  /// show up in discovery before giving up on Nearby.
  static const Duration nearbyDiscoveryTimeout = Duration(seconds: 10);

  /// How long the sender waits for a Nearby connection result.
  static const Duration nearbyConnectTimeout = Duration(seconds: 15);

  /// How long one payload may take (100 MB over Wi-Fi).
  static const Duration payloadTimeout = Duration(minutes: 10);

  /// Total budget for one Wi-Fi Direct attempt (discover + connect +
  /// send) before falling back to BLE.
  static const Duration wifiDirectTimeout = Duration(seconds: 120);
}

/// One outgoing fast transfer, keyed by Nearby payload id.
class _PendingSend {
  final String transferId;
  final void Function(double progress)? onProgress;
  final Completer<bool> done = Completer<bool>();

  _PendingSend({required this.transferId, this.onProgress});
}

/// One incoming Nearby file transfer, keyed by Nearby payload id.
/// The metadata (BYTES payload), the file uri (FILE payload) and the
/// SUCCESS transfer update can arrive in any order, so the transfer
/// completes only once all three are present.
class _PendingReceive {
  Map<String, dynamic>? meta;
  String? uri;
  bool success = false;
}

/// Fast file transfer service.
///
/// Created in `main.dart`, started from the home screen once the
/// identity exists (advertising + discovery + the Wi-Fi Direct
/// receiver all need the local user id). Idempotent: repeated
/// `start()` calls are no-ops.
class FastFileTransferService {
  FastFileTransferService({
    required IdentityStore identity,
    required ChatRepository repository,
    required BleChatService ble,
  })  : _identity = identity,
        _repository = repository,
        _ble = ble;

  final IdentityStore _identity;
  final ChatRepository _repository;
  final BleChatService _ble;

  final Nearby _nearby = Nearby();
  final MethodChannel _wifiDirect =
      const MethodChannel(FastTransferConfig.wifiDirectChannel);

  bool _started = false;
  bool _nearbyRunning = false;

  /// Discovered Nearby endpoints: peer userId → endpoint id.
  final Map<String, String> _discovered = {};

  /// Endpoints already accepted (avoid double-accept).
  final Set<String> _accepted = {};

  /// Outstanding Nearby connection results, by endpoint id.
  final Map<String, Completer<bool>> _connectionResults = {};

  final Map<int, _PendingSend> _pendingSends = {};
  final Map<int, _PendingReceive> _pendingReceives = {};

  /// Outstanding Wi-Fi Direct sends, by transfer id (for progress).
  final Map<String, void Function(double progress)?> _wifiDirectSends = {};

  /// Requests the runtime permissions the fast paths need, best
  /// effort. BLE permissions are NOT handled here (home screen owns
  /// those) and a denial here never blocks BLE chat — the fast paths
  /// simply fail and BLE fallback covers file sending.
  ///
  /// Android 13+: NEARBY_WIFI_DEVICES. Android 10–12: location is
  /// required for Nearby / Wi-Fi Direct discovery.
  Future<void> ensurePermissions() async {
    if (!Platform.isAndroid) return;
    try {
      final info = await DeviceInfoPlugin().androidInfo;
      final sdk = info.version.sdkInt;
      if (sdk >= 33) {
        await Permission.nearbyWifiDevices.request();
      } else if (sdk >= 29) {
        await Permission.locationWhenInUse.request();
      }
    } catch (_) {
      // Best effort — denial just means the fast paths will fail.
    }
  }

  /// Starts advertising + discovery (Nearby) and the Wi-Fi Direct
  /// receiver. Safe to call repeatedly; safe to call before the
  /// identity exists (it just waits — see home screen, which calls
  /// this after onboarding).
  Future<void> start() async {
    if (_started) return;
    if (!_identity.hasIdentity) return;
    _started = true;
    await ensurePermissions();

    // Incoming Wi-Fi Direct files / progress, from WifiDirectHelper.
    _wifiDirect.setMethodCallHandler(_onWifiDirectCall);

    try {
      await _wifiDirect.invokeMethod(
        'startReceiver',
        {'userId': _identity.userId},
      );
    } catch (_) {
      // Wi-Fi Direct unavailable (no Wi-Fi, no P2P support) — the
      // Nearby + BLE paths still work.
    }

    await _ensureNearby();
  }

  // ─── Send ───────────────────────────────────────────────────

  /// Sends a file to [peerUserId], trying Nearby, then Wi-Fi Direct,
  /// then BLE. Returns true when any path delivered it.
  ///
  /// [bytes] is the file contents for the BLE fallback only — pass
  /// null for files over 1 MB (BLE refuses them anyway) so a 100 MB
  /// file is never loaded into memory just for the fallback.
  /// [kind] is `voice` for voice notes so the receiver renders a
  /// player bubble; otherwise `file`.
  Future<bool> sendFile({
    required String peerUserId,
    required String filePath,
    required String fileName,
    required String mimeType,
    required String transferId,
    required int fileSize,
    Uint8List? bytes,
    String? groupId,
    MessageKind kind = MessageKind.file,
    void Function(double progress)? onProgress,
  }) async {
    if (await _tryNearby(
      peerUserId: peerUserId,
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType,
      transferId: transferId,
      fileSize: fileSize,
      groupId: groupId,
      kind: kind,
      onProgress: onProgress,
    )) {
      return true;
    }
    if (await _tryWifiDirect(
      peerUserId: peerUserId,
      filePath: filePath,
      fileName: fileName,
      mimeType: mimeType,
      transferId: transferId,
      fileSize: fileSize,
      groupId: groupId,
      kind: kind,
      onProgress: onProgress,
    )) {
      return true;
    }
    return _tryBle(
      peerUserId: peerUserId,
      fileName: fileName,
      mimeType: mimeType,
      transferId: transferId,
      bytes: bytes,
      groupId: groupId,
      onProgress: onProgress,
    );
  }

  // ─── Nearby Connections ───────────────────────────────────────

  Future<void> _ensureNearby() async {
    if (_nearbyRunning) return;
    try {
      final userId = _identity.userId;
      final advertising = await _nearby.startAdvertising(
        userId,
        Strategy.P2P_POINT_TO_POINT,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
        serviceId: FastTransferConfig.serviceId,
      );
      final discovering = await _nearby.startDiscovery(
        userId,
        Strategy.P2P_POINT_TO_POINT,
        onEndpointFound: _onEndpointFound,
        onEndpointLost: _onEndpointLost,
        serviceId: FastTransferConfig.serviceId,
      );
      _nearbyRunning = advertising && discovering;
    } catch (_) {
      _nearbyRunning = false;
    }
  }

  void _onEndpointFound(String endpointId, String endpointName, String _) {
    // Endpoint name IS the peer's user id (see _ensureNearby), so the
    // sender connects to exactly the intended peer, not any nearby
    // phone running the app.
    _discovered[endpointName] = endpointId;
  }

  void _onEndpointLost(String endpointId) {
    _discovered.removeWhere((_, id) => id == endpointId);
  }

  void _onConnectionInitiated(String endpointId, dynamic info) {
    // Auto-accept: same trust model as the BLE chat (any nearby phone
    // running the app may connect; the auth token is not verified).
    if (_accepted.contains(endpointId)) return;
    _accepted.add(endpointId);
    try {
      _nearby.acceptConnection(
        endpointId,
        onPayLoadRecieved: _onNearbyPayload,
        onPayloadTransferUpdate: _onNearbyTransferUpdate,
      );
    } catch (_) {
      _accepted.remove(endpointId);
    }
  }

  void _onConnectionResult(String endpointId, dynamic status) {
    final completer = _connectionResults.remove(endpointId);
    completer?.complete(_statusOk(status));
  }

  void _onDisconnected(String endpointId) {
    _accepted.remove(endpointId);
    _connectionResults
        .remove(endpointId)
        ?.complete(false);
  }

  /// Best-effort connection-result check. The plugin's `Status`
  /// shape is not pinned down by its published API docs, so accept
  /// the common shapes and treat "callback fired" as success —
  /// the payload send right after is the real check (it throws when
  /// the connection was actually rejected).
  bool _statusOk(dynamic status) {
    try {
      final code = (status as dynamic).statusCodes;
      if (code is int) return code == 0;
    } catch (_) {}
    try {
      final code = (status as dynamic).statusCode;
      if (code is int) return code == 0;
    } catch (_) {}
    if (status is bool) return status;
    return true;
  }

  Future<bool> _tryNearby({
    required String peerUserId,
    required String filePath,
    required String fileName,
    required String mimeType,
    required String transferId,
    required int fileSize,
    String? groupId,
    required MessageKind kind,
    void Function(double progress)? onProgress,
  }) async {
    try {
      await _ensureNearby();
      if (!_nearbyRunning) return false;

      // Wait for the peer's endpoint to show up in discovery.
      String? endpointId;
      final deadline = DateTime.now()
          .add(FastTransferConfig.nearbyDiscoveryTimeout);
      while (endpointId == null && DateTime.now().isBefore(deadline)) {
        endpointId = _discovered[peerUserId];
        if (endpointId == null) {
          await Future.delayed(const Duration(milliseconds: 500));
        }
      }
      if (endpointId == null) return false;

      final result = Completer<bool>();
      _connectionResults[endpointId] = result;
      final requested = await _nearby.requestConnection(
        _identity.userId,
        endpointId,
        onConnectionInitiated: _onConnectionInitiated,
        onConnectionResult: _onConnectionResult,
        onDisconnected: _onDisconnected,
      );
      if (!requested) {
        _connectionResults.remove(endpointId);
        return false;
      }
      final connected = await result.future.timeout(
        FastTransferConfig.nearbyConnectTimeout,
        onTimeout: () => false,
      );
      if (!connected) {
        try {
          await _nearby.disconnectFromEndpoint(endpointId);
        } catch (_) {}
        return false;
      }

      // File payload first, then the metadata BYTES payload carrying
      // its payload id (the plugin's documented pattern). The
      // receiver correlates the two by payload id.
      final payloadId = await _nearby
          .sendFilePayload(endpointId, filePath)
          .timeout(FastTransferConfig.payloadTimeout);
      final pending = _PendingSend(
        transferId: transferId,
        onProgress: onProgress,
      );
      _pendingSends[payloadId] = pending;
      bool ok = false;
      try {
        final meta = jsonEncode({
          'magic': 'CCFAST',
          'payloadId': payloadId,
          'transferId': transferId,
          'fileName': fileName,
          'mimeType': mimeType,
          'groupId': groupId,
          'senderId': _identity.userId,
          'senderName': _identity.displayName,
          'ts': DateTime.now().millisecondsSinceEpoch,
          'kind': kind == MessageKind.voice ? 'voice' : 'file',
        });
        await _nearby.sendBytesPayload(
          endpointId,
          Uint8List.fromList(utf8.encode(meta)),
        );

        ok = await pending.done.future.timeout(
          FastTransferConfig.payloadTimeout,
          onTimeout: () => false,
        );
      } catch (_) {
        ok = false;
      } finally {
        _pendingSends.remove(payloadId);
      }
      try {
        await _nearby.disconnectFromEndpoint(endpointId);
      } catch (_) {}
      return ok;
    } catch (_) {
      return false;
    }
  }

  void _onNearbyPayload(String endpointId, dynamic payload) {
    try {
      final type = (payload as dynamic).type;
      if (type == PayloadType.BYTES) {
        final raw = (payload as dynamic).bytes;
        if (raw == null) return;
        final text = utf8.decode(Uint8List.fromList(raw as List<int>));
        final map = jsonDecode(text);
        if (map is! Map || map['magic'] != 'CCFAST') return;
        final payloadId = map['payloadId'];
        if (payloadId is! int) return;
        final pending =
            _pendingReceives.putIfAbsent(payloadId, () => _PendingReceive());
        pending.meta = Map<String, dynamic>.from(map);
        _maybeCompleteNearbyReceive(payloadId);
      } else if (type == PayloadType.FILE) {
        // `uri` is exposed since nearby_connections 3.1.0 (replacing
        // the deprecated `filePath`). Accessed via dynamic because
        // its static type (String vs Uri) is not pinned by the docs.
        final uriRaw = (payload as dynamic).uri;
        final uri = uriRaw?.toString() ?? '';
        if (uri.isEmpty) return;
        // The payload id is not in the published docs; try it first
        // for exact pairing, else fall back to uri-keyed pairing
        // (see _maybeCompleteNearbyReceive).
        int? payloadId;
        try {
          payloadId = (payload as dynamic).id as int?;
        } catch (_) {}
        if (payloadId != null) {
          final pending = _pendingReceives.putIfAbsent(
            payloadId,
            () => _PendingReceive(),
          );
          pending.uri = uri;
          _maybeCompleteNearbyReceive(payloadId);
        } else {
          _unpairedReceiveUris.add(uri);
        }
      }
    } catch (_) {
      // A malformed payload must not kill the receiver.
    }
  }

  /// FILE uris whose payload object carried no id (fallback pairing).
  /// Nearby delivers one file at a time per connection in this app
  /// (the sender disconnects after each transfer), so the single
  /// unpaired uri belongs to the completing receive.
  final List<String> _unpairedReceiveUris = [];

  void _onNearbyTransferUpdate(String endpointId, dynamic update) {
    try {
      final id = (update as dynamic).id as int?;
      final transferred = (update as dynamic).bytesTransferred as int?;
      final total = (update as dynamic).totalBytes as int?;
      final status = (update as dynamic).status;
      if (id == null) return;

      final send = _pendingSends[id];
      if (send != null) {
        if (transferred != null &&
            total != null &&
            total > 0 &&
            send.onProgress != null) {
          send.onProgress!(transferred / total);
        }
        if (status == PayloadStatus.SUCCESS) {
          if (!send.done.isCompleted) send.done.complete(true);
        } else if (status == PayloadStatus.FAILURE) {
          if (!send.done.isCompleted) send.done.complete(false);
        }
        return;
      }

      // Receiver side: SUCCESS for a payload id means the file at
      // the pending receive's uri is complete. Create the entry if
      // the SUCCESS update beat the payload objects here.
      final receive = _pendingReceives.putIfAbsent(id, () => _PendingReceive());
      if (status == PayloadStatus.SUCCESS) {
        receive.success = true;
        _maybeCompleteNearbyReceive(id);
      } else if (status == PayloadStatus.FAILURE) {
        _pendingReceives.remove(id);
      }
    } catch (_) {}
  }

  Future<void> _maybeCompleteNearbyReceive(int payloadId) async {
    final receive = _pendingReceives[payloadId];
    if (receive == null || !receive.success) return;
    final meta = receive.meta;
    var uri = receive.uri;
    // Fall back to the unpaired-uri list when the FILE payload
    // object carried no id (see _onNearbyPayload).
    uri ??= _takeUnpairedReceiveUri();
    if (meta == null || uri == null || uri.isEmpty) return;
    _pendingReceives.remove(payloadId);

    try {
      final fileName = meta['fileName'] as String? ?? 'file';
      final target = await FileStorage.uniqueReceivedPath(fileName);
      final copied =
          await _nearby.copyFileAndDeleteOriginal(uri, target);
      if (!copied) return;
      final size = await File(target).length();
      await _repository.saveIncomingFastFile(
        transferId: meta['transferId'] as String? ?? '',
        from: meta['senderId'] as String? ?? '',
        senderName: meta['senderName'] as String? ?? '',
        fileName: fileName,
        fileSize: size,
        mimeType: meta['mimeType'] as String? ?? 'application/octet-stream',
        filePath: target,
        ts: meta['ts'] as int? ?? DateTime.now().millisecondsSinceEpoch,
        groupId: meta['groupId'] as String?,
        kind: meta['kind'] == 'voice' ? MessageKind.voice : MessageKind.file,
      );
    } catch (_) {
      // A failed receive must not kill the receiver.
    }
  }

  /// Takes (and removes) one unpaired FILE uri, if any.
  String? _takeUnpairedReceiveUri() {
    if (_unpairedReceiveUris.isEmpty) return null;
    return _unpairedReceiveUris.removeAt(0);
  }

  // ─── Wi-Fi Direct (MethodChannel fallback) ────────────────────

  Future<bool> _tryWifiDirect({
    required String peerUserId,
    required String filePath,
    required String fileName,
    required String mimeType,
    required String transferId,
    required int fileSize,
    String? groupId,
    required MessageKind kind,
    void Function(double progress)? onProgress,
  }) async {
    try {
      return await _tryWifiDirectInner(
        peerUserId: peerUserId,
        filePath: filePath,
        fileName: fileName,
        mimeType: mimeType,
        transferId: transferId,
        fileSize: fileSize,
        groupId: groupId,
        kind: kind,
        onProgress: onProgress,
      ).timeout(
        FastTransferConfig.wifiDirectTimeout,
        onTimeout: () => false,
      );
    } catch (_) {
      return false;
    }
  }

  Future<bool> _tryWifiDirectInner({
    required String peerUserId,
    required String filePath,
    required String fileName,
    required String mimeType,
    required String transferId,
    required int fileSize,
    String? groupId,
    required MessageKind kind,
    void Function(double progress)? onProgress,
  }) async {
    try {
      final peersRaw =
          await _wifiDirect.invokeMethod('discoverPeers').timeout(
                const Duration(seconds: 10),
              );
      final peers = (peersRaw as List?) ?? const [];
      for (final peer in peers) {
        if (peer is! Map) continue;
        final address = peer['deviceAddress'] as String?;
        if (address == null || address.isEmpty) continue;
        final infoRaw = await _wifiDirect.invokeMethod('connect', {
          'deviceAddress': address,
        }).timeout(const Duration(seconds: 30));
        final info = (infoRaw as Map?) ?? const {};
        if (info['connected'] != true) continue;
        try {
          // Sender-as-group-owner cannot work here: the receiver's
          // IP is unknown in that case (only the group owner's IP,
          // 192.168.49.1, is well-known). Skip this candidate — BLE
          // fallback covers it.
          if (info['isGroupOwner'] == true) continue;
          final host = info['groupOwnerAddress'] as String?;
          if (host == null || host.isEmpty) continue;
          _wifiDirectSends[transferId] = onProgress;
          final ok = await _wifiDirect.invokeMethod('sendFile', {
            'hostIp': host,
            'filePath': filePath,
            'fileName': fileName,
            'mimeType': mimeType,
            'groupId': groupId,
            'targetUserId': peerUserId,
            'senderId': _identity.userId,
            'senderName': _identity.displayName,
            'transferId': transferId,
            'ts': DateTime.now().millisecondsSinceEpoch,
            'kind': kind == MessageKind.voice ? 'voice' : 'file',
            'fileSize': fileSize,
          }).timeout(FastTransferConfig.payloadTimeout);
          if (ok == true) return true;
        } finally {
          try {
            await _wifiDirect.invokeMethod('disconnect');
          } catch (_) {}
          _wifiDirectSends.remove(transferId);
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Calls from WifiDirectHelper.kt: `onWifiDirectFile` (a complete
  /// incoming file) and `onWifiDirectProgress` (send progress).
  Future<void> _onWifiDirectCall(MethodCall call) async {
    try {
      switch (call.method) {
        case 'onWifiDirectFile':
          final args = (call.arguments as Map?) ?? const {};
          final sourcePath = args['path'] as String?;
          if (sourcePath == null || sourcePath.isEmpty) return;
          final fileName = args['fileName'] as String? ?? 'file';
          final target = await FileStorage.saveIncomingPath(
            sourcePath: sourcePath,
            fileName: fileName,
          );
          await _repository.saveIncomingFastFile(
            transferId: args['transferId'] as String? ?? '',
            from: args['senderId'] as String? ?? '',
            senderName: args['senderName'] as String? ?? '',
            fileName: fileName,
            fileSize: args['fileSize'] as int? ?? 0,
            mimeType:
                args['mimeType'] as String? ?? 'application/octet-stream',
            filePath: target,
            ts: args['ts'] as int? ??
                DateTime.now().millisecondsSinceEpoch,
            groupId: args['groupId'] as String?,
            kind: args['kind'] == 'voice'
                ? MessageKind.voice
                : MessageKind.file,
          );
        case 'onWifiDirectProgress':
          final args = (call.arguments as Map?) ?? const {};
          final transferId = args['transferId'] as String?;
          final sent = args['bytesSent'] as int?;
          final total = args['totalBytes'] as int?;
          if (transferId == null || sent == null || total == null) return;
          if (total <= 0) return;
          _wifiDirectSends[transferId]?.call(sent / total);
      }
    } catch (_) {
      // A bad native callback must not kill the receiver.
    }
  }

  // ─── BLE fallback ─────────────────────────────────────────────

  Future<bool> _tryBle({
    required String peerUserId,
    required String fileName,
    required String mimeType,
    required String transferId,
    required Uint8List? bytes,
    String? groupId,
    void Function(double progress)? onProgress,
  }) async {
    if (bytes == null) return false;
    if (bytes.length > FileTransferConfig.maxFileSize) return false;
    try {
      await FileTransferService.sendFile(
        send: (packet) => _ble.sendTo(peerUserId, packet),
        from: _identity.userId,
        name: _identity.displayName,
        transferId: transferId,
        fileName: fileName,
        bytes: bytes,
        mimeType: mimeType,
        groupId: groupId,
        onProgress: onProgress,
      );
      return true;
    } catch (_) {
      return false;
    }
  }
}
