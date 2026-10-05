# GhostShare

A native Oriel desktop app for sharing files over your local network with other computers and Android Quick Share. The UI runs on Oriel’s `native_ui` renderer (QuickJS, native DOM, Yoga and platform drawing), without a WebView.

## Run

For a fresh checkout, put the development framework beside this repository:

```sh
git clone --branch v0.9.1 https://github.com/highercomve/Oriel.git ../oriel
```

Requirements: Rust/Cargo, `protoc`, GTK4 development libraries and D-Bus development libraries on Linux. GhostShare uses the Oriel checkout at `../oriel`. CI checks out the official `v0.9.1` release alongside GhostShare and downloads its CLI from the matching GitHub release, verifying SHA256SUMS. Oriel installs the required Zig version automatically.

```sh
python3 scripts/setup-oriel.py
.oriel-cli/oriel-release-bin/oriel build -Dnative_ui
./zig-out/bin/ghostshare
```

Native rendering is the default, so `zig build -Doptimize=ReleaseSafe` works too. Cargo builds the protocol core into a static library and Zig links it into the application. The first build needs network access to fetch dependencies. There is no separate transfer daemon to install.

## Install locally (Linux)

```sh
./install-local.sh
```

Builds the native app and installs `~/.local/bin/ghostshare`, its icon, and
`~/.local/share/applications/dev.ghostshare.App.desktop`. The desktop launcher
appears as **GhostShare** in your application menu. The installer replaces the previous GhostFile launcher and binary; files already saved in `Downloads/GhostFile` are preserved. No sudo is needed. If
`XDG_DATA_HOME` is set, the launcher and icon use that directory instead.

Use `./install-local.sh --skip-build` to install the existing build. Additional
Zig options can be forwarded, for example `./install-local.sh -Doptimize=ReleaseFast`.


## Command-line interface (CLI)

GhostShare includes a headless CLI mode for terminal users, scripts, and autonomous agents to discover devices, send files or text to Android phones and computers, and receive files without opening a graphical window:

```sh
# Scan for nearby Quick Share receivers
ghostshare scan

# Send files to a device by name or direct IP:port
ghostshare send ./report.pdf --to "Pixel 8"
ghostshare send image1.png image2.png --to 192.168.1.50:53601

# Send text or a link
ghostshare send-text "https://github.com/highercomve/ghostshare" --to "Pixel 8"

# Pipe text from stdin (great for agent logs, output, or clipboard contents)
cat summary.txt | ghostshare send-text - --to "Pixel 8"

# Run a headless receiver saving to a custom folder
ghostshare receive --dir ~/Downloads/Shared --auto-accept
```

CLI commands bind ephemeral ports and run with receiver visibility disabled during send, allowing them to run alongside the desktop GUI without port collisions.

## Share

1. Open GhostShare on both computers, or open Android Quick Share’s receiving screen on the phone. Keep both devices on the same LAN/Wi-Fi network.
2. Choose files in GhostShare. Use the button again to add more files to the batch.
3. Select a nearby device and click Send.
4. Compare the confirmation PIN on both devices and accept on the receiver.

Received files go to `Downloads/GhostShare` (or `GhostShare` inside the home directory if no Downloads directory is configured). To use another folder, open Settings (⚙) and pick one with **Choose…**, the system's folder picker; **Use default folder** goes back. Incoming files need approval. Choose **Accept to default** or **Choose folder…** for each request. Completed Activity entries provide **Open file** and **Open folder**, using the actual saved filename. Existing files are preserved using numbered names. Partial files still owned by a failed or cancelled transfer are removed.

Visibility controls whether this computer advertises itself to nearby devices. Hiding does not block an already-known direct address or end an active transfer. The manual address field accepts a Quick Share destination’s IP and port, for example `192.168.1.20:54321`.

## Android compatibility

GhostShare uses the real Nearby Share / Quick Share LAN protocol through RQuickShare: mDNS discovery, UKEY2/P-256 key exchange, authenticated encrypted messages, confirmation PINs and file payloads. Bluetooth discovery triggers are enabled by default; they help Android advertise its receiving endpoint when BlueZ and an adapter are available. If a phone does not appear, enable Bluetooth and open its Quick Share receiving screen. Some Android/Samsung versions require additional interoperability work.

This implementation uses a shared local network. Wi-Fi Direct, hotspot creation, cloud transfers, Google contacts/account visibility and Wi-Fi credential sharing are not implemented. Plain text, links and files are supported.

Verified on Linux: native rendering and file selection, live Android discovery, and encrypted multi-file loopback transfers. The user has also received files from a physical Pixel 8. Windows, macOS and Android app builds are being checked by CI; device testing is still required. On Android, received files arrive in the app's own folder (`Android/data/dev.ghostshare.App/files/Received`); a folder chosen in Settings with **Choose…** (Android's folder picker, with access that lasts across restarts) receives each finished transfer, moved there by GhostShare. If that access is revoked, files stay in the app's folder and Settings asks for a folder again. GhostShare can't open received files on Android: open them from the Files app. The Android app holds a Wi-Fi multicast lock while it runs, without which Android drops the mDNS answers discovery relies on, and advertises the Quick Share BLE wake-up beacon (service 0xFE2C) once the Nearby devices permission is granted and Bluetooth is on, so nearby phones start announcing themselves; without it, an Android phone appears only while it is already advertising on the network (its Quick Share receiving screen open, visible to everyone). Other computers running GhostShare always advertise. The app announces the device name from Settings > About phone. The engine logs to logcat: `adb logcat -s Oriel GhostShare`. Folders are chosen with the system's picker on every desktop and on Android; opening received files is implemented on Linux only.

## Appearance and background receiving

Linux follows the desktop appearance setting (XDG Settings portal, GNOME setting, then GTK fallback), including changes while running. Closing the window keeps GhostShare receiving; the tray offers Show, Send files, Send clipboard, Visible to nearby devices, Check for updates and Quit. The tray visibility checkbox and the window switch stay synchronized; toggling discovery keeps a hidden window hidden. Incoming notifications show the confirmation PIN and offer Review request, Accept to default, and Decline. Accept saves to the default folder. Review opens the window to choose a save location. Completed notifications offer Open file and Open folder. No request is automatically accepted. Use Quit GhostShare in the window or tray to stop the engine. A desktop tray host and notification service are needed for those integrations.

## CI and signed releases

[GitHub Actions](https://github.com/highercomve/ghostshare/actions) builds Oriel packages for Linux x86_64 (.deb/.rpm/AppImage), macOS arm64 (.dmg), Windows x86_64 (NSIS), and Android arm64/x86_64 (APK/AAB). Pushes to main and pull requests build without signing secrets. A `v*` tag signs Windows/macOS/Android packages and publishes a GitHub release only after every platform succeeds. A manual workflow with `sign=true` verifies signed builds without publishing.

Certificates generated with `oriel signing create` are persistent, self-signed identities. They do not establish public SmartScreen/Gatekeeper trust or Apple notarization. Keep the originals and passwords in `~/.config/oriel/keys` backed up privately; never regenerate for routine releases.

Required repository secrets:

- Android: `ORIEL_ANDROID_KEYSTORE_BASE64`, `ORIEL_ANDROID_KEYSTORE_PASSWORD`, `ORIEL_ANDROID_KEY_ALIAS`, `ORIEL_ANDROID_KEY_PASSWORD`.
- macOS: `ORIEL_MACOS_CERT_P12_BASE64`, `ORIEL_MACOS_CERT_PASSWORD`, `ORIEL_MACOS_SIGN_IDENTITY`.
- Windows: `ORIEL_WINDOWS_CERT_P12_BASE64`, `ORIEL_WINDOWS_CERT_PASSWORD`.
- Updater: `ORIEL_UPDATE_KEY` (base64 Ed25519 seed). The public key is committed in `src/update-public-key.txt`.

Signing material is supplied only to trusted tag or explicitly signed manual builds, decoded into runner temporary directories, and removed after use. Local environment variables are not committed. Windows signs both the app payload and the rebuilt Oriel NSIS installer. Linux packages include SHA-256 checksums.

## Logo

The coral ghost carries a sharing arrow. Scalable SVG sources and launcher/tray PNGs are in [`assets/brand`](assets/brand/README.md). The header, desktop icon and tray use this mark.

## Updates

GhostShare automatically checks for updates on launch and every six hours. Check manually from the tray or the update bar. Desktop updates require **Install update**, verify the Ed25519 manifest plus payload size and SHA-256, replace the installed executable/AppImage or complete macOS app bundle, then offer **Restart now**. Restart is blocked while transfers are pending or active. System-owned installations may require installation through the package manager; the local installer and user-owned app packages can update directly.

Tagged releases publish `latest.json`, six individually signed update entries, and the corresponding payloads. Raw Linux executables and AppImages have separate entries. Windows updates contain the signed app executable; macOS updates contain the signed `.app` bundle. Android checks the same signed feed and offers the release APK download; Android installation requires the system installer and is not performed silently.

The first tagged release establishes the feed. Before that, the update bar reports that updates are unavailable. Preserve `~/.config/oriel/keys/ghostfile-update.key` privately: changing this key prevents existing installations from accepting new releases. Generate a replacement only as part of a planned key migration, using `zig build keygen -- --name ghostfile-update`.

## Test

```sh
zig build test
cargo test --locked --package rqs_lib --lib
python3 tests/quickshare_loopback.py
```

The loopback test loads the built Rust library in two separate processes. It verifies matching PINs, no files written before approval, encrypted multi-file delivery (including a 2 MB binary and an empty file), decline, cancellation, connection failures, visibility changes, preservation of existing files, Unicode clipboard text/URLs, text consent and size limits, and clean shutdown.

For native UI verification on a private Xvfb display:

```sh
bash tests/headless.sh ./tests/headless-ui.sh
bash tests/headless.sh python3 tests/desktop-integration.py
```

Screenshots and logs go in `artifacts/`. `GHOSTFILE_PORT` can fix the Quick Share TCP port for firewall rules; otherwise the OS chooses it. `RUST_LOG=rqs_lib=debug` enables protocol diagnostics.

## Structure and license

- `src/main.zig`: Oriel app, native file dialog and typed IPC commands.
- `frontend/`: HTML/CSS/JavaScript rendered natively.
- `native/quickshare/`: Rust C ABI, runtime lifecycle and bounded UI state.
- `vendor/rquickshare/`: pinned protocol engine with local interoperability and file-handling fixes; see `UPSTREAM.md`.

GPL-3.0-only, consistent with the integrated RQuickShare dependency. Oriel is MIT-licensed. GhostShare is an independent, unofficial application. Quick Share is a Google/Samsung trademark.

## Clipboard sharing

Choose **Clipboard text**, then **Paste clipboard** (or type text), review it, and select a nearby device. The tray also has **Send clipboard…**. Text and links use Quick Share text/BYTE payloads, with the same confirmation code and receiver approval as files. Text is limited to 1 MB. Clipboard images and automatic clipboard synchronization are not implemented.

Received text appears in Activity with **Copy text**, also available on its completion notification. Accepting text keeps it in the current session; it does not overwrite your clipboard or create a downloaded file. Copy is an explicit action.

Quick Share errors are saved in the application state directory (`~/.local/state/ghostshare/quickshare.log` on Linux). The previous log is retained when a log larger than 1 MB is rotated at startup. Outbound transfers remain active until the receiver confirms completion; a receiver that never confirms times out after 30 seconds.
