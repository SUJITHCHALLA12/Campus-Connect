import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:open_filex/open_filex.dart';
import 'package:path_provider/path_provider.dart';

import 'ble_protocol.dart';

/// File sharing over BLE.
///
/// Files move as a sequence of packets on the existing BLE link:
/// `fileStart` (name/size/mime) → `fileChunk` (base64, 8 KB raw each) →
/// `fileEnd`. The receiver assembles the bytes, saves them to the app's
/// documents directory, and the transport emits a synthetic `file`
/// packet so the chat stores one file message.
///
/// Limits: BLE throughput is low (each frame is a separate GATT write),
/// so files are capped at 1 MB. Anything bigger is refused with a
/// snackbar on the sender side before a single byte goes over the air.
abstract final class FileTransferConfig {
  /// Maximum file size accepted for transfer (1 MB).
  static const int maxFileSize = 1024 * 1024;

  /// Raw bytes per `fileChunk` packet.
  /// Max raw bytes per fileChunk packet. 1 KB keeps the base64 JSON
  /// packet (~1.5 KB) under the framing cap of 255 frames even at the
  /// MTU-23 minimum (8 payload bytes/frame → 255 × 8 = 2040 bytes).
  /// Larger chunks would silently truncate on low-MTU links.
  static const int chunkBytes = 1024;
}

/// Sends a packet over the BLE link. Implemented by the chat screen as
/// `(packet) => ble.sendTo(peerUserId, packet)`. Kept as a callback so
/// this file never imports the transport (no import cycle).
typedef PacketSender = Future<bool> Function(BlePacket packet);

abstract final class FileTransferService {
  FileTransferService._();

  /// Sends [bytes] as a chunked file transfer. Throws [StateError] if
  /// the link drops mid-transfer. Reports 0.0–1.0 progress per chunk.
  static Future<void> sendFile({
    required PacketSender send,
    required String from,
    required String name,
    required String transferId,
    required String fileName,
    required Uint8List bytes,
    required String mimeType,
    void Function(double progress)? onProgress,
  }) async {
    final startOk = await send(BlePacket.fileStart(
      transferId: transferId,
      from: from,
      name: name,
      fileName: fileName,
      fileSize: bytes.length,
      mimeType: mimeType,
    ));
    if (!startOk) throw StateError('No link to peer');

    final totalChunks =
        (bytes.length / FileTransferConfig.chunkBytes).ceil();
    for (var i = 0; i < totalChunks; i++) {
      final start = i * FileTransferConfig.chunkBytes;
      final end = min(start + FileTransferConfig.chunkBytes, bytes.length);
      final chunk = base64Encode(bytes.sublist(start, end));
      final ok = await send(BlePacket.fileChunk(
        transferId: transferId,
        from: from,
        name: name,
        seq: i,
        data: chunk,
      ));
      if (!ok) throw StateError('Link lost during transfer');
      onProgress?.call((i + 1) / totalChunks);
    }

    final endOk = await send(BlePacket.fileEnd(
      transferId: transferId,
      from: from,
      name: name,
    ));
    if (!endOk) throw StateError('Link lost finishing transfer');
  }
}

/// One in-progress incoming transfer, held by [FileReceiver].
class _IncomingFile {
  final String fileName;
  final int fileSize;
  final String mimeType;
  final String from;
  final String name;
  final int ts;
  final Map<int, Uint8List> chunks = {};

  _IncomingFile({
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.from,
    required this.name,
    required this.ts,
  });
}

/// A fully assembled incoming file, ready to save.
class CompletedFile {
  final String fileName;
  final int fileSize;
  final String mimeType;
  final String from;
  final String name;
  final int ts;
  final Uint8List bytes;

  CompletedFile({
    required this.fileName,
    required this.fileSize,
    required this.mimeType,
    required this.from,
    required this.name,
    required this.ts,
    required this.bytes,
  });
}

/// Collects `fileStart` / `fileChunk` / `fileEnd` packets and assembles
/// the file. One instance lives in [BleChatService]-adjacent transport
/// code; it holds no transport references itself.
class FileReceiver {
  final Map<String, _IncomingFile> _incoming = {};

  void handleStart(BlePacket packet) {
    if (packet.fileName == null || packet.fileSize == null) return;
    if (packet.fileSize! > FileTransferConfig.maxFileSize) return;
    _incoming[packet.id] = _IncomingFile(
      fileName: packet.fileName!,
      fileSize: packet.fileSize!,
      mimeType: packet.mimeType ?? 'application/octet-stream',
      from: packet.from,
      name: packet.name,
      ts: packet.ts,
    );
  }

  void handleChunk(BlePacket packet) {
    final file = _incoming[packet.id];
    if (file == null || packet.seq == null || packet.data == null) return;
    try {
      file.chunks[packet.seq!] = base64Decode(packet.data!);
    } catch (_) {
      // Corrupt chunk: drop it; the transfer fails completeness at end.
    }
  }

  /// Returns the assembled file once every chunk has arrived, else null.
  CompletedFile? handleEnd(BlePacket packet) {
    final file = _incoming.remove(packet.id);
    if (file == null) return null;
    final totalChunks =
        (file.fileSize / FileTransferConfig.chunkBytes).ceil();
    if (file.chunks.length != totalChunks) return null;
    final out = <int>[];
    for (var i = 0; i < totalChunks; i++) {
      final chunk = file.chunks[i];
      if (chunk == null) return null;
      out.addAll(chunk);
    }
    final bytes = Uint8List.fromList(out);
    if (bytes.length != file.fileSize) return null;
    return CompletedFile(
      fileName: file.fileName,
      fileSize: file.fileSize,
      mimeType: file.mimeType,
      from: file.from,
      name: file.name,
      ts: file.ts,
      bytes: bytes,
    );
  }
}

/// Persists received files and opens them with the platform viewer.
abstract final class FileStorage {
  FileStorage._();

  /// Saves [bytes] under the app documents `received/` folder, making
  /// the filename unique if one already exists. Returns the full path.
  static Future<String> saveIncoming({
    required String fileName,
    required Uint8List bytes,
  }) async {
    final dir = await getApplicationDocumentsDirectory();
    final received = Directory('${dir.path}/received');
    if (!await received.exists()) {
      await received.create(recursive: true);
    }
    final safe = fileName.replaceAll(RegExp(r'[\\/:*?"<>|]'), '_');
    var target = File('${received.path}/$safe');
    var n = 1;
    while (await target.exists()) {
      final dot = safe.lastIndexOf('.');
      final stem = dot > 0 ? safe.substring(0, dot) : safe;
      final ext = dot > 0 ? safe.substring(dot) : '';
      target = File('${received.path}/${stem}_$n$ext');
      n++;
    }
    await target.writeAsBytes(bytes);
    return target.path;
  }

  /// Opens [path] with the platform's default app for its type.
  static Future<void> open(String path) async {
    await OpenFilex.open(path);
  }
}

/// Human-readable file size: `842 B`, `312.5 KB`, `1.0 MB`.
String formatFileSize(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) {
    return '${(bytes / 1024).toStringAsFixed(1)} KB';
  }
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
}

/// Best-effort MIME type from a file extension.
String mimeForFileName(String name) {
  final ext = name.split('.').last.toLowerCase();
  switch (ext) {
    case 'jpg':
    case 'jpeg':
      return 'image/jpeg';
    case 'png':
      return 'image/png';
    case 'gif':
      return 'image/gif';
    case 'webp':
      return 'image/webp';
    case 'mp4':
      return 'video/mp4';
    case 'pdf':
      return 'application/pdf';
    case 'txt':
      return 'text/plain';
    case 'zip':
      return 'application/zip';
    default:
      return 'application/octet-stream';
  }
}
