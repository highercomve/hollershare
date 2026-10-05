use std::fs::File;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use ts_rs::TS;

use super::TextPayloadType;
use crate::utils::RemoteDeviceInfo;

#[derive(Debug)]
pub struct InternalFileInfo {
    pub payload_id: i64,
    pub file_url: PathBuf,
    pub bytes_transferred: i64,
    pub total_size: i64,
    pub file: Option<File>,
    /// Inbound: the MIME type the sender gave (empty when it gave none).
    pub mime_type: String,
}

#[derive(Debug, Clone, Default, Deserialize, Serialize, TS)]
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
