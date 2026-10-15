# Campus Connect — Architecture (v0.7)

## Decision log

| # | Decision | Rationale |
|---|----------|-----------|
| 1 | **Flutter + Dart**, Android-first | Single codebase; matches the builder's current Flutter experience (BitLock). iOS later. |
| 2 | **BLE-first, no web client** | Web messaging can't do nearby radio; the product's core is offline nearby chat. Web explicitly dropped 2026-10-11. |
| 3 | **No internet backend in v1** | The retained Supabase project stays untouched. v1 is pure device-to-device; an internet relay for distant users is a later milestone, not MVP. |
| 4 | **`bluetooth_low_energy` package** | `flutter_blue_plus` is central-role only — a two-phone chat needs each phone to advertise too. This package supports both roles on Android/iOS. |
| 5 | **sqflite local store** | No server ⇒ the database is the message store. Conversations + messages persist across restarts. |
| 6 | **Plaintext v1, crypto as explicit milestone** | Shipping the transport first, then adding ECDH+AES-GCM. The privacy goal is recorded, not claimed. |

## Component map

```
lib/
  main.dart            bootstrap: DB → identity → repository → BLE → UI
  app.dart             MaterialApp + aquatic "liquid glass" theme
  core/
    constants.dart     app name, timings (visual tokens in theme/)
    theme/             cc_colors.dart, cc_glass.dart — design system
    identity.dart      userId (uuid v4) + display name, SharedPreferences
    format.dart        chat time formatters
  ble/
    ble_protocol.dart  UUIDs, adv name format, BlePacket, FrameCodec
    ble_transport.dart BleChatService: peripheral + central roles, links, routing
  data/
    models.dart        ChatMessage, Conversation, Group
    database.dart      sqflite schema (v3: groups table)
    chat_repository.dart persistence + unread + delivery states + groups
  ui/
    welcome_screen.dart   display-name entry (first run)
    home_screen.dart      bottom nav: Home / Chats / Groups / Profile,
                          centre + button (pair nearby / create group),
                          Chats / Groups / Updates tabs
    chat_screen.dart      1:1 chat, ticks, out-of-range handling
    group_chat_screen.dart group chat (fan-out send, sender names)
    create_group_screen.dart group name + member picker
    nearby_sheet.dart     bottom sheet: nearby phones to pair with
    widgets/              aurora_background, message_bubble,
                          glass_input_bar, radar_pulse
```

The UI layer (v0.2) uses an aquatic liquid-glass design language —
aquatic palette, glass panels, bubble/input styling — implemented as
original code on top of the BLE-first core. v1 has no internet backend
by design (Sujith's call, 2026-10-11).

## Startup flow (v0.3)

`main()` creates the service instances, then `runApp` immediately —
the splash screen (logo + animated gradient loading bar) is on screen
while `AppBootstrap` opens the database and loads the identity. Once
ready, the app routes to the welcome screen ("Dive in" — first run)
or straight to chats. BLE starts when the home screen boots, as before.

## File sharing (v0.3)

File messages are a second message kind alongside text. Sending: the
chat composer offers image + file pickers; the file moves as
`fileStart` / `fileChunk` / `fileEnd` packets (see `docs/PROTOCOL.md`),
with live progress on the outgoing bubble. Receiving: the transport
assembles the bytes, saves them under the app documents `received/`
folder, and the repository stores one file message pointing at the
local copy. Tapping a file tile opens it with the platform viewer.
DB schema is v2: `messages` gained `kind`, `file_name`, `file_size`,
`mime_type`, `file_path` (v1 installs migrate via `ALTER TABLE`).

## Group chats (v0.4)

There is no group link — groups are fan-out over 1:1 links. The creator
picks members (people chatted with or currently linked), and the
repository stores the group in a `groups` table (id, name, member map,
last message, unread). Sending a group message writes one `groupMsg`
packet to each member over their 1:1 link; the first ack flips it to
delivered. The packet carries the group id, name and full member map,
so a receiver who has never seen the group creates it locally on first
message. A member out of range when a message is sent simply misses
that message — there is no server to hold it. DB schema is v3
(`groups` table added; v1/v2 installs migrate via `CREATE TABLE`).

## Voice messages (v0.5)

Voice notes are file transfers with an audio mime type — no new packet
type. Recording (mic button in the composer, tap ✓ to send, ✕ to
discard, 60 s cap) produces an .m4a file that travels as
`fileStart` / `fileChunk` / `fileEnd` with `mime: audio/m4a`. The
repository stores it with kind `voice` (sender passes the kind
explicitly; the receiver detects `audio/*` mimes), and the chat renders
a play/pause bubble with progress instead of a file tile. Group chats
do not send voice yet — their composer shows the send button only.

## Startup popups (v0.7)

**Bluetooth.** Home boot requests the BLE permissions (scan /
advertise / connect, + location on Android ≤ 30), then checks the
adapter state. If Bluetooth is off, a "Turn on Bluetooth?" popup
appears: Turn on opens the system Bluetooth settings (Android has no
public API for an app to flip Bluetooth on itself); Not now leaves
the app usable with a tap-to-turn-on "Bluetooth is off" banner.
Returning from settings with Bluetooth on starts BLE via the app
lifecycle resume hook.

**Update.** On launch the app fetches `version.json` from the repo's
main branch (5 s timeout, silent on failure) and compares its
`version` + `build` with the install's. When a newer release is out,
an "Update available" popup offers Update (opens the Releases page)
or Later (once per session). `version.json` must be bumped with
every release, alongside pubspec.

## Live distance + message actions (v0.6)

**Distance.** The chat header shows the peer's estimated distance
("Nearby · 12.345 m away"), refreshed every 30 s from the smoothed
advertisement RSSI (exponential moving average) via the log-distance
path-loss model (txPower −59 dBm at 1 m, exponent 2.0). BLE cannot
measure true distance — walls, bodies and reflections shift RSSI by
metres — so the number is an estimate, shown to 3 decimals as asked.

**Message actions.** Long-press a message for Reply / React / Edit /
Copy / Forward / Info / Delete. Replies carry a quote (original id,
text, sender); slide any bubble horizontally to reply. Reactions are
one emoji per sender stored as a JSON map on the message; sending the
same emoji again removes it. Edit is limited to the author's own text
messages within 5 minutes of sending, and marks the message edited.
Delete for me removes the local copy; delete for everyone sends a
delete packet the receiver applies only if the sender is the author.
Forward sends a copy with the forwarded flag (text to any chat;
files/voice to 1:1 chats only). DB schema is v4: `messages` gained
`edited`, `reactions`, `reply_to_id`, `reply_to_text`,
`reply_to_sender`, `forwarded`.

## Data flow (sending "hi")

1. `ChatScreen` builds `BlePacket.msg` → `ChatRepository.saveOutgoing` (status: sent).
2. `BleChatService.sendTo(peerUserId, packet)` → frames → GATT write/notify.
3. Peer's `BleChatService` reassembles → `_handlePacket` → emits on `incoming`
   and replies `ack`.
4. Peer's `ChatRepository` stores the message (unread+1 unless chat open).
5. Sender's repository gets the `ack` → `markDelivered` → double tick in UI.

## Link lifecycle

- Scan finds `CC:<shortId>:<name>` advertisements with our service UUID.
- Larger shortId connects as central (tie-break ⇒ exactly one link).
- Central: MTU request → discover GATT → subscribe TX → send HELLO on RX.
- Peripheral: first RX write must be HELLO → creates link → answers HELLO on TX.
- Disconnect (either side) → link removed; rescan reconnects automatically.

## Milestones

- **M1 — BLE chat MVP (this build):** onboarding, nearby discovery, 1:1 chat,
  local persistence, delivery acks. Plaintext.
- **M2 — Privacy hardening:** X25519 ECDH per conversation + AES-GCM frames,
  frame version bump, key storage in platform keystore.
- **M3 — Group chat:** local group sessions over the same transport.
- **M4 — Internet relay (optional):** use the retained Supabase project as a
  store-and-forward relay for distant users; BLE stays the nearby path.
- **M5 — iOS support:** same Dart code, iOS permission strings + testing.

## Known limitations (v1)

- Android only; BLE doesn't work on emulators — test on 2 physical phones.
- Plaintext over the air (see M2).
- No background operation yet: chats work while the app is open.
- Range is classic BLE (~10–30 m); no mesh relaying yet.
