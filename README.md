# Campus Connect

Nearby-first campus messaging over **Bluetooth Low Energy**. No internet, no
servers, no accounts — open the app near another phone running it and chat.

> **Status:** v0.1 BLE chat MVP (Android). Messages are currently **plaintext**
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

## Quick start (Windows, like your BitLock setup)

```bat
cd Campus-Connect
flutter pub get
flutter run            :: on a physical phone (BLE needs real hardware)
```

Then install on a **second** physical phone, open the app on both, enter
different names, grant the Bluetooth permissions — each phone should list the
other under "Nearby phones" within ~10 seconds. Tap to chat.

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
  ui/        onboarding, home (nearby + chats), chat screen
android/     Android scaffold, BLE permissions, self-bootstrapping gradlew
docs/        PROTOCOL.md, ARCHITECTURE.md
```

## Roadmap

1. **M1** — BLE 1:1 chat MVP ✅ (this)
2. **M2** — Privacy: ECDH + AES-GCM per conversation
3. **M3** — Local group chats
4. **M4** — Internet relay for distant users (Supabase project on standby)
5. **M5** — iOS support

Brand palette in the app is a placeholder — swap in the real logo colors
from Figma when they're ready.
