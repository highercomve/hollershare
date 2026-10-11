use std::collections::HashMap;
use std::time::Duration;

use anyhow::anyhow;
use libaes::{Cipher, AES_256_KEY_LEN};
use p256::{PublicKey, SecretKey};
use serde::{Deserialize, Serialize};
use ts_rs::TS;

use self::info::{InternalFileInfo, TransferMetadata};
use crate::securegcm::ukey2_client_init::CipherCommitment;
use crate::utils::RemoteDeviceInfo;

#[cfg(feature = "experimental")]
mod ble;
#[cfg(feature = "experimental")]
pub use ble::*;
#[cfg(all(feature = "experimental", target_os = "linux"))]
mod blea;
#[cfg(all(feature = "experimental", target_os = "linux"))]
pub use blea::*;
mod inbound;
pub use inbound::*;
pub(crate) mod info;
mod mdns_discovery;
pub use mdns_discovery::*;
#[cfg(any(target_os = "android", test))]
mod android_mdns;
#[cfg(target_os = "android")]
pub use android_mdns::MDnsServer;
mod mdns;
pub use mdns::*;
mod outbound;
pub use outbound::*;

#[allow(dead_code)]
#[derive(Debug, Clone, Default, Serialize, Deserialize, TS, PartialEq)]
#[ts(export)]
pub enum State {
    #[default]
    Initial,
    ReceivedConnectionRequest,
    SentUkeyServerInit,
    SentUkeyClientInit,
    SentUkeyClientFinish,
    SentPairedKeyEncryption,
    ReceivedUkeyClientFinish,
    SentConnectionResponse,
    SentPairedKeyResult,
    SentIntroduction,
    ReceivedPairedKeyResult,
    WaitingForUserConsent,
    ReceivingFiles,
    SendingFiles,
    Disconnected,
    Rejected,
    Cancelled,
    Finished,
}

#[derive(Debug, Default)]
pub struct InnerState {
    pub id: String,
    pub server_seq: i32,
    pub client_seq: i32,
    pub encryption_done: bool,

    // Subject to be used-facing for progress, ...
    pub state: State,
    pub remote_device_info: Option<RemoteDeviceInfo>,
    pub pin_code: Option<String>,
    pub transfer_metadata: Option<TransferMetadata>,
    pub transferred_files: HashMap<i64, InternalFileInfo>,

    // Everything needed for encryption/decryption/verif
    pub cipher_commitment: Option<CipherCommitment>,
    pub private_key: Option<SecretKey>,
    pub public_key: Option<PublicKey>,
    pub server_init_data: Option<Vec<u8>>,
    pub client_init_msg_data: Option<Vec<u8>>,
    pub ukey_client_finish_msg_data: Option<Vec<u8>>,
    pub decrypt_key: Option<Vec<u8>>,
    pub recv_hmac_key: Option<Vec<u8>>,
    pub encrypt_key: Option<Vec<u8>>,
    pub send_hmac_key: Option<Vec<u8>>,

    // Used to handle/track ingress transfer
    pub text_payload: Option<TextPayloadInfo>,
    // pub text_payload_id: i64,
    // pub text_is_url: bool,
    // pub wifi_ssid: Option<String>,
    pub payload_buffers: HashMap<i64, Vec<u8>>,
}

#[derive(Debug, Clone)]
pub enum TextPayloadInfo {
    Url(i64),
    Text(i64),
    Wifi((i64, String)),
}

#[derive(Debug, Clone, Serialize, Deserialize, TS)]
pub enum TextPayloadType {
    Url,
    Text,
    Wifi,
}

impl TextPayloadInfo {
    fn get_i64_value(&self) -> i64 {
        match self {
            TextPayloadInfo::Url(value)
            | TextPayloadInfo::Text(value)
            | TextPayloadInfo::Wifi((value, _)) => value.to_owned(),
        }
    }
}

/// Largest Bytes payload (and frame) accepted from a peer.
pub(crate) const SANE_FRAME_LENGTH: i32 = 5 * 1024 * 1024;
/// Most Bytes payloads a peer may have in flight at once.
pub(crate) const MAX_PAYLOAD_BUFFERS: usize = 8;
/// Upper bound on what is reserved up front for a new Bytes payload.
const PAYLOAD_INITIAL_RESERVE: usize = 64 * 1024;
/// How long a peer may stay silent before the connection is dropped.
pub(crate) const IDLE_TIMEOUT: Duration = Duration::from_secs(60);
/// How long a single socket write may take.
pub(crate) const WRITE_TIMEOUT: Duration = Duration::from_secs(30);
/// AES-CBC block / IV size.
const AES_IV_LEN: usize = 16;

/// Append one chunk of a Bytes payload to its reassembly buffer.
///
/// Validates the declared total size, the number of in-flight payloads,
/// the chunk offset and that the buffer never grows past the declared
/// total. On any error the payload's buffer is removed.
pub(crate) fn append_bytes_chunk(
    buffers: &mut HashMap<i64, Vec<u8>>,
    payload_id: i64,
    total_size: i64,
    offset: i64,
    body: Option<&[u8]>,
) -> Result<(), anyhow::Error> {
    if total_size < 0 || total_size > i64::from(SANE_FRAME_LENGTH) {
        buffers.remove(&payload_id);
        return Err(anyhow!("Payload too large: {} bytes", total_size));
    }
    // Bounded by SANE_FRAME_LENGTH above, so this cannot truncate.
    let total = total_size as usize;

    if !buffers.contains_key(&payload_id) {
        if buffers.len() >= MAX_PAYLOAD_BUFFERS {
            return Err(anyhow!("Too many concurrent payloads"));
        }
        buffers.insert(payload_id, Vec::with_capacity(total.min(PAYLOAD_INITIAL_RESERVE)));
    }

    let buffer_len = buffers.get(&payload_id).map_or(0, Vec::len);
    if offset != buffer_len as i64 {
        buffers.remove(&payload_id);
        return Err(anyhow!(
            "Unexpected chunk offset: {}, expected: {}",
            offset,
            buffer_len
        ));
    }

    let body = body.unwrap_or_default();
    if buffer_len.saturating_add(body.len()) > total {
        buffers.remove(&payload_id);
        return Err(anyhow!(
            "Payload exceeds declared size: {} > {}",
            buffer_len.saturating_add(body.len()),
            total
        ));
    }

    if let Some(buffer) = buffers.get_mut(&payload_id) {
        buffer.extend_from_slice(body);
    }
    Ok(())
}

/// AES-256-CBC decrypt with a peer-supplied IV, rejecting malformed input
/// instead of letting libaes panic on a short IV or key.
pub(crate) fn aes_cbc_decrypt(key: &[u8], iv: &[u8], data: &[u8]) -> Result<Vec<u8>, anyhow::Error> {
    if iv.len() != AES_IV_LEN {
        return Err(anyhow!("Invalid IV length: {}", iv.len()));
    }
    let key: &[u8; AES_256_KEY_LEN] = key
        .get(..AES_256_KEY_LEN)
        .and_then(|k| k.try_into().ok())
        .ok_or_else(|| anyhow!("Invalid decryption key"))?;
    let mut cipher = Cipher::new_256(key);
    cipher.set_auto_padding(true);
    Ok(cipher.cbc_decrypt(iv, data))
}

/// AES-256-CBC encrypt with a locally generated IV.
pub(crate) fn aes_cbc_encrypt(key: &[u8], iv: &[u8], data: &[u8]) -> Result<Vec<u8>, anyhow::Error> {
    if iv.len() != AES_IV_LEN {
        return Err(anyhow!("Invalid IV length: {}", iv.len()));
    }
    let key: &[u8; AES_256_KEY_LEN] = key
        .get(..AES_256_KEY_LEN)
        .and_then(|k| k.try_into().ok())
        .ok_or_else(|| anyhow!("Invalid encryption key"))?;
    let mut cipher = Cipher::new_256(key);
    cipher.set_auto_padding(true);
    Ok(cipher.cbc_encrypt(iv, data))
}

/// Increment a D2D sequence counter, failing instead of overflowing.
pub(crate) fn next_seq(seq: &mut i32) -> Result<i32, anyhow::Error> {
    *seq = seq
        .checked_add(1)
        .ok_or_else(|| anyhow!("Sequence number overflow"))?;
    Ok(*seq)
}

/// Write a whole buffer to the socket, bounded by WRITE_TIMEOUT.
pub(crate) async fn write_all_timeout(
    socket: &mut tokio::net::TcpStream,
    data: &[u8],
) -> Result<(), anyhow::Error> {
    use tokio::io::AsyncWriteExt;
    tokio::time::timeout(WRITE_TIMEOUT, async {
        socket.write_all(data).await?;
        socket.flush().await
    })
    .await
    .map_err(|_| anyhow!("Socket write timed out"))??;
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn bytes_payload_rejects_overflow_and_bad_input() {
        let mut b = HashMap::new();
        // Normal reassembly.
        append_bytes_chunk(&mut b, 1, 6, 0, Some(b"abc")).unwrap();
        append_bytes_chunk(&mut b, 1, 6, 3, Some(b"def")).unwrap();
        assert_eq!(b[&1], b"abcdef");
        // Growing past the declared total drops the buffer.
        append_bytes_chunk(&mut b, 2, 4, 0, Some(b"abc")).unwrap();
        assert!(append_bytes_chunk(&mut b, 2, 4, 3, Some(b"de")).is_err());
        assert!(!b.contains_key(&2));
        // Single oversized chunk.
        assert!(append_bytes_chunk(&mut b, 3, 2, 0, Some(b"abc")).is_err());
        assert!(!b.contains_key(&3));
        // Bad total size and bad offset.
        assert!(append_bytes_chunk(&mut b, 4, -1, 0, None).is_err());
        assert!(append_bytes_chunk(&mut b, 4, i64::from(SANE_FRAME_LENGTH) + 1, 0, None).is_err());
        assert!(append_bytes_chunk(&mut b, 5, 10, 4, Some(b"x")).is_err());
        assert!(!b.contains_key(&5));
        // Cap on concurrent payloads.
        b.clear();
        for id in 0..MAX_PAYLOAD_BUFFERS as i64 {
            append_bytes_chunk(&mut b, id, 10, 0, Some(b"x")).unwrap();
        }
        assert!(append_bytes_chunk(&mut b, 100, 10, 0, Some(b"x")).is_err());
        // Existing ids still progress.
        append_bytes_chunk(&mut b, 0, 10, 1, Some(b"y")).unwrap();
    }

    #[test]
    fn cbc_decrypt_rejects_bad_iv_and_key() {
        let key = [7u8; 32];
        let iv = [1u8; 16];
        let ct = aes_cbc_encrypt(&key, &iv, b"hello").unwrap();
        assert_eq!(aes_cbc_decrypt(&key, &iv, &ct).unwrap(), b"hello");
        assert!(aes_cbc_decrypt(&key, &[], &ct).is_err());
        assert!(aes_cbc_decrypt(&key, &iv[..15], &ct).is_err());
        assert!(aes_cbc_decrypt(&key, &[0u8; 17], &ct).is_err());
        assert!(aes_cbc_decrypt(&key[..16], &iv, &ct).is_err());
    }

    #[test]
    fn seq_counter_does_not_overflow() {
        let mut s = i32::MAX - 1;
        assert_eq!(next_seq(&mut s).unwrap(), i32::MAX);
        assert!(next_seq(&mut s).is_err());
    }
}
