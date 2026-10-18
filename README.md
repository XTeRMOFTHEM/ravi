<div align="center">

<img src="assets/images/logo.png" width="140" alt="RAVI logo" />

# RAVI

**راوی — ارتباط، چت، بازی**

*Connect · Chat · Play* — a fast, smooth, cross-platform messenger built with Flutter.

[![Flutter](https://img.shields.io/badge/Flutter-3.x-02569B?logo=flutter&logoColor=white)](https://flutter.dev)
[![Dart](https://img.shields.io/badge/Dart-3.13+-0175C2?logo=dart&logoColor=white)](https://dart.dev)
[![Platform](https://img.shields.io/badge/Platform-Android-3DDC84?logo=android&logoColor=white)](https://android.com)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

</div>

---

## ✨ Features

### 💬 Realtime messaging
- Private chats, groups, channels and a public room — powered by **Socket.IO**
- Live **typing indicators**, **read receipts** and unread badges
- Emoji **reactions**, message deletion, forwarding and **swipe-to-reply**
- Tappable **@mentions** and links

### 📸 Rich media
- Photo & video sharing with built-in **cropping**
- **Voice messages** — record and play in-chat
- Document attachments via the file picker
- **GIF picker** with a personal GIF library
- Built-in **music player** with a persistent player bar

### 🎨 Personalization
- Light & dark themes, out of the box
- **8 accent colors** that recolor the entire app live (Material + custom palette)
- Selectable **chat backgrounds**
- Full **Persian / English** localization with Vazirmatn & Inter typography

### 👤 Accounts & moderation
- Sign-up & login with field-level validation
- Profile editing — avatar, display name, bio
- Block / unblock users
- Room admin tools — member management and bans

## 🏗 Architecture

```
lib/
├── main.dart                  # Entrypoint
├── ravi_app.dart              # Root widget — theme & locale wiring
└── core/                      # Services & state (no UI)
    ├── api_service.dart       # REST client — auth, users, rooms, media
    ├── socket_service.dart    # Socket.IO layer — rooms, typing, reads, reactions
    ├── chat_controller.dart   # Chat state machine
    ├── app_state.dart         # Session & preferences store
    ├── cache_service.dart     # Media caching
    ├── player_service.dart    # Audio playback
    ├── constants.dart         # Design tokens & accent palettes
    ├── i18n.dart              # FA / EN localization
    ├── identity_parser.dart   # @mention & link parsing
    └── models.dart            # User, Chat, Message, Room models
lib/ui/
├── auth/                      # Login & sign-up
├── home/                      # Chats, contacts, magazine, profile, settings
├── chat/                      # Chat screen, bubbles, media & player UI
└── widgets/                   # Shared widgets & alerts
```

## 🚀 Getting started

**Prerequisites:** [Flutter SDK](https://docs.flutter.dev/get-started/install) (Dart 3.13+) and an Android toolchain.

```bash
git clone https://github.com/XTeRMOFTHEM/ravi.git
cd ravi
flutter pub get
```

Point the app at your backend and run:

```bash
flutter run --dart-define=RAVI_BASE_URL=http://10.0.2.2:5000
```

> `10.0.2.2` is the Android-emulator alias for your machine's `localhost`.
> On a physical device, use your machine's LAN IP.

Build a release APK:

```bash
flutter build apk --release --dart-define=RAVI_BASE_URL=https://your-server.example:5000
```

## ⚙️ Configuration

### Backend URL
The server endpoint is injected at build time via `--dart-define=RAVI_BASE_URL=<url>`
(see `lib/core/constants.dart`). The default is `http://localhost:5000`.

### Release signing
The Android release build reads its signing config from `android/key.properties`,
which is **git-ignored**. To sign your own builds:

1. Place your keystore inside `android/app/` (e.g. `release-keystore.jks`) — **never commit it**.
2. Create `android/key.properties`:

   ```properties
   storeFile=release-keystore.jks
   storePassword=your-store-password
   keyAlias=your-key-alias
   keyPassword=your-key-password
   ```

3. Build with `flutter build apk --release`.

Without `key.properties`, release builds automatically fall back to debug signing.

## 🧪 Testing

The suite includes unit tests (identity parsing, live API smoke) and **golden tests**
for the auth screens across devices, themes and keyboard states:

```bash
flutter test
```

Goldens live in `test/goldens/`. Update them after intentional UI changes:

```bash
flutter test --update-goldens
```

## 📄 License

Distributed under the [MIT License](LICENSE).
