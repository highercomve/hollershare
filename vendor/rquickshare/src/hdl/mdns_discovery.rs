use std::collections::HashMap;
use std::time::Duration;

#[cfg(not(target_os = "android"))]
use mdns_sd::{ServiceDaemon, ServiceEvent};
use serde::{Deserialize, Serialize};
use tokio::net::TcpStream;
use tokio::sync::broadcast;
use tokio::time::timeout;
use tokio_util::sync::CancellationToken;
use ts_rs::TS;

use crate::utils::{is_not_self_ip, parse_mdns_endpoint_info};
use crate::DeviceType;

#[derive(Debug, Clone, Default, Deserialize, Serialize, TS)]
#[ts(export)]
pub struct EndpointInfo {
    pub fullname: String,
    pub id: String,
    pub name: Option<String>,
    pub ip: Option<String>,
    pub port: Option<String>,
    pub rtype: Option<DeviceType>,
    pub present: Option<bool>,
}

pub struct MDnsDiscovery {
    #[cfg(not(target_os = "android"))]
    daemon: ServiceDaemon,
    sender: broadcast::Sender<EndpointInfo>,
}

#[cfg(target_os = "android")]
mod android_nsd {
    use std::ffi::CStr;
    use std::os::raw::c_char;
    use tokio::sync::mpsc;

    #[repr(C)]
    pub struct OrielMdnsTxt {
        pub key: *const c_char,
        pub value: *const u8,
        pub value_len: usize,
    }

    #[repr(C)]
    pub struct OrielMdnsEvent {
        pub kind: i32,
        pub name: *const c_char,
        pub service_type: *const c_char,
        pub host: *const c_char,
        pub addresses: *const *const c_char,
        pub address_count: usize,
        pub port: u16,
        pub txt: *const OrielMdnsTxt,
        pub txt_count: usize,
    }

    extern "C" {
        pub fn oriel_mdns_browse(
            service_type: *const c_char,
            cb: extern "C" fn(ctx: *mut std::ffi::c_void, event: *const OrielMdnsEvent),
            ctx: *mut std::ffi::c_void,
            out_handle: *mut u32,
        ) -> i32;
        pub fn oriel_mdns_browse_stop(handle: u32);
    }

    #[derive(Debug)]
    pub enum NsdEvent {
        Found {
            name: String,
            port: u16,
            addresses: Vec<String>,
            txt_n: Option<String>,
        },
        Lost {
            name: String,
        },
    }

    pub extern "C" fn on_event(ctx: *mut std::ffi::c_void, event: *const OrielMdnsEvent) {
        if ctx.is_null() || event.is_null() {
            return;
        }
        let tx = unsafe { &*(ctx as *const mpsc::Sender<NsdEvent>) };
        let ev = unsafe { &*event };

        let name = if !ev.name.is_null() {
            unsafe { CStr::from_ptr(ev.name) }.to_string_lossy().into_owned()
        } else {
            return;
        };

        if ev.kind == 0 {
            // FOUND
            let port = ev.port;
            let mut addresses = Vec::new();
            if !ev.addresses.is_null() && ev.address_count > 0 {
                for i in 0..ev.address_count {
                    let addr_ptr = unsafe { *ev.addresses.add(i) };
                    if !addr_ptr.is_null() {
                        addresses.push(unsafe { CStr::from_ptr(addr_ptr) }.to_string_lossy().into_owned());
                    }
                }
            }

            let mut txt_n = None;
            if !ev.txt.is_null() && ev.txt_count > 0 {
                for i in 0..ev.txt_count {
                    let entry = unsafe { &*ev.txt.add(i) };
                    if !entry.key.is_null() {
                        let key = unsafe { CStr::from_ptr(entry.key) }.to_string_lossy();
                        if key.eq_ignore_ascii_case("n") && !entry.value.is_null() && entry.value_len > 0 {
                            let bytes = unsafe { std::slice::from_raw_parts(entry.value, entry.value_len) };
                            if let Ok(s) = std::str::from_utf8(bytes) {
                                txt_n = Some(s.to_string());
                            }
                        }
                    }
                }
            }

            let _ = tx.try_send(NsdEvent::Found {
                name,
                port,
                addresses,
                txt_n,
            });
        } else if ev.kind == 1 {
            // LOST
            let _ = tx.try_send(NsdEvent::Lost { name });
        }
    }
}

impl MDnsDiscovery {
    #[cfg(not(target_os = "android"))]
    pub fn new(sender: broadcast::Sender<EndpointInfo>) -> Result<Self, anyhow::Error> {
        let daemon = ServiceDaemon::new()?;
        Ok(Self { daemon, sender })
    }

    #[cfg(target_os = "android")]
    pub fn new(sender: broadcast::Sender<EndpointInfo>) -> Result<Self, anyhow::Error> {
        Ok(Self { sender })
    }

    pub async fn run(self, ctk: CancellationToken) -> Result<(), anyhow::Error> {
        #[cfg(target_os = "android")]
        return self.run_android_nsd(ctk).await;
        #[cfg(not(target_os = "android"))]
        self.run_mdns_sd(ctk).await
    }

    #[cfg(target_os = "android")]
    async fn run_android_nsd(self, ctk: CancellationToken) -> Result<(), anyhow::Error> {
        info!("MDnsDiscovery: starting Android NsdManager discovery");

        let service_type_c = std::ffi::CString::new("_FC9F5ED42C8A._tcp")?;
        let (event_tx, mut event_rx) = tokio::sync::mpsc::channel::<android_nsd::NsdEvent>(64);
        let ctx = Box::into_raw(Box::new(event_tx));
        let ctx_addr = ctx as usize;
        let mut handle = 0u32;

        let ret = unsafe {
            android_nsd::oriel_mdns_browse(
                service_type_c.as_ptr(),
                android_nsd::on_event,
                ctx as *mut std::ffi::c_void,
                &mut handle,
            )
        };

        if ret != 0 {
            unsafe {
                drop(Box::from_raw(ctx_addr as *mut tokio::sync::mpsc::Sender<android_nsd::NsdEvent>));
            }
            error!("MDnsDiscovery: oriel_mdns_browse failed: {ret}");
            anyhow::bail!("oriel_mdns_browse failed with error {ret}");
        }

        info!("MDnsDiscovery: Android NsdManager discovery started (handle {handle})");

        let mut cache: HashMap<String, EndpointInfo> = HashMap::new();

        loop {
            tokio::select! {
                _ = ctk.cancelled() => {
                    info!("MDnsDiscovery: Android NsdManager discovery cancelled");
                    break;
                }
                Some(event) = event_rx.recv() => {
                    match event {
                        android_nsd::NsdEvent::Found { name, port, addresses, txt_n } => {
                            let n = match txt_n {
                                Some(ref n) => n,
                                None => {
                                    debug!("MDnsDiscovery (Android NSD): service {name} missing TXT 'n'");
                                    continue;
                                }
                            };

                            let (dt, dn) = match parse_mdns_endpoint_info(n) {
                                Ok(r) => r,
                                Err(e) => {
                                    debug!("MDnsDiscovery (Android NSD): parse endpoint info failed: {e}");
                                    continue;
                                }
                            };

                            let mut reachable_ip = None;
                            for addr_str in &addresses {
                                let clean_addr = addr_str.trim_start_matches('/');
                                if let Ok(ip) = clean_addr.parse::<std::net::Ipv4Addr>() {
                                    if !is_not_self_ip(&ip) {
                                        continue;
                                    }
                                    let ip_port = format!("{ip}:{port}");
                                    if let Ok(Ok(stream)) = timeout(Duration::from_millis(1000), TcpStream::connect(&ip_port)).await {
                                        if !connection_is_remote(&stream) {
                                            continue;
                                        }
                                        reachable_ip = Some(ip);
                                        break;
                                    }
                                }
                            }

                            if let Some(ip) = reachable_ip {
                                let ip_port = format!("{ip}:{port}");
                                let ei = EndpointInfo {
                                    fullname: name.clone(),
                                    id: ip_port,
                                    name: Some(dn),
                                    ip: Some(ip.to_string()),
                                    port: Some(port.to_string()),
                                    rtype: Some(dt),
                                    present: Some(true),
                                };
                                info!("ServiceResolved (Android NSD): Found device {name}: {:?}", ei);
                                cache.insert(name.clone(), ei.clone());
                                let _ = self.sender.send(ei);
                            } else {
                                debug!("ServiceResolved (Android NSD): Could not connect to any address for {name} ({addresses:?}:{port})");
                            }
                        }
                        android_nsd::NsdEvent::Lost { name } => {
                            if let Some(ei) = cache.remove(&name) {
                                info!("ServiceRemoved (Android NSD): Lost device {name}");
                                let _ = self.sender.send(EndpointInfo {
                                    id: ei.id,
                                    ..Default::default()
                                });
                            }
                        }
                    }
                }
            }
        }

        unsafe {
            android_nsd::oriel_mdns_browse_stop(handle);
            drop(Box::from_raw(ctx_addr as *mut tokio::sync::mpsc::Sender<android_nsd::NsdEvent>));
        }

        Ok(())
    }

    #[cfg(not(target_os = "android"))]
    async fn run_mdns_sd(self, ctk: CancellationToken) -> Result<(), anyhow::Error> {
        info!("MDnsDiscovery: service starting");

        #[cfg(not(target_os = "android"))]
        let daemon = self.daemon;
        let service_type = "_FC9F5ED42C8A._tcp.local.";
        let receiver = daemon.browse(service_type)?;

        // Map with fullname as key and EndpointInfo as value
        let mut cache: HashMap<String, EndpointInfo> = HashMap::new();

        loop {
            tokio::select! {
                _ = ctk.cancelled() => {
                    info!("MDnsDiscovery: tracker cancelled, breaking");
                    break;
                }
                r = receiver.recv_async() => {
                    match r {
                        Ok(event) => {
                            match event {
                                ServiceEvent::ServiceResolved(info) => {
                                    let port = info.get_port();

                                    let ip_hash = info.get_addresses_v4();
                                    if ip_hash.is_empty() {
                                        continue;
                                    }

                                    // Decode the "n" text properties
                                    let n = match info.get_property("n") {
                                        Some(_n) => _n,
                                        None => continue,
                                    };

                                    // Parse the endpoint info
                                    let (dt, dn) = match parse_mdns_endpoint_info(n.val_str()) {
                                        Ok(r) => r,
                                        Err(_) => continue,
                                    };

                                    let fullname = info.get_fullname().to_string();

                                    // Try all advertised IPv4 addresses with a 1-second timeout
                                    // to find a reachable interface (important when hosts have
                                    // multiple interfaces such as Docker, Tailscale, Wi-Fi, Ethernet).
                                    let mut reachable_ip = None;
                                    for ip in ip_hash {
                                        if !is_not_self_ip(ip) {
                                            continue;
                                        }
                                        let ip_port = format!("{ip}:{port}");
                                        if let Ok(Ok(stream)) = timeout(Duration::from_millis(1000), TcpStream::connect(&ip_port)).await {
                                            if !connection_is_remote(&stream) {
                                                continue;
                                            }
                                            reachable_ip = Some(*ip);
                                            break;
                                        }
                                    }

                                    if let Some(ip) = reachable_ip {
                                        let ip_port = format!("{ip}:{port}");
                                        let ei = EndpointInfo {
                                            fullname: fullname.clone(),
                                            id: ip_port,
                                            name: Some(dn),
                                            ip: Some(ip.to_string()),
                                            port: Some(port.to_string()),
                                            rtype: Some(dt),
                                            present: Some(true),
                                        };
                                        info!("ServiceResolved: Resolved a new service: {:?}", ei);
                                        cache.insert(fullname.clone(), ei.clone());
                                        let _ = self.sender.send(ei);
                                    } else {
                                        debug!("ServiceResolved: Could not connect to any address for {fullname}");
                                    }
                                }
                                ServiceEvent::ServiceRemoved(_, fullname) => {
                                    trace!("ServiceRemoved: checking if should remove {}", fullname);
                                    // Only remove if it has not been seen in the last cleanup_threshold
                                    let should_remove = cache.get(&fullname).map(|ei| ei.id.clone());

                                    if let Some(id) = should_remove {
                                        info!("ServiceRemoved: Remove a previous service: {}", fullname);
                                        cache.remove(&fullname);
                                        let _ = self.sender.send(EndpointInfo {
                                            id,
                                            ..Default::default()
                                        });
                                    }
                                }
                                ServiceEvent::SearchStarted(_) | ServiceEvent::SearchStopped(_) => {}
                                _ => {}
                            }
                        },
                        Err(err) => error!("MDnsDiscovery: error: {}", err),
                    }
                }
            }
        }

        let _ = daemon.stop_browse(service_type);
        if let Ok(receiver) = daemon.shutdown() {
            let _ = receiver.recv_timeout(std::time::Duration::from_secs(1));
        }
        Ok(())
    }
}

// Android may refuse native interface enumeration. The connected socket
// still tells us whether both ends are this device; do not list ourselves.
fn connection_is_remote(stream: &TcpStream) -> bool {
    match (stream.local_addr(), stream.peer_addr()) {
        (Ok(local), Ok(peer)) => local.ip() != peer.ip(),
        _ => false,
    }
}

#[cfg(test)]
mod connection_tests {
    use super::*;

    #[tokio::test]
    async fn excludes_own_listener_without_enumerating_interfaces() {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let stream = TcpStream::connect(listener.local_addr().unwrap()).await.unwrap();
        assert!(!connection_is_remote(&stream));
    }
}
