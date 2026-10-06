const $ = id => document.getElementById(id);
let files = [], model = null, sending = false, polling = false, share_mode = "files";
// Android: received files land in HollerShare's folder, then move to the
// folder chosen in Settings (model.relocations); opening them is left to
// the Files app.
let platform_android = false, settings = null;
function ready_to_send() { return share_mode === "text" ? $("clipboard-text").value.length > 0 : files.length > 0; }
function set_share_mode(mode) {
  share_mode = mode;
  $("file-compose").hidden = mode !== "files"; $("text-compose").hidden = mode !== "text";
  $("clear").hidden = mode !== "files" || !files.length;
  $("mode-files").className = mode === "files" ? "secondary" : "text-button";
  $("mode-text").className = mode === "text" ? "secondary" : "text-button";
  $("mode-files").setAttribute("aria-pressed", String(mode === "files"));
  $("mode-text").setAttribute("aria-pressed", String(mode === "text"));
  render_files(); render_peers();
}
async function paste_clipboard() {
  set_share_mode("text"); $("read-clipboard").disabled = true;
  try { const result = await call("read_clipboard"); $("clipboard-text").value = result.text; if (!result.text) error("The clipboard has no text to share."); else $("error").hidden = true; }
  catch (err) { error(err.message || err); }
  finally { $("read-clipboard").disabled = false; render_files(); render_peers(); }
}
const terminal = new Set(["Finished", "Rejected", "Cancelled", "Disconnected"]);
const states = { Initial:"Connecting", ReceivedConnectionRequest:"Connecting", SentIntroduction:"Waiting for receiver",
  WaitingForUserConsent:"Waiting for approval", ReceivingFiles:"Receiving", SendingFiles:"Sending", Finished:"Complete",
  Rejected:"Declined", Cancelled:"Cancelled", Disconnected:"Disconnected" };
function bytes(value) {
  if (value < 1024) return value + " B";
  const units = ["KB", "MB", "GB", "TB"];
  let i = -1;
  do { value /= 1024; i++; } while (value >= 1024 && i < units.length - 1);
  return value.toFixed(value < 10 ? 1 : 0) + " " + units[i];
}
function element(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}
function clear(node) { node.innerHTML = ""; }
function error(message) { $("error").textContent = String(message); $("error").hidden = false; }
async function call(command, args) {
  if (!window.oriel) throw new Error("Open HollerShare as a desktop app to share files.");
  const response = await window.oriel.invoke(command, args || null);
  if (typeof response !== "string") return response;
  const result = JSON.parse(response);
  if (!result.ok) throw new Error(result.error);
  return result.data;
}
function button(text, className, action) {
  const node = element("button", className, text);
  node.addEventListener("click", action);
  return node;
}
function render_files() {
  clear($("file-list"));
  $("file-empty").hidden = files.length > 0;
  $("clear").hidden = share_mode !== "files" || files.length === 0;
  $("choose").textContent = files.length ? "Add another file ＋" : "Choose files ＋";
  for (const file of files) {
    const row = element("div", "file-row");
    const detail = element("div", "file-detail");
    detail.appendChild(element("div", "file-name", file.name));
    detail.appendChild(element("div", "small", bytes(file.size)));
    row.appendChild(detail);
    const remove = button("Remove", "text-button", () => { files = files.filter(f => f.path !== file.path); render_files(); render_peers(); });
    remove.disabled = sending;
    row.appendChild(remove);
    $("file-list").appendChild(row);
  }
  $("manual-send").disabled = !ready_to_send() || sending || !$("address").value.trim();
}
function render_peers() {
  const peers = model ? model.peers : [];
  clear($("peers"));
  $("peer-empty").hidden = peers.length > 0;
  $("peer-count").textContent = String(peers.length);
  for (const peer of peers) {
    const row = element("div", "peer-row");
    row.appendChild(element("div", "device-icon", peer.rtype === "Phone" ? "▯" : "▱"));
    const detail = element("div", "peer-detail");
    detail.appendChild(element("div", "peer-name", peer.name || "Nearby device"));
    detail.appendChild(element("div", "small", (peer.rtype || "Device") + " · " + peer.id));
    row.appendChild(detail);
    const sendButton = button("Send ↗", "", () => send(peer.id, peer.name || "Nearby device"));
    sendButton.disabled = !ready_to_send() || sending;
    row.appendChild(sendButton);
    $("peers").appendChild(row);
  }
}
async function send(address, name) {
  if (!ready_to_send() || sending) return;
  sending = true; $("choose").disabled = true; $("clear").disabled = true;
  $("clipboard-text").disabled = true; $("mode-files").disabled = true; $("mode-text").disabled = true; $("read-clipboard").disabled = true;
  render_files(); render_peers();
  try {
    if (share_mode === "text") { await call("send_text", { address, name, text:$("clipboard-text").value }); $("clipboard-text").value = ""; }
    else { await call("send_files", { address, name, paths:files.map(f => f.path) }); files = []; } $("error").hidden = true;
  } catch (err) { error(err.message || err); }
  finally { sending = false; $("clipboard-text").disabled = false; $("mode-files").disabled = false; $("mode-text").disabled = false; $("read-clipboard").disabled = false; $("choose").disabled = false; $("clear").disabled = false; render_files(); render_peers(); await poll(); }
}
async function decision(id, accept, controls, chooseFolder = false) {
  for (const node of controls) node.disabled = true;
  try {
    let directory = null;
    if (chooseFolder) { directory = await call("select_folder"); if (!directory) return; }
    await call("decide", { id, accept, directory }); await poll();
  }
  catch (err) { error(err.message || err); }
  finally { for (const node of controls) node.disabled = false; }
}
function render_transfers() {
  clear($("requests")); clear($("transfers"));
  const transfers = (model.transfers || []).slice().reverse();
  if (!transfers.length) $("transfers").appendChild(element("p", "activity-empty", "Your files’ next adventure starts here."));
  for (const transfer of transfers) {
    const meta = transfer.meta || {};
    const incoming = transfer.rtype === "Inbound";
    const peer = meta.source ? meta.source.name : "Nearby device";
    const names = (meta.files || []).map(name => name.split(/[\\/]/).pop()).join(", ") || meta.text_description || ((!meta.files && (transfer.state === "WaitingForUserConsent" || transfer.state === "Finished")) ? "Clipboard text" : "Preparing transfer");
    if (incoming && transfer.state === "WaitingForUserConsent") {
      const request = element("div", "request");
      request.appendChild(element("h3", "", peer + " wants to share"));
      request.appendChild(element("div", "", names + " · " + bytes(meta.total_bytes || 0)));
      request.appendChild(element("p", "small", "Confirm that this code matches the other device before accepting."));
      request.appendChild(element("div", "pin", meta.pin_code || "—"));
      const actions = element("div", "request-actions");
      const controls = [];
      const is_text = !meta.files;
      if (!is_text) request.appendChild(element("div", "small", (platform_android ? "Saves to " : "Default folder · ") + folder_label()));
      controls.push(button(is_text ? "Accept" : "Accept to default", "primary", () => decision(transfer.id, true, controls)));
      if (!is_text && !platform_android) controls.push(button("Choose folder…", "secondary", () => decision(transfer.id, true, controls, true)));
      controls.push(button("Decline", "secondary", () => decision(transfer.id, false, controls)));
      for (const control of controls) actions.appendChild(control);
      request.appendChild(actions); $("requests").appendChild(request);
    }
    const row = element("div", "transfer-row");
    const detail = element("div", "transfer-detail");
    detail.appendChild(element("div", "transfer-name", names));
    detail.appendChild(element("div", "small", (incoming ? "From " + peer : "Sending") + " · " + bytes(meta.total_bytes || 0)));
    if (!terminal.has(transfer.state)) {
      const progress = element("div", "progress");
      const fill = element("div", "progress-fill");
      fill.style.width = Math.min(100, meta.total_bytes ? (meta.ack_bytes || 0) / meta.total_bytes * 100 : 0) + "%";
      progress.appendChild(fill); detail.appendChild(progress);
    }
    if (transfer.state === "Finished" && typeof meta.text_payload === "string") {
      detail.appendChild(element("div", "text-preview", meta.text_payload));
      const copy = button("Copy text", "secondary", async () => {
        try { await call("copy_transfer", {id:transfer.id}); copy.textContent = "Copied"; } catch (err) { error(err.message || err); }
      });
      detail.appendChild(copy);
    }
    if (platform_android && transfer.state === "Finished" && incoming && meta.saved_files) render_relocation(detail, transfer);
    else if (transfer.state === "Finished" && !platform_android && (incoming ? meta.saved_files : meta.files)) {
      const actions = element("div", "file-actions");
      const paths = (incoming ? meta.saved_files : meta.files) || [];
      paths.forEach((path, index) => actions.appendChild(button(paths.length === 1 ? "Open file" : "Open " + path.split(/[\\/]/).pop(), "secondary", async () => {
        try { await call("open_transfer", {id:transfer.id, index, folder:false}); } catch (err) { error(err.message || err); }
      })));
      if (paths.length) actions.appendChild(button("Open folder", "text-button", async () => {
        try { await call("open_transfer", {id:transfer.id, index:0, folder:true}); } catch (err) { error(err.message || err); }
      }));
      detail.appendChild(actions);
      if (incoming && meta.destination) detail.appendChild(element("div", "small", "Saved in " + meta.destination));
    }
    row.appendChild(detail);
    const status = element("div", "transfer-status");
    status.appendChild(element("div", "", states[transfer.state] || "Connecting securely"));
    if (meta.pin_code && !incoming && !terminal.has(transfer.state)) status.appendChild(element("div", "small", "Code " + meta.pin_code));
    if (!terminal.has(transfer.state)) status.appendChild(button("Cancel", "text-button", async () => {
      try { await call("cancel", { id:transfer.id }); await poll(); } catch(err) { error(err.message || err); }
    }));
    row.appendChild(status); $("transfers").appendChild(row);
  }
}
// Android: where a finished transfer's files are. Opening them needs the
// Files app: HollerShare can't hand them to another app.
function render_relocation(detail, transfer) {
  const moved = (model.relocations || {})[transfer.id];
  const files_app = " · Open them from your Files app";
  if (!moved) { detail.appendChild(element("div", "small", "Saved in HollerShare’s folder" + files_app)); return; }
  const names = moved.names || [];
  if (moved.state === "moving") detail.appendChild(element("div", "small", "Moving to " + moved.folder + "…"));
  else if (moved.state === "moved") detail.appendChild(element("div", "small", "Saved to " + moved.folder + (names.length === 1 ? " as " + names[0] : "") + files_app));
  else {
    const kept = moved.kept || 0;
    detail.appendChild(element("div", "small", (names.length ? names.length + " saved to " + moved.folder + ", " : "") + kept + (kept === 1 ? " file stays" : " files stay") + " in HollerShare’s folder" + files_app));
  }
  if (moved.error) detail.appendChild(element("div", "small relocation-error", moved.error));
}
// Where received files go, for the request card and the footer.
function folder_label() {
  if (platform_android && settings && settings.download_folder) return settings.download_folder_name + (settings.folder_available ? "" : " (unavailable)");
  if (platform_android) return "HollerShare’s folder";
  return model ? model.download_dir : "";
}
let previous_peers = "", previous_transfers = "";
// The banner shows a failed snapshot until one succeeds (the engine may
// still be starting when the page first asks).
let poll_failed = false;
async function poll() {
  if (polling) return;
  polling = true;
  try {
    model = await call("snapshot");
    if (poll_failed) { poll_failed = false; $("error").hidden = true; }
    $("visibility").textContent = model.visible ? "● Visible to nearby devices" : "○ Hidden from nearby devices";
    $("visibility").className = "presence" + (model.visible ? "" : " off");
    $("identity").textContent = "This computer · " + model.name;
    $("downloads").textContent = "Save to " + folder_label();
    if (model.error) error(model.error);
    const peers = JSON.stringify(model.peers), transfers = JSON.stringify([model.transfers, model.relocations]);
    if (peers !== previous_peers) { previous_peers = peers; render_peers(); }
    if (transfers !== previous_transfers) { previous_transfers = transfers; render_transfers(); }
  } catch (err) { poll_failed = true; error(err.message || err); $("visibility").textContent = "Quick Share unavailable"; }
  finally { polling = false; }
}
async function choose_files() {
  $("choose").disabled = true;
  try {
    const file = await call("select_file");
    if (file && !files.some(f => f.path === file.path)) files.push(file);
    render_files(); render_peers();
  } catch (err) { error(err.message || err); }
  finally { $("choose").disabled = false; }
}

// Drag and drop onto the "Choose what to share" card (Oriel's
// docs/drag-and-drop-design.md): a dropped File carries an opaque handle
// that resolves to where the file lives, the same way a picked file arrives
// with a path. Text drops open the clipboard composer instead.
const drop_panel = document.querySelector(".files-panel");
let drop_depth = 0;
// Protected mode (enter, over): only `types` is readable — "Files" marks a
// file drag, and the drop event itself brings the data.
function drag_taken(event) {
  const types = event.dataTransfer ? Array.from(event.dataTransfer.types || []) : [];
  return types.includes("Files") || types.includes("text/plain");
}
function dropped_of(event) {
  const transfer = event.dataTransfer;
  if (!transfer) return null;
  const list = Array.from(transfer.files || []);
  if (list.length) return { files: list, text: null };
  if (types_has_text(transfer)) return { files: [], text: transfer.getData("text/plain") };
  return null;
}
function types_has_text(transfer) { return Array.from(transfer.types || []).includes("text/plain"); }
function drop_leave() { drop_depth = Math.max(0, drop_depth - 1); if (!drop_depth) drop_panel.classList.remove("drop-hover"); }
async function drop_received(event) {
  const dropped = dropped_of(event);
  if (!dropped) return;
  event.preventDefault();
  drop_depth = 0; drop_panel.classList.remove("drop-hover");
  if (!dropped.files.length) {
    set_share_mode("text"); $("clipboard-text").value = dropped.text; render_files(); render_peers();
    return;
  }
  const added = [], lost = [];
  for (const file of dropped.files) {
    try {
      const path = await window.oriel.drop.path(file);
      if (!path) { lost.push(file.name || "a file"); continue; }
      if (!files.some(f => f.path === path)) added.push({ path, name:file.name || path.split("/").pop(), size:file.size || 0 });
    } catch (_) { lost.push(file.name || "a file"); }
  }
  if (added.length) { set_share_mode("files"); files.push(...added); $("error").hidden = true; }
  if (lost.length) error(lost.length === dropped.files.length ? "These files can't be shared from where they came from." : added.length ? lost.length + " of the dropped files can't be shared from where they came from." : "The dropped file can't be shared from where it came from.");
  render_files(); render_peers();
}
if (drop_panel && window.oriel) {
  drop_panel.addEventListener("dragenter", event => { if (drag_taken(event)) { event.preventDefault(); drop_depth++; drop_panel.classList.add("drop-hover"); } });
  drop_panel.addEventListener("dragover", event => { if (drag_taken(event)) event.preventDefault(); });
  drop_panel.addEventListener("dragleave", drop_leave);
  drop_panel.addEventListener("drop", drop_received);
}
$("mode-files").addEventListener("click", () => set_share_mode("files"));
$("mode-text").addEventListener("click", () => set_share_mode("text"));
$("read-clipboard").addEventListener("click", paste_clipboard);
$("clipboard-text").addEventListener("input", () => { render_files(); render_peers(); });
$("choose").addEventListener("click", choose_files);
$("clear").addEventListener("click", () => { files = []; render_files(); render_peers(); });
$("address").addEventListener("input", () => { $("manual-send").disabled = !ready_to_send() || sending || !$("address").value.trim(); });
$("manual-send").addEventListener("click", () => send($("address").value.trim(), "Nearby device"));
$("visibility").addEventListener("click", async () => {
  if (!model) return;
  $("visibility").disabled = true;
  try { await call("visibility", { visible:!model.visible }); await poll(); }
  catch (err) { error(err.message || err); }
  finally { $("visibility").disabled = false; }
});
render_files(); poll(); setInterval(poll, 800);

function apply_share_payload(payload) {
  if (!payload) return;
  if (typeof payload === "string") {
    try { payload = JSON.parse(payload); } catch (e) { return; }
  }
  if (payload.mode === "text") {
    set_share_mode("text");
    $("clipboard-text").value = payload.text || "";
    render_files();
    render_peers();
  } else if (payload.mode === "files" && Array.isArray(payload.files) && payload.files.length) {
    set_share_mode("files");
    for (const f of payload.files) {
      if (!files.some(existing => existing.path === f.path)) {
        files.push(f);
      }
    }
    render_files();
    render_peers();
  }
}
let theme_event_received = false;
function set_theme(dark) {
  document.documentElement.setAttribute("data-theme", dark ? "dark" : "light");
  const mark = $("brand-mark-img");
  if (mark) mark.src = dark ? "brand-mark-dark.png" : "brand-mark.png";
}
if (window.oriel) {
  call("system_info").then(info => {
    platform_android = !!info.android;
    if (!theme_event_received && typeof info.dark === "boolean") set_theme(info.dark);
    previous_transfers = ""; return poll();
  }).catch(err => error(err.message || err));
  window.oriel.listen("system_theme", info => { theme_event_received = true; if (typeof info.dark === "boolean") set_theme(info.dark); });
  call("get_pending_share").then(apply_share_payload).catch(() => {});
  window.oriel.listen("share_target", apply_share_payload);
  window.oriel.listen("tray_send", () => { set_share_mode("files"); choose_files(); });
  window.oriel.listen("tray_clipboard", paste_clipboard);
  window.oriel.listen("tray_visibility", () => poll());
  window.oriel.listen("review_request", () => poll());
  window.oriel.listen("notification_error", error);
  window.oriel.listen("folder_error", message => {
    error(message);
    if (settings) { settings.folder_available = false; render_folder(); }
  });
}
$("quit").addEventListener("click", () => call("quit"));

// Settings: the advertised name and the download folder. Empty fields are
// the defaults (the system's name, the platform's folder).
let settings_busy = false;
function field_error(id, message) { $(id).textContent = message || ""; $(id).hidden = !message; }
// The same rules as src/settings.zig: trimmed, up to 64 characters, no control characters.
function name_problem(name) {
  if (/[\u0000-\u001f\u007f-\u009f]/.test(name)) return "The name can't contain control characters";
  const chars = Array.from(name), utf8 = chars.reduce((n, c) => { const p = c.codePointAt(0); return n + (p < 0x80 ? 1 : p < 0x800 ? 2 : p < 0x10000 ? 3 : 4); }, 0);
  if (chars.length > 64 || utf8 > 170) return "Use a shorter name (up to 64 characters)";
  return "";
}
function render_settings() {
  if (!settings) return;
  $("device-name").value = settings.device_name;
  $("device-name").placeholder = settings.system_name || "This device";
  render_folder();
}
// The folder: its name, and its path (desktop) or what happens to files
// (Android). Chosen with the system's folder picker, applied at once.
function render_folder() {
  if (!settings) return;
  const chosen = settings.download_folder.length > 0;
  $("download-name").textContent = chosen ? (settings.download_folder_name || settings.download_folder) : (platform_android ? "HollerShare’s folder" : "Default folder");
  let detail;
  if (chosen && !settings.folder_available) detail = "Unavailable · HollerShare can’t save here any more. Choose the folder again, or use the default folder.";
  else if (chosen) detail = settings.android ? "Finished transfers move here" : settings.download_folder;
  else detail = model ? model.download_dir : "";
  $("download-detail").textContent = detail;
  $("download-detail").hidden = !detail;
  $("download-current").className = "path folder" + (chosen && !settings.folder_available ? " unavailable" : "");
  $("download-browse").hidden = !settings.folder_picker;
  $("download-default").hidden = !chosen;
  $("download-help-text").textContent = settings.android
    ? (chosen ? "HollerShare receives into its own folder, then moves each finished transfer here." : "Received files stay in HollerShare’s own folder. Choose a folder to move them somewhere you can find them.")
    : "New transfers are saved here.";
  if (model) $("downloads").textContent = "Save to " + folder_label();
}
async function load_settings() {
  try { settings = await call("settings_get"); render_folder(); } catch (_) {}
}
async function open_settings() {
  $("settings").hidden = false; $("settings-open").setAttribute("aria-expanded", "true");
  field_error("device-name-error"); field_error("download-dir-error"); $("settings-status").textContent = "";
  try { settings = await call("settings_get"); render_settings(); $("device-name").focus(); }
  catch (err) { field_error("download-dir-error", err.message || err); }
}
function close_settings() { $("settings").hidden = true; $("settings-open").setAttribute("aria-expanded", "false"); }
const settings_controls = ["settings-save", "settings-reset", "download-browse", "download-default"];
function settings_disabled(disabled) { for (const id of settings_controls) $(id).disabled = disabled; }
async function save_settings(device_name, default_folder) {
  if (settings_busy) return;
  field_error("device-name-error"); field_error("download-dir-error"); $("settings-status").textContent = "";
  const problem = name_problem(device_name.trim());
  if (problem) { field_error("device-name-error", problem); return; }
  settings_busy = true; settings_disabled(true);
  try {
    settings = await call("settings_save", { device_name, default_folder });
    await poll(); render_settings();
    $("settings-status").textContent = "Saved · Nearby devices now see " + (model ? model.name : settings.device_name || settings.system_name);
  } catch (err) {
    const message = String(err.message || err);
    field_error(/name/i.test(message) ? "device-name-error" : "download-dir-error", message);
  } finally { settings_busy = false; settings_disabled(false); }
}
// "Choose…" (the folder picker) and "Use default folder": saved at once;
// the name field keeps what's being typed.
async function change_folder(choose) {
  if (settings_busy) return;
  field_error("download-dir-error"); $("settings-status").textContent = "";
  settings_busy = true; settings_disabled(true);
  try {
    const before = settings && settings.download_folder;
    settings = await call("settings_folder", { choose });
    await poll(); render_folder(); if (model) { previous_transfers = ""; render_transfers(); }
    if (settings.download_folder !== before) $("settings-status").textContent = "Saved · Received files go to " + (settings.download_folder ? settings.download_folder_name : (platform_android ? "HollerShare’s folder" : "the default folder"));
  } catch (err) { field_error("download-dir-error", err.message || err); }
  finally { settings_busy = false; settings_disabled(false); }
}
$("settings-open").addEventListener("click", () => $("settings").hidden ? open_settings() : close_settings());
$("settings-close").addEventListener("click", close_settings);
$("settings-save").addEventListener("click", () => save_settings($("device-name").value, false));
$("settings-reset").addEventListener("click", () => save_settings("", true));
$("download-default").addEventListener("click", () => change_folder(false));
$("download-browse").addEventListener("click", () => change_folder(true));
$("device-name").addEventListener("input", () => field_error("device-name-error", name_problem($("device-name").value.trim())));
if (window.oriel) load_settings();

let update_busy = false, update_android = false, update_version = "";
async function check_updates() {
  if (update_busy || !$("update-restart").hidden) return;
  update_busy = true; $("update-check").disabled = true;
  $("update-status").textContent = "Checking for updates…";
  try {
    const info = await call("update_info"); update_android = info.android; update_version = info.version;
    if (info.play_store) {
      $("update-status").textContent = "HollerShare " + update_version + " · Updates through Google Play";
      $("update-check").hidden = true; $("update-install").hidden = true;
      return;
    }
    const update = await call("updater_check");
    $("update-status").textContent = update.available ? "HollerShare " + update.version + " is available" : "HollerShare " + update_version + " · Up to date";
    $("update-install").hidden = !update.available;
    $("update-install").textContent = update_android ? "Download APK" : "Install update";
  } catch (err) { $("update-status").textContent = "Updates unavailable · Try again later"; }
  finally { update_busy = false; $("update-check").disabled = false; }
}
function active_transfers() { return model && (model.transfers || []).some(t => !terminal.has(t.state)); }
$("update-check").addEventListener("click", check_updates);
$("update-install").addEventListener("click", async () => {
  if (update_busy) return;
  if (update_android) { await window.oriel.openExternal("https://github.com/highercomve/hollershare/releases/latest"); return; }
  if (active_transfers()) { $("update-status").textContent = "Finish or cancel your transfers before updating"; return; }
  update_busy = true; $("update-install").disabled = true; $("update-check").disabled = true;
  try {
    $("update-status").textContent = "Downloading and verifying update…";
    await call("updater_install");
    $("update-status").textContent = "Update installed · Restart when your transfers are finished";
    $("update-install").hidden = true; $("update-restart").hidden = false;
    $("update-check").hidden = true;
  } catch (err) { $("update-status").textContent = "Update failed: " + (err.message || err); }
  finally { update_busy = false; $("update-install").disabled = false; $("update-check").disabled = false; }
});
$("update-restart").addEventListener("click", async () => {
  if (active_transfers()) { $("update-status").textContent = "Finish or cancel your transfers before restarting"; return; }
  try { await call("updater_restart"); } catch (err) { $("update-status").textContent = String(err.message || err); }
});
// Quick Share finds devices over Bluetooth LE and mDNS: ask for both at
// startup (Android shows the "Nearby devices" prompt; elsewhere the OS
// answers without one). A refusal isn't fatal: discovery carries on.
async function request_permissions() {
  if (!window.oriel.permissions) return;
  for (const name of ["bluetooth", "local_network"]) {
    try { await window.oriel.permissions.request(name); } catch (_) {}
  }
}
if (window.oriel) {
  request_permissions();
  window.oriel.listen("tray_update", check_updates);
  window.oriel.listen("updater://progress", progress => {
    $("update-status").textContent = "Downloading update · " + (progress.total ? Math.round(progress.downloaded / progress.total * 100) + "%" : bytes(progress.downloaded));
  });
  setTimeout(check_updates, 1500);
  setInterval(() => { if ($("update-restart").hidden) check_updates(); }, 6 * 60 * 60 * 1000);
}

$("privacy-open").addEventListener("click", () => {
  $("privacy-policy").hidden = false; $("privacy-open").setAttribute("aria-expanded", "true");
  $("privacy-close").focus();
});
$("privacy-close").addEventListener("click", () => {
  $("privacy-policy").hidden = true; $("privacy-open").setAttribute("aria-expanded", "false");
  $("privacy-open").focus();
});
