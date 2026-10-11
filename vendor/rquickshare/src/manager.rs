use std::sync::Arc;
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast::Sender;
use tokio::sync::mpsc::Receiver;
use tokio::sync::Semaphore;
use tokio_util::sync::CancellationToken;
use tokio_util::task::TaskTracker;
use ts_rs::TS;

use crate::channel::{ChannelDirection, ChannelMessage};
use crate::errors::AppError;
use crate::hdl::{InboundRequest, OutboundPayload, OutboundRequest, State};
use crate::utils::RemoteDeviceInfo;

const INNER_NAME: &str = "TcpServer";
/// Most inbound connections handled at once; extra sockets are dropped.
const MAX_INBOUND_CONNECTIONS: usize = 16;
/// Back-off after a failed accept() (e.g. EMFILE) so the loop doesn't spin.
const ACCEPT_ERROR_BACKOFF: Duration = Duration::from_millis(100);

#[derive(Debug, Deserialize, Serialize, TS)]
#[ts(export)]
pub struct SendInfo {
    pub id: String,
    pub name: String,
    pub addr: String,
    pub ob: OutboundPayload,
}

pub struct TcpServer {
    endpoint_id: [u8; 4],
    tcp_listener: TcpListener,
    sender: Sender<ChannelMessage>,
    connect_receiver: Receiver<SendInfo>,
    tracker: TaskTracker,
    inbound_slots: Arc<Semaphore>,
}

impl TcpServer {
    pub fn new(
        endpoint_id: [u8; 4],
        tcp_listener: TcpListener,
        sender: Sender<ChannelMessage>,
        connect_receiver: Receiver<SendInfo>,
        tracker: TaskTracker,
    ) -> Result<Self, anyhow::Error> {
        Ok(Self {
            endpoint_id,
            tcp_listener,
            sender,
            connect_receiver,
            tracker,
            inbound_slots: Arc::new(Semaphore::new(MAX_INBOUND_CONNECTIONS)),
        })
    }

    pub async fn run(&mut self, ctk: CancellationToken) -> Result<(), anyhow::Error> {
        info!("{INNER_NAME}: service starting");

        loop {
            let cctk = ctk.clone();

            tokio::select! {
                _ = ctk.cancelled() => {
                    info!("{INNER_NAME}: tracker cancelled, breaking");
                    break;
                }
                Some(i) = self.connect_receiver.recv() => {
                    info!("{INNER_NAME}: connect_receiver: got {:?}", i);
                    let endpoint_id = self.endpoint_id;
                    let sender = self.sender.clone();
                    self.tracker.spawn(async move {
                        let id = i.id.clone();
                        if let Err(e) = Self::connect(endpoint_id, sender.clone(), cctk, i).await {
                            let _ = sender.send(ChannelMessage { id, direction: ChannelDirection::LibToFront,
                                rtype: Some(crate::channel::TransferType::Outbound),
                                state: Some(State::Disconnected), ..Default::default() });
                            error!("{INNER_NAME}: error sending: {}", e);
                        }
                    });
                }
                r = self.tcp_listener.accept() => {
                    match r {
                        Ok((socket, remote_addr)) => {
                            trace!("{INNER_NAME}: new client: {remote_addr}");
                            let permit = match self.inbound_slots.clone().try_acquire_owned() {
                                Ok(p) => p,
                                Err(_) => {
                                    warn!("{INNER_NAME}: too many inbound connections, dropping {remote_addr}");
                                    drop(socket);
                                    continue;
                                }
                            };
                            let esender = self.sender.clone();
                            let csender = self.sender.clone();

                            self.tracker.spawn(async move {
                                let _permit = permit;
                                let mut ir = InboundRequest::new(socket, remote_addr.to_string(), csender);

                                loop {
                                    let r = tokio::select! {
                                        _ = cctk.cancelled() => {
                                            info!("{INNER_NAME}: tracker cancelled, closing {remote_addr}");
                                            break;
                                        }
                                        r = ir.handle() => r,
                                    };
                                    match r {
                                        Ok(_) => {},
                                        Err(e) => match e.downcast_ref() {
                                            Some(AppError::NotAnError) => break,
                                            None => {
                                                if ir.state.state == State::Initial {
                                                    break;
                                                }

                                                if ir.state.state != State::Finished {
                                                    let _ = esender.send(ChannelMessage {
                                                        id: remote_addr.to_string(),
                                                        direction: ChannelDirection::LibToFront,
                                                        state: Some(State::Disconnected),
                                                        ..Default::default()
                                                    });
                                                }
                                                error!("{INNER_NAME}: error while handling client: {e} ({:?})", ir.state.state);
                                                break;
                                            }
                                        },
                                    }
                                }
                            });
                        },
                        Err(err) => {
                            error!("{INNER_NAME}: error accepting: {}", err);
                            tokio::time::sleep(ACCEPT_ERROR_BACKOFF).await;
                        }
                    }
                }
            }
        }

        Ok(())
    }

    /// To be called inside a separate task if we want to handle concurrency
    pub async fn connect(
        endpoint_id: [u8; 4],
        sender: Sender<ChannelMessage>,
        ctk: CancellationToken,
        si: SendInfo,
    ) -> Result<(), anyhow::Error> {
        debug!("{INNER_NAME}: Connecting to: {}", si.addr);
        let socket = tokio::time::timeout(
            std::time::Duration::from_secs(5),
            TcpStream::connect(si.addr.clone()),
        )
        .await??;
        let transfer_id = si.id.clone();

        let mut or = OutboundRequest::new(
            endpoint_id,
            socket,
            si.id,
            sender.clone(),
            si.ob,
            RemoteDeviceInfo {
                device_type: crate::DeviceType::Unknown,
                name: si.name,
            },
        );

        // Send connection request
        or.send_connection_request().await?;
        // Send UKEY init
        or.send_ukey2_client_init().await?;

        loop {
            tokio::select! {
                _ = ctk.cancelled() => {
                    info!("{INNER_NAME}: tracker cancelled, breaking");
                    break;
                },
                r = or.handle() => {
                    if let Err(e) = r {
                        match e.downcast_ref() {
                            Some(AppError::NotAnError) => break,
                            None => {
                                if or.state.state == State::Initial {
                                    break;
                                }

                                if or.state.state != State::Finished && or.state.state != State::Cancelled {
                                    let _ = sender.clone().send(ChannelMessage {
                                        id: transfer_id.clone(),
                                        direction: ChannelDirection::LibToFront,
                                        state: Some(State::Disconnected),
                                        ..Default::default()
                                    });
                                }
                                error!("{INNER_NAME}: error while handling client: {e} ({:?})", or.state.state);
                                break;
                            }
                        }
                    }
                }
            }
        }

        Ok(())
    }
}
