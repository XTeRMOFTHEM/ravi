<div align="center">

<img src="docs/banner.png" alt="RAVI — Connect · Chat · Play" width="100%" />

[![Version](https://img.shields.io/badge/Version-1.5.1-5865F2?style=flat-square)](/../../releases)
[![Flutter](https://img.shields.io/badge/Flutter-3.44+-02569B?style=flat-square&logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.13+-0175C2?style=flat-square&logo=dart&logoColor=white)](https://dart.dev)
[![Socket.IO](https://img.shields.io/badge/Realtime-Socket.IO-white?style=flat-square&logo=socketdotio&logoColor=white)](https://socket.io)
[![Backend](https://img.shields.io/badge/Backend-Python%2FFlask-3776AB?style=flat-square&logo=python&logoColor=white)](backend)
[![License: MIT](https://img.shields.io/badge/License-MIT-F7DF1E?style=flat-square)](LICENSE)

</div>

---

**RAVI** — *Connect · Chat · Play* — a fast, smooth, cross-platform messenger built with **Flutter**: private chats, groups, public rooms and channels with **Socket.IO** realtime messaging, rich media, full theming and deep personalization.

## Features

### <img src="docs/icons/zap.svg" width="20"> Realtime messaging
Private chats, groups, the public room and channels powered by **Socket.IO**: live typing indicators, read receipts, and unread badges/previews that update **without any refresh**.

### <img src="docs/icons/download.svg" width="20"> Smart media downloads
Photos and videos auto-download to a permanent on-disk cache (works offline afterwards); videos stream over HTTP Range even mid-download; circular progress rings, Telegram-style.

### <img src="docs/icons/file.svg" width="20"> File bubbles for every format
zip / pdf / apk / docx / iso and more get per-format icons, the real file name, size, a progress ring and a delivery tick.

### <img src="docs/icons/mic.svg" width="20"> Audio and music
Voice messages and a built-in music player with a persistent player bar.

### <img src="docs/icons/chat.svg" width="20"> Modern chat tooling
Reactions, swipe-to-reply, forward, delete and @mentions — everything a modern chat needs.

### <img src="docs/icons/megaphone.svg" width="20"> Channels
Admin-only posting with a clean, message-only channel view and live view counters.

### <img src="docs/icons/image.svg" width="20"> Avatar frames
7 frames (Baroque, Butterfly, Gothic, Silver Stars, Stars Outline, Thorns, Wings), a live-preview frame picker, and a server-driven frame list (`GET /api/frames`) so new frames ship without an app update.

### <img src="docs/icons/star.svg" width="20"> Animated PREMIUM badge
The animated premium emblem plays on profiles (8s cycle) with a lightweight static version in lists.

### <img src="docs/icons/palette.svg" width="20"> Personalization
Light and dark themes, **8 live accent colors** that recolor the whole app instantly, selectable chat backgrounds, Vazirmatn and Inter typography (Fa/En).

### <img src="docs/icons/user.svg" width="20"> Multi-account
Switch between saved accounts right from the app.

### <img src="docs/icons/folder.svg" width="20"> Data and storage
Clear caches (images, persistent media, audio, and metadata), manage downloads with automatic 350 MB disk LRU eviction, control auto-download & gallery saving, and search across chats.

### <img src="docs/icons/chat.svg" width="20"> Magazine & RAVI AI
Publish, like, reply to, and filter community posts in the **Magazine** tab (synced with user profiles), and chat with **RAVI AI** (Standard & Pro modes) backed by the server's AI endpoints.

### <img src="docs/icons/rocket.svg" width="20"> Performance-first
Cached list extents, constant list animations and clamping scroll physics keep it smooth on low-end phones.

## Backend

> [!NOTE]
> This repository ships both the RAVI Flutter **client** and the Python/Flask **backend**. Straight after cloning, `kBaseUrl` defaults to a placeholder (`<your-backend-url>`). Point the client at your backend using `--dart-define=RAVI_BASE_URL=...` (recommended) or by editing `lib/core/constants.dart`.

1. Pass your server address at build/run time (recommended):

   ```bash
   flutter run --dart-define=RAVI_BASE_URL=https://your-ravi-server.example.com
   ```

   Or set `kBaseUrl` in **`lib/core/constants.dart`**. Android defaults to **HTTPS** (`cleartextTrafficPermitted="false"`), with localhost/LAN cleartext allowed for local development in `android/app/src/main/res/xml/network_security_config.xml`.

2. **A ready-to-run RAVI backend lives in this repository** — see [`backend/`](backend) and its [README](backend/README.md) for setup, environment variables, and running the `pytest` suite (`pytest backend/tests/`).
3. The backend exposes REST endpoints — auth/session (`/api/me`, `/api/user`, `/api/sessions`), rooms (`/api/rooms`, `/api/room`), private chats (`/api/pv/…`), avatar frames (`/api/frames`), Magazine & user posts (`/api/magazine/posts`, `/api/users/<username>/posts`), and RAVI AI (`/api/ai_chat`, `/api/ai_pro_chat`) — plus the **Socket.IO** realtime layer.

## Getting started

```bash
git clone https://github.com/XTeRMOFTHEM/ravi.git
cd ravi
flutter pub get
flutter run --dart-define=RAVI_BASE_URL=http://10.0.2.2:5000
flutter test test/identity_parser_test.dart test/client_logic_test.dart
```

### Release APK signing

Create `android/key.properties` (git-ignored) with `storeFile`, `storePassword`, `keyAlias`, and `keyPassword`, then run:

```bash
flutter build apk --release --dart-define=RAVI_BASE_URL=https://your-ravi-server.example.com
```

Release builds refuse to sign with the debug keystore unless `-PallowDebugReleaseSigning=true` is explicitly passed.

> Requires Flutter SDK `3.44+` (Dart `3.13+`). App icons are generated with `flutter_launcher_icons` from `assets/images/`.

## Project structure

```
lib/
├── main.dart                     # Entrypoint
├── ravi_app.dart                 # Root widget — theme and locale wiring
├── core/
│   ├── api_service.dart          # REST client (auth, rooms, chats, media, frames)
│   ├── socket_service.dart       # Socket.IO realtime layer
│   ├── chat_controller.dart      # Chat state machine
│   ├── app_state.dart            # Session, language and preferences
│   ├── account_manager.dart      # Multi-account store
│   ├── media_download_manager.dart # Smart media downloads w/ progress
│   ├── audio_cache_service.dart  # Permanent audio cache
│   ├── storage_service.dart      # Permanent on-disk media store
│   ├── player_service.dart       # Audio playback
│   ├── chat_bg.dart              # Chat backgrounds
│   ├── i18n.dart                 # English / Persian strings
│   └── constants.dart            # Design tokens, palettes, kBaseUrl
└── ui/
    ├── splash_screen.dart
    ├── auth/auth_screen.dart
    ├── chat/                     # chat screen, bubbles, previews, player bar…
    ├── home/                     # chats, profile, settings, group info…
    └── widgets/                  # premium badge, alerts, common widgets
```

---

<div align="center">

**RAVI v1.5.1** · MIT licensed — see [LICENSE](LICENSE)

</div>
