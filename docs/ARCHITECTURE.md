# Campus Connect — Architecture (v0.1)

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
    models.dart        ChatMessage, Conversation
    database.dart      sqflite schema
    chat_repository.dart persistence + unread + delivery states
  ui/
    welcome_screen.dart   display-name entry (first run)
    home_screen.dart      bottom tabs: Chats / Nearby / Settings
    chat_screen.dart      1:1 chat, ticks, out-of-range handling
    widgets/              aurora_background, message_bubble,
                          glass_input_bar, radar_pulse
```

The UI layer (v0.2) uses an aquatic liquid-glass design language —
aquatic palette, glass panels, bubble/input styling — implemented as
original code on top of the BLE-first core. v1 has no internet backend
by design (Sujith's call, 2026-10-11).

## Startup flow (v0.3)

`main()` creates the service instances, then `runApp` immediately —
the splash screen (logo + loading spinner) is on screen while
`AppBootstrap` opens the database and loads the identity. Once ready,
the app routes to the welcome screen ("Dive in" — first run) or straight
to chats. BLE starts when the home screen boots, as before.

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
