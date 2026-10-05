#[cfg(not(target_os = "android"))]
use std::sync::{Arc, Mutex};
#[cfg(not(target_os = "android"))]
use std::time::Duration;

#[cfg(not(target_os = "android"))]
use mdns_sd::{AddrType, ServiceDaemon, ServiceInfo};
use serde::{Deserialize, Serialize};
#[cfg(not(target_os = "android"))]
use tokio::sync::broadcast::Receiver;
#[cfg(not(target_os = "android"))]
use tokio::sync::watch;
#[cfg(not(target_os = "android"))]
use tokio::time::{interval_at, Instant};
#[cfg(not(target_os = "android"))]
use tokio_util::sync::CancellationToken;
use ts_rs::TS;

#[cfg(not(target_os = "android"))]
use crate::utils::{
    device_name, gen_mdns_endpoint_info, gen_mdns_name, subscribe_device_name, DeviceType,
};

#[cfg(not(target_os = "android"))]
const INNER_NAME: &str = "MDnsServer";
#[cfg(not(target_os = "android"))]
const TICK_INTERVAL: Duration = Duration::from_secs(60);

#[derive(Debug, Clone, Copy, PartialEq, Serialize, Deserialize, TS)]
#[ts(export)]
pub enum Visibility {
    Visible = 0,
    Invisible = 1,
    Temporarily = 2,
}

#[allow(dead_code)]
impl Visibility {
    pub fn from_raw_value(value: u64) -> Self {
        match value {
            0 => Visibility::Visible,
            1 => Visibility::Invisible,
            2 => Visibility::Temporarily,
            _ => unreachable!(),
        }
    }
}

#[cfg(not(target_os = "android"))]
pub struct MDnsServer {
    daemon: ServiceDaemon,
    endpoint_id: [u8; 4],
    service_port: u16,
    service_info: ServiceInfo,
    ble_receiver: Receiver<()>,
    visibility_sender: Arc<Mutex<watch::Sender<Visibility>>>,
    visibility_receiver: watch::Receiver<Visibility>,
}

#[cfg(not(target_os = "android"))]
impl MDnsServer {
    pub fn new(
        endpoint_id: [u8; 4],
        service_port: u16,
        ble_receiver: Receiver<()>,
        visibility_sender: Arc<Mutex<watch::Sender<Visibility>>>,
        visibility_receiver: watch::Receiver<Visibility>,
    ) -> Result<Self, anyhow::Error> {
        let service_info = Self::build_service(endpoint_id, service_port, DeviceType::Laptop)?;

        Ok(Self {
            daemon: ServiceDaemon::new()?,
            endpoint_id,
            service_port,
            service_info,
            ble_receiver,
            visibility_sender,
            visibility_receiver,
        })
    }

    pub async fn run(&mut self, ctk: CancellationToken) -> Result<(), anyhow::Error> {
        info!("{INNER_NAME}: service starting");
        let monitor = self.daemon.monitor()?;
        let ble_receiver = &mut self.ble_receiver;
        let mut visibility = *self.visibility_receiver.borrow();
        let mut interval = interval_at(Instant::now() + TICK_INTERVAL, TICK_INTERVAL);
        let mut name_changes = subscribe_device_name();
        name_changes.mark_unchanged();

        loop {
            tokio::select! {
                _ = ctk.cancelled() => {
                    info!("{INNER_NAME}: tracker cancelled, breaking");
                    break;
                }
                r = monitor.recv_async() => {
                    match r {
                        Ok(_) => continue,
                        Err(err) => return Err(err.into()),
                    }
                },
                Ok(()) = name_changes.changed() => {
                    // The name is in the TXT record: withdraw the service
                    // (goodbye packets, so browsers drop the old name) and
                    // announce it again with the new one.
                    name_changes.mark_unchanged();
                    let service_info = Self::build_service(self.endpoint_id, self.service_port, DeviceType::Laptop)?;
                    if visibility != Visibility::Invisible {
                        if let Ok(receiver) = self.daemon.unregister(self.service_info.get_fullname()) {
                            let _ = receiver.recv_timeout(Duration::from_secs(1));
                        }
                        self.daemon.register(service_info.clone())?;
                    }
                    self.service_info = service_info;
                }
                _ = self.visibility_receiver.changed() => {
                    visibility = *self.visibility_receiver.borrow_and_update();

                    debug!("{INNER_NAME}: visibility changed: {visibility:?}");
                    if visibility == Visibility::Visible {
                        self.daemon.register(self.service_info.clone())?;
                    } else if visibility == Visibility::Invisible {
                        let receiver = self.daemon.unregister(self.service_info.get_fullname())?;
                        let _ = receiver.recv();
                    } else if visibility == Visibility::Temporarily {
                        self.daemon.register(self.service_info.clone())?;
                        interval.reset();
                    }
                }
                _ = ble_receiver.recv() => {
                    if visibility == Visibility::Invisible {
                        continue;
                    }

                    debug!("{INNER_NAME}: ble_receiver: got event");
                    if visibility == Visibility::Visible || visibility == Visibility::Temporarily {
                        // Android can sometime not see the mDNS service if the service
                        // was running BEFORE Android started the Discovery phase for QuickShare.
                        // So resend a broadcast if there's a android device sending.
                        self.daemon.register_resend(self.service_info.get_fullname())?;
                    } else {
                        self.daemon.register(self.service_info.clone())?;
                    }
                },
                _ = interval.tick() => {
                    if visibility != Visibility::Temporarily {
                        continue;
                    }

                    let receiver = self.daemon.unregister(self.service_info.get_fullname())?;
                    let _ = receiver.recv();
                    let _ = self.visibility_sender.lock().unwrap().send(Visibility::Invisible);
                }
            }
        }

        // Hidden devices are already unregistered. Stop the daemon thread too.
        if visibility != Visibility::Invisible {
            if let Ok(receiver) = self.daemon.unregister(self.service_info.get_fullname()) {
                let _ = receiver.recv_timeout(Duration::from_secs(1));
            }
        }
        if let Ok(receiver) = self.daemon.shutdown() {
            let _ = receiver.recv_timeout(Duration::from_secs(1));
        }

        Ok(())
    }

    fn build_service(
        endpoint_id: [u8; 4],
        service_port: u16,
        device_type: DeviceType,
    ) -> Result<ServiceInfo, anyhow::Error> {
        let name = gen_mdns_name(endpoint_id);
        // The mDNS host name stays the system's; the name phones show is
        // the device name in the endpoint info.
        let hostname = mdns_hostname(&hostname::get()?.to_string_lossy());
        let device_name = device_name();
        info!("Broadcasting as: {device_name} (host {hostname})");
        let endpoint_info = gen_mdns_endpoint_info(device_type as u8, &device_name);

        let properties = [("n", endpoint_info)];
        let si = ServiceInfo::new(
            "_FC9F5ED42C8A._tcp.local.",
            &name,
            &hostname,
            "",
            service_port,
            &properties[..],
        )?
        .enable_addr_auto(AddrType::V4);

        Ok(si)
    }
}

// Android's resolver needs a fully qualified mDNS host, rather than a bare
// system hostname such as "ridge" (or Android's shared "localhost").
#[cfg(not(target_os = "android"))]
fn mdns_hostname(hostname: &str) -> String {
    let hostname = hostname.trim_end_matches('.');
    if hostname.to_ascii_lowercase().ends_with(".local") {
        format!("{hostname}.")
    } else {
        format!("{hostname}.local.")
    }
}

#[cfg(all(test, not(target_os = "android")))]
mod hostname_tests {
    use super::mdns_hostname;

    #[test]
    fn announces_fully_qualified_local_hostname() {
        assert_eq!(mdns_hostname("ridge"), "ridge.local.");
        assert_eq!(mdns_hostname("ridge.local"), "ridge.local.");
        assert_eq!(mdns_hostname("ridge.local."), "ridge.local.");
        assert_eq!(mdns_hostname("ridge.LOCAL."), "ridge.LOCAL.");
    }
}
