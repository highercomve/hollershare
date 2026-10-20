use std::collections::HashMap;
use std::net::IpAddr;
use std::sync::{Arc, Weak};
use std::time::Duration;

use serde::{Deserialize, Serialize};
use tokio::net::{TcpListener, TcpStream};
use tokio::sync::broadcast::Sender;
use tokio::sync::mpsc::Receiver;
use tokio::sync::{OwnedSemaphorePermit, Semaphore};
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
const MAX_INBOUND_PER_PEER: usize = 4;

struct InboundLimits {
    slots: Arc<Semaphore>,
    peers: HashMap<IpAddr, Weak<Semaphore>>,
}

impl InboundLimits {
    fn new() -> Self {
        Self {
            slots: Arc::new(Semaphore::new(MAX_INBOUND_CONNECTIONS)),
            peers: HashMap::new(),
        }
    }

    fn acquire(&mut self, address: IpAddr) -> Option<(OwnedSemaphorePermit, OwnedSemaphorePermit)> {
        let global = self.slots.clone().try_acquire_owned().ok()?;
        // Only active connections retain these semaphores; stale IPs never
        // accumulate. The global permit bounds this map to 16 entries too.
        self.peers.retain(|_, peer| peer.strong_count() > 0);
        let peer = self
            .peers
            .get(&address)
            .and_then(Weak::upgrade)
            .unwrap_or_else(|| {
                let slots = Arc::new(Semaphore::new(MAX_INBOUND_PER_PEER));
                self.peers.insert(address, Arc::downgrade(&slots));
                slots
            });
        let per_peer = peer.try_acquire_owned().ok()?;
        Some((global, per_peer))
    }
}

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
    inbound_limits: InboundLimits,
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
            inbound_limits: InboundLimits::new(),
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
                    info!("{INNER_NAME}: starting outbound transfer: {:?}", i.ob);
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
                            debug!("{INNER_NAME}: new client: {remote_addr}");
                            let permit = match self.inbound_limits.acquire(remote_addr.ip()) {
                                Some(p) => p,
                                None => {
                                    warn!("{INNER_NAME}: inbound connection limit reached, dropping {remote_addr}");
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
                                                    debug!("{INNER_NAME}: initial connection from {remote_addr} failed: {e}");
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
        use crate::location_nearby_connections::bandwidth_upgrade_negotiation_frame::upgrade_path_info::Medium;
        // A receiver found over Bluetooth (`bt:` address): RFCOMM, where the
        // transfer stays; else TCP, which it may upgrade within the LAN.
        #[cfg(all(feature = "experimental", target_os = "linux"))]
        let bluetooth = crate::hdl::bt_classic::parse_peer_address(&si.addr);
        #[cfg(not(all(feature = "experimental", target_os = "linux")))]
        let bluetooth: Option<()> = None;
        let (socket, upgrade_mediums): (Box<dyn crate::hdl::Duplex>, Vec<Medium>) = match bluetooth {
            #[cfg(all(feature = "experimental", target_os = "linux"))]
            Some(address) => {
                let connection = tokio::select! {
                    _ = ctk.cancelled() => return Err(anyhow::anyhow!("Transfer cancelled")),
                    result = crate::hdl::bt_classic::connect(address) => result?,
                };
                (Box::new(connection), vec![])
            },
            #[cfg(not(all(feature = "experimental", target_os = "linux")))]
            Some(()) => unreachable!(),
            None => (
                Box::new(tokio::time::timeout(std::time::Duration::from_secs(5), TcpStream::connect(si.addr.clone())).await??),
                vec![Medium::WifiLan],
            ),
        };
        let transfer_id = si.id.clone();

        let mut or = OutboundRequest::new(
            endpoint_id,
            socket,
            upgrade_mediums,
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

#[cfg(test)]
mod admission_tests {
    use super::*;

    #[test]
    fn peer_limits_release_without_leaking_global_slots_or_peer_entries() {
        let mut limits = InboundLimits::new();
        let ip: IpAddr = "192.0.2.1".parse().unwrap();
        let mut permits = Vec::new();
        for _ in 0..MAX_INBOUND_PER_PEER {
            permits.push(limits.acquire(ip).unwrap());
        }
        assert!(limits.acquire(ip).is_none());
        assert_eq!(
            limits.slots.available_permits(),
            MAX_INBOUND_CONNECTIONS - MAX_INBOUND_PER_PEER
        );
        let other = limits.acquire("192.0.2.2".parse().unwrap()).unwrap();
        drop(permits);
        drop(other);
        for n in 1..=1000 {
            let address = IpAddr::V4(std::net::Ipv4Addr::from(n));
            drop(limits.acquire(address).unwrap());
            assert!(limits.peers.len() <= 1);
        }
        assert_eq!(limits.slots.available_permits(), MAX_INBOUND_CONNECTIONS);
    }

    #[test]
    fn global_limit_still_bounds_distinct_peers() {
        let mut limits = InboundLimits::new();
        let permits: Vec<_> = (1..=MAX_INBOUND_CONNECTIONS)
            .map(|n| {
                limits
                    .acquire(IpAddr::V4(std::net::Ipv4Addr::from(n as u32)))
                    .unwrap()
            })
            .collect();
        assert!(limits.acquire("192.0.2.200".parse().unwrap()).is_none());
        drop(permits);
        assert!(limits.acquire("192.0.2.200".parse().unwrap()).is_some());
    }
}
