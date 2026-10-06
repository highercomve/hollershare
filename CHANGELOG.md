# Changelog

Notable changes in HollerShare releases.

## Unreleased

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
