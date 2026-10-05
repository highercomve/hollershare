//! C ABI between Oriel/Zig and the Quick Share protocol engine.
use rqs_lib::{
    channel::{ChannelAction, ChannelDirection, ChannelMessage, TransferType},
    EndpointInfo, OutboundPayload, SendInfo, State, Visibility, RQS,
};
use serde::Deserialize;
use serde_json::{json, Value};
use std::{
    collections::BTreeMap,
    ffi::{CStr, CString},
    os::raw::c_char,
    path::{Path, PathBuf},
    sync::{mpsc as sync_channel, Mutex, OnceLock},
    thread,
    time::Duration,
};
use tokio::sync::{broadcast, mpsc};

type EventCallback = unsafe extern "C" fn(*const c_char);
static EVENT_CALLBACK: Mutex<Option<EventCallback>> = Mutex::new(None);
#[no_mangle]
pub extern "C" fn ghostshare_set_event_callback(callback: Option<EventCallback>) {
    if let Ok(mut current) = EVENT_CALLBACK.lock() { *current = callback; }
}
fn notify_transfer(event: &ChannelMessage) {
    if event.rtype != Some(TransferType::Inbound) { return; }
    let kind = match event.state {
        Some(State::WaitingForUserConsent) => "request",
        Some(State::Finished) => "finished",
        Some(State::ReceivingFiles | State::Rejected | State::Cancelled | State::Disconnected) => "dismiss",
        _ => return,
    };
    let name = event.meta.as_ref().and_then(|m| m.source.as_ref()).map(|s| s.name.as_str()).unwrap_or("Nearby device");
    let pin = event.meta.as_ref().and_then(|m| m.pin_code.as_deref());
    let value = CString::new(json!({"id":event.id,"kind":kind,"name":name,"pin":pin,"text":event.meta.as_ref().is_some_and(|m| m.files.is_none())}).to_string()).unwrap();
    if let Ok(callback) = EVENT_CALLBACK.lock() {
        if let Some(callback) = *callback { unsafe { callback(value.as_ptr()); } }
    }
}
static ENGINE: OnceLock<Mutex<Option<Engine>>> = OnceLock::new();
struct Engine {
    tx: mpsc::Sender<Envelope>,
    thread: thread::JoinHandle<()>,
}
struct Envelope {
    request: Request,
    reply: sync_channel::Sender<Result<Value, String>>,
}
#[derive(Deserialize)]
#[serde(tag = "command", rename_all = "snake_case")]
enum Request {
    Snapshot,
    Visibility {
        visible: bool,
    },
    Send {
        address: String,
        name: String,
        paths: Vec<String>,
    },
    SendText { address: String, name: String, text: String },
    ResolveText { id: String },
    Decide {
        id: String,
        accept: bool,
        directory: Option<String>,
    },
    Cancel {
        id: String,
    },
    ResolvePath { id: String, index: usize, folder: bool },
    /// Where new transfers are saved: `directory` empty is the default
    /// folder; `create` makes it (the default folder) instead of requiring
    /// an existing, writable one (a folder the user chose).
    DownloadDir { directory: String, create: bool },
    /// A finished inbound transfer's files: `[{path, name, mime}]`, with
    /// the staged path, the sender's name and MIME type ("" when unknown).
    ReceivedFiles { id: String },
    /// Where the app moved a transfer's files after it finished (Android:
    /// into the folder chosen in Settings), shown in snapshots as
    /// `relocations[id]`. The engine only keeps it.
    Relocation { id: String, relocation: Value },
    Stop,
}
struct Model {
    download_dir: PathBuf,
    visible: bool,
    peers: BTreeMap<String, EndpointInfo>,
    transfers: Vec<ChannelMessage>,
    relocations: BTreeMap<String, Value>,
    error: Option<String>,
}
impl Model {
    fn snapshot(&self) -> Value {
        json!({"name":rqs_lib::device_name(), "download_dir":self.download_dir, "visible":self.visible,
            "peers":self.peers.values().collect::<Vec<_>>(), "transfers":self.transfers,
            "relocations":self.relocations, "error":self.error, "protocol":"Quick Share"})
    }
    /// A restarted phone has a new port and service ID; Android may leave
    /// its previous announcement cached. Remove unreachable duplicate
    /// endpoints, keeping distinct receivers that are still listening.
    async fn prune_duplicate_peers(&mut self) {
        let candidates: Vec<String> = self.peers.values().filter(|peer| {
            peer.ip.is_some() && self.peers.values().any(|other| {
                peer.id != other.id && peer.ip == other.ip && peer.name == other.name
            })
        }).map(|peer| peer.id.clone()).collect();
        let mut probes = tokio::task::JoinSet::new();
        for id in candidates {
            probes.spawn(async move {
                let reachable = matches!(tokio::time::timeout(
                    Duration::from_millis(750), tokio::net::TcpStream::connect(&id)
                ).await, Ok(Ok(_)));
                (!reachable).then_some(id)
            });
        }
        while let Some(result) = probes.join_next().await {
            if let Ok(Some(id)) = result { self.peers.remove(&id); }
        }
    }
    fn transfer_event(&mut self, mut event: ChannelMessage) {
        if event.direction != ChannelDirection::LibToFront {
            return;
        }
        let old_state = self.transfers.iter().find(|t| t.id == event.id).and_then(|t| t.state.clone());
        if let Some(index) = self.transfers.iter().position(|t| t.id == event.id) {
            if event.meta.is_none() {
                event.meta = self.transfers[index].meta.clone();
            }
            if event.rtype.is_none() {
                event.rtype = self.transfers[index].rtype.clone();
            }
            if old_state != event.state { notify_transfer(&event); }
            self.transfers[index] = event;
        } else {
            if self.transfers.len() >= 64 {
                if let Some(index) = self
                    .transfers
                    .iter()
                    .position(|t| terminal(t.state.as_ref()))
                {
                    let removed = self.transfers.remove(index);
                    self.relocations.remove(&removed.id);
                } else {
                    self.error = Some("Too many active transfers".into());
                    return;
                }
            }
            if old_state != event.state { notify_transfer(&event); }
            self.transfers.push(event);
        }
    }
}
/// `[{path, name, mime}]` for a received transfer's saved files: names and
/// MIME types fall back to the saved file's name and "" when the engine
/// didn't record them.
fn received_files(transfer: &ChannelMessage) -> Result<Value, String> {
    let meta = transfer.meta.as_ref().ok_or("File metadata unavailable")?;
    let saved = meta.saved_files.as_deref().unwrap_or_default();
    let files = saved.iter().enumerate().map(|(i, path)| {
        let name = meta.saved_names.as_ref().and_then(|n| n.get(i)).cloned()
            .or_else(|| Path::new(path).file_name().map(|n| n.to_string_lossy().into_owned()))
            .unwrap_or_default();
        let mime = meta.saved_mime_types.as_ref().and_then(|m| m.get(i)).cloned().unwrap_or_default();
        json!({"path":path, "name":name, "mime":mime})
    });
    Ok(Value::Array(files.collect()))
}
fn terminal(state: Option<&State>) -> bool {
    matches!(
        state,
        Some(State::Finished | State::Rejected | State::Cancelled | State::Disconnected)
    )
}
fn validate_paths(paths: &[String]) -> Result<Vec<String>, String> {
    if paths.is_empty() || paths.len() > 1024 {
        return Err("Choose between 1 and 1024 files".into());
    }
    paths
        .iter()
        .map(|p| {
            let path = std::fs::canonicalize(p).map_err(|e| e.to_string())?;
            let info = std::fs::metadata(&path).map_err(|e| e.to_string())?;
            if !info.is_file() {
                return Err("Only regular files can be sent".into());
            }
            if info.len() > (1 << 40) {
                return Err("File exceeds the 1 TB limit".into());
            }
            path.to_str()
                .map(str::to_owned)
                .ok_or_else(|| "Filename is not UTF-8".into())
        })
        .collect()
}
fn control_message(id: String, action: ChannelAction) -> ChannelMessage {
    ChannelMessage {
        id,
        direction: ChannelDirection::FrontToLib,
        action: Some(action),
        ..Default::default()
    }
}
async fn handle(
    request: Request,
    model: &mut Model,
    rqs: &mut RQS,
    sender: &mpsc::Sender<SendInfo>,
) -> Result<Value, String> {
    match request {
        Request::Snapshot => return Ok(model.snapshot()),
        Request::Visibility { visible } => {
            rqs.change_visibility(if visible {
                Visibility::Visible
            } else {
                Visibility::Invisible
            });
            model.visible = visible;
        }
        Request::Send {
            address,
            name,
            paths,
        } => {
            let address: std::net::SocketAddr = address
                .parse()
                .map_err(|_| "Use an IP address and port".to_string())?;
            if address.port() == 0 || address.ip().is_unspecified() || address.ip().is_multicast() {
                return Err("Invalid destination".into());
            }
            let paths = validate_paths(&paths)?;
            let id = format!(
                "{}-{}",
                address,
                std::time::SystemTime::now()
                    .duration_since(std::time::UNIX_EPOCH)
                    .unwrap_or_default()
                    .as_nanos()
            );
            sender
                .try_send(SendInfo {
                    id,
                    name,
                    addr: address.to_string(),
                    ob: OutboundPayload::Files(paths),
                })
                .map_err(|e| e.to_string())?;
        }
        Request::SendText { address, name, text } => {
            if text.is_empty() || text.len() > 1024 * 1024 || text.contains('\0') {
                return Err("Clipboard text must be between 1 byte and 1 MB, without NUL characters".into());
            }
            let address: std::net::SocketAddr = address.parse().map_err(|_| "Use an IP address and port")?;
            if address.port() == 0 || address.ip().is_unspecified() || address.ip().is_multicast() {
                return Err("Invalid destination".into());
            }
            let id = format!("{}-{}", address, std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos());
            sender.try_send(SendInfo { id, name, addr: address.to_string(), ob: OutboundPayload::Text(text) }).map_err(|e| e.to_string())?;
        }
        Request::ResolveText { id } => {
            let transfer = model.transfers.iter().find(|t| t.id == id).ok_or("Transfer not found")?;
            if transfer.state != Some(State::Finished) { return Err("Transfer has not completed".into()); }
            return Ok(json!(transfer.meta.as_ref().and_then(|m| m.text_payload.as_ref()).ok_or("Text unavailable")?));
        }
        Request::Decide { id, accept, directory } => {
            let transfer = model
                .transfers
                .iter()
                .find(|t| t.id == id)
                .ok_or("Request expired")?;
            if transfer.rtype != Some(TransferType::Inbound)
                || transfer.state != Some(State::WaitingForUserConsent)
            {
                return Err("Request is no longer waiting for approval".into());
            }
            let directory = if accept {
                directory.map(|dir| -> Result<String, String> {
                    let path = std::fs::canonicalize(dir).map_err(|e| e.to_string())?;
                    if !path.is_dir() { return Err("Save location must be a directory".into()); }
                    Ok(path.to_string_lossy().into_owned())
                }).transpose()?
            } else { None };
            let mut message = control_message(id, if accept { ChannelAction::AcceptTransfer } else { ChannelAction::RejectTransfer });
            message.save_directory = directory;
            rqs.message_sender.send(message).map_err(|e| e.to_string())?;
        }
        Request::ResolvePath { id, index, folder } => {
            let transfer = model.transfers.iter().find(|t| t.id == id).ok_or("Transfer not found")?;
            if transfer.state != Some(State::Finished) { return Err("Transfer has not completed".into()); }
            let meta = transfer.meta.as_ref().ok_or("File metadata unavailable")?;
            let paths = if transfer.rtype == Some(TransferType::Inbound) { &meta.saved_files } else { &meta.files };
            let path = PathBuf::from(paths.as_ref().and_then(|p| p.get(index)).ok_or("File not found")?);
            let path = if folder { path.parent().ok_or("Folder unavailable")?.to_path_buf() } else { path };
            return Ok(json!(std::fs::canonicalize(path).map_err(|e| e.to_string())?));
        }
        Request::ReceivedFiles { id } => {
            let transfer = model.transfers.iter().find(|t| t.id == id).ok_or("Transfer not found")?;
            if transfer.state != Some(State::Finished) || transfer.rtype != Some(TransferType::Inbound) {
                return Err("Transfer has not completed".into());
            }
            return received_files(transfer);
        }
        Request::Relocation { id, relocation } => {
            if !model.transfers.iter().any(|t| t.id == id) { return Err("Transfer not found".into()); }
            model.relocations.insert(id, relocation);
        }
        Request::DownloadDir { directory, create } => {
            let directory = download_directory(&directory, create)?;
            rqs.set_download_path(Some(directory.clone()));
            model.download_dir = directory;
            return Ok(json!(model.download_dir));
        }
        Request::Cancel { id } => {
            let transfer = model
                .transfers
                .iter()
                .find(|t| t.id == id)
                .ok_or("Transfer not found")?;
            if terminal(transfer.state.as_ref()) {
                return Err("Transfer already ended".into());
            }
            rqs.message_sender
                .send(control_message(id, ChannelAction::CancelTransfer))
                .map_err(|e| e.to_string())?;
        }
        Request::Stop => unreachable!(),
    }
    Ok(json!(true))
}
async fn run(
    mut requests: mpsc::Receiver<Envelope>,
    ready: sync_channel::Sender<Result<(), String>>,
    directory: PathBuf,
) {
    let mut model = Model {
        download_dir: directory.clone(),
        visible: true,
        peers: BTreeMap::new(),
        transfers: vec![],
        relocations: BTreeMap::new(),
        error: None,
    };
    let port = std::env::var("GHOSTFILE_PORT")
        .ok()
        .and_then(|p| p.parse::<u16>().ok())
        .map(u32::from);
    let mut rqs = RQS::new(Visibility::Visible, port, Some(directory));
    let mut transfers = rqs.message_sender.subscribe();
    let (peers_tx, mut peers) = broadcast::channel(64);
    let sender = match rqs.run().await {
        Ok((sender, _)) => sender,
        Err(e) => {
            let _ = ready.send(Err(e.to_string()));
            return;
        }
    };
    if let Err(e) = rqs.discovery(peers_tx) {
        let _ = ready.send(Err(e.to_string()));
        let _ = tokio::time::timeout(Duration::from_secs(3), rqs.stop()).await;
        return;
    }
    let _ = ready.send(Ok(()));
    let mut peer_cleanup = tokio::time::interval(Duration::from_secs(5));
    loop {
        tokio::select! {
            _ = peer_cleanup.tick() => model.prune_duplicate_peers().await,
            envelope = requests.recv() => {
                let Some(envelope) = envelope else { break; };
                if matches!(envelope.request, Request::Stop) {
                    let _ = envelope.reply.send(Ok(json!(true)));
                    break;
                }
                let result = handle(envelope.request, &mut model, &mut rqs, &sender).await;
                let _ = envelope.reply.send(result);
            }
            event = peers.recv() => match event {
                Ok(peer) if peer.present == Some(true) => {
                    if model.peers.len() < 128 || model.peers.contains_key(&peer.id) {
                        model.peers.insert(peer.id.clone(), peer);
                    }
                }
                Ok(peer) => { model.peers.remove(&peer.id); }
                Err(broadcast::error::RecvError::Lagged(_)) => { model.error = Some("Discovery updates were delayed".into()); }
                Err(broadcast::error::RecvError::Closed) => break,
            },
            event = transfers.recv() => match event {
                Ok(event) => model.transfer_event(event),
                Err(broadcast::error::RecvError::Lagged(_)) => { model.error = Some("Transfer updates were delayed".into()); }
                Err(broadcast::error::RecvError::Closed) => break,
            },
        }
    }
    let _ = tokio::time::timeout(Duration::from_secs(3), rqs.stop()).await;
}
fn encode(result: Result<Value, String>) -> *mut c_char {
    let value = match result {
        Ok(data) => json!({"ok":true,"data":data}),
        Err(error) => json!({"ok":false,"error":error}),
    };
    CString::new(value.to_string())
        .expect("JSON has no literal NUL")
        .into_raw()
}
fn guarded(f: impl FnOnce() -> Result<Value, String>) -> *mut c_char {
    encode(
        std::panic::catch_unwind(std::panic::AssertUnwindSafe(f))
            .unwrap_or_else(|_| Err("Quick Share engine panicked".into())),
    )
}
/// Android discards stderr and has no state directory for a log file: the
/// engine's log goes to logcat instead (`adb logcat -s GhostShare`), with
/// discovery (`rqs_lib`) at info so that resolved devices show up there.
#[cfg(target_os = "android")]
fn setup_logging() {
    let _ = tracing_subscriber::fmt()
        .with_ansi(false)
        .without_time()
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "warn,rqs_lib=info".into()))
        .with_writer(|| logcat::Writer::default())
        .try_init();
}
#[cfg(target_os = "android")]
mod logcat {
    use std::{ffi::CString, io, os::raw::{c_char, c_int}};
    #[link(name = "log")]
    extern "C" {
        fn __android_log_write(priority: c_int, tag: *const c_char, text: *const c_char) -> c_int;
    }
    /// One tracing event's text, written to logcat as one entry when dropped.
    #[derive(Default)]
    pub struct Writer(Vec<u8>);
    impl io::Write for Writer {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0.extend_from_slice(bytes);
            Ok(bytes.len())
        }
        fn flush(&mut self) -> io::Result<()> { Ok(()) }
    }
    impl Drop for Writer {
        fn drop(&mut self) {
            let text = String::from_utf8_lossy(&self.0);
            let text = text.trim_end();
            if text.is_empty() { return; }
            // android/log.h: INFO 4, WARN 5, ERROR 6.
            let level = text.split_whitespace().next().unwrap_or("");
            let priority = match level { "ERROR" => 6, "WARN" => 5, _ => 4 };
            let Ok(text) = CString::new(text.replace('\0', " ")) else { return; };
            unsafe { __android_log_write(priority, c"GhostShare".as_ptr(), text.as_ptr()); }
        }
    }
}
#[cfg(not(target_os = "android"))]
fn setup_logging() {
    let writer: Box<dyn std::io::Write + Send> = (|| -> std::io::Result<_> {
        let dirs = directories::ProjectDirs::from("dev", "ghostshare", "GhostShare")
            .ok_or_else(|| std::io::Error::other("No application state directory"))?;
        let folder = dirs.state_dir().unwrap_or(dirs.data_local_dir());
        std::fs::create_dir_all(folder)?;
        let path = folder.join("quickshare.log");
        if std::fs::metadata(&path).is_ok_and(|m| m.len() > 1024 * 1024) {
            let _ = std::fs::rename(&path, folder.join("quickshare.previous.log"));
        }
        let mut options = std::fs::OpenOptions::new();
        options.create(true).append(true);
        #[cfg(unix)] {
            use std::os::unix::fs::OpenOptionsExt;
            options.mode(0o600);
        }
        options.open(path)
    })().map(|file| Box::new(file) as Box<dyn std::io::Write + Send>)
        .unwrap_or_else(|_| Box::new(std::io::stderr()));
    let _ = tracing_subscriber::fmt()
        .with_ansi(false)
        .with_env_filter(tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| "warn".into()))
        .with_writer(Mutex::new(writer))
        .try_init();
}
/// The name nearby devices see (the platform's device name, from Oriel),
/// before `ghostshare_start`. Null or empty: the host name. Input must be a
/// NUL-terminated string owned by the caller (invalid UTF-8 is replaced).
#[no_mangle]
pub unsafe extern "C" fn ghostshare_set_device_name(name: *const c_char) {
    let name = if name.is_null() {
        None
    } else {
        Some(CStr::from_ptr(name).to_string_lossy().into_owned())
    };
    rqs_lib::set_device_name(name);
}
/// Input must be a valid NUL-terminated UTF-8 string owned by the caller.
#[no_mangle]
pub unsafe extern "C" fn ghostshare_start(directory: *const c_char) -> *mut c_char {
    guarded(|| {
        setup_logging();
        if directory.is_null() {
            return Err("Missing downloads directory".into());
        }
        let text = CStr::from_ptr(directory)
            .to_str()
            .map_err(|e| e.to_string())?;
        let directory = download_directory(text, true)?;
        let mut engine = ENGINE
            .get_or_init(|| Mutex::new(None))
            .lock()
            .map_err(|e| e.to_string())?;
        if engine.is_some() {
            return Err("Engine already running".into());
        }
        let runtime = tokio::runtime::Builder::new_multi_thread()
            .worker_threads(2)
            .enable_all()
            .build()
            .map_err(|e| e.to_string())?;
        let (tx, rx) = mpsc::channel(32);
        let (ready_tx, ready_rx) = sync_channel::channel();
        let thread = thread::Builder::new()
            .name("ghostshare-quickshare".into())
            .spawn(move || {
                runtime.block_on(run(rx, ready_tx, directory));
                runtime.shutdown_timeout(Duration::from_secs(1));
            })
            .map_err(|e| e.to_string())?;
        match ready_rx.recv_timeout(Duration::from_secs(10)) {
            Ok(Ok(())) => {
                *engine = Some(Engine { tx, thread });
                Ok(json!(true))
            }
            Ok(Err(e)) => {
                drop(tx);
                let _ = thread.join();
                Err(e)
            }
            Err(e) => {
                drop(tx);
                let _ = thread.join();
                Err(e.to_string())
            }
        }
    })
}
#[no_mangle]
pub unsafe extern "C" fn ghostshare_request(request: *const c_char) -> *mut c_char {
    guarded(|| {
        if request.is_null() {
            return Err("Missing request".into());
        }
        let request: Request = serde_json::from_slice(CStr::from_ptr(request).to_bytes())
            .map_err(|e| e.to_string())?;
        if matches!(request, Request::Stop) {
            return Err("Use ghostshare_stop".into());
        }
        let engine = ENGINE
            .get_or_init(|| Mutex::new(None))
            .lock()
            .map_err(|e| e.to_string())?;
        let engine = engine.as_ref().ok_or("Quick Share engine is not running")?;
        let (tx, rx) = sync_channel::channel();
        engine
            .tx
            .try_send(Envelope { request, reply: tx })
            .map_err(|e| e.to_string())?;
        rx.recv_timeout(Duration::from_secs(5))
            .map_err(|e| e.to_string())?
    })
}
/// The desktop default download folder: `GHOSTFILE_DOWNLOAD_DIR`, else
/// `~/Downloads/GhostShare`.
fn default_directory() -> Result<PathBuf, String> {
    if let Some(directory) = std::env::var_os("GHOSTFILE_DOWNLOAD_DIR") {
        return Ok(PathBuf::from(directory));
    }
    let dirs = directories::UserDirs::new().ok_or("Could not locate home directory")?;
    Ok(dirs.download_dir().unwrap_or(dirs.home_dir()).join("GhostShare"))
}
/// Fails unless a file can be created in `directory`.
fn check_writable(directory: &Path) -> Result<(), String> {
    let nanos = std::time::SystemTime::now().duration_since(std::time::UNIX_EPOCH).unwrap_or_default().as_nanos();
    let probe = directory.join(format!(".ghostshare-write-test-{}-{nanos}", std::process::id()));
    std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&probe)
        .map_err(|_| "GhostShare can't write to this folder".to_string())?;
    let _ = std::fs::remove_file(&probe);
    Ok(())
}
/// Where received files go, canonical: `text` empty is `default_directory`.
/// With `create`, the folder is made if missing (default folders); without,
/// it must already exist (a folder the user chose). Either way it must be a
/// writable directory.
fn download_directory(text: &str, create: bool) -> Result<PathBuf, String> {
    let directory = if text.trim().is_empty() { default_directory()? } else { PathBuf::from(text) };
    if !directory.is_absolute() {
        return Err("Use a full folder path".into());
    }
    if create {
        std::fs::create_dir_all(&directory).map_err(|e| e.to_string())?;
    }
    let directory = std::fs::canonicalize(&directory).map_err(|_| "This folder doesn't exist".to_string())?;
    if !directory.is_dir() {
        return Err("Choose a folder, not a file".into());
    }
    check_writable(&directory)?;
    Ok(directory)
}
#[no_mangle]
pub extern "C" fn ghostshare_stop() {
    let Some(lock) = ENGINE.get() else {
        return;
    };
    let Ok(mut guard) = lock.lock() else {
        return;
    };
    if let Some(engine) = guard.take() {
        let (tx, _) = sync_channel::channel();
        let _ = engine.tx.try_send(Envelope {
            request: Request::Stop,
            reply: tx,
        });
        drop(engine.tx);
        let _ = engine.thread.join();
    }
}
/// Free exactly once a non-null pointer returned by start/request.
#[no_mangle]
pub unsafe extern "C" fn ghostshare_free(pointer: *mut c_char) {
    if !pointer.is_null() {
        drop(CString::from_raw(pointer));
    }
}
#[cfg(test)]
mod tests {
    use super::*;
    #[tokio::test]
    async fn removes_stale_phone_ports_and_preserves_live_receivers() {
        let live = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let another_live = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let stopped = tokio::net::TcpListener::bind("127.0.0.1:0").await.unwrap();
        let old_address = stopped.local_addr().unwrap();
        drop(stopped);
        let make_peer = |address: std::net::SocketAddr| EndpointInfo {
            id: address.to_string(),
            ip: Some(address.ip().to_string()),
            port: Some(address.port().to_string()),
            name: Some("Poco x3".into()),
            present: Some(true),
            ..Default::default()
        };
        let live_id = live.local_addr().unwrap().to_string();
        let another_id = another_live.local_addr().unwrap().to_string();
        let peers = [make_peer(live.local_addr().unwrap()),
            make_peer(another_live.local_addr().unwrap()), make_peer(old_address)];
        let mut model = Model {
            download_dir: PathBuf::new(), visible: true,
            peers: peers.into_iter().map(|peer| (peer.id.clone(), peer)).collect(),
            transfers: vec![], relocations: BTreeMap::new(), error: None,
        };
        model.prune_duplicate_peers().await;
        assert_eq!(model.peers.len(), 2);
        assert!(model.peers.contains_key(&live_id));
        assert!(model.peers.contains_key(&another_id));
        assert!(!model.peers.contains_key(&old_address.to_string()));
    }
    #[test]
    fn rejects_non_files_and_empty_batches() {
        assert!(validate_paths(&[]).is_err());
        assert!(validate_paths(&["/a/nonexistent/ghostshare".into()]).is_err());
        assert!(validate_paths(&[std::env::temp_dir().to_string_lossy().into_owned()]).is_err());
    }
    #[test]
    fn preserves_pin_and_metadata_when_state_only_event_arrives() {
        let mut model = Model {
            download_dir: PathBuf::new(),
            visible: true,
            peers: BTreeMap::new(),
            transfers: vec![],
            relocations: BTreeMap::new(),
            error: None,
        };
        let mut event: ChannelMessage = serde_json::from_value(json!({"id":"1", "direction":"LibToFront",
            "rtype":"Inbound", "state":"WaitingForUserConsent", "meta":{"id":"1", "pin_code":"1234", "total_bytes":5,"ack_bytes":0}})).unwrap();
        model.transfer_event(event.clone());
        event.state = Some(State::Finished);
        event.meta = None;
        event.rtype = None;
        model.transfer_event(event);
        assert_eq!(
            model.transfers[0]
                .meta
                .as_ref()
                .unwrap()
                .pin_code
                .as_deref(),
            Some("1234")
        );
        assert_eq!(model.transfers[0].rtype, Some(TransferType::Inbound));
    }
    #[test]
    fn received_files_pair_paths_with_names_and_types() {
        let transfer = |meta: Value| -> ChannelMessage { serde_json::from_value(json!({"id":"1", "direction":"LibToFront", "meta":meta})).unwrap() };
        let full = transfer(json!({"id":"1", "total_bytes":0, "ack_bytes":0,
            "saved_files":["/r/photo.jpg", "/r/1_notes"], "saved_names":["photo.jpg", "notes"], "saved_mime_types":["image/jpeg", ""]}));
        assert_eq!(received_files(&full).unwrap(), json!([
            {"path":"/r/photo.jpg", "name":"photo.jpg", "mime":"image/jpeg"},
            {"path":"/r/1_notes", "name":"notes", "mime":""},
        ]));
        // Without names (an older engine's metadata): the saved file's name.
        let bare = transfer(json!({"id":"1", "total_bytes":0, "ack_bytes":0, "saved_files":["/r/a.txt"]}));
        assert_eq!(received_files(&bare).unwrap(), json!([{"path":"/r/a.txt", "name":"a.txt", "mime":""}]));
    }
    fn scratch(name: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!("ghostshare-test-{}-{name}", std::process::id()));
        let _ = std::fs::remove_dir_all(&path);
        path
    }
    #[test]
    fn chosen_download_folder_must_exist() {
        let path = scratch("missing");
        assert!(download_directory(path.to_str().unwrap(), false).is_err());
        assert!(!path.exists());
        std::fs::create_dir_all(&path).unwrap();
        assert_eq!(download_directory(path.to_str().unwrap(), false).unwrap(), std::fs::canonicalize(&path).unwrap());
        // No probe file left behind.
        assert_eq!(std::fs::read_dir(&path).unwrap().count(), 0);
        std::fs::remove_dir_all(&path).unwrap();
    }
    #[test]
    fn default_download_folder_is_created() {
        let path = scratch("default").join("Received");
        assert_eq!(download_directory(path.to_str().unwrap(), true).unwrap(), std::fs::canonicalize(&path).unwrap());
        std::fs::remove_dir_all(path.parent().unwrap()).unwrap();
    }
    #[test]
    fn download_folder_rejects_files_and_relative_paths() {
        let path = scratch("file");
        std::fs::create_dir_all(&path).unwrap();
        let file = path.join("a.txt");
        std::fs::write(&file, b"x").unwrap();
        assert!(download_directory(file.to_str().unwrap(), false).is_err());
        assert!(download_directory("relative/folder", false).is_err());
        std::fs::remove_dir_all(&path).unwrap();
    }
    #[cfg(unix)]
    #[test]
    fn download_folder_must_be_writable() {
        use std::os::unix::fs::PermissionsExt;
        let path = scratch("readonly");
        std::fs::create_dir_all(&path).unwrap();
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o555)).unwrap();
        // Root can write anywhere: only check where permissions apply.
        if std::fs::write(path.join("probe"), b"").is_err() {
            assert!(download_directory(path.to_str().unwrap(), false).is_err());
        }
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
        std::fs::remove_dir_all(&path).unwrap();
    }
    #[test]
    fn device_name_changes_notify_and_show_in_snapshots() {
        let mut changes = rqs_lib::subscribe_device_name();
        changes.mark_unchanged();
        rqs_lib::set_device_name(Some("  Desk  ".into()));
        assert!(changes.has_changed().unwrap());
        changes.mark_unchanged();
        // The same name again is not a change.
        rqs_lib::set_device_name(Some("Desk".into()));
        assert!(!changes.has_changed().unwrap());
        let model = Model { download_dir: PathBuf::new(), visible: true, peers: BTreeMap::new(), transfers: vec![], relocations: BTreeMap::new(), error: None };
        assert_eq!(model.snapshot()["name"], "Desk");
        rqs_lib::set_device_name(None);
        assert!(changes.has_changed().unwrap());
    }
}
