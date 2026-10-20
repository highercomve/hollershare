//! Quick Share over Bluetooth Classic (BlueZ): receivers that don't announce
//! themselves on the LAN, such as a Chromebook, advertise their endpoint in
//! their Bluetooth device name, and take connections on an RFCOMM service
//! named after the Nearby service id. Discovery decodes those names; a
//! sender connects through a BlueZ client profile for that service (BlueZ
//! finds its channel) and speaks the same Nearby frames as over TCP.
//!
//! Device name (base64url): [VERSION(3 bits)|PCP(5 bits)][ENDPOINT_ID(4)]
//! [SERVICE_ID_HASH(3)][FIELD(1)][RESERVED(6)][ENDPOINT_INFO_SIZE(1)]
//! [ENDPOINT_INFO] (Nearby Connections' BluetoothDeviceName).

use std::collections::HashMap;
use std::time::Duration;

use anyhow::anyhow;
use base64::engine::general_purpose::URL_SAFE_NO_PAD;
use base64::Engine;
use bluer::rfcomm::{Profile, ProfileHandle, Role, Stream};
use bluer::{Address, DiscoveryFilter, DiscoveryTransport, Session};
use futures::StreamExt;
use sha2::{Digest, Sha256};
use tokio::sync::broadcast;
use tokio_util::sync::CancellationToken;
use uuid::{uuid, Uuid};

use crate::hdl::EndpointInfo;
use crate::utils::{parse_endpoint_info, DeviceType};

const INNER_NAME: &str = "BtClassic";

/// Quick Share's Nearby service id.
const SERVICE_ID: &str = "NearbySharing";
/// Its RFCOMM service: a name-based UUID (v3, MD5) of the service id, as
/// Nearby Connections makes it (Java's UUID.nameUUIDFromBytes).
pub const SERVICE_UUID: Uuid = uuid!("a82efa21-ae5c-3dde-9bbc-f16da7b16c5a");
/// The address prefix of a Bluetooth peer (`bt:AA:BB:CC:DD:EE:FF`).
pub const ADDRESS_PREFIX: &str = "bt:";

const VERSION_V1: u8 = 1;
const PCP_P2P_CLUSTER: u8 = 1;
const PCP_P2P_STAR: u8 = 2;
const PCP_P2P_POINT_TO_POINT: u8 = 3;
const HEADER_LENGTH: usize = 1 + 4 + 3 + 1 + 6;

/// A Quick Share receiver's Bluetooth device name: its endpoint id, device
/// type and name (None: not a Quick Share endpoint).
pub fn parse_device_name(name: &str) -> Option<(String, DeviceType, String)> {
    let bytes = URL_SAFE_NO_PAD.decode(name.trim_end_matches('=')).ok()?;
    if bytes.len() < HEADER_LENGTH + 1 {
        return None;
    }
    if bytes[0] >> 5 != VERSION_V1 {
        return None;
    }
    let pcp = bytes[0] & 0x1f;
    if !matches!(pcp, PCP_P2P_CLUSTER | PCP_P2P_STAR | PCP_P2P_POINT_TO_POINT) {
        return None;
    }
    let endpoint_id = std::str::from_utf8(&bytes[1..5]).ok()?.to_owned();
    if bytes[5..8] != Sha256::digest(SERVICE_ID.as_bytes())[..3] {
        return None;
    }
    let info_length = bytes[HEADER_LENGTH] as usize;
    let info = bytes.get(HEADER_LENGTH + 1..HEADER_LENGTH + 1 + info_length)?;
    let (device_type, device_name) = parse_endpoint_info(info).ok()?;
    Some((endpoint_id, device_type, device_name))
}

/// The address a peer found over Bluetooth is sent to.
pub fn peer_address(address: Address) -> String {
    format!("{ADDRESS_PREFIX}{address}")
}

/// A `bt:` address's Bluetooth address (None: not one).
pub fn parse_peer_address(address: &str) -> Option<Address> {
    address.strip_prefix(ADDRESS_PREFIX)?.parse().ok()
}

/// Finds Quick Share receivers by their Bluetooth device names, while
/// discovery runs: present while in range (BlueZ reports their RSSI), gone
/// when they leave or stop advertising.
pub struct BtDiscovery {
    sender: broadcast::Sender<EndpointInfo>,
}

impl BtDiscovery {
    pub fn new(sender: broadcast::Sender<EndpointInfo>) -> Self {
        Self { sender }
    }

    pub async fn run(self, ctk: CancellationToken) -> Result<(), anyhow::Error> {
        info!("{INNER_NAME}: discovery starting");
        let session = Session::new().await?;
        let adapter = session.default_adapter().await?;
        if !adapter.is_powered().await? {
            return Err(anyhow!("the Bluetooth adapter is off"));
        }
        adapter
            .set_discovery_filter(DiscoveryFilter {
                transport: DiscoveryTransport::BrEdr,
                ..Default::default()
            })
            .await?;
        // Keeps BR/EDR inquiry running while it's held.
        let mut events = adapter.discover_devices_with_changes().await?;
        let mut tick = tokio::time::interval(Duration::from_secs(2));
        // Address → what was last reported (an endpoint seen).
        let mut seen: HashMap<Address, EndpointInfo> = HashMap::new();

        loop {
            tokio::select! {
                _ = ctk.cancelled() => {
                    info!("{INNER_NAME}: discovery cancelled");
                    break;
                }
                event = events.next() => {
                    if event.is_none() {
                        break;
                    }
                }
                _ = tick.tick() => {}
            }
            // What's in range now, and named as a Quick Share receiver.
            let mut now: HashMap<Address, EndpointInfo> = HashMap::new();
            for address in adapter.device_addresses().await.unwrap_or_default() {
                let Ok(device) = adapter.device(address) else { continue };
                if !matches!(device.rssi().await, Ok(Some(_))) {
                    continue;
                }
                let Ok(Some(name)) = device.name().await else { continue };
                let Some((endpoint_id, device_type, device_name)) = parse_device_name(&name) else {
                    continue;
                };
                now.insert(address, EndpointInfo {
                    fullname: format!("{endpoint_id}@{address}"),
                    id: peer_address(address),
                    name: Some(device_name),
                    ip: None,
                    port: None,
                    rtype: Some(device_type),
                    present: Some(true),
                });
            }
            for (address, info) in &now {
                if seen.get(address).map(|old| old.name != info.name || old.rtype != info.rtype).unwrap_or(true) {
                    debug!("{INNER_NAME}: found {:?} at {address}", info.name);
                    let _ = self.sender.send(info.clone());
                }
            }
            for (address, info) in &seen {
                if !now.contains_key(address) {
                    debug!("{INNER_NAME}: lost {address}");
                    let _ = self.sender.send(EndpointInfo { present: Some(false), ..info.clone() });
                }
            }
            seen = now;
        }
        for info in seen.into_values() {
            let _ = self.sender.send(EndpointInfo { present: Some(false), ..info });
        }
        Ok(())
    }
}

/// The profile registration belongs to the stream, so completing, failing or
/// cancelling a transfer drops both resources. No detached keepalive task.
#[derive(Debug)]
pub struct Connection {
    stream: Stream,
    _profile: ProfileHandle,
}

impl tokio::io::AsyncRead for Connection {
    fn poll_read(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &mut tokio::io::ReadBuf<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().stream).poll_read(cx, buf)
    }
}

impl tokio::io::AsyncWrite for Connection {
    fn poll_write(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
        buf: &[u8],
    ) -> std::task::Poll<std::io::Result<usize>> {
        std::pin::Pin::new(&mut self.get_mut().stream).poll_write(cx, buf)
    }
    fn poll_flush(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().stream).poll_flush(cx)
    }
    fn poll_shutdown(
        self: std::pin::Pin<&mut Self>,
        cx: &mut std::task::Context<'_>,
    ) -> std::task::Poll<std::io::Result<()>> {
        std::pin::Pin::new(&mut self.get_mut().stream).poll_shutdown(cx)
    }
}

/// Connect and accept concurrently: BlueZ can wait for accept() before its
/// connect call returns. Failure/timeout drops both futures and the profile.
pub async fn connect(address: Address) -> Result<Connection, anyhow::Error> {
    tokio::time::timeout(Duration::from_secs(20), async {
        let session = Session::new().await?;
        let adapter = session.default_adapter().await?;
        let device = adapter.device(address)?;
        let mut profile = session
            .register_profile(Profile {
                uuid: SERVICE_UUID,
                name: Some("Quick Share".into()),
                role: Some(Role::Client),
                require_authentication: Some(false),
                require_authorization: Some(false),
                auto_connect: Some(false),
                ..Default::default()
            })
            .await?;
        let (_, stream) = tokio::try_join!(
            async {
                device
                    .connect_profile(&SERVICE_UUID)
                    .await
                    .map_err(anyhow::Error::from)
            },
            async {
                profile
                    .next()
                    .await
                    .ok_or_else(|| anyhow!("Bluetooth profile closed"))?
                    .accept()
                    .map_err(anyhow::Error::from)
            },
        )?;
        Ok(Connection {
            stream,
            _profile: profile,
        })
    })
    .await
    .map_err(|_| anyhow!("Bluetooth connection timed out"))?
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn decodes_a_chromebooks_device_name() {
        let (endpoint, device_type, name) =
            parse_device_name("I0VIUlb8n14AAAAAAAAAJQbUVKmdhgh4PMr6KocB5iZ0E1NlcmdpbydzIENocm9tZWJvb2s").unwrap();
        assert_eq!(endpoint, "EHRV");
        assert_eq!(device_type, DeviceType::Laptop);
        assert_eq!(name, "Sergio's Chromebook");
    }

    #[test]
    fn ignores_other_devices() {
        assert!(parse_device_name("Samsung The Frame 50").is_none());
        assert!(parse_device_name("pvwificonnect").is_none());
    }

    #[test]
    fn service_uuid_is_the_service_ids() {
        let mut h: [u8; 16] = md5_of(SERVICE_ID.as_bytes());
        h[6] = (h[6] & 0x0f) | 0x30;
        h[8] = (h[8] & 0x3f) | 0x80;
        assert_eq!(Uuid::from_bytes(h), SERVICE_UUID);
    }

    // MD5, for the test above only (RFC 1321).
    fn md5_of(data: &[u8]) -> [u8; 16] {
        let s: [u32; 64] = [
            7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 7, 12, 17, 22, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20, 5, 9, 14, 20,
            4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 4, 11, 16, 23, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21, 6, 10, 15, 21,
        ];
        let k: Vec<u32> = (0..64).map(|i| ((i as f64 + 1.0).sin().abs() * 4294967296.0) as u32).collect();
        let (mut a0, mut b0, mut c0, mut d0) = (0x67452301u32, 0xefcdab89u32, 0x98badcfeu32, 0x10325476u32);
        let mut msg = data.to_vec();
        let bit_len = (data.len() as u64).wrapping_mul(8);
        msg.push(0x80);
        while msg.len() % 64 != 56 {
            msg.push(0);
        }
        msg.extend_from_slice(&bit_len.to_le_bytes());
        for chunk in msg.chunks(64) {
            let m: Vec<u32> = chunk.chunks(4).map(|w| u32::from_le_bytes([w[0], w[1], w[2], w[3]])).collect();
            let (mut a, mut b, mut c, mut d) = (a0, b0, c0, d0);
            for i in 0..64 {
                let (f, g) = match i / 16 {
                    0 => ((b & c) | (!b & d), i),
                    1 => ((d & b) | (!d & c), (5 * i + 1) % 16),
                    2 => (b ^ c ^ d, (3 * i + 5) % 16),
                    _ => (c ^ (b | !d), (7 * i) % 16),
                };
                let f2 = f.wrapping_add(a).wrapping_add(k[i]).wrapping_add(m[g]);
                a = d;
                d = c;
                c = b;
                b = b.wrapping_add(f2.rotate_left(s[i]));
            }
            a0 = a0.wrapping_add(a);
            b0 = b0.wrapping_add(b);
            c0 = c0.wrapping_add(c);
            d0 = d0.wrapping_add(d);
        }
        let mut out = [0u8; 16];
        for (i, v) in [a0, b0, c0, d0].iter().enumerate() {
            out[i * 4..i * 4 + 4].copy_from_slice(&v.to_le_bytes());
        }
        out
    }
}
