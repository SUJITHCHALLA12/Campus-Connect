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

// groupMsg — a message to a group chat (fan-out: one copy per member).
// owner + perms ride along so a receiver learning the group from this
// message gets the correct owner and permission set.
{"t":"groupMsg","id":"<uuid>","from":"<userId>","name":"<display>","ts":123,"text":"hi all","gid":"<group uuid>","gname":"Study Group","members":{"<userId>":"<display>", "...": "..."},"owner":"<owner userId>","permSend":false,"permEdit":false,"permAdd":false}

// groupUpdate — group permissions changed by the owner. Receivers
// apply it only when from == owner.
{"t":"groupUpdate","id":"<uuid>","from":"<userId>","name":"<display>","ts":123,"gid":"<group uuid>","owner":"<owner userId>","permSend":true,"permEdit":false,"permAdd":false}

// ack — delivery acknowledgement for a msg id
{"t":"ack","id":"<msg uuid>","from":"<userId>","name":"<display>","ts":123}

// bye — graceful teardown notice (optional)
{"t":"bye","id":"<uuid>","from":"<userId>","name":"<display>","ts":123}

// fileStart — begins a file transfer (id = transfer id).
// gid set → the file belongs to that group chat, not a 1:1 chat.
{"t":"fileStart","id":"<transfer uuid>","from":"<userId>","name":"<display>","ts":123,"fileName":"photo.jpg","fileSize":184320,"mime":"image/jpeg","gid":"<group uuid, if group>"}

// fileChunk — one chunk: base64 of up to 1 KB raw bytes (keeps the
// packet under the 255-frame cap even at the MTU-23 minimum)
{"t":"fileChunk","id":"<transfer uuid>","from":"<userId>","name":"<display>","ts":123,"seq":0,"data":"<base64>","gid":"<group uuid, if group>"}

// fileEnd — ends a file transfer; receiver assembles + saves it
{"t":"fileEnd","id":"<transfer uuid>","from":"<userId>","name":"<display>","ts":123,"gid":"<group uuid, if group>"}
```

On receiving `msg`, the receiver stores it and replies `ack`. The sender
marks the message delivered when the ack arrives.

On receiving `groupMsg`, the receiver creates the group locally if it
has never seen the id (from `gname` + `members`), stores the message,
and replies `ack` like a normal message. `owner` / `permSend` /
`permEdit` / `permAdd` ride on every `groupMsg`: a new group takes
them outright; a known group only accepts them when the sender IS the
owner.

On receiving `groupUpdate`, the receiver applies the new permission
set only when `from` equals `owner` — a non-owner cannot spoof a
permissions change — and replies `ack`.

### Group permissions (v0.9)

Each permission is Everyone (false) or Only owner (true), defaulting
to Everyone for backward compatibility with existing groups:

| Key | Permission | Enforcement |
|---|---|---|
| `permSend` | Send messages | Composer disabled + notice for non-owners when true |
| `permEdit` | Edit group info (name / photo) | Photo edit hidden/disabled for non-owners when true (no rename UI exists yet) |
| `permAdd` | Add members | No add-members flow exists yet — the flag syncs and will gate that flow when it is built |

Only the group owner (the creator, `owner`) can change permissions.
Groups created before v0.9 have no owner and are never restricted.

// edit — replaces the text of a message the sender authored
{"t":"edit","id":"<uuid>","from":"<userId>","name":"<display>","ts":123,"text":"fixed","editId":"<edited msg uuid>","gid":"<group uuid, if group>"}

// delete — deletes a message the sender authored everywhere
{"t":"delete","id":"<uuid>","from":"<userId>","name":"<display>","ts":123,"deleteId":"<deleted msg uuid>","gid":"<group uuid, if group>"}

// react — a reaction (same emoji again removes it)
{"t":"react","id":"<uuid>","from":"<userId>","name":"<display>","ts":123,"reactId":"<msg uuid>","reactEmoji":"❤️","gid":"<group uuid, if group>"}

// msg / groupMsg may also carry a reply quote and/or the forwarded flag
{"t":"msg","id":"<uuid>","from":"<userId>","name":"<display>","ts":123,"text":"got it","replyTo":"<quoted msg uuid>","replyText":"<quoted text>","replyName":"<quoted sender>","fwd":true}

File transfers reuse the same framing: each `fileChunk` packet is itself
split into frames by the codec (a 1 KB chunk fits in ≤255 frames even at
the MTU-23 minimum). The receiver collects chunks per transfer id;
on `fileEnd` it verifies every chunk arrived and the total byte count
matches `fileSize`, saves the file under the app documents `received/`
folder, stores one file message (kind `voice` when the mime type is
`audio/*`, so voice notes render a player bubble), and replies `ack`
with the transfer id so the sender marks its file message delivered. Incomplete or corrupt
transfers are dropped silently. Files are capped at 1 MB — BLE
throughput is low (each frame is a separate GATT write), so bigger files
are refused on the sender side before any byte goes over the air.
When `gid` is set on the file packets, the file is stored in that
group conversation instead of the 1:1 chat with the sender (group
files fan out: the sender runs one transfer per member).

## Fast file transfer (v0.10) — out-of-band, not a BLE protocol change

The BLE packets above are unchanged. File bytes now prefer two
faster, out-of-band paths before falling back to BLE chunking:

1. **Nearby Connections** (primary, `nearby_connections` plugin) —
   the Quick Share transport: BLE discovery/handshake, then an
   automatic upgrade to a high-throughput Wi-Fi / Bluetooth socket.
   The sender connects to the Nearby endpoint whose endpoint name is
   the peer's user id, sends a FILE payload plus a small JSON
   metadata BYTES payload (`CCFAST` + transfer id, file name, mime,
   group id, sender, kind), and the receiver saves the file under
   `received/` and stores the same file/voice message.
2. **Raw Wi-Fi Direct** (fallback, hand-written Kotlin in
   `WifiDirectHelper.kt`, MethodChannel `.../wifi_direct`) — the
   sender tries discovered devices one by one; the receiver's
   server socket accepts a JSON-line handshake and drops the
   connection when `targetUserId` is not its own user id (Wi-Fi
   Direct devices carry no app-level identity). First-time Wi-Fi
   Direct between two phones may show a system accept prompt on
   the receiver.
3. **BLE** (last resort) — the chunked transfer above, 1 MB cap.

Caps: fast paths allow up to 100 MB; BLE fallback keeps the 1 MB
cap. A big file whose fast paths both fail is reported as failed,
not truncated. Chat text, reactions and all signalling stay on BLE.
Permissions: `NEARBY_WIFI_DEVICES` (API 33+), Wi-Fi state +
location (API 29–31) — see `docs/ARCHITECTURE.md`.

## Security status (v1)

**Plaintext.** Anyone in radio range running a BLE sniffer can read
messages. The version byte exists so a future revision can negotiate
ECDH + AES-GCM per conversation without changing the framing. Do not
describe v1 as end-to-end encrypted — see `docs/ARCHITECTURE.md` milestones.

## Test checklist (two physical phones)

1. Both phones: fresh install → enter different names → grant BT permissions.
2. Both show each other under "+ → Pair with nearby" within ~10 s.
3. Exactly one side shows the link first; no duplicate conversations.
4. Send messages both ways; each shows double-tick (delivered).
5. Kill Bluetooth on one phone → other shows "Out of range"; sending fails
   visibly (red icon), message stays stored.
6. Re-enable → link re-establishes automatically via rescan.
7. 500-char message → arrives complete (chunking works).
8. Send a small image (< 1 MB) → receiver gets a file tile, taps it,
   and the image opens in the platform viewer.
9. Send a > 1 MB file → sender sees the "1 MB max" notice, nothing sent.
10. Group photo: set a photo in Group Info → it shows in the group
    header and groups list on this phone only; the other phone still
    sees the default avatar (photos are not transmitted).
11. Owner-only messaging: owner flips the Send-messages permission
    in Group Info → members see the composer disabled with the
    notice; the owner can still send. A member's send attempt is
    blocked locally.
12. Group permissions: the owner can set Send / Edit info / Add
    members to Everyone or Only owner; non-owners see the settings
    read-only. Edit-info gates the group photo (no rename UI yet);
    Add-members has no flow to gate yet.
13. Group file: send a file from a group chat → every in-range member
    gets it in the group conversation (not in the 1:1 chat).
