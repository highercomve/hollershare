# Changelog

Notable changes in HollerShare releases.

## [Unreleased]

Fixes from a code review against the NASA/JPL "Power of 10" rules.

- Receiving is safer against misbehaving devices on the network: a text or data payload can't grow past its declared size, idle and stalled connections time out, at most 16 incoming connections are handled at once, a failed accept no longer stops receiving until restart, and malformed messages (a short encryption IV, file data before the transfer is accepted, a negative size) are refused instead of crashing the connection.
- Received file names are also refused when they are Windows device names (CON, NUL, COM1…), end in a dot or space, or contain direction-override characters that can disguise an extension.
- `hollershare receive` no longer accepts transfers on its own when there is no one to ask (stdin closed): it declines unless `--auto-accept` is given. It reports when accepting or declining fails, gives up when the engine stops answering, and no longer grows in memory while it runs.
- If the sharing engine stops unexpectedly, the app notices and can start it again instead of failing every request. A slow request no longer blocks the others or quitting.
- Android: files shared from other apps are copied off the main thread, with limits (1024 files, 8 GB), so large shares no longer freeze the app; a new share no longer deletes files an earlier one is still sending; shared text is limited to 1 MB.
- Android: fixed a crash path when the system returned no application or class loader to the multicast and Bluetooth helpers.

## [1.0.3] — 2026-10-11

- Built on Oriel 0.9.15 (from 0.9.11). Fixed Android discovery on phones older than Android 14: a device lookup the system never answered blocked the lookups after it, and a failed one was never retried, so other computers and phones could stay missing. Lookups now time out after 10 seconds and failed ones are retried.

## [1.0.2] — 2026-10-09

- Built on Oriel 0.9.11 (from 0.9.3), with its memory-safety, Windows and Linux fixes.
- Fixed sending drag-and-drop files: resolve native path objects into strings before submitting the transfer.

## [1.0.1] — 2026-10-06

- Fixed Android startup without Wi-Fi: discovery registration retries automatically when a network becomes available, without blocking the sharing engine. Verified on Pixel 8 running Android 17.
- Included matching native debugging symbols in Android App Bundles and a separate symbols archive for diagnosing crashes and ANRs in Play Console.
- Clarified local discovery metadata and encrypted transfers in the online and offline privacy policies.
- Added a Zine website, sharing guide and public privacy policy on GitHub Pages.
- Added an offline privacy policy in Settings and Google Play listing artwork.
- Android builds target API 36 with AGP 8.9.3. Google Play builds disable GitHub updates.

## [1.0.0] — 2026-10-05

The first HollerShare release: native desktop and Android interfaces for
sharing files and text over your local network, with encrypted Quick Share
transfers, command-line sharing and signed update packages.

### Added

- HollerShare branding with the Relay H logo, launcher and tray icons, and
  header marks that adapt to light and dark mode. Android adaptive icons use
  a full green background and support themed launchers.
- Received text is copied to the clipboard as soon as an accepted transfer
  finishes, with a notification and an action to copy it again.
- Drag and drop files to add them to a transfer, or text to open the clipboard
  composer on desktop.
- Device-name and received-file-folder settings, including Android folder
  selection with lasting access.
- System dark mode with a warm palette.
- Android Bluetooth discovery beacon, Wi-Fi multicast lock and nearby-device
  permissions.
- A local Linux installer with `ORIEL_FORK` overrides for compatible local
  Oriel checkouts; the default dependency is pinned by commit and package hash.

### Improved

- Android discovery uses the system NsdManager, advertises the configured
  device name and starts the sharing engine off the UI thread.
- Desktop discovery selects reachable addresses and filters self-discovery
  and stale duplicate endpoints.
- Android helpers load through the app's ClassLoader, with engine logs
  available through logcat.
- Release builds use the official Oriel v0.9.2 framework and checksum-verified
  CLI binaries. Release notes are extracted from this changelog.
- The application id is `dev.hollershare.App`, the binary is `hollershare`,
  and settings and state use HollerShare folders. The installer removes legacy
  launchers while preserving previously received files.
