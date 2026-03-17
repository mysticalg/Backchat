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

## Direct computer-to-computer messaging (P2P)

Short answer: **Flutter can do P2P-capable apps**, but Flutter itself is just the UI/runtime layer.

- This scaffold currently has an in-memory `MessagingService` for demo behavior and does **not** include internet transport yet.
- Real-world chat apps usually still need at least a lightweight backend for:
  - identity/account lookup
  - key directory / pre-key bundles
  - push notification wakeups (mobile)
  - offline message queueing
  - NAT/firewall traversal signaling
- True direct device-to-device delivery is possible for some peers (for example using WebRTC data channels), but many networks block inbound direct connections without relay fallback.

### Practical architecture options

1. **Server-routed E2EE (most common)**
   - Encrypted on sender device, decrypted on receiver device.
   - Server only routes ciphertext and metadata.
2. **Hybrid P2P + relay fallback**
   - Attempt direct channel first.
   - Fall back to TURN/relay when peers cannot connect directly.
3. **LAN-only direct mode**
   - Works well on same local network.
   - Limited for internet-wide reliability.

If your goal is "no third party can read messages," option 1 already achieves that with solid end-to-end encryption.
If your goal is "no middlebox at all," expect reduced reliability unless both peers are on friendly networks.

## Hosted API (username sync + invites)

The app can use a hosted API for shared username accounts and contact invites.

Run with:

```bash
flutter run -d windows --dart-define=BACKCHAT_API_BASE_URL=https://mysticalg.kesug.com/backchat-api
```

Server files are in `backend/api/`.

> Note: InfinityFree may inject a JavaScript anti-bot interstitial for direct
> API calls. Native app HTTP clients cannot execute that JavaScript, which
> breaks JSON API calls. If this happens, move the API to a host without that
> interstitial.
