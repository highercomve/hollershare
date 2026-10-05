# Changelog

Notable changes in GhostShare releases.

## [0.2.0] — 2026-10-05

GhostShare 0.2.0 improves Android discovery and adds device and download-folder
settings, with a warm dark theme that follows the system.

### Added

- Settings for the advertised device name and received-file folder, including
  Android folder selection with lasting access.
- System dark mode with a warm palette.
- Android Bluetooth discovery beacon, Wi-Fi multicast lock and nearby-device
  permissions, plus launcher icons at multiple sizes.

### Improved

- Android service discovery and advertising use the system NsdManager through
  Oriel v0.9.1. Saved device names are advertised and updated immediately.
- Desktop discovery checks multiple advertised network interfaces and selects
  a reachable address instead of blocking on an unroutable interface.
- Android starts its sharing engine off the UI thread and reports engine logs
  through logcat.
- Builds use the official Oriel v0.9.1 framework tag and download its released
  CLI binaries with checksum verification. The CLI manages the required Zig
  version automatically.
- Release notes are read from this changelog for reproducible release text.

### Fixed

- Android discovery crashes when resolving services with multiple TXT
  attributes, using the fix released in Oriel v0.9.1.
- Devices discovering their own sharing endpoint.
- Stale duplicate rows for the same device after its listening port changes;
  reachable endpoints remain available.
- Desktop mDNS hostname formatting so Android can resolve advertisements.
- Android helper loading through the app's ClassLoader and stale startup
  status messages.

### Validation

- 27 Rust protocol and bridge tests passed, including registration cleanup,
  self-discovery filtering and stale endpoint handling.
- Android APK built for ARM64 and x86_64; final manifest and helper classes
  checked in the APK.
- Discovery and transfers checked with a Poco X3, Pixel 8 and Linux desktop,
  including an APK transfer to the Pixel through native Quick Share.

## [0.1.0] — 2026-10-05

- Initial release with native desktop and Android interfaces, encrypted Quick
  Share transfers, command-line sharing and signed update packages.
