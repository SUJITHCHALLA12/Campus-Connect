import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:bluetooth_low_energy/bluetooth_low_energy.dart';
import 'package:uuid/uuid.dart';

/// Wire protocol for the Campus Connect BLE transport (v1).
///
/// Role model: every phone runs BOTH roles at once —
///   * peripheral: hosts the Campus Connect GATT service and advertises it
///   * central:    scans for the service and connects to nearby phones
///
/// Exactly one BLE link exists per pair of phones. The tie-break is
/// deterministic: the phone whose advertised short id compares GREATER
/// connects as central; the other side only accepts the incoming link.
///
/// Characteristic direction:
///   * RX (central --write--> peripheral)
///   * TX (peripheral --notify--> central)
///
/// SECURITY NOTE (v1): packets are plaintext. The frame header reserves a
/// version byte so a future version can negotiate ECDH + AES-GCM without
/// changing the framing. Do not describe v1 as end-to-end encrypted.
abstract final class BleProtocol {
  static final UUID serviceUuid =
      UUID.fromString('f2a7b1c0-9d3e-4f5a-8b6c-1d2e3f4a5b6c');
  static final UUID rxUuid =
      UUID.fromString('f2a7b1c1-9d3e-4f5a-8b6c-1d2e3f4a5b6c');
  static final UUID txUuid =
      UUID.fromString('f2a7b1c2-9d3e-4f5a-8b6c-1d2e3f4a5b6c');

  static const String advPrefix = 'CC';

  /// Frame layout (see docs/PROTOCOL.md):
  ///   [0]    magic 0xCC
  ///   [1]    version 0x01
  ///   [2..9] message id (8 random bytes)
  ///   [10]   total chunk count (1..255)
  ///   [11]   chunk index (0-based)
  ///   [12..] payload bytes
  static const int frameMagic = 0xCC;
  static const int frameVersion = 0x01;
  static const int frameHeaderLength = 12;
  static const int maxChunks = 255;

  /// Builds the BLE advertising name: "CC:<8-char id>:<display name>".
  /// The stack may truncate it; the full identity always arrives via HELLO.
  static String advName(String shortId, String displayName) {
    final name = displayName.replaceAll(':', ' ').trim();
    final clipped = name.length > 10 ? name.substring(0, 10) : name;
    return '$advPrefix:$shortId:$clipped';
  }

  /// Parses an advertising name back into (shortId, displayName).
  /// Returns null when the advertisement is not a Campus Connect phone.
  static ({String shortId, String displayName})? parseAdvName(String? raw) {
    if (raw == null || raw.isEmpty) return null;
    final parts = raw.split(':');
    if (parts.length < 3 || parts[0] != advPrefix) return null;
    if (parts[1].length != 8) return null;
    return (shortId: parts[1], displayName: parts.sublist(2).join(':'));
  }
}

/// A logical packet exchanged over a BLE link.
///
/// JSON-encoded, then split into frames by [FrameCodec]. Types:
///   * hello — identity exchange right after connect (carries shortId too)
///   * msg   — a chat message
///   * ack   — delivery acknowledgement for a msg id
///   * bye   — graceful link teardown notice
///   * fileStart — begins a file transfer (carries name, size, mime)
///   * fileChunk — one base64 chunk of a file transfer (carries seq, data)
///   * fileEnd — ends a file transfer; the receiver assembles + saves it
///   * file  — synthetic packet the transport emits to the repository
///             once an incoming file is saved (carries the local path)
///   * groupMsg — a message to a group chat (carries group id, name and
///             the member map so a receiver can create the group)
///   * edit — replaces the text of a message the sender authored
///             (carries the edited message's id; only the author may
///             edit, and only within 5 minutes of sending)
///   * delete — deletes a message the sender authored everywhere
///             (carries the deleted message's id)
///   * react — a reaction to a message (carries the message id + emoji;
///             sending the same emoji again removes the reaction)
class BlePacket {
  final String type;
  final String id;
  final String from;
  final String name;
  final int ts;
  final String? text;
  final String? shortId;
  final String? fileName;
  final int? fileSize;
  final String? mimeType;
  final String? filePath;
  final int? seq;
  final String? data;
  final String? groupId;
  final String? groupName;
  final Map<String, String>? members;
  final String? editId;
  final String? deleteId;
  final String? reactId;
  final String? reactEmoji;
  final String? replyToId;
  final String? replyToText;
  final String? replyToSender;
  final bool forwarded;

  BlePacket({
    required this.type,
    required this.id,
    required this.from,
    required this.name,
    required this.ts,
    this.text,
    this.shortId,
    this.fileName,
    this.fileSize,
    this.mimeType,
    this.filePath,
    this.seq,
    this.data,
    this.groupId,
    this.groupName,
    this.members,
    this.editId,
    this.deleteId,
    this.reactId,
    this.reactEmoji,
    this.replyToId,
    this.replyToText,
    this.replyToSender,
    this.forwarded = false,
  });

  factory BlePacket.hello({
    required String from,
    required String name,
    required String shortId,
  }) =>
      BlePacket(
        type: 'hello',
        id: const Uuid().v4(),
        from: from,
        name: name,
        ts: DateTime.now().millisecondsSinceEpoch,
        shortId: shortId,
      );

  factory BlePacket.msg({
    required String from,
    required String name,
    required String text,
    String? replyToId,
    String? replyToText,
    String? replyToSender,
    bool forwarded = false,
  }) =>
      BlePacket(
        type: 'msg',
        id: const Uuid().v4(),
        from: from,
        name: name,
        ts: DateTime.now().millisecondsSinceEpoch,
        text: text,
        replyToId: replyToId,
        replyToText: replyToText,
        replyToSender: replyToSender,
        forwarded: forwarded,
      );

  factory BlePacket.ack({
    required String forId,
    required String from,
    required String name,
  }) =>
      BlePacket(
        type: 'ack',
        id: forId,
        from: from,
        name: name,
        ts: DateTime.now().millisecondsSinceEpoch,
      );

  /// Starts a file transfer. [id] is the transfer id — the receiver's
  /// saved file message and the sender's ack both use it.
  factory BlePacket.fileStart({
    required String transferId,
    required String from,
    required String name,
    required String fileName,
    required int fileSize,
    required String mimeType,
  }) =>
      BlePacket(
        type: 'fileStart',
        id: transferId,
        from: from,
        name: name,
        ts: DateTime.now().millisecondsSinceEpoch,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
      );

  /// One chunk of a file transfer. [data] is base64 of up to
  /// [FileTransferConfig.chunkBytes] raw bytes.
  factory BlePacket.fileChunk({
    required String transferId,
    required String from,
    required String name,
    required int seq,
    required String data,
  }) =>
      BlePacket(
        type: 'fileChunk',
        id: transferId,
        from: from,
        name: name,
        ts: DateTime.now().millisecondsSinceEpoch,
        seq: seq,
        data: data,
      );

  /// Ends a file transfer; the receiver assembles and saves the file.
  factory BlePacket.fileEnd({
    required String transferId,
    required String from,
    required String name,
  }) =>
      BlePacket(
        type: 'fileEnd',
        id: transferId,
        from: from,
        name: name,
        ts: DateTime.now().millisecondsSinceEpoch,
      );

  /// Synthetic packet the transport emits after saving an incoming
  /// file, so the repository can store it as a file message.
  factory BlePacket.file({
    required String transferId,
    required String from,
    required String name,
    required int ts,
    required String fileName,
    required int fileSize,
    required String mimeType,
    required String filePath,
  }) =>
      BlePacket(
        type: 'file',
        id: transferId,
        from: from,
        name: name,
        ts: ts,
        text: fileName,
        fileName: fileName,
        fileSize: fileSize,
        mimeType: mimeType,
        filePath: filePath,
      );

  /// A message to a group chat. [members] maps every member's user id
  /// to their display name so a receiver who has never seen this group
  /// can create it locally. The sender fans the packet out to each
  /// member over their 1:1 BLE link.
  factory BlePacket.groupMsg({
    required String from,
    required String name,
    required String text,
    required String groupId,
    required String groupName,
    required Map<String, String> members,
    String? replyToId,
    String? replyToText,
    String? replyToSender,
    bool forwarded = false,
  }) =>
      BlePacket(
        type: 'groupMsg',
        id: const Uuid().v4(),
        from: from,
        name: name,
        ts: DateTime.now().millisecondsSinceEpoch,
        text: text,
        groupId: groupId,
        groupName: groupName,
        members: members,
        replyToId: replyToId,
        replyToText: replyToText,
        replyToSender: replyToSender,
        forwarded: forwarded,
      );

  /// Replaces the text of a message the sender authored. [editId] is
  /// the edited message's id. [groupId] set → a group message edit
  /// (fanned out to members); null → a 1:1 edit.
  factory BlePacket.edit({
    required String from,
    required String name,
    required String editId,
    required String text,
    String? groupId,
  }) =>
      BlePacket(
        type: 'edit',
        id: const Uuid().v4(),
        from: from,
        name: name,
        ts: DateTime.now().millisecondsSinceEpoch,
        text: text,
        editId: editId,
        groupId: groupId,
      );

  /// Deletes a message the sender authored everywhere. [deleteId] is
  /// the deleted message's id. [groupId] set → a group message delete.
  factory BlePacket.deleteMsg({
    required String from,
    required String name,
    required String deleteId,
    String? groupId,
  }) =>
      BlePacket(
        type: 'delete',
        id: const Uuid().v4(),
        from: from,
        name: name,
        ts: DateTime.now().millisecondsSinceEpoch,
        deleteId: deleteId,
        groupId: groupId,
      );

  /// A reaction to a message. [reactId] is the message's id, [emoji]
  /// the reaction. Sending the same emoji again removes the reaction.
  factory BlePacket.react({
    required String from,
    required String name,
    required String reactId,
    required String emoji,
    String? groupId,
  }) =>
      BlePacket(
        type: 'react',
        id: const Uuid().v4(),
        from: from,
        name: name,
        ts: DateTime.now().millisecondsSinceEpoch,
        reactId: reactId,
        reactEmoji: emoji,
        groupId: groupId,
      );

  Map<String, dynamic> toJson() => {
        't': type,
        'id': id,
        'from': from,
        'name': name,
        'ts': ts,
        if (text != null) 'text': text,
        if (shortId != null) 'sid': shortId,
        if (fileName != null) 'fileName': fileName,
        if (fileSize != null) 'fileSize': fileSize,
        if (mimeType != null) 'mime': mimeType,
        if (filePath != null) 'path': filePath,
        if (seq != null) 'seq': seq,
        if (data != null) 'data': data,
        if (groupId != null) 'gid': groupId,
        if (groupName != null) 'gname': groupName,
        if (members != null) 'members': members,
        if (editId != null) 'editId': editId,
        if (deleteId != null) 'deleteId': deleteId,
        if (reactId != null) 'reactId': reactId,
        if (reactEmoji != null) 'reactEmoji': reactEmoji,
        if (replyToId != null) 'replyTo': replyToId,
        if (replyToText != null) 'replyText': replyToText,
        if (replyToSender != null) 'replyName': replyToSender,
        if (forwarded) 'fwd': true,
      };

  factory BlePacket.fromJson(Map<String, dynamic> json) => BlePacket(
        type: json['t'] as String,
        id: json['id'] as String,
        from: json['from'] as String,
        name: (json['name'] as String?) ?? '',
        ts: (json['ts'] as num?)?.toInt() ?? 0,
        text: json['text'] as String?,
        shortId: json['sid'] as String?,
        fileName: json['fileName'] as String?,
        fileSize: (json['fileSize'] as num?)?.toInt(),
        mimeType: json['mime'] as String?,
        filePath: json['path'] as String?,
        seq: (json['seq'] as num?)?.toInt(),
        data: json['data'] as String?,
        groupId: json['gid'] as String?,
        groupName: json['gname'] as String?,
        members: (json['members'] as Map?)?.map(
          (k, v) => MapEntry(k.toString(), v.toString()),
        ),
        editId: json['editId'] as String?,
        deleteId: json['deleteId'] as String?,
        reactId: json['reactId'] as String?,
        reactEmoji: json['reactEmoji'] as String?,
        replyToId: json['replyTo'] as String?,
        replyToText: json['replyText'] as String?,
        replyToSender: json['replyName'] as String?,
        forwarded: (json['fwd'] as bool?) ?? false,
      );

  Uint8List encode() => Uint8List.fromList(utf8.encode(jsonEncode(toJson())));

  static BlePacket decode(Uint8List bytes) =>
      BlePacket.fromJson(jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>);
}

/// Splits payloads into BLE-sized frames and reassembles them.
///
/// One [FrameReassembler] instance is kept per link direction; frames carry
/// a random 8-byte message id so interleaved messages reassemble correctly.
class FrameCodec {
  static List<Uint8List> encode(Uint8List payload,
      {required int chunkSize}) {
    assert(chunkSize >= 8 && chunkSize <= 512);
    final random = Random.secure();
    final msgId =
        Uint8List.fromList(List.generate(8, (_) => random.nextInt(256)));
    final total = (payload.length / chunkSize)
        .ceil()
        .clamp(1, BleProtocol.maxChunks)
        .toInt();
    final frames = <Uint8List>[];
    for (var i = 0; i < total; i++) {
      final start = i * chunkSize;
      final end = min(start + chunkSize, payload.length);
      final frame =
          Uint8List(BleProtocol.frameHeaderLength + (end - start));
      final header = ByteData.sublistView(frame);
      header.setUint8(0, BleProtocol.frameMagic);
      header.setUint8(1, BleProtocol.frameVersion);
      frame.setRange(2, 10, msgId);
      header.setUint8(10, total);
      header.setUint8(11, i);
      frame.setRange(BleProtocol.frameHeaderLength,
          BleProtocol.frameHeaderLength + (end - start), payload, start);
      frames.add(frame);
    }
    return frames;
  }
}

class _Assembly {
  final int total;
  final Map<int, Uint8List> chunks = {};
  final DateTime startedAt = DateTime.now();
  _Assembly(this.total);
}

class FrameReassembler {
  final Map<String, _Assembly> _pending = {};

  /// Feeds one received frame. Returns the complete payload once every
  /// chunk of the message has arrived, otherwise null.
  Uint8List? add(Uint8List frame) {
    _prune();
    if (frame.length < BleProtocol.frameHeaderLength) return null;
    final header = ByteData.sublistView(frame);
    if (header.getUint8(0) != BleProtocol.frameMagic) return null;
    if (header.getUint8(1) != BleProtocol.frameVersion) return null;
    final key = frame
        .sublist(2, 10)
        .map((b) => b.toRadixString(16).padLeft(2, '0'))
        .join();
    final total = header.getUint8(10);
    final index = header.getUint8(11);
    if (total == 0 || index >= total) return null;

    final assembly = _pending.putIfAbsent(key, () => _Assembly(total));
    if (assembly.total != total) return null; // corrupted stream; drop
    assembly.chunks[index] =
        frame.sublist(BleProtocol.frameHeaderLength);
    if (assembly.chunks.length != total) return null;

    _pending.remove(key);
    final out = <int>[];
    for (var i = 0; i < total; i++) {
      out.addAll(assembly.chunks[i]!);
    }
    return Uint8List.fromList(out);
  }

  void _prune() {
    final cutoff = DateTime.now().subtract(const Duration(seconds: 30));
    _pending.removeWhere((_, a) => a.startedAt.isBefore(cutoff));
  }
}
