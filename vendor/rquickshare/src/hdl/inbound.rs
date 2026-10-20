use std::io::{Seek, SeekFrom, Write};
use std::time::Duration;

use anyhow::anyhow;
use bytes::Bytes;
use hmac::{Hmac, Mac};
use p256::ecdh::diffie_hellman;
use p256::elliptic_curve::sec1::{FromEncodedPoint, ToEncodedPoint};
use p256::{EncodedPoint, PublicKey};
use prost::Message;
use rand::Rng;
use sha2::{Digest, Sha256, Sha512};
use tokio::io::AsyncReadExt;
use tokio::net::TcpStream;
use tokio::sync::broadcast::{Receiver, Sender};

use super::{
    aes_cbc_decrypt, aes_cbc_encrypt, append_bytes_chunk, next_seq, write_all_timeout,
    InnerState, State, IDLE_TIMEOUT, SANE_FRAME_LENGTH,
};
use crate::channel::{ChannelAction, ChannelDirection, ChannelMessage};
use crate::hdl::info::{InternalFileInfo, TransferMetadata};
use crate::hdl::{TextPayloadInfo, TextPayloadType};
use crate::location_nearby_connections::payload_transfer_frame::{
    payload_header, PacketType, PayloadChunk, PayloadHeader,
};
use crate::location_nearby_connections::{KeepAliveFrame, OfflineFrame, PayloadTransferFrame};
use crate::securegcm::ukey2_alert::AlertType;
use crate::securegcm::{
    ukey2_message, DeviceToDeviceMessage, GcmMetadata, Type, Ukey2Alert, Ukey2ClientFinished,
    Ukey2ClientInit, Ukey2HandshakeCipher, Ukey2Message, Ukey2ServerInit,
};
use crate::securemessage::{
    EcP256PublicKey, EncScheme, GenericPublicKey, Header, HeaderAndBody, PublicKeyType,
    SecureMessage, SigScheme,
};
use crate::sharing_nearby::{paired_key_result_frame, text_metadata};
use crate::utils::{
    encode_point, gen_ecdsa_keypair, gen_random, get_download_dir, hkdf_extract_expand,
    stream_read_exact, to_four_digit_string, RemoteDeviceInfo,
};
use crate::{location_nearby_connections, sharing_nearby};

type HmacSha256 = Hmac<Sha256>;

const SANITY_DURATION: Duration = Duration::from_micros(10);
const CONSENT_TIMEOUT: Duration = Duration::from_secs(120);

#[derive(Debug)]
pub struct InboundRequest {
    socket: TcpStream,
    header_bytes: [u8; 4],
    header_length: usize,
    // Last time the peer made progress; drives the idle timeout.
    last_activity: tokio::time::Instant,
    consent_deadline: Option<tokio::time::Instant>,
    pub state: InnerState,
    sender: Sender<ChannelMessage>,
    receiver: Receiver<ChannelMessage>,
}

impl InboundRequest {
    pub fn new(socket: TcpStream, id: String, sender: Sender<ChannelMessage>) -> Self {
        let receiver = sender.subscribe();

        Self {
            socket,
            header_bytes: [0; 4],
            header_length: 0,
            last_activity: tokio::time::Instant::now(),
            consent_deadline: None,
            state: InnerState {
                id,
                server_seq: 0,
                client_seq: 0,
                state: State::Initial,
                // Becomes true once UKEY2 keys exist (finalize_key_exchange);
                // until then disconnection/keepalive frames go out in plaintext.
                encryption_done: false,
                ..Default::default()
            },
            sender,
            receiver,
        }
    }

    pub async fn handle(&mut self) -> Result<(), anyhow::Error> {
        // Buffer for the 4-byte length
        let mut length_buf = [0u8; 4];

        let deadline = if self.state.state == State::WaitingForUserConsent {
            self.consent_deadline.ok_or_else(|| anyhow!("Missing consent deadline"))?
        } else {
            self.last_activity + IDLE_TIMEOUT
        };
        // Check before select as well: continuously ready peer/control traffic
        // must not starve the absolute consent deadline.
        if tokio::time::Instant::now() >= deadline {
            return Err(anyhow!("Peer idle or user consent deadline expired"));
        }

        tokio::select! {
            _ = tokio::time::sleep_until(deadline) => {
                return Err(anyhow!("Peer idle or user consent deadline expired"));
            }
            i = self.receiver.recv() => {
                match i {
                    Ok(channel_msg) => {
                        if channel_msg.direction == ChannelDirection::LibToFront {
                            return Ok(());
                        }

                        if channel_msg.id != self.state.id {
                            return Ok(());
                        }

                        debug!("inbound: got: {:?}", channel_msg);
                        match channel_msg.action {
                            Some(ChannelAction::AcceptTransfer) => {
                                self.accept_transfer(channel_msg.save_directory.as_deref()).await?;
                            },
                            Some(ChannelAction::RejectTransfer) => {
                                self.update_state(
                                    |e| {
                                        e.state = State::Rejected;
                                    },
                                    true,
                                ).await;

                                self.reject_transfer(Some(
                                    sharing_nearby::connection_response_frame::Status::Reject
                                )).await?;
                                return Err(anyhow!(crate::errors::AppError::NotAnError));
                            },
                            Some(ChannelAction::CancelTransfer) => {
                                self.update_state(
                                    |e| {
                                        e.state = State::Cancelled;
                                    },
                                    true,
                                ).await;
                                self.disconnection().await?;
                                return Err(anyhow!(crate::errors::AppError::NotAnError));
                            },
                            None => {
                                trace!("inbound: nothing to do")
                            },
                        }
                    }
                    Err(e) => {
                        error!("inbound: channel error: {}", e);
                    }
                }
            },
            h = self.socket.read(&mut length_buf[self.header_length..]) => {
                let count = h?;
                if count == 0 { return Err(anyhow!("Connection closed")); }
                self.last_activity = tokio::time::Instant::now();
                self.header_bytes[self.header_length..self.header_length + count]
                    .copy_from_slice(&length_buf[self.header_length..self.header_length + count]);
                self.header_length += count;
                if self.header_length == 4 {
                    let header = self.header_bytes;
                    self.header_length = 0;
                    tokio::time::timeout(Duration::from_secs(30), self._handle(header)).await??;
                    self.last_activity = tokio::time::Instant::now();
                }
            }
        }

        Ok(())
    }

    pub async fn _handle(&mut self, length_buf: [u8; 4]) -> Result<(), anyhow::Error> {
        let msg_length = u32::from_be_bytes(length_buf) as usize;
        // Ensure the message length is not unreasonably big to avoid allocation attacks
        if msg_length > SANE_FRAME_LENGTH as usize {
            error!("Message length too big");
            return Err(anyhow!("value"));
        }

        // Allocate buffer for the actual message and read it
        let mut frame_data = vec![0u8; msg_length];
        stream_read_exact(&mut self.socket, &mut frame_data).await?;

        let current_state = &self.state;
        // Now determine what will be the request type based on current state
        match current_state.state {
            State::Initial => {
                debug!("Handling State::Initial frame");
                let frame = location_nearby_connections::OfflineFrame::decode(&*frame_data)?;
                let rdi = Self::process_connection_request(&frame)?;
                info!("RemoteDeviceInfo: {:?}", &rdi);

                // Advance current state
                self.update_state(
                    |e: &mut InnerState| {
                        e.state = State::ReceivedConnectionRequest;
                        e.remote_device_info = Some(rdi);
                    },
                    false,
                )
                .await;
            }
            State::ReceivedConnectionRequest => {
                debug!("Handling State::ReceivedConnectionRequest frame");
                let msg = Ukey2Message::decode(&*frame_data)?;
                self.process_ukey2_client_init(&msg).await?;

                self.update_state(
                    |e: &mut InnerState| {
                        e.state = State::SentUkeyServerInit;
                        e.client_init_msg_data = Some(frame_data);
                    },
                    false,
                )
                .await;
            }
            State::SentUkeyServerInit => {
                debug!("Handling State::SentUkeyServerInit frame");
                let msg = Ukey2Message::decode(&*frame_data)?;
                self.process_ukey2_client_finish(&msg, &frame_data).await?;

                self.update_state(
                    |e: &mut InnerState| {
                        e.state = State::ReceivedUkeyClientFinish;
                    },
                    false,
                )
                .await;
            }
            State::ReceivedUkeyClientFinish => {
                debug!("Handling State::ReceivedUkeyClientFinish frame");
                let frame = location_nearby_connections::OfflineFrame::decode(&*frame_data)?;
                self.process_connection_response(&frame).await?;

                self.update_state(
                    |e: &mut InnerState| {
                        e.state = State::SentConnectionResponse;
                    },
                    false,
                )
                .await;
            }
            _ => {
                debug!("Handling SecureMessage frame");
                let smsg = SecureMessage::decode(&*frame_data)?;
                self.decrypt_and_process_secure_message(&smsg).await?;
            }
        }

        Ok(())
    }

    fn process_connection_request(
        frame: &location_nearby_connections::OfflineFrame,
    ) -> Result<RemoteDeviceInfo, anyhow::Error> {
        let v1_frame = frame
            .v1
            .as_ref()
            .ok_or_else(|| anyhow!("Missing required fields"))?;

        if v1_frame.r#type() != location_nearby_connections::v1_frame::FrameType::ConnectionRequest
        {
            return Err(anyhow!(format!(
                "Unexpected frame type: {:?}",
                v1_frame.r#type()
            )));
        }

        let connection_request = v1_frame
            .connection_request
            .as_ref()
            .ok_or_else(|| anyhow!("Missing required fields"))?;

        let endpoint_info = connection_request
            .endpoint_info
            .as_ref()
            .ok_or_else(|| anyhow!("Missing endpoint info"))?;

        // Use the same format and validation as discovery: Android may omit
        // its public name, leaving only the 17-byte endpoint header.
        let (device_type, device_name) = crate::utils::parse_endpoint_info(endpoint_info)?;

        Ok(RemoteDeviceInfo {
            name: device_name,
            device_type,
        })
    }

    async fn process_ukey2_client_init(&mut self, msg: &Ukey2Message) -> Result<(), anyhow::Error> {
        if msg.message_type() != ukey2_message::Type::ClientInit {
            self.send_ukey2_alert(AlertType::BadMessageType).await?;
            return Err(anyhow!(
                "UKey2: message_type({:?}) != ClientInit",
                msg.message_type
            ));
        }

        let client_init = match Ukey2ClientInit::decode(msg.message_data()) {
            Ok(uk2ci) => uk2ci,
            Err(e) => {
                self.send_ukey2_alert(AlertType::BadMessageData).await?;
                return Err(anyhow!("UKey2: Ukey2ClientInit::decode: {}", e));
            }
        };

        if client_init.version() != 1 {
            self.send_ukey2_alert(AlertType::BadVersion).await?;
            return Err(anyhow!("UKey2: client_init.version != 1"));
        }

        if client_init.random().len() != 32 {
            self.send_ukey2_alert(AlertType::BadRandom).await?;
            return Err(anyhow!("UKey2: client_init.random.len != 32"));
        }

        // Searching for preferred cipher commitment
        let mut found = false;
        for commitment in &client_init.cipher_commitments {
            trace!("CipherCommitment: {:?}", commitment.handshake_cipher());
            if Ukey2HandshakeCipher::P256Sha512 == commitment.handshake_cipher() {
                found = true;
                self.update_state(
                    |e| {
                        e.cipher_commitment = Some(commitment.clone());
                    },
                    false,
                )
                .await;
                break;
            }
        }

        if !found {
            self.send_ukey2_alert(AlertType::BadHandshakeCipher).await?;
            return Err(anyhow!("UKey2: badHandshakeCipher"));
        }

        if client_init.next_protocol() != "AES_256_CBC-HMAC_SHA256" {
            self.send_ukey2_alert(AlertType::BadNextProtocol).await?;
            return Err(anyhow!(
                "UKey2: badNextProtocol: {}",
                client_init.next_protocol()
            ));
        }

        let (secret_key, public_key) = gen_ecdsa_keypair();

        let encoded_point = public_key.to_encoded_point(false);
        let x = encoded_point.x().unwrap();
        let y = encoded_point.y().unwrap();

        let pkey = GenericPublicKey {
            r#type: PublicKeyType::EcP256.into(),
            ec_p256_public_key: Some(EcP256PublicKey {
                x: encode_point(Bytes::from(x.to_vec()))?,
                y: encode_point(Bytes::from(y.to_vec()))?,
            }),
            ..Default::default()
        };

        let server_init = Ukey2ServerInit {
            version: Some(1),
            random: Some(rand::rng().random::<[u8; 32]>().to_vec()),
            handshake_cipher: Some(Ukey2HandshakeCipher::P256Sha512.into()),
            public_key: Some(pkey.encode_to_vec()),
        };

        let server_init_msg = Ukey2Message {
            message_type: Some(ukey2_message::Type::ServerInit.into()),
            message_data: Some(server_init.encode_to_vec()),
        };

        let server_init_data = server_init_msg.encode_to_vec();
        self.update_state(
            |e| {
                e.private_key = Some(secret_key);
                e.public_key = Some(public_key);
                e.server_init_data = Some(server_init_data.clone());
            },
            false,
        )
        .await;

        self.send_frame(server_init_data).await?;

        Ok(())
    }

    async fn process_ukey2_client_finish(
        &mut self,
        msg: &Ukey2Message,
        frame_data: &Vec<u8>,
    ) -> Result<(), anyhow::Error> {
        if msg.message_type() != ukey2_message::Type::ClientFinish {
            self.send_ukey2_alert(AlertType::BadMessageType).await?;
            return Err(anyhow!(
                "UKey2: message_type({:?}) != ClientFinish",
                msg.message_type
            ));
        }

        let sha512 = Sha512::digest(frame_data);
        if self.state.cipher_commitment.as_ref().unwrap().commitment() != &sha512[..] {
            error!("cipher_commitment isn't equals to sha512(frame_data)");
            return Err(anyhow!("UKey2: cipher_commitment != sha512"));
        }

        let client_finish = match Ukey2ClientFinished::decode(msg.message_data()) {
            Ok(uk2cf) => uk2cf,
            Err(e) => {
                return Err(anyhow!("UKey2: Ukey2ClientFinished::decode: {}", e));
            }
        };

        if client_finish.public_key.is_none() {
            return Err(anyhow!("UKey2: client_finish.public_key None"));
        }

        let client_public_key = match GenericPublicKey::decode(client_finish.public_key()) {
            Ok(cpk) => cpk,
            Err(e) => {
                return Err(anyhow!("UKey2: GenericPublicKey::decode: {}", e));
            }
        };

        self.finalize_key_exchange(client_public_key).await?;

        Ok(())
    }

    async fn process_connection_response(
        &mut self,
        frame: &location_nearby_connections::OfflineFrame,
    ) -> Result<(), anyhow::Error> {
        let v1_frame = frame
            .v1
            .as_ref()
            .ok_or_else(|| anyhow!("Missing required fields"))?;

        if v1_frame.r#type() != location_nearby_connections::v1_frame::FrameType::ConnectionResponse
        {
            return Err(anyhow!(format!(
                "Unexpected frame type: {:?}",
                v1_frame.r#type()
            )));
        }

        let response = location_nearby_connections::OfflineFrame {
			version: Some(location_nearby_connections::offline_frame::Version::V1.into()),
			v1: Some(location_nearby_connections::V1Frame {
				r#type: Some(location_nearby_connections::v1_frame::FrameType::ConnectionResponse.into()),
				connection_response: Some(location_nearby_connections::ConnectionResponseFrame {
					response: Some(location_nearby_connections::connection_response_frame::ResponseStatus::Accept.into()),
					os_info: Some(location_nearby_connections::OsInfo {
						r#type: Some(location_nearby_connections::os_info::OsType::Linux.into())
					}),
					..Default::default()
				}),
				..Default::default()
			})
		};

        self.send_frame(response.encode_to_vec()).await?;

        let paired_encryption = sharing_nearby::Frame {
            version: Some(sharing_nearby::frame::Version::V1.into()),
            v1: Some(sharing_nearby::V1Frame {
                r#type: Some(sharing_nearby::v1_frame::FrameType::PairedKeyEncryption.into()),
                paired_key_encryption: Some(sharing_nearby::PairedKeyEncryptionFrame {
                    secret_id_hash: Some(gen_random(6)),
                    signed_data: Some(gen_random(72)),
                    ..Default::default()
                }),
                ..Default::default()
            }),
        };

        self.send_encrypted_frame(&paired_encryption).await?;

        Ok(())
    }

    async fn decrypt_and_process_secure_message(
        &mut self,
        smsg: &SecureMessage,
    ) -> Result<(), anyhow::Error> {
        let recv_hmac_key = self
            .state
            .recv_hmac_key
            .as_ref()
            .ok_or_else(|| anyhow!("Missing receive HMAC key"))?;
        let mut hmac = HmacSha256::new_from_slice(recv_hmac_key)?;
        hmac.update(&smsg.header_and_body);
        hmac.verify_slice(&smsg.signature)
            .map_err(|_| anyhow!("hmac!=signature"))?;

        let header_and_body = HeaderAndBody::decode(&*smsg.header_and_body)?;

        let msg_data = header_and_body.body;
        let key = self
            .state
            .decrypt_key
            .as_ref()
            .ok_or_else(|| anyhow!("Missing decryption key"))?;
        let decrypted = aes_cbc_decrypt(key, header_and_body.header.iv(), &msg_data)?;

        let d2d_msg = DeviceToDeviceMessage::decode(&*decrypted)?;

        let seq = self.get_client_seq_inc()?;
        if d2d_msg.sequence_number() != seq {
            return Err(anyhow!(
                "Error d2d_msg.sequence_number invalid ({} vs {})",
                d2d_msg.sequence_number(),
                seq
            ));
        }

        let offline = location_nearby_connections::OfflineFrame::decode(d2d_msg.message())?;
        self.process_secure_offline_frame(&offline).await
    }

    async fn process_secure_offline_frame(
        &mut self,
        offline: &OfflineFrame,
    ) -> Result<(), anyhow::Error> {
        let v1 = offline
            .v1
            .as_ref()
            .ok_or_else(|| anyhow!("Missing frame"))?;
        match v1.r#type() {
            location_nearby_connections::v1_frame::FrameType::PayloadTransfer => {
                let transfer = v1
                    .payload_transfer
                    .as_ref()
                    .ok_or_else(|| anyhow!("Missing payload"))?;
                let header = transfer
                    .payload_header
                    .as_ref()
                    .ok_or_else(|| anyhow!("Missing payload header"))?;
                let chunk = transfer
                    .payload_chunk
                    .as_ref()
                    .ok_or_else(|| anyhow!("Missing payload chunk"))?;
                match header.r#type() {
                    payload_header::PayloadType::Bytes => {
                        self.process_bytes_payload(header, chunk).await?
                    }
                    payload_header::PayloadType::File => {
                        self.process_file_payload(header, chunk).await?
                    }
                    _ => return Err(anyhow!("Unsupported payload type")),
                }
            }
            location_nearby_connections::v1_frame::FrameType::KeepAlive => {
                self.send_keepalive(true).await?
            }
            _ => error!("Unhandled encrypted frame type: {:?}", v1.r#type()),
        }
        Ok(())
    }

    async fn process_bytes_payload(
        &mut self,
        header: &PayloadHeader,
        chunk: &PayloadChunk,
    ) -> Result<(), anyhow::Error> {
        let text = self
            .state
            .text_payload
            .as_ref()
            .filter(|text| text.get_i64_value() == header.id())
            .cloned();
        if text.is_some() && self.state.state != State::ReceivingFiles {
            return Err(anyhow!("Text received before approval"));
        }
        append_bytes_chunk(
            &mut self.state.payload_buffers,
            header.id(),
            header.total_size(),
            chunk.offset(),
            chunk.body.as_deref(),
        )?;
        if chunk.flags() & 1 == 0 {
            return Ok(());
        }
        let buffer = self
            .state
            .payload_buffers
            .remove(&header.id())
            .unwrap_or_default();
        if buffer.len() as i64 != header.total_size() {
            return Err(anyhow!("Incomplete byte payload"));
        }
        if let Some(text) = text {
            self.finish_text_payload(text, &buffer).await
        } else {
            let frame = super::sharing_frame::decode_sharing_frame(&buffer)?;
            self.process_transfer_setup(&frame).await
        }
    }

    async fn finish_text_payload(
        &mut self,
        text: TextPayloadInfo,
        buffer: &[u8],
    ) -> Result<(), anyhow::Error> {
        let end = if matches!(text, TextPayloadInfo::Wifi(_)) {
            buffer
                .iter()
                .position(|&byte| byte == 16)
                .unwrap_or(buffer.len())
        } else {
            buffer.len()
        };
        let payload = std::str::from_utf8(&buffer[..end])?.to_owned();
        let (kind, payload) = match text {
            TextPayloadInfo::Url(_) => (TextPayloadType::Url, payload),
            TextPayloadInfo::Text(_) => (TextPayloadType::Text, payload),
            TextPayloadInfo::Wifi((_, ssid)) => {
                (TextPayloadType::Wifi, format!("{ssid}: {}", payload.trim()))
            }
        };
        self.update_state(
            |state| {
                state.state = State::Finished;
                if let Some(meta) = state.transfer_metadata.as_mut() {
                    meta.text_payload = Some(payload);
                    meta.text_type = Some(kind);
                    meta.ack_bytes = meta.total_bytes;
                }
            },
            true,
        )
        .await;
        self.disconnection().await?;
        Err(anyhow!(crate::errors::AppError::NotAnError))
    }

    async fn process_file_payload(
        &mut self,
        header: &PayloadHeader,
        chunk: &PayloadChunk,
    ) -> Result<(), anyhow::Error> {
        if self.state.state != State::ReceivingFiles {
            return Err(anyhow!("File data received before approval"));
        }
        let finished = self.write_file_chunk(header.id(), chunk)?;
        self.update_state(
            |state| {
                if let Some(meta) = state.transfer_metadata.as_mut() {
                    meta.ack_bytes += chunk.body().len() as u64;
                }
                if finished {
                    state.state = State::Finished;
                }
            },
            true,
        )
        .await;
        if finished {
            self.disconnection().await?;
            return Err(anyhow!(crate::errors::AppError::NotAnError));
        }
        Ok(())
    }

    fn write_file_chunk(&mut self, id: i64, chunk: &PayloadChunk) -> Result<bool, anyhow::Error> {
        let info = self
            .state
            .transferred_files
            .get_mut(&id)
            .ok_or_else(|| anyhow!("Unknown file payload ID"))?;
        if chunk.offset() != info.bytes_transferred {
            return Err(anyhow!("Invalid file offset"));
        }
        let next = info
            .bytes_transferred
            .checked_add(chunk.body().len() as i64)
            .ok_or_else(|| anyhow!("File offset overflow"))?;
        if next > info.total_size {
            return Err(anyhow!("Transferred file size exceeds introduction"));
        }
        let file = info
            .file
            .as_mut()
            .ok_or_else(|| anyhow!("File not accepted"))?;
        if !chunk.body().is_empty() {
            file.seek(SeekFrom::Start(info.bytes_transferred as u64))?;
            file.write_all(chunk.body())?;
            info.bytes_transferred = next;
        } else if chunk.flags() & 1 != 0 {
            if next != info.total_size {
                return Err(anyhow!("Incomplete file payload"));
            }
            file.sync_all()?;
            self.state.transferred_files.remove(&id);
            return Ok(self.state.transferred_files.is_empty());
        }
        Ok(false)
    }

    async fn process_transfer_setup(
        &mut self,
        frame: &sharing_nearby::Frame,
    ) -> Result<(), anyhow::Error> {
        let v1_frame = frame
            .v1
            .as_ref()
            .ok_or_else(|| anyhow!("Missing required fields"))?;

        debug!(
            "Sharing setup frame type: {:?}, response: {:?}",
            v1_frame.r#type(),
            v1_frame
                .connection_response
                .as_ref()
                .map(|response| response.status())
        );

        if v1_frame.r#type() == sharing_nearby::v1_frame::FrameType::Cancel {
            info!("Transfer canceled");
            self.update_state(
                |e| {
                    e.state = State::Cancelled;
                },
                true,
            )
            .await;
            self.disconnection().await?;
            return Err(anyhow!(crate::errors::AppError::NotAnError));
        }

        match self.state.state {
            State::SentConnectionResponse => {
                debug!("Processing State::SentConnectionResponse");
                self.process_paired_key_encryption_frame(v1_frame).await?;
                self.update_state(
                    |e| {
                        e.state = State::SentPairedKeyResult;
                    },
                    false,
                )
                .await;
            }
            State::SentPairedKeyResult => {
                debug!("Processing State::SentPairedKeyResult");
                self.process_paired_key_result(v1_frame).await?;
                self.update_state(
                    |e| {
                        e.state = State::ReceivedPairedKeyResult;
                    },
                    false,
                )
                .await;
            }
            State::ReceivedPairedKeyResult => {
                debug!("Processing State::ReceivedPairedKeyResult");
                // Native Quick Share sends its own ACCEPT before its
                // introduction. This acknowledges sender readiness only;
                // it must never replace the local user's approval.
                if v1_frame.r#type() == sharing_nearby::v1_frame::FrameType::Response {
                    if v1_frame
                        .connection_response
                        .as_ref()
                        .is_some_and(|response| {
                            response.status()
                                == sharing_nearby::connection_response_frame::Status::Accept
                        })
                    {
                        return Ok(());
                    }
                    return Err(anyhow!("Sender rejected transfer before introduction"));
                }
                if v1_frame.r#type() != sharing_nearby::v1_frame::FrameType::Introduction {
                    return Err(anyhow!("Expected introduction"));
                }
                self.process_introduction(v1_frame).await?;
            }
            _ => {
                info!(
                    "Unhandled connection state in process_transfer_setup: {:?}",
                    self.state.state
                );
            }
        }

        Ok(())
    }

    async fn process_paired_key_encryption_frame(
        &mut self,
        v1_frame: &sharing_nearby::V1Frame,
    ) -> Result<(), anyhow::Error> {
        if v1_frame.paired_key_encryption.is_none() {
            return Err(anyhow!("Missing required fields"));
        }

        let paired_result = sharing_nearby::Frame {
            version: Some(sharing_nearby::frame::Version::V1.into()),
            v1: Some(sharing_nearby::V1Frame {
                r#type: Some(sharing_nearby::v1_frame::FrameType::PairedKeyResult.into()),
                paired_key_result: Some(sharing_nearby::PairedKeyResultFrame {
                    status: Some(paired_key_result_frame::Status::Unable.into()),
                }),
                ..Default::default()
            }),
        };

        self.send_encrypted_frame(&paired_result).await?;

        Ok(())
    }

    async fn process_paired_key_result(
        &self,
        v1_frame: &sharing_nearby::V1Frame,
    ) -> Result<(), anyhow::Error> {
        if v1_frame.paired_key_result.is_none() {
            return Err(anyhow!("Missing required fields"));
        }

        Ok(())
    }

    async fn process_introduction(
        &mut self,
        v1_frame: &sharing_nearby::V1Frame,
    ) -> Result<(), anyhow::Error> {
        let introduction = v1_frame
            .introduction
            .as_ref()
            .ok_or_else(|| anyhow!("Missing introduction"))?;
        let mut metadata = self.incoming_metadata();
        let text_payload = match (
            introduction.file_metadata.as_slice(),
            introduction.text_metadata.as_slice(),
            introduction.wifi_credentials_metadata.as_slice(),
        ) {
            (files, [], []) if !files.is_empty() => {
                self.prepare_incoming_files(files, &mut metadata)?;
                None
            }
            ([], [text], []) if text.r#type() != text_metadata::Type::Unknown => {
                if !(0..=i64::from(SANE_FRAME_LENGTH)).contains(&text.size()) {
                    return Err(anyhow!("Invalid text size"));
                }
                metadata.text_description = text.text_title.clone();
                metadata.total_bytes = text.size() as u64;
                Some(if text.r#type() == text_metadata::Type::Url {
                    TextPayloadInfo::Url(text.payload_id())
                } else {
                    TextPayloadInfo::Text(text.payload_id())
                })
            }
            ([], [], [wifi]) => {
                metadata.text_description = wifi.ssid.clone();
                Some(TextPayloadInfo::Wifi((
                    wifi.payload_id(),
                    wifi.ssid().to_owned(),
                )))
            }
            _ => {
                self.reject_transfer(Some(
                    sharing_nearby::connection_response_frame::Status::UnsupportedAttachmentType,
                ))
                .await?;
                self.update_state(|s| s.state = State::Rejected, true).await;
                return Err(anyhow!(crate::errors::AppError::NotAnError));
            }
        };
        // Only a validated introduction can occupy a consent slot. Neither
        // keepalives nor unrelated frontend messages extend this deadline.
        self.consent_deadline = Some(tokio::time::Instant::now() + CONSENT_TIMEOUT);
        info!("Asking for user consent");
        self.update_state(
            |s| {
                s.state = State::WaitingForUserConsent;
                s.text_payload = text_payload;
                s.transfer_metadata = Some(metadata);
            },
            true,
        )
        .await;
        Ok(())
    }

    fn incoming_metadata(&self) -> TransferMetadata {
        TransferMetadata {
            id: self.state.id.clone(),
            source: self.state.remote_device_info.clone(),
            pin_code: self.state.pin_code.clone(),
            ..Default::default()
        }
    }

    fn prepare_incoming_files(
        &mut self,
        files: &[sharing_nearby::FileMetadata],
        metadata: &mut TransferMetadata,
    ) -> Result<(), anyhow::Error> {
        if files.len() > super::sharing_frame::MAX_METADATA_ENTRIES {
            return Err(anyhow!("Too many files"));
        }
        let mut names = Vec::with_capacity(files.len());
        for file in files {
            if !is_safe_file_name(file.name())
                || !(0..=(1_i64 << 40)).contains(&file.size())
                || self
                    .state
                    .transferred_files
                    .contains_key(&file.payload_id())
            {
                return Err(anyhow!("Invalid file metadata"));
            }
            let info = InternalFileInfo {
                file_url: get_download_dir().join(file.name()),
                bytes_transferred: 0,
                total_size: file.size(),
                file: None,
                mime_type: file.mime_type().to_owned(),
            };
            metadata.total_bytes += info.total_size as u64;
            self.state.transferred_files.insert(file.payload_id(), info);
            names.push(file.name().to_owned());
        }
        metadata.destination = Some(
            get_download_dir()
                .into_os_string()
                .into_string()
                .map_err(|_| anyhow!("Invalid download directory"))?,
        );
        metadata.files = Some(names);
        Ok(())
    }

    async fn disconnection(&mut self) -> Result<(), anyhow::Error> {
        let frame = location_nearby_connections::OfflineFrame {
            version: Some(location_nearby_connections::offline_frame::Version::V1.into()),
            v1: Some(location_nearby_connections::V1Frame {
                r#type: Some(
                    location_nearby_connections::v1_frame::FrameType::Disconnection.into(),
                ),
                disconnection: Some(location_nearby_connections::DisconnectionFrame {
                    ..Default::default()
                }),
                ..Default::default()
            }),
        };

        if self.state.encryption_done {
            self.encrypt_and_send(&frame).await
        } else {
            self.send_frame(frame.encode_to_vec()).await
        }
    }

    async fn accept_transfer(&mut self, directory: Option<&str>) -> Result<(), anyhow::Error> {
        let ids: Vec<i64> = self.state.transferred_files.keys().cloned().collect();

        let directory = std::fs::canonicalize(directory.map(std::path::PathBuf::from).unwrap_or_else(get_download_dir))?;
        if !directory.is_dir() { return Err(anyhow!("Save location must be a directory")); }
        let mut saved_files = Vec::new();
        let mut saved_names = Vec::new();
        let mut saved_mime_types = Vec::new();
        for id in ids {
            let mfi = self.state.transferred_files.get_mut(&id).unwrap();
            let name = mfi.file_url.file_name().ok_or_else(|| anyhow!("Missing filename"))?.to_string_lossy().into_owned();
            saved_names.push(name.clone());
            saved_mime_types.push(mfi.mime_type.clone());
            let mut created = false;
            for counter in 0..10000 {
                let dest = directory.join(if counter == 0 { name.clone() } else { format!("{counter}_{name}") });
                match std::fs::OpenOptions::new().write(true).create_new(true).open(&dest) {
                    Ok(file) => {
                        mfi.file_url = dest;
                        mfi.file = Some(file);
                        saved_files.push(mfi.file_url.to_string_lossy().into_owned());
                        created = true;
                        break;
                    }
                    Err(e) if e.kind() == std::io::ErrorKind::AlreadyExists => continue,
                    Err(e) => return Err(e.into()),
                }
            }
            if !created { return Err(anyhow!("Too many files with this name")); }
        }
        if let Some(meta) = self.state.transfer_metadata.as_mut() {
            meta.destination = Some(directory.to_string_lossy().into_owned());
            meta.saved_files = Some(saved_files);
            meta.saved_names = Some(saved_names);
            meta.saved_mime_types = Some(saved_mime_types);
        }

        let frame = sharing_nearby::Frame {
            version: Some(sharing_nearby::frame::Version::V1.into()),
            v1: Some(sharing_nearby::V1Frame {
                r#type: Some(sharing_nearby::v1_frame::FrameType::Response.into()),
                connection_response: Some(sharing_nearby::ConnectionResponseFrame {
                    status: Some(sharing_nearby::connection_response_frame::Status::Accept.into()),
                }),
                ..Default::default()
            }),
        };

        self.send_encrypted_frame(&frame).await?;

        self.update_state(
            |e| {
                e.state = State::ReceivingFiles;
            },
            true,
        )
        .await;

        Ok(())
    }

    async fn reject_transfer(
        &mut self,
        reason: Option<sharing_nearby::connection_response_frame::Status>,
    ) -> Result<(), anyhow::Error> {
        let sreason = if let Some(r) = reason {
            r
        } else {
            sharing_nearby::connection_response_frame::Status::Reject
        };

        let frame = sharing_nearby::Frame {
            version: Some(sharing_nearby::frame::Version::V1.into()),
            v1: Some(sharing_nearby::V1Frame {
                r#type: Some(sharing_nearby::v1_frame::FrameType::Response.into()),
                connection_response: Some(sharing_nearby::ConnectionResponseFrame {
                    status: Some(sreason.into()),
                }),
                ..Default::default()
            }),
        };

        self.send_encrypted_frame(&frame).await?;

        Ok(())
    }

    async fn finalize_key_exchange(
        &mut self,
        raw_peer_key: GenericPublicKey,
    ) -> Result<(), anyhow::Error> {
        let peer_p256_key = raw_peer_key
            .ec_p256_public_key
            .ok_or_else(|| anyhow!("Missing required fields"))?;

        let bytes = crate::utils::p256_point_bytes(&peer_p256_key.x, &peer_p256_key.y)?;
        let encoded_point = EncodedPoint::from_bytes(bytes)?;
        let peer_key = Option::<PublicKey>::from(PublicKey::from_encoded_point(&encoded_point))
            .ok_or_else(|| anyhow!("Invalid peer public key"))?;
        let priv_key = self.state.private_key.as_ref().unwrap();

        let dhs = diffie_hellman(priv_key.to_nonzero_scalar(), peer_key.as_affine());
        let derived_secret = Sha256::digest(dhs.raw_secret_bytes());

        let mut ukey_info: Vec<u8> = vec![];
        ukey_info.extend_from_slice(self.state.client_init_msg_data.as_ref().unwrap());
        ukey_info.extend_from_slice(self.state.server_init_data.as_ref().unwrap());

        let auth_label = "UKEY2 v1 auth".as_bytes();
        let next_label = "UKEY2 v1 next".as_bytes();

        let auth_string = hkdf_extract_expand(auth_label, &derived_secret, &ukey_info, 32)?;
        let next_secret = hkdf_extract_expand(next_label, &derived_secret, &ukey_info, 32)?;

        let salt_hex = "82AA55A0D397F88346CA1CEE8D3909B95F13FA7DEB1D4AB38376B8256DA85510";
        let salt =
            hex::decode(salt_hex).map_err(|e| anyhow!("Failed to decode salt_hex: {}", e))?;

        let d2d_client = hkdf_extract_expand(&salt, &next_secret, "client".as_bytes(), 32)?;
        let d2d_server = hkdf_extract_expand(&salt, &next_secret, "server".as_bytes(), 32)?;

        let key_salt_hex = "BF9D2A53C63616D75DB0A7165B91C1EF73E537F2427405FA23610A4BE657642E";
        let key_salt = hex::decode(key_salt_hex)
            .map_err(|e| anyhow!("Failed to decode key_salt_hex: {}", e))?;

        let client_key = hkdf_extract_expand(&key_salt, &d2d_client, "ENC:2".as_bytes(), 32)?;
        let client_hmac_key = hkdf_extract_expand(&key_salt, &d2d_client, "SIG:1".as_bytes(), 32)?;
        let server_key = hkdf_extract_expand(&key_salt, &d2d_server, "ENC:2".as_bytes(), 32)?;
        let server_hmac_key = hkdf_extract_expand(&key_salt, &d2d_server, "SIG:1".as_bytes(), 32)?;

        self.update_state(
            |e| {
                e.decrypt_key = Some(client_key);
                e.recv_hmac_key = Some(client_hmac_key);
                e.encrypt_key = Some(server_key);
                e.send_hmac_key = Some(server_hmac_key);
                e.pin_code = Some(to_four_digit_string(&auth_string));
                e.encryption_done = true;
            },
            false,
        )
        .await;

        debug!("Peer verification code established");

        Ok(())
    }

    async fn send_ukey2_alert(&mut self, atype: AlertType) -> Result<(), anyhow::Error> {
        let alert = Ukey2Alert {
            r#type: Some(atype.into()),
            error_message: None,
        };

        let data = Ukey2Message {
            message_type: Some(atype.into()),
            message_data: Some(alert.encode_to_vec()),
        };

        self.send_frame(data.encode_to_vec()).await
    }

    async fn send_encrypted_frame(
        &mut self,
        frame: &sharing_nearby::Frame,
    ) -> Result<(), anyhow::Error> {
        let frame_data = frame.encode_to_vec();
        let body_size = frame_data.len();

        let payload_header = PayloadHeader {
            id: Some(rand::rng().random_range(i64::MIN..i64::MAX)),
            r#type: Some(payload_header::PayloadType::Bytes.into()),
            total_size: Some(body_size as i64),
            is_sensitive: Some(false),
            ..Default::default()
        };

        let transfer = PayloadTransferFrame {
            packet_type: Some(PacketType::Data.into()),
            payload_chunk: Some(PayloadChunk {
                offset: Some(0),
                flags: Some(0),
                body: Some(frame_data),
            }),
            payload_header: Some(payload_header.clone()),
            ..Default::default()
        };

        let wrapper = location_nearby_connections::OfflineFrame {
            version: Some(location_nearby_connections::offline_frame::Version::V1.into()),
            v1: Some(location_nearby_connections::V1Frame {
                r#type: Some(
                    location_nearby_connections::v1_frame::FrameType::PayloadTransfer.into(),
                ),
                payload_transfer: Some(transfer),
                ..Default::default()
            }),
        };

        // Encrypt and send offline
        self.encrypt_and_send(&wrapper).await?;

        // Send lastChunk
        let transfer = PayloadTransferFrame {
            packet_type: Some(PacketType::Data.into()),
            payload_chunk: Some(PayloadChunk {
                offset: Some(body_size as i64),
                flags: Some(1), // lastChunk
                body: Some(vec![]),
            }),
            payload_header: Some(payload_header),
            ..Default::default()
        };

        let wrapper = location_nearby_connections::OfflineFrame {
            version: Some(location_nearby_connections::offline_frame::Version::V1.into()),
            v1: Some(location_nearby_connections::V1Frame {
                r#type: Some(
                    location_nearby_connections::v1_frame::FrameType::PayloadTransfer.into(),
                ),
                payload_transfer: Some(transfer),
                ..Default::default()
            }),
        };

        // Encrypt and send offline
        self.encrypt_and_send(&wrapper).await?;

        Ok(())
    }

    async fn encrypt_and_send(&mut self, frame: &OfflineFrame) -> Result<(), anyhow::Error> {
        let d2d_msg = DeviceToDeviceMessage {
            sequence_number: Some(self.get_server_seq_inc()?),
            message: Some(frame.encode_to_vec()),
        };

        let key = self
            .state
            .encrypt_key
            .as_ref()
            .ok_or_else(|| anyhow!("Missing encryption key"))?;
        let msg_data = d2d_msg.encode_to_vec();
        let iv = gen_random(16);

        let encrypted = aes_cbc_encrypt(key, &iv, &msg_data)?;

        let hb = HeaderAndBody {
            body: encrypted,
            header: Header {
                encryption_scheme: EncScheme::Aes256Cbc.into(),
                signature_scheme: SigScheme::HmacSha256.into(),
                iv: Some(iv),
                public_metadata: Some(
                    GcmMetadata {
                        r#type: Type::DeviceToDeviceMessage.into(),
                        version: Some(1),
                    }
                    .encode_to_vec(),
                ),
                ..Default::default()
            },
        };

        let send_hmac_key = self
            .state
            .send_hmac_key
            .as_ref()
            .ok_or_else(|| anyhow!("Missing send HMAC key"))?;
        let mut hmac = HmacSha256::new_from_slice(send_hmac_key)?;
        hmac.update(&hb.encode_to_vec());
        let result = hmac.finalize();

        let smsg = SecureMessage {
            header_and_body: hb.encode_to_vec(),
            signature: result.into_bytes().to_vec(),
        };

        self.send_frame(smsg.encode_to_vec()).await?;

        Ok(())
    }

    async fn send_keepalive(&mut self, ack: bool) -> Result<(), anyhow::Error> {
        let ack_frame = location_nearby_connections::OfflineFrame {
            version: Some(location_nearby_connections::offline_frame::Version::V1.into()),
            v1: Some(location_nearby_connections::V1Frame {
                r#type: Some(location_nearby_connections::v1_frame::FrameType::KeepAlive.into()),
                keep_alive: Some(KeepAliveFrame { ack: Some(ack) }),
                ..Default::default()
            }),
        };

        if self.state.encryption_done {
            self.encrypt_and_send(&ack_frame).await
        } else {
            self.send_frame(ack_frame.encode_to_vec()).await
        }
    }

    async fn send_frame(&mut self, data: Vec<u8>) -> Result<(), anyhow::Error> {
        let length = data.len();

        // Prepare length prefix in big-endian format
        let length_bytes = [
            (length >> 24) as u8,
            (length >> 16) as u8,
            (length >> 8) as u8,
            length as u8,
        ];

        let mut prefixed_length = Vec::with_capacity(length + 4);
        prefixed_length.extend_from_slice(&length_bytes);
        prefixed_length.extend_from_slice(&data);

        write_all_timeout(&mut self.socket, &prefixed_length).await
    }

    fn get_server_seq_inc(&mut self) -> Result<i32, anyhow::Error> {
        next_seq(&mut self.state.server_seq)
    }

    fn get_client_seq_inc(&mut self) -> Result<i32, anyhow::Error> {
        next_seq(&mut self.state.client_seq)
    }

    async fn update_state<F>(&mut self, f: F, inform: bool)
    where
        F: FnOnce(&mut InnerState),
    {
        f(&mut self.state);

        if !inform {
            return;
        }

        trace!("Sending msg into the channel");
        let _ = self.sender.send(ChannelMessage {
            id: self.state.id.clone(),
            direction: ChannelDirection::LibToFront,
            rtype: Some(crate::channel::TransferType::Inbound),
            state: Some(self.state.state.clone()),
            meta: self.state.transfer_metadata.clone(),
            ..Default::default()
        });
        // Add a small sleep timer to allow the Tokio runtime to have
        // some spare time to process channel's message. Otherwise it
        // get spammed by new requests. Currently set to 10 micro secs.
        tokio::time::sleep(SANITY_DURATION).await;
    }
}

// Clean up only incomplete files this request created and still owns.
impl Drop for InboundRequest {
    fn drop(&mut self) {
        for file in self.state.transferred_files.values_mut() {
            if let Some(handle) = file.file.take() {
                drop(handle);
                let _ = std::fs::remove_file(&file.file_url);
            }
        }
    }
}

/// Windows device names that cannot be used as a file name, with or without
/// an extension.
const WINDOWS_RESERVED_NAMES: [&str; 24] = [
    "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$", "COM1", "COM2", "COM3", "COM4", "COM5",
    "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7",
    "LPT8", "LPT9",
];

/// Unicode format (Cf) characters that can hide or reorder parts of a name
/// (bidi overrides and isolates, invisible separators, BOM, tags). ZWJ and
/// ZWNJ are allowed since emoji sequences and several scripts need them.
fn is_disallowed_format_char(c: char) -> bool {
    matches!(
        c,
        '\u{00AD}'
            | '\u{0600}'..='\u{0605}'
            | '\u{061C}'
            | '\u{06DD}'
            | '\u{070F}'
            | '\u{0890}'..='\u{0891}'
            | '\u{08E2}'
            | '\u{180E}'
            | '\u{200B}'
            | '\u{200E}'..='\u{200F}'
            | '\u{202A}'..='\u{202E}'
            | '\u{2060}'..='\u{2064}'
            | '\u{2066}'..='\u{206F}'
            | '\u{FEFF}'
            | '\u{FFF9}'..='\u{FFFB}'
            | '\u{110BD}'
            | '\u{110CD}'
            | '\u{13430}'..='\u{1343F}'
            | '\u{1BCA0}'..='\u{1BCA3}'
            | '\u{1D173}'..='\u{1D17A}'
            | '\u{E0001}'
            | '\u{E0020}'..='\u{E007F}'
    )
}

/// Whether a peer-supplied file name is safe to create inside the download
/// directory on any supported platform.
pub(crate) fn is_safe_file_name(name: &str) -> bool {
    if name.is_empty() || name.len() > 255 || name == "." || name == ".." {
        return false;
    }
    if name.chars().any(|c| {
        c.is_control() || c == '/' || c == '\\' || c == ':' || is_disallowed_format_char(c)
    }) {
        return false;
    }
    // Windows silently strips these, so "a.txt." and "a.txt " alias "a.txt".
    if name.ends_with('.') || name.ends_with(' ') {
        return false;
    }
    // "CON", "con.txt", "Nul .tar.gz": Windows looks at the part before the
    // first dot, ignoring trailing spaces.
    let stem = name.split('.').next().unwrap_or(name).trim_end_matches(' ');
    if WINDOWS_RESERVED_NAMES
        .iter()
        .any(|r| stem.eq_ignore_ascii_case(r))
    {
        return false;
    }
    true
}

#[cfg(test)]
mod tests {
    use super::{is_safe_file_name, InboundRequest};
    use crate::location_nearby_connections::{
        self as connections, ConnectionRequestFrame, OfflineFrame, V1Frame,
    };
    use crate::utils::DeviceType;

    #[tokio::test]
    async fn native_sender_accept_does_not_bypass_local_consent() {
        use crate::sharing_nearby as sharing;
        let (mut request, _client) = request_pair().await;
        request.state.state = super::State::ReceivedPairedKeyResult;
        let ready = sharing::Frame {
            v1: Some(sharing::V1Frame {
                r#type: Some(sharing::v1_frame::FrameType::Response.into()),
                connection_response: Some(sharing::ConnectionResponseFrame {
                    status: Some(sharing::connection_response_frame::Status::Accept.into()),
                }),
                ..Default::default()
            }),
            ..Default::default()
        };
        request.process_transfer_setup(&ready).await.unwrap();
        assert_eq!(request.state.state, super::State::ReceivedPairedKeyResult);
        assert!(request.state.transfer_metadata.is_none());
        assert!(request.consent_deadline.is_none());
        let intro = sharing::Frame {
            v1: Some(sharing::V1Frame {
                r#type: Some(sharing::v1_frame::FrameType::Introduction.into()),
                introduction: Some(sharing::IntroductionFrame {
                    text_metadata: vec![sharing::TextMetadata {
                        r#type: Some(sharing::text_metadata::Type::Text.into()),
                        payload_id: Some(42),
                        size: Some(4),
                        ..Default::default()
                    }],
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        };
        request.process_transfer_setup(&intro).await.unwrap();
        assert_eq!(request.state.state, super::State::WaitingForUserConsent);
        assert!(request.consent_deadline.is_some());
        assert!(request
            .state
            .transfer_metadata
            .as_ref()
            .unwrap()
            .text_payload
            .is_none());
        // A matching text payload still cannot be accepted before consent.
        let header = super::PayloadHeader {
            id: Some(42),
            total_size: Some(4),
            ..Default::default()
        };
        let chunk = super::PayloadChunk {
            offset: Some(0),
            flags: Some(1),
            body: Some(b"test".to_vec()),
        };
        assert!(request
            .process_bytes_payload(&header, &chunk)
            .await
            .is_err());
    }

    async fn request_pair() -> (InboundRequest, tokio::net::TcpStream) {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let client = tokio::net::TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
        let (socket, _) = listener.accept().await.unwrap();
        let (sender, _) = tokio::sync::broadcast::channel(16);
        (InboundRequest::new(socket, "test".into(), sender), client)
    }

    #[tokio::test]
    async fn consent_expiry_is_not_extended_by_recent_peer_activity() {
        let (mut request, _client) = request_pair().await;
        request.state.state = super::State::WaitingForUserConsent;
        request.last_activity = tokio::time::Instant::now();
        request.consent_deadline = Some(tokio::time::Instant::now() - std::time::Duration::from_secs(1));
        assert!(request.handle().await.unwrap_err().to_string().contains("deadline expired"));
    }

    #[tokio::test]
    async fn silent_consent_connection_is_closed_by_absolute_deadline() {
        let (mut request, _client) = request_pair().await;
        request.state.state = super::State::WaitingForUserConsent;
        request.consent_deadline = Some(tokio::time::Instant::now() + std::time::Duration::from_millis(10));
        let result = tokio::time::timeout(std::time::Duration::from_secs(1), request.handle()).await.unwrap();
        assert!(result.unwrap_err().to_string().contains("deadline expired"));
    }

    fn connection_request(endpoint_info: Vec<u8>) -> OfflineFrame {
        OfflineFrame {
            v1: Some(V1Frame {
                r#type: Some(connections::v1_frame::FrameType::ConnectionRequest.into()),
                connection_request: Some(ConnectionRequestFrame {
                    endpoint_info: Some(endpoint_info),
                    ..Default::default()
                }),
                ..Default::default()
            }),
            ..Default::default()
        }
    }

    #[test]
    fn incoming_android_endpoint_without_name() {
        // Contacts-only Android endpoints omit the optional public name.
        // Bit 4 is part of the endpoint flags, not the device type.
        let mut endpoint = vec![0; 17];
        endpoint[0] = (DeviceType::Phone as u8) << 1 | 0x10;
        let info =
            InboundRequest::process_connection_request(&connection_request(endpoint)).unwrap();
        assert_eq!(info.name, "Android device");
        assert!(matches!(info.device_type, DeviceType::Phone));
    }

    #[test]
    fn incoming_endpoint_name_validation() {
        let mut endpoint = vec![0; 17];
        endpoint[0] = (DeviceType::Phone as u8) << 1;
        endpoint.push(7);
        endpoint.extend_from_slice(b"Pixel 8");
        let info =
            InboundRequest::process_connection_request(&connection_request(endpoint.clone())).unwrap();
        assert_eq!(info.name, "Pixel 8");
        assert!(matches!(info.device_type, DeviceType::Phone));
        endpoint.pop();
        assert!(InboundRequest::process_connection_request(&connection_request(endpoint)).is_err());
        assert!(InboundRequest::process_connection_request(&connection_request(vec![0; 16])).is_err());
        let mut invalid_utf8 = vec![0; 17];
        invalid_utf8.extend_from_slice(&[1, 0xff]);
        assert!(InboundRequest::process_connection_request(&connection_request(invalid_utf8)).is_err());
    }

    #[test]
    fn file_name_sanitizer() {
        for ok in [
            "photo.jpg",
            "my file (1).tar.gz",
            ".hidden",
            "CONSOLE.txt",
            "com10.log",
            "lpt.txt",
            "résumé.pdf",
            "\u{1F468}\u{200D}\u{1F469}.png",
        ] {
            assert!(is_safe_file_name(ok), "{ok:?} should be accepted");
        }
        let long = "a".repeat(256);
        for bad in [
            "",
            ".",
            "..",
            long.as_str(),
            "a/b",
            "a\\b",
            "c:x",
            "a\nb",
            "CON",
            "con",
            "Con.txt",
            "nul.tar.gz",
            "COM1",
            "lpt9.doc",
            "aux .txt",
            "PRN",
            "conin$",
            "name.",
            "name ",
            "name.txt...",
            "evil\u{202E}gpj.exe",
            "a\u{200E}b",
            "a\u{200F}b",
            "a\u{2066}b",
            "a\u{2069}b",
            "a\u{202A}b",
            "a\u{FEFF}b",
            "a\u{200B}b",
            "a\u{E0041}b",
        ] {
            assert!(!is_safe_file_name(bad), "{bad:?} should be rejected");
        }
    }
}
