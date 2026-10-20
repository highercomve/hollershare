use std::fs::File;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use ts_rs::TS;

use super::TextPayloadType;
use crate::utils::RemoteDeviceInfo;

#[derive(Debug)]
pub struct InternalFileInfo {
    pub file_url: PathBuf,
    pub bytes_transferred: i64,
    pub total_size: i64,
    pub file: Option<File>,
    /// Inbound: the MIME type the sender gave (empty when it gave none).
    pub mime_type: String,
}

#[derive(Clone, Default, Deserialize, Serialize, TS)]
#[ts(export)]
pub struct TransferMetadata {
    pub id: String,
    pub source: Option<RemoteDeviceInfo>,
    pub pin_code: Option<String>,

    pub destination: Option<String>,
    pub files: Option<Vec<String>>,
    pub saved_files: Option<Vec<String>>,
    /// Inbound, parallel to `saved_files`: each file's name as the sender
    /// gave it (a saved file may be "1_name" after a clash) and the MIME
    /// type it gave (empty when none).
    pub saved_names: Option<Vec<String>>,
    pub saved_mime_types: Option<Vec<String>>,

    pub text_type: Option<TextPayloadType>,
    pub text_description: Option<String>,
    pub text_payload: Option<String>,

    pub total_bytes: u64,
    pub ack_bytes: u64,
}

// Metadata includes clipboard contents, credentials, verification PINs and
// private file names. Debug is intentionally limited to transfer progress.
impl std::fmt::Debug for TransferMetadata {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.debug_struct("TransferMetadata")
            .field("id", &self.id)
            .field("file_count", &self.files.as_ref().map(Vec::len))
            .field("text_type", &self.text_type)
            .field("total_bytes", &self.total_bytes)
            .field("ack_bytes", &self.ack_bytes)
            .finish()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn diagnostics_exclude_transfer_secrets() {
        let secret = "AUDIT_SECRET_MARKER";
        let metadata = TransferMetadata {
            pin_code: Some(secret.into()),
            text_payload: Some(secret.into()),
            text_description: Some(secret.into()),
            files: Some(vec![secret.into()]),
            ..Default::default()
        };
        let payload = crate::SendInfo {
            id: "transfer".into(),
            name: "peer".into(),
            addr: "127.0.0.1:1".into(),
            ob: super::super::OutboundPayload::Text(secret.into()),
        };
        assert!(!format!("{metadata:?} {payload:?}").contains(secret));
        // Serialization to the application still carries the actual contents.
        assert_eq!(metadata.text_payload.as_deref(), Some(secret));
    }
}
