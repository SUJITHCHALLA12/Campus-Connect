# Campus Connect

Nearby-first campus messaging over **Bluetooth Low Energy**. No internet, no
servers, no accounts — open the app near another phone running it and chat.

> **Status:** v0.4 (Android). Messages are currently **plaintext**
> over the air; per-conversation encryption is a planned milestone, not a
> claim. See `docs/ARCHITECTURE.md`.

## How it works

Every phone runs both BLE roles at once: it **advertises** a Campus Connect
GATT service and **scans** for others. When two phones find each other, a
deterministic tie-break (larger advertised id connects) creates exactly one
link. Messages are JSON packets, split into small BLE frames, reassembled on
arrival, acknowledged, and stored locally in SQLite.

Full wire spec: [`docs/PROTOCOL.md`](docs/PROTOCOL.md).
Architecture + decision log: [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md).

Chats also carry files: the composer has image + file buttons, and
picked files (up to 1 MB) travel to the other phone over the same BLE
link as chunked `fileStart` / `fileChunk` / `fileEnd` packets. Received
files save to the app's documents folder and open with a tap.

## Quick start (Windows, like your BitLock setup)

```bat
cd Campus-Connect
flutter pub get
flutter run            :: on a physical phone (BLE needs real hardware)
```

Then install on a **second** physical phone, open the app on both, enter
different names, grant the Bluetooth permissions — each phone should list the
other under "+ → Pair with nearby" within ~10 seconds. Tap to chat.

Notes:
- `android/gradlew` is self-bootstrapping (downloads Gradle 8.14 once);
  the binary wrapper jar is intentionally not committed.
- `minSdk` is 24 (required by the BLE plugin).
- Emulators can't do BLE — use physical devices.

## Project layout

```
lib/
  main.dart  app.dart
  core/      identity, constants
  ble/       protocol, frame codec, BLE transport (the interesting part)
  data/      models, sqflite database, chat repository
  ui/        onboarding, home (Home/Chats/Groups/Profile + + sheet),
           1:1 + group chat screens, create-group, nearby sheet
android/     Android scaffold, BLE permissions, self-bootstrapping gradlew
docs/        PROTOCOL.md, ARCHITECTURE.md
```

## Roadmap

1. **M1** — BLE 1:1 chat MVP ✅ (shipped 2026-10-11)
2. **M1.5 / v0.2** — Aquatic liquid-glass UI redesign ✅ (this):
   welcome screen, bottom-tab home (Chats / Nearby / Settings), glass
   chat screen. Same BLE core underneath.
3. **M1.6 / v0.3** — Logo branding + file sharing ✅ (this): app theme
   and launcher icon from the Campus Connect logo (cyan → violet on
   deep navy), splash loading page → "Dive in" → chats, image + file
   sending over BLE (1 MB cap).
4. **M1.7 / v0.4** — Group chats + mockup home ✅ (this): bottom nav
   Home / Chats / + / Groups / Profile, Chats / Groups / Updates tabs,
   centre + button → pair with nearby or create a group chat. Group
   messages fan out to every member over their 1:1 BLE link.
5. **M2** — Privacy: ECDH + AES-GCM per conversation
6. **M4** — Internet relay for distant users (Supabase project on standby)
7. **M5** — iOS support

The app theme follows the logo: cyan → violet gradients on a deep-navy
background, with the logo on the splash and welcome screens.

## Credits

- BLE transport uses the `bluetooth_low_energy` Flutter plugin.
