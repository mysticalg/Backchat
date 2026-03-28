# Backchat

Backchat is a cross-platform encrypted messaging app scaffold targeting:

- macOS
- Windows
- Linux
- Android
- iOS (optional from the same codebase)

Live page: [backchatapp.co.uk](https://backchatapp.co.uk/)

It includes:

- Browser OAuth sign-in for Google, Facebook, and X
- Profile import (avatar + display name)
- Contact discovery from providers (where APIs allow)
- End-to-end encryption primitives for messages
- Presence state (Online / Offline / Busy)
- Desktop taskbar unread badges and contact-side unread counters
- Local conversation history caching per computer
- One-to-one voice/video calling with advanced direct/VPN routing controls
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

### Windows (`.exe` installer)

```bash
flutter build windows --release
```

To package a proper Windows installer locally with Inno Setup:

```bash
"C:\Program Files (x86)\Inno Setup 6\ISCC.exe" /DMyAppVersion=0.1.0+12 /DMyBuildDir="build\windows\x64\runner\Release" /DMyOutputDir="." windows\installer\backchat.iss
```

The GitHub release workflow now publishes both a Windows installer EXE and a portable ZIP.

To remove Windows' `Unknown publisher` warning on other machines, you must
Authenticode-sign the app and installer with a trusted code-signing
certificate. This repo now supports optional signing in GitHub Actions and
locally:

- `WINDOWS_SIGN_PFX_BASE64` - base64-encoded `.pfx` certificate
- `WINDOWS_SIGN_PFX_PASSWORD` - password for that `.pfx`
- Optional `WINDOWS_SIGN_TIMESTAMP_URL` - RFC 3161 timestamp URL

If those variables are present, the Windows workflow signs both
`backchat.exe` and the generated setup EXE. For a local build, export the same
variables and run:

```powershell
.\scripts\windows-code-sign.ps1 -Files @(
  "build/windows/x64/runner/Release/backchat.exe",
  "backchat-windows-x64-0.1.0+12-setup.exe"
)
```

A self-signed certificate is fine for private/internal testing, but it will
still show as untrusted on other PCs. To clear the warning for normal users,
use a certificate that chains to a public trusted root (or a service such as
Trusted Signing).

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

Release signing now reads from `android/key.properties`. Copy
[`android/key.properties.example`](/Users/drhoo/OneDrive/Documents/GitHub/Backchat/android/key.properties.example)
to `android/key.properties`, point `storeFile` at your upload keystore, and
fill in the alias/passwords. Keep both the keystore and `android/key.properties`
out of git.

The GitHub `Build Installers and Executables` workflow expects these repository
secrets before Android release builds will pass:

- `ANDROID_UPLOAD_KEYSTORE_BASE64`
- `ANDROID_UPLOAD_STORE_PASSWORD`
- `ANDROID_UPLOAD_KEY_ALIAS`
- `ANDROID_UPLOAD_KEY_PASSWORD`

## Google Play internal testing

This repo also includes a manual workflow at
[`publish-google-play-internal.yml`](/Users/drhoo/OneDrive/Documents/GitHub/Backchat/.github/workflows/publish-google-play-internal.yml)
for uploading the signed Android App Bundle to Google Play.

Before it will work, add this extra repository secret:

- `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`

That secret should contain the full JSON for a Google Cloud service account that
has access to the app in Google Play Console API access.

The workflow currently publishes package:

```text
com.mysticalg.backchat
```

Recommended first use:

1. Create the app in Play Console for `com.mysticalg.backchat`.
2. Enable Play Console API access and grant the service account release
   permissions for the app.
3. Run **Actions** -> **Publish Android to Google Play**.
4. Choose `internal`.
5. Type `PUBLISH` to confirm.

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

Optional Windows signing secrets for that workflow:

- `WINDOWS_SIGN_PFX_BASE64`
- `WINDOWS_SIGN_PFX_PASSWORD`
- Optional `WINDOWS_SIGN_TIMESTAMP_URL`

GitHub Releases are only updated when all four platform builds are enabled and
pass in the same workflow run. This keeps the latest tagged release complete so
in-app updates can always find the right package for each platform.

## GitHub Actions backend deploy

This repo includes an Elastic Beanstalk deploy workflow at `.github/workflows/deploy-backend-api.yml` for pushing `backend/api/*` live.

Set these repository secrets first:

- `AWS_ROLE_TO_ASSUME`
- `BACKCHAT_SETUP_KEY`
- Optional OAuth secrets:
  - `BACKCHAT_GOOGLE_OAUTH_CLIENT_ID`
  - `BACKCHAT_GOOGLE_OAUTH_CLIENT_SECRET`
  - `BACKCHAT_GOOGLE_OAUTH_REDIRECT_URI`
  - `BACKCHAT_FACEBOOK_OAUTH_CLIENT_ID`
  - `BACKCHAT_FACEBOOK_OAUTH_CLIENT_SECRET`
  - `BACKCHAT_FACEBOOK_OAUTH_REDIRECT_URI`
  - `BACKCHAT_X_OAUTH_CLIENT_ID`
  - `BACKCHAT_X_OAUTH_CLIENT_SECRET`
  - `BACKCHAT_X_OAUTH_REDIRECT_URI`
- Optional WebRTC relay secrets:
  - `BACKCHAT_CALL_STUN_URLS`
  - `BACKCHAT_CALL_TURN_URLS`
  - `BACKCHAT_CALL_TURN_USERNAME`
  - `BACKCHAT_CALL_TURN_CREDENTIAL`

Run it:

1. Push backend changes to `main` to deploy automatically.
2. Or open **Actions** -> **Deploy Backend API** and run it manually.
3. For manual production runs, type `DEPLOY` in the confirmation box.
4. Set `run_setup` to `true` only when you want the workflow to call `setup.php`.

## OAuth setup

You must configure OAuth credentials in the respective consoles:

- Google Cloud Console (OAuth client IDs)
- Meta for Developers (Facebook Login)
- X Developer Portal (OAuth app keys)

Then wire runtime secrets through platform-specific config files.

For the current implementation, social login runs through the Backchat PHP API:

1. Fill OAuth keys in `backend/api/config.php` (copied from `config.php.example`).
2. Set each provider redirect URI to:
   - `https://<your-api-host>/auth_oauth_callback.php`
3. Re-run `POST /setup.php` once to create OAuth tables.
4. Run Flutter with your API base URL:

```bash
flutter run -d windows --dart-define=BACKCHAT_API_BASE_URL=https://<your-api-host>
```

> Note: OAuth providers generally require HTTPS redirect URIs. The current
> Elastic Beanstalk URL for this project is HTTP-only, so username-based sign-in
> works there, but Google/Facebook/X login should wait until you add HTTPS.

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

## Voice and video calls

Backchat now includes one-to-one voice/video calling over WebRTC:

- Signaling goes through the PHP API on AWS.
- Media attempts peer-to-peer routing first.
- Advanced settings let users prefer direct/VPN paths, force direct-only, or force relay-only.
- TURN relay fallback is optional and controlled by:
  - `BACKCHAT_CALL_STUN_URLS`
  - `BACKCHAT_CALL_TURN_URLS`
  - `BACKCHAT_CALL_TURN_USERNAME`
  - `BACKCHAT_CALL_TURN_CREDENTIAL`

If TURN is not configured, direct/VPN routes can still work, but some internet-to-internet calls may fail.

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
It now defaults to:

```text
https://d2axmspob6mqyx.cloudfront.net
```

Desktop and mobile builds can use that HTTPS URL as-is.

Run with:

```bash
flutter run -d windows --dart-define=BACKCHAT_API_BASE_URL=https://d2axmspob6mqyx.cloudfront.net
```

To enable the built-in GIPHY picker for the `GIF` button, also pass a GIPHY
API key at build time:

```bash
flutter run -d windows --dart-define=BACKCHAT_API_BASE_URL=https://d2axmspob6mqyx.cloudfront.net --dart-define=BACKCHAT_GIPHY_API_KEY=your_giphy_api_key
```

GitHub release workflows will also include the picker when
`BACKCHAT_GIPHY_API_KEY` is set as a repository variable or secret.

Server files are in `backend/api/`.

> Note: InfinityFree may inject a JavaScript anti-bot interstitial for direct
> API calls. Native app HTTP clients cannot execute that JavaScript, which
> breaks JSON API calls. If this happens, move the API to a host without that
> interstitial.

## Support

If you'd like to support this project, you can buy me a coffee:
[buymeacoffee.com/dhooksterm](https://buymeacoffee.com/dhooksterm)
