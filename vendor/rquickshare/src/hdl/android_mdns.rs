//! Android owns the multicast sockets: announce through NsdManager, just
//! as discovery does. Raw desktop mDNS daemons may have no usable Android
//! interfaces and compete with the system responder on UDP port 5353.
#![cfg_attr(not(target_os = "android"), allow(dead_code))]

use std::ffi::CString;
use std::os::raw::c_char;
use std::sync::{Arc, Mutex};
use std::time::Duration;

use tokio::sync::{broadcast, watch};
use tokio::time::{interval_at, Instant};
use tokio_util::sync::CancellationToken;

use super::mdns::Visibility;
use crate::utils::{
    device_name, gen_mdns_endpoint_info, gen_mdns_name, subscribe_device_name, DeviceType,
};

#[repr(C)]
struct Txt {
    key: *const c_char,
    value: *const u8,
    value_len: usize,
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::utils::parse_mdns_endpoint_info;
    use std::ffi::CStr;
    use std::sync::atomic::{AtomicU32, Ordering};

    static REMOVED: AtomicU32 = AtomicU32::new(0);

    #[no_mangle]
    unsafe extern "C" fn oriel_mdns_register(
        service_type: *const c_char,
        name: *const c_char,
        port: u16,
        txt: *const Txt,
        txt_count: usize,
        out_handle: *mut u32,
        _out_name: *mut c_char,
        _out_name_size: usize,
    ) -> i32 {
        assert_eq!(
            CStr::from_ptr(service_type).to_bytes(),
            b"_FC9F5ED42C8A._tcp"
        );
        assert!(!CStr::from_ptr(name).to_bytes().is_empty());
        assert_eq!(txt_count, 1);
        let txt = &*txt;
        assert_eq!(CStr::from_ptr(txt.key).to_bytes(), b"n");
        let value =
            std::str::from_utf8(std::slice::from_raw_parts(txt.value, txt.value_len)).unwrap();
        let (kind, name) = parse_mdns_endpoint_info(value).unwrap();
        assert_eq!(kind, DeviceType::Phone);
        assert!(!name.is_empty());
        if port == 0 {
            return -6;
        }
        *out_handle = 42;
        0
    }

    #[no_mangle]
    extern "C" fn oriel_mdns_unregister(handle: u32) {
        REMOVED.store(handle, Ordering::SeqCst);
    }

    #[tokio::test]
    async fn registers_phone_name_and_recovers_after_initial_registration_failure() {
        REMOVED.store(0, Ordering::SeqCst);
        assert!(Registration::new(*b"ABCD", 0).is_err());
        assert_eq!(REMOVED.load(Ordering::SeqCst), 0);
        let registration = Registration::new(*b"ABCD", 54321).unwrap();
        assert_eq!(REMOVED.load(Ordering::SeqCst), 0);
        drop(registration);
        assert_eq!(REMOVED.load(Ordering::SeqCst), 42);

        let (visibility_tx, visibility_rx) = watch::channel(Visibility::Visible);
        let (_, ble_rx) = broadcast::channel(1);
        let mut server = MDnsServer::new(
            *b"ABCD",
            0,
            ble_rx,
            Arc::new(Mutex::new(visibility_tx)),
            visibility_rx,
        )
        .unwrap();
        assert!(server.registration.is_none());
        assert!(server.announce().await.is_err());
        assert!(server.registration.is_none());
        server.port = 54321;
        server.announce().await.unwrap();
        assert!(server.registration.is_some());
    }
}

extern "C" {
    fn oriel_mdns_register(
        service_type: *const c_char,
        name: *const c_char,
        port: u16,
        txt: *const Txt,
        txt_count: usize,
        out_handle: *mut u32,
        out_name: *mut c_char,
        out_name_size: usize,
    ) -> i32;
    fn oriel_mdns_unregister(handle: u32);
}

struct Registration(u32);

impl Registration {
    fn new(endpoint_id: [u8; 4], port: u16) -> Result<Self, anyhow::Error> {
        let name = CString::new(gen_mdns_name(endpoint_id))?;
        let device_name = device_name();
        let endpoint_info = gen_mdns_endpoint_info(DeviceType::Phone as u8, &device_name);
        let txt = Txt {
            key: c"n".as_ptr(),
            value: endpoint_info.as_ptr(),
            value_len: endpoint_info.len(),
        };
        let mut handle = 0;
        let result = unsafe {
            oriel_mdns_register(
                c"_FC9F5ED42C8A._tcp".as_ptr(),
                name.as_ptr(),
                port,
                &txt,
                1,
                &mut handle,
                std::ptr::null_mut(),
                0,
            )
        };
        anyhow::ensure!(result == 0, "Android mDNS registration failed ({result})");
        info!("Android NsdManager: broadcasting as {device_name} on port {port}");
        Ok(Self(handle))
    }
}

impl Drop for Registration {
    fn drop(&mut self) {
        unsafe {
            oriel_mdns_unregister(self.0);
        }
    }
}

pub struct MDnsServer {
    endpoint_id: [u8; 4],
    port: u16,
    registration: Option<Registration>,
    visibility_sender: Arc<Mutex<watch::Sender<Visibility>>>,
    visibility_receiver: watch::Receiver<Visibility>,
    name_changes: watch::Receiver<u64>,
}

impl MDnsServer {
    pub fn new(
        endpoint_id: [u8; 4],
        port: u16,
        _ble_receiver: broadcast::Receiver<()>,
        visibility_sender: Arc<Mutex<watch::Sender<Visibility>>>,
        visibility_receiver: watch::Receiver<Visibility>,
    ) -> Result<Self, anyhow::Error> {
        // Android may not answer registration while Wi-Fi is unavailable.
        // Start the transfer engine independently; the announcement task
        // retries registration when a network becomes available.
        let mut name_changes = subscribe_device_name();
        name_changes.mark_unchanged();
        Ok(Self {
            endpoint_id,
            port,
            registration: None,
            visibility_sender,
            visibility_receiver,
            name_changes,
        })
    }

    async fn announce(&mut self) -> Result<(), anyhow::Error> {
        // Oriel waits for Android's registration callback. Keep that wait
        // off the async worker that handles transfers and discovery.
        self.registration.take();
        let endpoint_id = self.endpoint_id;
        let port = self.port;
        self.registration =
            Some(tokio::task::spawn_blocking(move || Registration::new(endpoint_id, port)).await??);
        Ok(())
    }

    pub async fn run(&mut self, ctk: CancellationToken) -> Result<(), anyhow::Error> {
        let mut visibility = *self.visibility_receiver.borrow();
        let mut names = self.name_changes.clone();
        if visibility != Visibility::Invisible {
            if let Err(err) = self.announce().await {
                warn!("Android NsdManager: announcement pending, will retry: {err}");
            }
        }
        let mut retry = interval_at(
            Instant::now() + Duration::from_secs(5),
            Duration::from_secs(5),
        );
        let mut interval = interval_at(
            Instant::now() + Duration::from_secs(60),
            Duration::from_secs(60),
        );
        loop {
            tokio::select! {
                _ = ctk.cancelled() => break,
                changed = self.visibility_receiver.changed() => {
                    if changed.is_err() { break; }
                    visibility = *self.visibility_receiver.borrow_and_update();
                    if visibility == Visibility::Invisible {
                        self.registration.take();
                    } else {
                        if let Err(err) = self.announce().await {
                            error!("Android NsdManager: {err}");
                        }
                        if visibility == Visibility::Temporarily { interval.reset(); }
                    }
                }
                changed = names.changed() => {
                    if changed.is_err() { break; }
                    names.borrow_and_update();
                    if visibility != Visibility::Invisible {
                        if let Err(err) = self.announce().await {
                            error!("Android NsdManager: name update failed: {err}");
                        }
                    }
                }
                _ = retry.tick(), if visibility != Visibility::Invisible && self.registration.is_none() => {
                    if let Err(err) = self.announce().await {
                        warn!("Android NsdManager: announcement pending, will retry: {err}");
                    }
                }
                _ = interval.tick() => {
                    if visibility == Visibility::Temporarily {
                        let _ = self.visibility_sender.lock().unwrap().send(Visibility::Invisible);
                    }
                }
            }
        }
        self.registration.take();
        Ok(())
    }
}
