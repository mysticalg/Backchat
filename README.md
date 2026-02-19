# Backchat

Backchat is a cross-platform encrypted messaging app scaffold targeting:

- macOS
- Windows
- Linux
- Android
- iOS (optional from the same codebase)

It includes:

- OAuth sign-in with Google and Facebook
- Profile import (avatar + display name)
- Contact discovery from providers (where APIs allow)
- End-to-end encryption primitives for messages
- Presence state (Online / Offline / Busy)
- Desktop tray integration for messenger-style quick access
- Starter packaging commands for `.exe`, `.dmg`, Linux bundles, and Android artifacts

> **Important platform/API constraint**
> Directly relaying encrypted messages *through Facebook Messenger* from a third-party app is generally not available for consumer accounts via public APIs. This scaffold uses provider OAuth identity and profile/contact data where legal/available, then sends encrypted messages through Backchat's own transport.

## Project layout

- `pubspec.yaml` – Flutter dependencies and metadata
- `lib/main.dart` – App entry, auth flow, status UI, encrypted message demo
- `lib/services/` – OAuth, contacts, encryption, and messaging abstractions
- `lib/models/` – Core data models

## Quick start

1. Install Flutter (stable) and platform SDKs.
2. Fetch packages:

```bash
flutter pub get
```

3. Run on a platform:

```bash
flutter run -d windows
flutter run -d macos
flutter run -d linux
flutter run -d android
```

## Build installers / binaries

### Windows (`.exe`)

```bash
flutter build windows --release
```

Bundle into MSI/installer with Inno Setup or WiX using `build/windows/x64/runner/Release` output.

### macOS (`.app`, `.dmg`)

```bash
flutter build macos --release
```

Package `.app` into `.dmg` using `create-dmg` or notarized packaging pipeline.

### Linux

```bash
flutter build linux --release
```

Package into `.deb`, `.rpm`, or AppImage via CI.

### Android (`.apk` / `.aab`)

```bash
flutter build apk --release
flutter build appbundle --release
```

## GitHub Actions build pipeline

This repo now includes a manual GitHub Actions workflow at `.github/workflows/build-artifacts.yml`.

To run it:

1. Push your branch to GitHub.
2. Open **Actions** → **Build Installers and Executables**.
3. Click **Run workflow** and select which platforms to build.
4. Download generated artifacts from the workflow run:
   - `windows-release`
   - `macos-release`
   - `linux-release`
   - `android-release`

## OAuth setup

You must configure OAuth credentials in the respective consoles:

- Google Cloud Console (OAuth client IDs)
- Meta for Developers (Facebook Login)

Then wire runtime secrets through platform-specific config files.

## Security model

- Messages are encrypted on-device using X25519 key exchange + AES-GCM (via `cryptography` package).
- The included code demonstrates encryption/decryption primitives.
- Production deployment should add:
  - Forward secrecy with per-session/per-message ratchets
  - Key verification UX
  - Device key backup/recovery
  - Replay protection and metadata minimization

## Presence model

Backchat tracks user-selected status (`online`, `offline`, `busy`) and can map provider presence where API access exists.

