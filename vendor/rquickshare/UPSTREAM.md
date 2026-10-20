# RQuickShare protocol core

Source: https://github.com/Martichou/rquickshare
Revision: 378d8ae969941bee4bf60ad34ac9cf8bb7005eb7 (0.11.5)
License: GPL-3.0, see LICENSE.

HollerShare modifications:

- Reject unsafe incoming filenames, negative/oversized sizes and duplicate payload IDs.
- Create received files exclusively; preserve collisions both on disk and within a batch.
- Remove incomplete files owned by a failed/cancelled transfer and verify advertised length before completion.
- Accept nameless 17-byte Android endpoints in discovery and incoming connections, using the same validated parser.
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

Additional HollerShare integration patches: per-transfer save directories, atomic
collision-safe file creation at acceptance, actual saved path metadata, portable
seek/write and file-length APIs, and hostname lookup without sys_metrics.

- Implement outbound Quick Share plain-text/URL metadata and encrypted BYTE payloads for clipboard sharing. Preserve UTF-8 text (including control byte 0x10), require consent before completing inbound text, and validate received payload length.

- Keep outbound transfers connected until receiver completion/acknowledgement, handle Android ACK/CONTROL packets without assuming they contain data chunks, and use 64 KiB file chunks. Do not report successful transfer merely because socket writes completed.

## Resource and diagnostic boundaries

- Before decoding sharing protobufs, scan borrowed wire slices to limit the
  aggregate file/text/Wi-Fi metadata count to 1,024 and certificates to 128.
  Budgets span duplicate envelopes because protobuf merges singular messages.
  Keep this check aligned with repeated fields in `wire_format.proto`.
- Inbound connections are limited to 16 globally and four per IP. Waiting for
  consent expires after 120 seconds, independently of keepalives. Dropping a
  connection releases both permits and incomplete files.
- Desktop and Android discovery retain at most 128 services. Resolution refreshes
  recency; eviction publishes a removal so consumers do not retain stale entries.
- Bluetooth profile registrations belong to their connection streams. Connect
  and accept run concurrently under a single timeout, without detached tasks.
- Diagnostic formatting excludes outgoing text, file paths, received content,
  credentials and verification PINs. The application still receives full transfer
  metadata through serialization; logs are not a substitute for that channel.

Power of 10 principles guide these boundaries, but this desktop/mobile protocol
engine is not a strictly compliant safety-critical system. Rust/Tokio and GUI
frameworks allocate during normal operation; network buffers and collections must
therefore have explicit admission limits rather than a no-allocation claim.
Long-running service loops are intentional and cancellable. Fallible validation
returns errors for hostile input rather than relying on process-aborting
assertions. GTK callbacks and platform conditional compilation remain necessary
framework boundaries; the native C layer tracks signal handler IDs for cleanup.
No claim is made about assertion-density or whole-program static stack bounds.

Regression tests cover allocation-amplification inputs, duplicate protobuf
wrappers, consent expiry, admission/permit cleanup, cache eviction and log
redaction. Linux CI runs Clippy with warnings denied, pedantic C compilation and
Clang static analysis, alongside encrypted transfer integration tests.

Native Quick Share interoperability: accept the sender's early ACCEPT response
while awaiting its introduction, without advancing local consent state. Poco X3
hardware validation covers native Quick Share text and image sends to the engine,
image sends back to native Quick Share, matching PINs, exact file contents and
TRACE-log redaction. The early-response regression test explicitly rejects text
payloads until the local user approves.
