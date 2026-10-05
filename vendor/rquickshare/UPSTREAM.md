# RQuickShare protocol core

Source: https://github.com/Martichou/rquickshare
Revision: 378d8ae969941bee4bf60ad34ac9cf8bb7005eb7 (0.11.5)
License: GPL-3.0, see LICENSE.

GhostShare modifications:

- Reject unsafe incoming filenames, negative/oversized sizes and duplicate payload IDs.
- Create received files exclusively; preserve collisions both on disk and within a batch.
- Remove incomplete files owned by a failed/cancelled transfer and verify advertised length before completion.
- Accept nameless 17-byte Android advertisements.
- Correctly pad variable-width P-256 coordinates and reject invalid public keys.
- Replace deprecated digest slice access and use constant-time HMAC verification.
- Send termination frames for empty files; handle source files changing during send; process cancellation between chunks.
- Preserve partially read frame headers across cancelled reads and bound frame-read timeouts.
- Run outbound connections independently of accepting inbound connections; propagate connection failures with the correct transfer ID.
- Shut down mDNS daemons and avoid unregistering an already hidden service.
- Use Android NsdManager for both discovery and advertising, including saved-name changes and visibility. Announce Android endpoints as phones; avoid desktop multicast daemons on Android and report initial registration failures during startup.
- Advertise desktop mDNS hosts with the fully qualified `.local.` suffix so Android NsdManager can resolve their addresses.
- Exclude self-discovery using connected socket addresses even when native interface enumeration is unavailable on Android.
- Remove TypeScript binding writes during build.

Original schemas and copyright headers are retained. Regression coverage lives in the library tests and ../../tests/quickshare_loopback.py.

Additional GhostShare integration patches: per-transfer save directories, atomic
collision-safe file creation at acceptance, actual saved path metadata, portable
seek/write and file-length APIs, and hostname lookup without sys_metrics.

- Implement outbound Quick Share plain-text/URL metadata and encrypted BYTE payloads for clipboard sharing. Preserve UTF-8 text (including control byte 0x10), require consent before completing inbound text, and validate received payload length.

- Keep outbound transfers connected until receiver completion/acknowledgement, handle Android ACK/CONTROL packets without assuming they contain data chunks, and use 64 KiB file chunks. Do not report successful transfer merely because socket writes completed.
