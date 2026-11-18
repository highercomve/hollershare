const $ = id => document.getElementById(id);
let files = [], model = null, sending = false, polling = false, share_mode = "files";
// Android: received files land in HollerShare's folder, then move to the
// folder chosen in Settings (model.relocations); opening them is left to
// the Files app.
let platform_android = false, settings = null;
// The engine takes text up to 1 MB (UTF-8).
const text_limit = 1024 * 1024;
// Counted once per change: many renders ask for it.
let utf8_cache = { text: "", length: 0 };
function utf8_length(text) {
  if (text !== utf8_cache.text) utf8_cache = { text, length: utf8_count(text) };
  return utf8_cache.length;
}
function utf8_count(text) {
  let n = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0x80) n += 1; else if (c < 0x800) n += 2;
    else if (c >= 0xd800 && c <= 0xdbff && is_low_surrogate(text.charCodeAt(i + 1))) { n += 4; i++; }
    // Everything else, a lone surrogate included (sent as U+FFFD): 3 bytes.
    else n += 3;
  }
  return n;
}
function is_low_surrogate(c) { return c >= 0xdc00 && c <= 0xdfff; }
// Lone surrogates become U+FFFD, the 3 bytes utf8_length counts for them.
function well_formed(text) {
  let out = "", from = 0;
  for (let i = 0; i < text.length; i++) {
    const c = text.charCodeAt(i);
    if (c < 0xd800 || c > 0xdfff) continue;
    if (c <= 0xdbff && is_low_surrogate(text.charCodeAt(i + 1))) { i++; continue; }
    out += text.slice(from, i) + "\ufffd"; from = i + 1;
  }
  return from ? out + text.slice(from) : text;
}
function text_too_long() { return share_mode === "text" && utf8_length($("clipboard-text").value) > text_limit; }
function ready_to_send() { return share_mode === "text" ? $("clipboard-text").value.length > 0 && !text_too_long() : files.length > 0; }
// "12 KB of 1 MB" under the text, red once it's over.
function render_text_size() {
  const value = $("clipboard-text").value, size = value ? utf8_length(value) : 0;
  $("text-size").textContent = !size ? "Up to 1 MB" : bytes(size) + " of 1 MB" + (size > text_limit ? " · too long to send" : "");
  $("text-size").className = "small" + (size > text_limit ? " over" : "");
}
function set_share_mode(mode) {
  share_mode = mode;
  $("file-compose").hidden = mode !== "files"; $("text-compose").hidden = mode !== "text";
  $("mode-files").className = mode === "files" ? "on" : "";
  $("mode-text").className = mode === "text" ? "on" : "";
  $("mode-files").setAttribute("aria-pressed", String(mode === "files"));
  $("mode-text").setAttribute("aria-pressed", String(mode === "text"));
  render_files(); render_peers();
}
async function paste_clipboard() {
  show_view("share"); set_share_mode("text"); $("read-clipboard").disabled = true;
  try {
    const result = await call("read_clipboard");
    if (result.image) {
      // An image goes in the batch as a PNG file (named so another
      // HollerShare puts it on its clipboard).
      set_share_mode("files");
      if (!files.some(f => f.path === result.image.path)) files.push(result.image);
      $("error").hidden = true;
    } else {
      if (result.text) $("clipboard-text").value = result.text;
      if (!result.text) error("The clipboard has no text or image to share."); else $("error").hidden = true;
    }
  }
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
function error(message) { $("error-text").textContent = String(message); $("error").hidden = false; }
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
  $("drop-zone").className = "drop-zone" + (files.length ? " filled" : "");
  // Clear empties what's being shared: the files, or the text (even over 1 MB).
  $("clear").hidden = share_mode === "text" ? !$("clipboard-text").value.length : !files.length;
  $("choose").textContent = files.length ? "Add another file" : "Choose files";
  // Once there's text, pasting is no longer the next step.
  const has_text = $("clipboard-text").value.length > 0;
  $("read-clipboard").className = has_text ? "text-button link" : "secondary";
  $("read-clipboard").textContent = has_text ? "Replace with clipboard" : "Paste from clipboard";
  render_text_size();
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
  render_manual();
}
// The address form: Send needs something to share and an address, and says which is missing.
function render_manual() {
  const ready = ready_to_send(), address = $("address").value.trim();
  $("manual-send").disabled = !ready || sending || !address;
  $("manual-hint").textContent = text_too_long() ? "The text is over 1 MB: shorten it to send it."
    : !ready ? (share_mode === "text" ? "Type some text first, then send it here." : "Choose files first, then send them here.")
    : !address ? "Type the address and port shown by the other device." : "The other device must run Quick Share or HollerShare.";
}
// What's ready to send, said where the next step is: in Send to.
function render_ready(peers) {
  const ready = ready_to_send() && !sending;
  $("ready-hint").hidden = !ready;
  if (!ready) return;
  // One short line.
  const what = share_mode === "text" ? "Text ready" : files.length === 1 ? "1 file ready" : files.length + " files ready";
  $("ready-hint").textContent = what + (peers.length ? " · pick a device below" : " · send it when a device shows up");
}
// Discovery never stops, but after a few seconds with nobody found the card
// says so instead of spinning.
const discovery_started = Date.now(), searching_for = 8000;
let peers_settle_timer = null;
const peer_kinds = { Phone:"Phone", Tablet:"Tablet", Laptop:"Computer", Desktop:"Computer" };
function render_peers() {
  const peers = model ? model.peers : [];
  clear($("peers"));
  $("peer-empty").hidden = peers.length > 0;
  const settled = Date.now() - discovery_started >= searching_for;
  $("peer-spin").hidden = settled;
  $("peer-empty-title").textContent = settled ? "No nearby devices yet" : "Looking for nearby devices";
  $("peer-still").hidden = !settled;
  if (!settled && !peers_settle_timer) peers_settle_timer = setTimeout(render_peers, searching_for - (Date.now() - discovery_started) + 50);
  // The spinner says "searching"; the badge counts what's found.
  $("peer-count").textContent = peers.length + " nearby";
  $("peer-count").hidden = !peers.length;
  $("send-hint").hidden = !peers.length || ready_to_send() || sending;
  render_ready(peers);
  for (const peer of peers) {
    const row = element("div", "peer-row");
    const phone = peer.rtype === "Phone" || peer.rtype === "Tablet";
    row.appendChild(icon(phone ? "phone" : "computer"));
    const detail = element("div", "peer-detail");
    detail.appendChild(element("div", "peer-name", peer.name || "Nearby device"));
    // The kind of device; its address only to tell two of the same name apart.
    const twin = peer.name && peers.some(other => other !== peer && other.name === peer.name);
    detail.appendChild(element("div", "small", (peer_kinds[peer.rtype] || "Nearby device") + (twin && peer.ip ? " · " + peer.ip : "")));
    row.appendChild(detail);
    const sendButton = button("Send", "", () => send(peer.id, peer.name || "Nearby device"));
    sendButton.disabled = !ready_to_send() || sending;
    sendButton.setAttribute("aria-label", "Send to " + (peer.name || "nearby device"));
    row.appendChild(sendButton);
    $("peers").appendChild(row);
  }
}
async function send(address, name) {
  if (!ready_to_send() || sending) return;
  sending = true; $("choose").disabled = true; $("clear").disabled = true;
  $("clipboard-text").disabled = true; $("mode-files").disabled = true; $("mode-text").disabled = true; $("read-clipboard").disabled = true;
  render_files(); render_peers();
  let sent = false;
  // What's submitted: a drop or a share arriving meanwhile may change the
  // composer, and only what was sent is cleared afterwards.
  const mode = share_mode, text = $("clipboard-text").value, paths = files.map(f => f.path);
  try {
    if (mode === "text") {
      await call("send_text", { address, name, text:well_formed(text) });
      if ($("clipboard-text").value === text) $("clipboard-text").value = "";
    } else {
      await call("send_files", { address, name, paths });
      files = files.filter(f => !paths.includes(f.path));
    }
    $("error").hidden = true;
    sent = true;
  } catch (err) { error(err.message || err); }
  finally { sending = false; $("clipboard-text").disabled = false; $("mode-files").disabled = false; $("mode-text").disabled = false; $("read-clipboard").disabled = false; $("choose").disabled = false; $("clear").disabled = false; render_files(); render_peers(); await poll(); }
  // On a phone Activity is below the fold: bring the new row (with the code
  // to compare on the other device) into view.
  const activity = document.querySelector(".activity");
  if (sent && platform_android && activity && typeof activity.scrollIntoView === "function") activity.scrollIntoView({ block: "start" });
}
// Requests being answered (or whose folder is being picked), by transfer id:
// a re-render meanwhile keeps their controls disabled.
const pending_decisions = new Set();
async function decision(id, accept, controls, chooseFolder = false) {
  if (pending_decisions.has(id)) return;
  pending_decisions.add(id);
  for (const node of controls) node.disabled = true;
  try {
    let directory = null;
    if (chooseFolder) { directory = await call("select_folder"); if (!directory) return; }
    await call("decide", { id, accept, directory }); await poll();
  }
  catch (err) { error(err.message || err); }
  finally {
    pending_decisions.delete(id);
    // The controls in hand may have been replaced: render the current ones.
    if (model) render_transfers();
  }
}
// Small inline icons: devices in Send to and Webcam, direction in Activity.
const icon_svg = {
  phone: '<svg class="icon" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" fill-rule="evenodd" d="M8 2h8a2 2 0 0 1 2 2v16a2 2 0 0 1-2 2H8a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2zm0 2v13h8V4H8zm4 14.5a1.2 1.2 0 1 0 0 2.4 1.2 1.2 0 0 0 0-2.4z"/></svg>',
  computer: '<svg class="icon" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" fill-rule="evenodd" d="M6 4h12a2 2 0 0 1 2 2v9H4V6a2 2 0 0 1 2-2zm0 2v7h12V6H6zM2 16.5h20V17a2 2 0 0 1-2 2H4a2 2 0 0 1-2-2v-.5z"/></svg>',
  down: '<svg class="icon" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M11 4h2v11.2l4.6-4.6L19 12l-7 7-7-7 1.4-1.4 4.6 4.6V4z"/></svg>',
  up: '<svg class="icon" viewBox="0 0 24 24" width="18" height="18" aria-hidden="true"><path fill="currentColor" d="M11 20h2V8.8l4.6 4.6L19 12l-7-7-7 7 1.4 1.4L11 8.8V20z"/></svg>',
};
function icon(kind, className, label) {
  const node = element("div", className || "device-icon");
  node.innerHTML = icon_svg[kind] || icon_svg.computer;
  if (label) { node.setAttribute("role", "img"); node.setAttribute("aria-label", label); }
  return node;
}
// Text, not "Clipboard text": the user may have typed it. A link says so.
function text_title(meta) {
  const d = meta.text_description;
  if (d && d !== "Clipboard text") return d;
  return meta.text_type === "Url" ? "Link" : "Text";
}
// Who a sent transfer goes to: the device's name, or the address typed for a
// manual send (the transfer id starts with it).
function recipient_of(transfer, meta) {
  const name = meta.source && meta.source.name;
  if (name && name !== "Nearby device") return name;
  const address = String(transfer.id || "").replace(/-\d+$/, "");
  return address || "the other device";
}
function percent(meta) { return Math.min(100, Math.round(meta.total_bytes ? (meta.ack_bytes || 0) / meta.total_bytes * 100 : 0)); }
// One status per state, in one place on every row: [words, tone].
function transfer_status(transfer, incoming, peer, meta) {
  switch (transfer.state) {
    case "Initial": case "ReceivedConnectionRequest": return [incoming ? "Connecting…" : "Connecting to " + peer + "…", "active"];
    case "SentIntroduction": return ["Waiting for " + peer + " to accept", "active"];
    case "WaitingForUserConsent": return ["Needs your approval", "active"];
    case "SendingFiles": return ["Sending… " + percent(meta) + "%", "active"];
    case "ReceivingFiles": return ["Receiving… " + percent(meta) + "%", "active"];
    case "Finished": return [incoming ? "Received" : "Sent", "done"];
    case "Rejected": return [incoming ? "Declined" : "Declined by " + peer, "failed"];
    case "Cancelled": return ["Cancelled", "failed"];
    case "Disconnected": return ["Connection lost", "failed"];
    default: return ["Connecting securely…", "active"];
  }
}
function render_transfers() {
  clear($("requests")); clear($("transfers"));
  const transfers = (model.transfers || []).slice().reverse();
  let rows = 0, waiting = 0;
  for (const transfer of transfers) {
    const meta = transfer.meta || {};
    const incoming = transfer.rtype === "Inbound";
    const is_text = !meta.files;
    const peer = incoming ? (meta.source && meta.source.name ? meta.source.name : "Nearby device") : recipient_of(transfer, meta);
    const names = (meta.files || []).map(name => name.split(/[\\/]/).pop()).join(", ") || (is_text ? text_title(meta) : "Preparing transfer");
    if (incoming && transfer.state === "WaitingForUserConsent") {
      // The request card is the one place to answer it; Activity shows the
      // transfer once it's accepted.
      waiting++;
      const request = element("div", "request");
      request.appendChild(element("h3", "", peer + " wants to share"));
      request.appendChild(element("div", "", names + " · " + bytes(meta.total_bytes || 0)));
      request.appendChild(element("p", "small", "Confirm that this code matches the other device before accepting."));
      request.appendChild(element("div", "pin", meta.pin_code || "—"));
      const actions = element("div", "request-actions");
      const controls = [];
      if (!is_text) request.appendChild(element("div", "small", (platform_android ? "Saves to " : "Default folder · ") + folder_label()));
      controls.push(button(is_text ? "Accept" : "Accept to default", "primary", () => decision(transfer.id, true, controls)));
      if (!is_text && !platform_android) controls.push(button("Choose folder…", "secondary", () => decision(transfer.id, true, controls, true)));
      controls.push(button("Decline", "outline", () => decision(transfer.id, false, controls)));
      for (const control of controls) { control.disabled = pending_decisions.has(transfer.id); actions.appendChild(control); }
      request.appendChild(actions); $("requests").appendChild(request);
      continue;
    }
    rows++;
    // Every row: direction icon, title, "From/To peer · size", one status
    // line, then what belongs to the state; Cancel on the right while active.
    const row = element("div", "transfer-row");
    row.appendChild(icon(incoming ? "down" : "up", "device-icon direction", incoming ? "Received" : "Sent"));
    const detail = element("div", "transfer-detail");
    detail.appendChild(element("div", "transfer-name", names));
    detail.appendChild(element("div", "small", (incoming ? "From " : "To ") + peer + " · " + bytes(meta.total_bytes || 0)));
    const [status_text, tone] = transfer_status(transfer, incoming, peer, meta);
    detail.appendChild(element("div", "transfer-state " + tone, status_text));
    // The sender compares the same code the receiver sees, just as big.
    if (!incoming && transfer.state === "SentIntroduction" && meta.pin_code) {
      const check = element("div", "send-code");
      check.appendChild(element("div", "pin", meta.pin_code));
      check.appendChild(element("p", "small", "Check this code matches on " + peer + ", then accept there."));
      detail.appendChild(check);
    }
    // A bar only while bytes move.
    if (transfer.state === "SendingFiles" || transfer.state === "ReceivingFiles") {
      const progress = element("div", "progress");
      const fill = element("div", "progress-fill");
      fill.style.width = percent(meta) + "%";
      progress.appendChild(fill); detail.appendChild(progress);
    }
    if (transfer.state === "Finished" && typeof meta.text_payload === "string") {
      detail.appendChild(element("div", "text-preview", meta.text_payload));
      // Received text is what people copy; on a sent row it's a quiet link.
      const copy = button(incoming ? "Copy text" : "Copy", incoming ? "secondary" : "text-button link", async () => {
        try { await call("copy_transfer", {id:transfer.id}); copy.textContent = "Copied"; } catch (err) { error(err.message || err); }
      });
      detail.appendChild(copy);
    }
    if (platform_android && transfer.state === "Finished" && incoming && !is_text && meta.saved_files) render_relocation(detail, transfer);
    else if (transfer.state === "Finished" && !platform_android && !is_text) {
      const paths = (incoming ? meta.saved_files : meta.files) || [];
      if (paths.length) {
        const actions = element("div", "file-actions");
        paths.forEach((path, index) => actions.appendChild(button(paths.length === 1 ? "Open file" : "Open " + path.split(/[\\/]/).pop(), "secondary", async () => {
          try { await call("open_transfer", {id:transfer.id, index, folder:false}); } catch (err) { error(err.message || err); }
        })));
        actions.appendChild(button("Open folder", "text-button", async () => {
          try { await call("open_transfer", {id:transfer.id, index:0, folder:true}); } catch (err) { error(err.message || err); }
        }));
        detail.appendChild(actions);
        if (incoming && meta.destination) detail.appendChild(element("div", "small", "Saved in " + human_path(meta.destination)));
      }
    }
    row.appendChild(detail);
    if (!terminal.has(transfer.state)) {
      const cancel = button("Cancel", "text-button transfer-cancel", async () => {
        try { await call("cancel", { id:transfer.id }); await poll(); } catch(err) { error(err.message || err); }
      });
      cancel.setAttribute("aria-label", "Cancel " + names);
      row.appendChild(cancel);
    }
    $("transfers").appendChild(row);
  }
  if (!rows) $("transfers").appendChild(element("p", "activity-empty", waiting ? "Accept or decline the request above; the transfer shows up here." : "No transfers yet. Files and text you send or receive show up here."));
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
  return model ? human_path(model.download_dir) : "";
}
// A folder in words people use: "Home › Downloads" for /home/me/Downloads.
function human_path(path) {
  if (!path) return "";
  const home = /^(\/home\/[^\/]+|\/Users\/[^\/]+|\/root|[A-Za-z]:\\Users\\[^\\]+)(.*)$/.exec(path);
  const parts = (home ? home[2] : path).split(/[\\/]/).filter(Boolean);
  if (home) return ["Home"].concat(parts).join(" › ");
  return parts.length ? parts.join(" › ") : path;
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
    $("visibility-text").textContent = platform_android ? (model.visible ? "Visible" : "Hidden") : (model.visible ? "Visible to nearby devices" : "Hidden from nearby devices");
    $("visibility").setAttribute("aria-checked", String(!!model.visible));
    $("visibility").setAttribute("aria-label", "Visible to nearby devices");
    $("visibility").className = "presence" + (model.visible ? "" : " off");
    $("identity").textContent = (platform_android ? "This phone · " : "This computer · ") + model.name;
    if (model.error) error(model.error);
    const peers = JSON.stringify(model.peers), transfers = JSON.stringify([model.transfers, model.relocations]);
    if (peers !== previous_peers) { previous_peers = peers; render_peers(); }
    if (transfers !== previous_transfers) { previous_transfers = transfers; render_transfers(); }
  } catch (err) { poll_failed = true; error(err.message || err); $("visibility-text").textContent = "Quick Share unavailable"; }
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
      if (typeof path !== "string" || !path) { lost.push(file.name || "a file"); continue; }
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
$("clear").addEventListener("click", () => {
  if (share_mode === "text") { $("clipboard-text").value = ""; $("clipboard-text").focus(); } else files = [];
  render_files(); render_peers();
});
$("address").addEventListener("input", render_manual);
// The address is the name Activity shows for a manual send.
$("manual-send").addEventListener("click", () => { const address = $("address").value.trim(); send(address, address); });
$("error-dismiss").addEventListener("click", () => { $("error").hidden = true; });
$("visibility").addEventListener("click", async () => {
  if (!model) return;
  $("visibility").disabled = true;
  try { await call("visibility", { visible:!model.visible }); await poll(); }
  catch (err) { error(err.message || err); }
  finally { $("visibility").disabled = false; }
});
// Share | Webcam (the Webcam tab only where the camera works), and Settings,
// which takes the place of both while it's open.
let current_view = "share";
function show_view(view) {
  if (view === "webcam" && (!camera.role || camera.role === "none")) view = "share";
  if (!$("settings-view").hidden) close_settings();
  const first_webcam = view === "webcam" && current_view !== "webcam";
  current_view = view;
  $("share-view").hidden = view !== "share";
  $("webcam-view").hidden = view !== "webcam";
  select_tab(view);
  if (first_webcam) camera_opened();
  camera_watch();
}
// Share | Webcam shows where the camera works, except under Settings on a
// phone: there Back (in the header, and the system's) is the way out.
function render_tabs() {
  const settings_open = !$("settings-view").hidden;
  $("view-tabs").hidden = !camera.role || camera.role === "none" || (platform_android && settings_open);
  $("settings-back").hidden = !(platform_android && settings_open);
}
// The selected tab; none while Settings is open.
function select_tab(view) {
  for (const [id, name] of [["tab-share", "share"], ["tab-webcam", "webcam"]]) {
    $(id).className = view === name ? "on" : "";
    $(id).setAttribute("aria-pressed", String(view === name));
  }
}
// Copy that differs between a computer and a phone.
function apply_platform() {
  document.body.classList.toggle("android", platform_android);
  $("drop-hint").textContent = platform_android ? "Pick one or more files to send." : "or";
  $("peer-help").textContent = platform_android
    ? "Open HollerShare on the other device, or turn on receiving in Quick Share on another phone."
    : "Open HollerShare on the other computer, or Quick Share on Android set to receive.";
  $("background-note").textContent = platform_android ? "Receives while HollerShare is open" : "Closing the window keeps receiving.";
  $("quit").hidden = platform_android;
  // Settings: a page with Back on the phone, Close (and Esc) on the computer.
  $("settings-close").hidden = platform_android; render_tabs();
  if (model) $("identity").textContent = (platform_android ? "This phone · " : "This computer · ") + model.name;
}
$("tab-share").addEventListener("click", () => show_view("share"));
$("tab-webcam").addEventListener("click", () => show_view("webcam"));
document.addEventListener("keydown", event => {
  if (event.key !== "Escape") return;
  if (!$("privacy-policy").hidden) { close_privacy(); event.preventDefault(); }
  else if (!$("settings-view").hidden) { close_settings(); event.preventDefault(); }
});
render_files(); poll(); setInterval(poll, 800);

function apply_share_payload(payload) {
  if (!payload) return;
  if (typeof payload === "string") {
    try { payload = JSON.parse(payload); } catch (e) { return; }
  }
  if (payload.mode === "text") {
    show_view("share"); set_share_mode("text");
    $("clipboard-text").value = payload.text || "";
    render_files();
    render_peers();
  } else if (payload.mode === "files" && Array.isArray(payload.files) && payload.files.length) {
    show_view("share"); set_share_mode("files");
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
  // Android draws the system bars in this colour (light icons on both).
  for (const meta of document.querySelectorAll('meta[name="theme-color"]')) meta.setAttribute("content", dark ? "#1a1714" : "#f5f1e9");
  const mark = $("brand-mark-img");
  if (mark) mark.src = dark ? "brand-mark-dark.png" : "brand-mark.png";
}
if (window.oriel) {
  call("system_info").then(info => {
    platform_android = !!info.android;
    apply_platform();
    if (!theme_event_received && typeof info.dark === "boolean") set_theme(info.dark);
    previous_transfers = ""; return poll();
  }).catch(err => error(err.message || err));
  window.oriel.listen("system_theme", info => { theme_event_received = true; if (typeof info.dark === "boolean") set_theme(info.dark); });
  call("get_pending_share").then(apply_share_payload).catch(() => {});
  window.oriel.listen("share_target", apply_share_payload);
  window.oriel.listen("tray_send", () => { show_view("share"); set_share_mode("files"); choose_files(); });
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
// The same rules as settings_save (src/main.zig) and src/settings.zig:
// trimmed of spaces, tabs and line breaks, at most 64 bytes of UTF-8, no
// control characters.
const name_max_bytes = 64;
function trim_name(name) { return name.replace(/^[ \t\r\n]+|[ \t\r\n]+$/g, ""); }
function name_problem(name) {
  const trimmed = trim_name(name);
  if (/[\u0000-\u001f\u007f-\u009f]/.test(trimmed)) return "The name can't contain control characters";
  if (utf8_count(trimmed) > name_max_bytes) return "Use a shorter name (up to 64 letters, fewer with accents, other scripts or emoji)";
  return "";
}
// The name field holds the draft; `settings` what's saved. The draft is
// filled from the saved name only while the user hasn't touched it (or on
// a reset), so a load or save finishing late never replaces what's typed.
let name_touched = false;
function render_settings(rewrite_name) {
  if (!settings) return;
  if (rewrite_name || !name_touched) { $("device-name").value = settings.device_name; name_touched = false; }
  $("device-name").placeholder = settings.system_name || "This device";
  render_folder();
}
// The folder: its name, and its path (desktop) or what happens to files
// (Android). Chosen with the system's folder picker, applied at once.
function render_folder() {
  if (!settings) return;
  const chosen = settings.download_folder.length > 0;
  const default_dir = model ? model.download_dir : "";
  $("download-name").textContent = chosen ? (settings.download_folder_name || human_path(settings.download_folder))
    : platform_android ? "HollerShare’s folder" : (human_path(default_dir).split(" › ").pop() || "Default folder");
  let detail;
  if (chosen && !settings.folder_available) detail = "Unavailable · HollerShare can’t save here any more. Choose the folder again, or use the default folder.";
  else if (chosen) detail = settings.android ? "Finished transfers move here" : human_path(settings.download_folder);
  else detail = platform_android ? "" : (default_dir ? human_path(default_dir) + " · the default" : "");
  $("download-current").title = chosen && !settings.android ? settings.download_folder : (platform_android ? "" : default_dir);
  $("download-detail").textContent = detail;
  $("download-detail").hidden = !detail;
  $("download-current").className = "path folder" + (chosen && !settings.folder_available ? " unavailable" : "");
  $("download-browse").hidden = !settings.folder_picker;
  $("download-default").hidden = !chosen;
  $("download-help-text").textContent = settings.android
    ? (chosen ? "HollerShare receives into its own folder, then moves each finished transfer here." : "Received files stay in HollerShare’s own folder. Choose a folder to move them somewhere you can find them.")
    : "New transfers are saved here.";
}
async function load_settings() {
  try {
    const version = settings_version, loaded = await call("settings_get");
    if (version === settings_version && !settings_busy) { settings = loaded; render_folder(); }
  } catch (_) {}
}
// Saves and folder changes run one at a time, in order; reopening Settings
// waits for the ones still running (say, the save closing Settings started).
let settings_chain = Promise.resolve();
function settings_serial(task) {
  const run = settings_chain.then(task, task);
  settings_chain = run.catch(() => {});
  return run;
}
// The last failed save's message, kept until a save succeeds.
let settings_save_error = "";
// Bumped by every save and folder change, so a load that started before
// one doesn't replace what it saved.
let settings_version = 0;
async function open_settings() {
  $("settings-view").hidden = false; $("settings").hidden = false; $("privacy-policy").hidden = true;
  $("share-view").hidden = true; $("webcam-view").hidden = true;
  $("settings-open").setAttribute("aria-expanded", "true");
  select_tab(null); render_tabs(); camera_watch();
  reset_confirm(false);
  // A save that failed while Settings was closed stays said under the name.
  field_error("device-name-error", settings_save_error && name_pending() ? settings_save_error : "");
  field_error("download-dir-error"); $("settings-status").textContent = ""; $("download-status").textContent = "";
  try {
    await settings_chain;
    const version = settings_version, loaded = await call("settings_get");
    if (version === settings_version && !settings_busy) settings = loaded;
    render_settings();
    if (!name_touched) (platform_android ? $("settings-back") : $("device-name")).focus();
    if (name_pending() && !name_problem($("device-name").value)) schedule_name_save(800);
  }
  catch (err) { field_error("download-dir-error", err.message || err); }
}
function close_settings() {
  if (name_pending()) save_name();
  $("settings-view").hidden = true; select_tab(current_view); render_tabs(); $("settings-open").setAttribute("aria-expanded", "false");
  $("share-view").hidden = current_view !== "share"; $("webcam-view").hidden = current_view !== "webcam";
  $("settings-open").focus(); camera_watch();
}
function reset_confirm(asking) { $("reset-ask").hidden = asking; $("reset-confirm").hidden = !asking; if (asking) $("settings-reset-no").focus(); }
const settings_controls = ["settings-reset", "settings-reset-yes", "download-browse", "download-default"];
function settings_disabled(disabled) { for (const id of settings_controls) $(id).disabled = disabled; }
// The name saves by itself: a moment after typing stops, on Enter and when
// the field loses focus (or Settings closes). Reset saves both at once.
let name_timer = null;
function name_pending() { return !!settings && trim_name($("device-name").value) !== trim_name(settings.device_name || ""); }
function schedule_name_save(delay) { clearTimeout(name_timer); name_timer = setTimeout(save_name, delay); }
// Queued behind any save running; the field is read when its turn comes.
function save_name() {
  clearTimeout(name_timer); name_timer = null;
  return settings_serial(async () => {
    if (!name_pending() || name_problem($("device-name").value)) return;
    await save_settings_now($("device-name").value, false);
  });
}
function save_settings(device_name, default_folder) { return settings_serial(() => save_settings_now(device_name, default_folder)); }
async function save_settings_now(device_name, default_folder) {
  field_error("device-name-error"); field_error("download-dir-error"); $("settings-status").textContent = "";
  const problem = name_problem(device_name);
  if (problem) { field_error("device-name-error", problem); return; }
  settings_busy = true; settings_disabled(true);
  try {
    settings = await call("settings_save", { device_name, default_folder });
    settings_version++; settings_save_error = "";
    await poll();
    // Keep what's being typed: only a reset rewrites the field. The draft
    // counts as untouched again once what's in it is saved.
    if (default_folder) render_settings(true);
    else {
      if (trim_name($("device-name").value) === trim_name(settings.device_name || "")) name_touched = false;
      $("device-name").placeholder = settings.system_name || "This device"; render_folder();
    }
    $("settings-status").textContent = "✓ Saved · Nearby devices now see " + (model ? model.name : settings.device_name || settings.system_name);
    if (name_pending()) schedule_name_save(700);
  } catch (err) {
    const message = String(err.message || err);
    settings_save_error = message;
    field_error(/name/i.test(message) ? "device-name-error" : "download-dir-error", message);
    // Settings was closed (the close saved the name): say it where it shows.
    if ($("settings-view").hidden) error("The device name wasn’t saved: " + message);
  } finally { settings_busy = false; settings_disabled(false); }
}
// "Choose…" (the folder picker) and "Use default folder": saved at once;
// the name field keeps what's being typed.
function change_folder(choose) {
  if (settings_busy) return;
  return settings_serial(() => change_folder_now(choose));
}
async function change_folder_now(choose) {
  field_error("download-dir-error"); $("download-status").textContent = "";
  settings_busy = true; settings_disabled(true);
  try {
    const before = settings && settings.download_folder;
    settings = await call("settings_folder", { choose });
    settings_version++;
    await poll(); render_folder(); if (model) { previous_transfers = ""; render_transfers(); }
    if (settings.download_folder !== before) $("download-status").textContent = "✓ Saved · Received files go to " + (settings.download_folder ? settings.download_folder_name : (platform_android ? "HollerShare’s folder" : "the default folder"));
  } catch (err) { field_error("download-dir-error", err.message || err); }
  finally { settings_busy = false; settings_disabled(false); }
}
$("settings-open").addEventListener("click", () => $("settings-view").hidden ? open_settings() : close_settings());
$("settings-close").addEventListener("click", close_settings);
// Back leaves the privacy policy first, then Settings.
$("settings-back").addEventListener("click", () => { if (!$("privacy-policy").hidden) close_privacy(); else close_settings(); });
$("device-name").addEventListener("keydown", event => { if (event.key === "Enter") save_name(); });
$("device-name").addEventListener("blur", () => save_name());
$("settings-reset").addEventListener("click", () => reset_confirm(true));
$("settings-reset-no").addEventListener("click", () => { reset_confirm(false); $("settings-reset").focus(); });
$("settings-reset-yes").addEventListener("click", async () => { await save_settings("", true); reset_confirm(false); });
$("download-default").addEventListener("click", () => change_folder(false));
$("download-browse").addEventListener("click", () => change_folder(true));
$("device-name").addEventListener("input", () => {
  name_touched = true;
  const problem = name_problem($("device-name").value);
  field_error("device-name-error", problem); $("settings-status").textContent = "";
  if (problem) clearTimeout(name_timer); else schedule_name_save(800);
});
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

// The policy takes the settings' place; Close (or Esc) goes back to them.
$("privacy-open").addEventListener("click", () => {
  $("settings").hidden = true; $("privacy-policy").hidden = false; $("privacy-open").setAttribute("aria-expanded", "true");
  $("privacy-close").focus();
  $("privacy-policy").scrollIntoView({ block: "start" });
});
function close_privacy() {
  $("privacy-policy").hidden = true; $("settings").hidden = false; $("privacy-open").setAttribute("aria-expanded", "false");
  $("privacy-open").focus();
  $("privacy-open").scrollIntoView({ block: "nearest" });
}
$("privacy-close").addEventListener("click", close_privacy);


// Phone camera (src/camera/): "Use as webcam" on Android (the phone streams
// its camera), "Phone as webcam" on Linux (the computer shows it to every
// app as the HollerShare Camera device). Elsewhere the Webcam tab is hidden.
// Everything the camera reports, errors included, shows in its own card.
const camera = {
  role: null, on: false, busy: false, polling: false, status: null,
  view: { rotate: 0, mirror: false, fill: false }, quality: { height: 720, fps: 30, jpeg: 70 },
  // The computer's steps: the phones found, the one picked, the last try.
  phones: [], finding: false, found_once: false, find_error: "", last_find: 0,
  target: null, last: null, local_error: "", was_live: false, dismissed: null, prev_state: null, step: null,
  // A background refresh of a list already shown (no spinner); the list as
  // last drawn, to redraw it only when it changes.
  find_quiet: false, phones_key: "[]",
  // Stop (or Back from pairing) was asked: the session shows as idle until
  // camera_stop answers. Queued while another command runs.
  stop_pending: false, stop_queued: false,
  // Bumped around every command, so a status read before one is dropped.
  gen: 0,
};
const camera_quality_options = { height: [480, 720, 1080], fps: [15, 24, 30], jpeg: [50, 70, 85, 95] };
const picture_names = { 50: "Light", 70: "Balanced", 85: "Sharp", 95: "Best" };
function wrong_code(message) { return /^Wrong code/i.test(message || ""); }
function show_inline(id, message) { $(id + "-text").textContent = message || ""; $(id).hidden = !message; }
function camera_badge(text, live) { $("camera-state").textContent = text; $("camera-state").className = "badge" + (live ? " live" : ""); }
function camera_render(status) {
  if (!status || status.role === "none") {
    camera.role = "none"; render_tabs();
    if (current_view === "webcam") show_view("share");
    camera_watch();
    return;
  }
  camera.role = status.role; camera.status = status;
  render_tabs();
  if (status.role === "phone") camera_render_phone(status.phone || {}, status.phone_address || ""); else camera_render_computer(status.computer);
  camera_watch();
}
function camera_refresh() { if (camera.status) camera_render(camera.status); }

// "Back camera" / "Front camera", from the lens streaming.
function lens_name(facing) { return facing === "front" ? "Front camera" : facing === "back" ? "Back camera" : ""; }
function camera_render_phone(p, address) {
  camera.on = !!p.on;
  $("webcam-lede").textContent = "Let your computer use this phone’s camera for video calls.";
  $("camera-phone").hidden = false; $("camera-computer").hidden = true;
  const live = !!(p.on && p.streaming);
  $("phone-off").hidden = !!p.on;
  $("phone-waiting").hidden = !p.on || live;
  $("phone-live").hidden = !live;
  // The status pill sits on the visible state's heading row.
  $("camera-top").hidden = true;
  const head = document.querySelector("#" + (!p.on ? "phone-off" : live ? "phone-live" : "phone-waiting") + " .head-row");
  if (head && $("camera-state").parentNode !== head) head.appendChild($("camera-state"));
  if (p.on) $("camera-code").textContent = group_code(p.code);
  $("phone-name").textContent = model && model.name ? model.name : "this phone’s name";
  // The address a computer types when it can't find the phone, in the form its field takes.
  $("phone-address").textContent = address;
  $("phone-address-fold").hidden = !address;
  $("phone-waiting-text").textContent = "On the computer, open HollerShare › Webcam, pick this phone and type this code."
    + (p.discoverable || address ? "" : " If the phone isn’t listed there, enter this phone’s address with port " + p.port + ".");
  $("phone-live-computer").textContent = p.computer || "your computer";
  const lens = lens_name(p.facing);
  $("phone-live-lens").textContent = lens ? "Streaming the " + lens.toLowerCase() : "";
  $("phone-live-lens").hidden = !lens;
  camera_badge(!p.on ? "Off" : live ? "Live" : "Waiting", live);
  $("webcam-live").hidden = !live;
  show_inline("phone-error", p.error || camera.local_error);
}

function camera_render_computer(c) {
  $("webcam-lede").textContent = "Use your Android phone as a camera for video calls on this computer.";
  $("camera-computer").hidden = false; $("camera-phone").hidden = true;
  $("camera-top").hidden = false;
  if ($("camera-state").parentNode !== $("camera-top")) $("camera-top").appendChild($("camera-state"));
  // While a stop is on its way, the session it ends shows as over.
  const s = camera.stop_pending ? Object.assign({}, c.session, { state: "idle", error: "" }) : c.session;
  const failure = s.state === "failed" && s.error && s.error !== camera.dismissed ? s.error : "";
  // A wrong code: clear the field for the next try.
  if (s.state !== camera.prev_state && s.state === "failed" && wrong_code(s.error)) {
    $("camera-code-entry").value = "";
    setTimeout(() => $("camera-code-entry").focus(), 0);
    if (camera.target === null && camera.last) camera.target = { name: camera.last.name, address: camera.last.address };
  }
  camera.prev_state = s.state;
  if (s.state === "idle") camera.was_live = false;
  let step;
  if (!c.device) step = "setup";
  else if (s.state === "streaming") { step = "live"; camera.was_live = true; }
  else if (s.state === "connecting") step = camera.was_live ? "live" : "code";
  else if (failure) step = wrong_code(failure) || !camera.was_live ? "code" : "ended";
  else step = camera.target ? "code" : "pick";
  if (step === "code" && !camera.target) camera.target = camera.last ? { name: camera.last.name, address: camera.last.address } : { name: s.phone || "your phone", address: "" };
  const changed = step !== camera.step;
  if (changed && camera.step !== null) camera.local_error = "";
  camera.step = step;

  $("camera-setup").hidden = step !== "setup";
  $("camera-steps").hidden = step === "setup";
  $("camera-pick").hidden = step !== "pick";
  $("camera-code-step").hidden = step !== "code";
  $("camera-live").hidden = step !== "live";
  $("camera-ended").hidden = step !== "ended";
  // The stepper: done steps ticked, the current one marked, later ones muted;
  // after a stop, step 3 says so instead of "Live".
  const order = ["pick", "code", "live"], at = order.indexOf(step === "ended" ? "live" : step);
  [["step-phone", 0], ["step-code", 1], ["step-live", 2]].forEach(([id, i]) => {
    const stopped = step === "ended" && i === 2;
    $(id).className = "step" + (stopped ? " stopped" : i === at ? " on" : i < at ? " done" : "");
    $(id).firstElementChild.textContent = i < at ? "✓" : String(i + 1);
    if (i === at) $(id).setAttribute("aria-current", "step"); else $(id).removeAttribute("aria-current");
  });
  $("step-live-label").textContent = step === "ended" ? "Stopped" : "Live";
  $("webcam-live").hidden = s.state !== "streaming";

  const connecting = s.state === "connecting";
  if (step === "setup") camera_badge("Not set up");
  else if (step === "live") camera_badge(connecting ? "Reconnecting" : "Live", !connecting);
  else if (step === "ended") camera_badge("Stopped");
  else if (step === "code") camera_badge(connecting ? "Connecting" : "Pairing");
  else camera_badge(connecting ? "Connecting" : "Off");

  // 1 Phone
  const searching = camera.finding && !camera.find_quiet;
  $("camera-searching").hidden = !searching;
  $("camera-none").hidden = searching || !camera.found_once || camera.phones.length > 0 || !!camera.find_error;
  $("camera-find-row").hidden = searching;
  show_inline("camera-pick-error", camera.find_error || (step === "pick" ? camera.local_error : ""));

  // 2 Code
  const name = camera.target ? camera.target.name : (s.phone || "your phone");
  const address = camera.target ? camera.target.address : "";
  $("camera-code-phone").textContent = !address ? name : name === address ? "Phone at " + address : name + " · " + address;
  $("camera-code-entry").disabled = connecting || camera.busy;
  $("camera-code-msg").textContent = connecting ? "Connecting to " + name + "…" : "Connects by itself after the 6th digit.";
  const code_error = (step === "code" && failure) || (step === "code" ? camera.local_error : "");
  show_inline("camera-error", code_error);
  $("camera-retry").hidden = !failure || wrong_code(failure) || !camera.last;
  $("camera-code-entry").className = "code-entry" + (code_error && wrong_code(code_error) ? " bad" : "");
  if (changed && step === "code" && !connecting) setTimeout(() => $("camera-code-entry").focus(), 0);

  // 3 Live
  $("camera-live-title").textContent = connecting ? "Reconnecting to " + (s.phone || name) + "…" : "Live · " + (s.phone || name);
  camera.view = s.view || { rotate: 0, mirror: false, fill: false };
  camera.quality = s.quality || { height: 720, fps: 30, jpeg: 70 };
  const lens = lens_name(s.facing);
  let size = "";
  if (s.state === "streaming" && s.width) {
    size = (lens ? lens + " · " : "") + s.width + "×" + s.height + " · " + s.fps + " fps";
    if (!s.held_by_app && s.height && camera.quality.height && s.height !== camera.quality.height) size += " · the phone’s closest size to " + camera.quality.height + "p";
  }
  $("camera-live-size").textContent = size;
  $("camera-live-size").hidden = !size;
  // A video app already holds the camera at another size: it streams at that one.
  const held = s.held_by_app && s.held_by_app !== camera.quality.height;
  $("camera-held").textContent = held ? "Your video app opened the camera at " + s.held_by_app + "p. To use " + camera.quality.height + "p, close the video app, then Stop webcam and connect again." : "";
  $("camera-held").hidden = !held;
  $("camera-switch").disabled = s.state !== "streaming";
  // Named by where it goes.
  $("camera-switch").textContent = s.facing === "back" ? "Switch to front camera" : s.facing === "front" ? "Switch to back camera" : "Switch camera";
  // Picture toggles: filled with a tick when on.
  $("camera-rotate").textContent = (camera.view.rotate ? "✓ " : "") + "Rotate · " + (camera.view.rotate || 0) + "°";
  $("camera-rotate").className = "chip" + (camera.view.rotate ? " on" : "");
  for (const [id, on, label] of [["camera-mirror", camera.view.mirror, "Mirror"], ["camera-fill", camera.view.fill, "Fill frame"]]) {
    $(id).textContent = (on ? "✓ " : "") + label;
    $(id).className = "chip" + (on ? " on" : "");
    $(id).setAttribute("aria-pressed", String(!!on));
  }
  for (const [key, values] of Object.entries(camera_quality_options)) {
    for (const v of values) {
      const b = $("q-" + key + "-" + v);
      const chosen = camera.quality[key] === v;
      b.className = chosen ? "on" : "";
      b.setAttribute("aria-pressed", String(chosen));
    }
  }
  $("camera-quality-summary").textContent = "Video quality · " + camera.quality.height + "p · " + camera.quality.fps + " fps · " + (picture_names[camera.quality.jpeg] || "Custom");
  show_inline("camera-live-error", step === "live" ? camera.local_error : "");

  // Stopped
  $("camera-ended-text").textContent = failure || "The connection to the phone ended.";
  // Reconnect is the way back; without a last code, picking a phone is.
  $("camera-reconnect").hidden = !camera.last;
  $("camera-ended-help").hidden = !camera.last;
  $("camera-start-over").className = camera.last ? "text-button link" : "primary auto";
}
// "123456" as "123 456", the way both screens show it.
function group_code(code) { const d = String(code || ""); return d.length === 6 ? d.slice(0, 3) + " " + d.slice(3) : d; }

// Step 1 searches again by itself every few seconds while the Webcam view
// shows it, so phones that appear or go away show (Search again stays for
// the gaps between).
const camera_find_every = 4000;
function camera_view_open() { return current_view === "webcam" && $("settings-view").hidden; }
function camera_autofind() {
  if (camera.role !== "computer" || camera.step !== "pick" || camera.finding || !camera_view_open()) return;
  if (Date.now() - camera.last_find >= camera_find_every) camera_find(true);
}
// Status is polled while the Webcam view is open or a session needs
// watching (the phone's webcam on; the computer connecting or live), and
// once at startup to learn whether there's a camera at all ("none": never).
let camera_timer = null;
function camera_session_active() {
  const st = camera.status;
  if (!st) return false;
  if (st.role === "phone") return !!(st.phone && st.phone.on);
  const s = st.computer && st.computer.session;
  return !!s && (s.state === "connecting" || s.state === "streaming");
}
function camera_watch() {
  if (!window.oriel) return;
  const want = camera.role !== "none" && (camera.role === null || camera_view_open() || camera_session_active() || camera.busy || camera.stop_pending);
  if (want && !camera_timer) { camera_timer = setInterval(camera_poll, 1000); camera_poll(); }
  else if (!want && camera_timer) { clearInterval(camera_timer); camera_timer = null; }
}
async function camera_poll() {
  camera_autofind();
  if (camera.polling || camera.busy || camera.role === "none" || !window.oriel) return;
  camera.polling = true;
  const gen = camera.gen;
  try {
    const status = await call("camera_status");
    // A command ran meanwhile: its status is newer than this one.
    if (gen === camera.gen && !camera.busy) camera_render(status);
  } catch (_) {} finally { camera.polling = false; camera_watch(); }
}
// A camera command; what it reports (or its failure) shows in the card.
// One at a time; while one runs others are dropped, except Stop, which
// waits for it (camera_stop_session).
async function camera_act(command, args, control) {
  if (camera.busy || camera.stop_pending) return;
  camera.busy = true; camera.gen++; if (control) control.disabled = true;
  try {
    const status = await call(command, args);
    camera.local_error = "";
    if (status && status.role) camera_render(status);
  } catch (err) { camera.local_error = String(err.message || err); }
  finally {
    camera.busy = false; camera.gen++; if (control) control.disabled = false;
    if (camera.stop_queued) camera_run_stop(); else { camera_refresh(); camera_watch(); }
  }
}
// Stop webcam, and Back while pairing: always takes effect. Behind a
// command still running (a quality change that would reconnect, say) it
// runs right after it, so the session stays stopped.
function camera_stop_session(forget) {
  camera.target = null; camera.was_live = false;
  if (forget) camera.last = null;
  if (camera.stop_pending) return;
  camera.stop_pending = true; camera.gen++;
  camera_refresh();
  if (camera.busy) camera.stop_queued = true; else camera_run_stop();
}
async function camera_run_stop() {
  camera.stop_queued = false; camera.busy = true; camera.gen++; $("camera-stop").disabled = true;
  try {
    const status = await call("camera_stop");
    camera.local_error = ""; camera.stop_pending = false;
    if (status && status.role) camera_render(status);
  } catch (err) { camera.local_error = String(err.message || err); }
  finally {
    camera.stop_pending = false; camera.busy = false; camera.gen++; $("camera-stop").disabled = false;
    camera_refresh(); camera_watch();
  }
}
function render_camera_phones() {
  clear($("camera-phones"));
  for (const phone of camera.phones) {
    const row = element("div", "peer-row");
    row.appendChild(icon("phone", "device-icon", "Phone"));
    const detail = element("div", "peer-detail");
    detail.appendChild(element("div", "peer-name", phone.name || "Phone"));
    detail.appendChild(element("div", "small", phone.address + " · showing a code"));
    row.appendChild(detail);
    const next = button("Next", "", () => camera_choose(phone));
    next.setAttribute("aria-label", "Use " + (phone.name || phone.address));
    row.appendChild(next);
    $("camera-phones").appendChild(row);
  }
}
// `quiet`: refresh a list already shown without the spinner in its place.
async function camera_find(quiet) {
  if (camera.finding) return;
  camera.finding = true; camera.find_quiet = !!quiet && camera.phones.length > 0; camera.find_error = ""; camera_refresh();
  try {
    camera.phones = await call("camera_find") || [];
    // Redrawn only when it changes, so a Next being pressed stays put.
    const key = JSON.stringify(camera.phones);
    if (key !== camera.phones_key) { camera.phones_key = key; render_camera_phones(); }
  } catch (err) { camera.find_error = String(err.message || err); }
  finally { camera.finding = false; camera.find_quiet = false; camera.found_once = true; camera.last_find = Date.now(); camera_refresh(); }
}
// Leave a failure behind (Back, a new phone, a new code).
function camera_dismiss() {
  const s = camera.status && camera.status.computer && camera.status.computer.session;
  if (s && s.state === "failed") camera.dismissed = s.error;
  camera.local_error = "";
}
function camera_choose(phone) {
  camera_dismiss(); camera.was_live = false;
  camera.target = { name: phone.name || phone.address, address: phone.address };
  $("camera-code-entry").value = "";
  camera_refresh();
}
function camera_connect(code) {
  if (!camera.target || !camera.target.address) { camera.target = null; camera.local_error = "Pick a phone, or enter its address."; camera_refresh(); return; }
  camera.last = { name: camera.target.name, address: camera.target.address, code };
  camera.was_live = false; camera.dismissed = null;
  camera_act("camera_connect", { address: camera.target.address, code });
}
function camera_reconnect() {
  if (!camera.last) return;
  camera.target = { name: camera.last.name, address: camera.last.address };
  camera.dismissed = null;
  camera_act("camera_connect", { address: camera.last.address, code: camera.last.code });
}
// Opening the Webcam tab looks for phones by itself (again, if some were found before).
function camera_opened() {
  const c = camera.status && camera.status.computer;
  if (camera.role === "computer" && c && c.device && camera.step === "pick") camera_find(true);
}
async function camera_setup() {
  const control = $("camera-setup-run");
  control.disabled = true; show_inline("camera-setup-error", "");
  try {
    const result = await call("camera_setup");
    if (!result.ok) show_inline("camera-setup-error", result.message);
    await camera_poll();
    if (result.ok) camera_opened();
  } catch (err) { show_inline("camera-setup-error", String(err.message || err)); }
  finally { control.disabled = false; }
}
$("phone-start").addEventListener("click", () => camera_act("camera_phone_start", undefined, $("phone-start")));
$("phone-cancel").addEventListener("click", () => camera_act("camera_phone_stop", undefined, $("phone-cancel")));
$("phone-stop").addEventListener("click", () => camera_act("camera_phone_stop", undefined, $("phone-stop")));
$("camera-find").addEventListener("click", () => camera_find());
$("camera-setup-run").addEventListener("click", camera_setup);
$("camera-address-next").addEventListener("click", () => {
  const address = $("camera-address").value.trim();
  if (!address) { camera.find_error = "Type the phone’s address, like 192.168.1.20:47311."; camera_refresh(); return; }
  camera.find_error = "";
  camera_choose({ name: address, address });
});
$("camera-address").addEventListener("keydown", event => { if (event.key === "Enter") $("camera-address-next").click(); });
$("camera-code-entry").addEventListener("input", () => {
  const entry = $("camera-code-entry"), digits = entry.value.replace(/[^0-9]/g, "").slice(0, 6);
  // Rewrite the field only to drop what isn't a digit: setting the value
  // moves the caret in the native renderer, so reformatting while typing
  // (say, into "123 456") would scramble the digits.
  if (entry.value !== digits) entry.value = digits;
  if (camera.local_error || (camera.status && camera.status.computer && camera.status.computer.session.state === "failed")) { camera_dismiss(); camera_refresh(); }
  if (digits.length === 6) camera_connect(digits);
});
$("camera-code-entry").addEventListener("keydown", event => {
  const digits = $("camera-code-entry").value.replace(/[^0-9]/g, "");
  if (event.key === "Enter" && /^[0-9]{6}$/.test(digits)) camera_connect(digits);
});
$("camera-retry").addEventListener("click", camera_reconnect);
$("camera-reconnect").addEventListener("click", camera_reconnect);
// Back from pairing ends the attempt too: left running, it could still go
// live, or bring the code step back with no phone to show.
$("camera-back").addEventListener("click", () => { camera_dismiss(); camera_stop_session(true); camera_find(true); });
$("camera-start-over").addEventListener("click", () => { camera_dismiss(); camera.target = null; camera.was_live = false; camera_refresh(); camera_find(); });
$("camera-stop").addEventListener("click", () => camera_stop_session(false));
$("camera-switch").addEventListener("click", () => camera_act("camera_switch", undefined, $("camera-switch")));
function camera_view(change, control) {
  camera_act("camera_view", Object.assign({}, camera.view, change), control);
}
$("camera-rotate").addEventListener("click", () => camera_view({ rotate: (camera.view.rotate + 90) % 360 }, $("camera-rotate")));
$("camera-mirror").addEventListener("click", () => camera_view({ mirror: !camera.view.mirror }, $("camera-mirror")));
$("camera-fill").addEventListener("click", () => camera_view({ fill: !camera.view.fill }, $("camera-fill")));
for (const [key, values] of Object.entries(camera_quality_options)) {
  for (const v of values) {
    const b = $("q-" + key + "-" + v);
    b.addEventListener("click", () => camera_act("camera_quality", Object.assign({}, camera.quality, { [key]: v }), b));
  }
}
camera_watch();
