# Campus Connect BLE Wire Protocol — v1

This document is the source of truth for how two phones talk to each other.
Both sides implement it identically; there is no client/server asymmetry
beyond the BLE central/peripheral roles.

## Roles

Every phone runs **both** BLE roles simultaneously:

| Role       | What it does                                              |
|------------|-----------------------------------------------------------|
| Peripheral | Hosts the Campus Connect GATT service, advertises it      |
| Central    | Scans for the service, connects to nearby phones         |

Exactly **one** BLE link exists per pair of phones. Tie-break rule: the phone
whose advertised short id compares **greater** (lexicographically) connects
as central; the other side only accepts the incoming link. This is
deterministic, so no duplicate links and no negotiation round-trips.

## GATT layout

Service UUID: `f2a7b1c0-9d3e-4f5a-8b6c-1d2e3f4a5b6c`

| Characteristic | UUID                                   | Direction                  | Properties                  |
|----------------|----------------------------------------|----------------------------|-----------------------------|
| RX             | `f2a7b1c1-9d3e-4f5a-8b6c-1d2e3f4a5b6c` | central → peripheral       | write, writeWithoutResponse |
| TX             | `f2a7b1c2-9d3e-4f5a-8b6c-1d2e3f4a5b6c` | peripheral → central       | notify                      |

The central subscribes to TX notifications immediately after connecting, then
sends HELLO on RX. The peripheral answers HELLO on TX.

## Advertising

Name format: `CC:<shortId>:<displayName>` (display name clipped to 10 chars;
the stack may truncate further — the full identity always comes via HELLO).

The service UUID is included in the advertisement so scanners can filter.

`shortId` = first 8 hex chars of the phone's random user id.

## Framing

Packets are JSON (UTF-8), then split into frames because a BLE ATT payload
is tiny (20 bytes at MTU 23, ~509 at MTU 512). Frame layout:

```
[0]    0xCC            magic
[1]    0x01            version (bit 7 reserved: future "encrypted" flag)
[2..9] 8 random bytes  message id (lets interleaved messages reassemble)
[10]   uint8           total chunk count (1..255)
[11]   uint8           chunk index (0-based)
[12..] payload bytes
```

The sender queries the real ATT limit (`getMaximumWriteLength` /
`getMaximumNotifyLength`) after connect and sizes chunks as
`limit − 12` bytes. MTU 512 is requested; if negotiation fails, chunking
still works at the 20-byte minimum.

Incomplete assemblies expire after 30 s. Unknown magic/version frames are
dropped.

## Packets

```jsonc
// hello — first packet on every link, both directions
{"t":"hello","id":"<uuid>","from":"<userId>","name":"<display>","ts":123,"sid":"<shortId>"}

// msg — a chat message
{"t":"msg","id":"<uuid>","from":"<userId>","name":"<display>","ts":123,"text":"hello"}

// ack — delivery acknowledgement for a msg id
{"t":"ack","id":"<msg uuid>","from":"<userId>","name":"<display>","ts":123}

// bye — graceful teardown notice (optional)
{"t":"bye","id":"<uuid>","from":"<userId>","name":"<display>","ts":123}

// fileStart — begins a file transfer (id = transfer id)
{"t":"fileStart","id":"<transfer uuid>","from":"<userId>","name":"<display>","ts":123,"fileName":"photo.jpg","fileSize":184320,"mime":"image/jpeg"}

// fileChunk — one chunk: base64 of up to 8 KB raw bytes
{"t":"fileChunk","id":"<transfer uuid>","from":"<userId>","name":"<display>","ts":123,"seq":0,"data":"<base64>"}

// fileEnd — ends a file transfer; receiver assembles + saves it
{"t":"fileEnd","id":"<transfer uuid>","from":"<userId>","name":"<display>","ts":123}
```

On receiving `msg`, the receiver stores it and replies `ack`. The sender
marks the message delivered when the ack arrives.

File transfers reuse the same framing: each `fileChunk` packet is itself
split into frames by the codec (an 8 KB chunk fits in ≤255 frames at the
negotiated chunk size). The receiver collects chunks per transfer id;
on `fileEnd` it verifies every chunk arrived and the total byte count
matches `fileSize`, saves the file under the app documents `received/`
folder, stores one file message, and replies `ack` with the transfer id
so the sender marks its file message delivered. Incomplete or corrupt
transfers are dropped silently. Files are capped at 1 MB — BLE
throughput is low (each frame is a separate GATT write), so bigger files
are refused on the sender side before any byte goes over the air.

## Security status (v1)

**Plaintext.** Anyone in radio range running a BLE sniffer can read
messages. The version byte exists so a future revision can negotiate
ECDH + AES-GCM per conversation without changing the framing. Do not
describe v1 as end-to-end encrypted — see `docs/ARCHITECTURE.md` milestones.

## Test checklist (two physical phones)

1. Both phones: fresh install → enter different names → grant BT permissions.
2. Both show each other under "Nearby phones" within ~10 s.
3. Exactly one side shows the link first; no duplicate conversations.
4. Send messages both ways; each shows double-tick (delivered).
5. Kill Bluetooth on one phone → other shows "Out of range"; sending fails
   visibly (red icon), message stays stored.
6. Re-enable → link re-establishes automatically via rescan.
7. 500-char message → arrives complete (chunking works).
8. Send a small image (< 1 MB) → receiver gets a file tile, taps it,
   and the image opens in the platform viewer.
9. Send a > 1 MB file → sender sees the "1 MB max" notice, nothing sent.
