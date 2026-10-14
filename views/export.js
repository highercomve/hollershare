// HollerShare's page as .oriel views for the Oriel renderer (-Drenderer=oriel).
// With a native-renderer build (the default):
//   ORIEL_NUI_EXPORT=<dir> ORIEL_NUI_EXPORT_SCRIPT=views/export.js zig-out/bin/hollershare
// then, in Oriel, `zig build check-views -Dzig_ui -Dviews=<dir>`, and copy
// <dir>/*.oriel here. The views are the page's look; the app
// (src/oriel_frontend.zig) shows and hides their parts and fills their lists
// as app.js does.
const wait = (ms) => new Promise((r) => setTimeout(r, ms));
await wait(2500);
// The page as it is now: no polls or update checks while it is exported.
polling = true; update_busy = true;

const H = 860;
const looks = { base: [980, false], dark: [980, true], narrow: [600, false], "dark-narrow": [600, true] };
const media = { dark: "prefers-color-scheme: dark", narrow: "max-width: 680", "dark-narrow": "prefers-color-scheme: dark and max-width: 680" };
async function look(name) {
  const [w, dark] = looks[name];
  __oriel.resize(w, H, dark);
  set_theme(dark);
  await wait(200);
}
const text = (id, value) => { $(id).textContent = value; };
const bind = (el, value) => { if (el) el.textContent = value; };
function unhide() { for (const el of document.querySelectorAll("[hidden]")) el.hidden = false; }
// The `focus` variants: every control as it looks with the visible focus
// (the page's :focus-visible styles), the views' @when (focus) blocks.
const focusable = "button, input, textarea, select, a[href], [tabindex]";
function focusAll(on) {
  for (const el of document.querySelectorAll(focusable)) {
    if (on) el.setAttribute("data-nui-focus-visible", ""); else el.removeAttribute("data-nui-focus-visible");
  }
}
// The `hover` variants: everything as it looks under the pointer (the
// page's :hover styles), the views' @when (hover) blocks.
function hoverAll(on) {
  for (const el of document.querySelectorAll("body *")) {
    if (on) el.setAttribute("data-nui-hover", ""); else el.removeAttribute("data-nui-hover");
  }
}

// --- The lists' rows: three of a kind (first, middle, last) -------------
const transfer = (state, meta, rtype = "Outbound") => ({ id: "t", rtype, state, meta: { total_bytes: 1, ...meta } });
function showTransfers(list) {
  model = { peers: [], transfers: list, relocations: {}, download_dir: "{folder}" };
  render_transfers();
}
function rowTexts(row) {
  bind(row.querySelector(".transfer-name"), "{name}");
  bind(row.querySelector(".transfer-detail > .small"), "{detail}");
  bind(row.querySelector(".transfer-status > div"), "{status}");
}
const kinds = {
  "file-row": {
    render() { files = [0, 1, 2].map((i) => ({ path: "/tmp/f" + i, name: "{name}", size: 1 })); render_files(); },
    rows: () => document.querySelectorAll(".file-row"),
    dress(row) { bind(row.querySelector(".file-name"), "{name}"); bind(row.querySelector(".small"), "{size}"); row.querySelector("button").id = "remove"; },
  },
  "peer-row": {
    render() { model = { peers: [0, 1, 2].map((i) => ({ name: "{name}", rtype: "Phone", id: "p" + i })), transfers: [] }; render_peers(); },
    rows: () => document.querySelectorAll(".peer-row"),
    dress(row) { bind(row.querySelector(".device-icon"), "{icon}"); bind(row.querySelector(".small"), "{detail}"); row.querySelector("button").id = "send"; },
  },
  request: {
    render() { showTransfers([0, 1, 2].map(() => transfer("WaitingForUserConsent", { files: ["a"], source: { name: "p" }, pin_code: "1" }, "Inbound"))); },
    rows: () => document.querySelectorAll(".request"),
    dress(card) {
      bind(card.querySelector("h3"), "{title}"); bind(card.children[1], "{summary}"); bind(card.children[3], "{pin}"); bind(card.children[4], "{folder}");
      card.children[1].id = "summary"; card.children[4].id = "folder-line";
      const [accept, choose, decline] = card.querySelectorAll(".request-actions button");
      accept.id = "accept"; choose.id = "choose-folder"; decline.id = "decline";
    },
  },
  "request-text": {
    render() { showTransfers([0, 1, 2].map(() => transfer("WaitingForUserConsent", { source: { name: "p" }, pin_code: "1" }, "Inbound"))); },
    rows: () => document.querySelectorAll(".request"),
    dress(card) {
      bind(card.querySelector("h3"), "{title}"); bind(card.children[1], "{summary}"); bind(card.children[3], "{pin}");
      const [accept, decline] = card.querySelectorAll(".request-actions button");
      accept.id = "accept"; decline.id = "decline";
    },
  },
  "transfer-active": {
    render() { showTransfers([0, 1, 2].map(() => transfer("SendingFiles", { files: ["a"], pin_code: "1", ack_bytes: 0 }))); },
    rows: () => document.querySelectorAll(".transfer-row"),
    dress(row) {
      rowTexts(row);
      const code = row.querySelector(".transfer-status > .small");
      bind(code, "{code}"); code.id = "code";
      row.querySelector(".progress-fill").id = "fill";
      row.querySelector(".transfer-status button").id = "cancel";
    },
  },
  "transfer-done": {
    render() { showTransfers([0, 1, 2].map(() => transfer("Finished", { files: ["a"], saved_files: ["/x/a"], destination: "{folder}", source: { name: "p" } }, "Inbound"))); },
    rows: () => document.querySelectorAll(".transfer-row"),
    dress(row) {
      rowTexts(row);
      const saved = row.querySelector(".file-actions + .small");
      bind(saved, "{saved}"); saved.id = "saved";
      row.querySelector(".file-actions").id = "actions";
      const [open, folder] = row.querySelectorAll(".file-actions button");
      bind(open, "{open-label}"); open.id = "open"; folder.id = "open-folder";
    },
  },
  "transfer-text": {
    // As the engine sends a received text: no files saved, where they'd go.
    render() { showTransfers([0, 1, 2].map(() => transfer("Finished", { text_payload: "{text}", saved_files: [], destination: "{folder}" }, "Inbound"))); },
    rows: () => document.querySelectorAll(".transfer-row"),
    dress(row) {
      rowTexts(row);
      row.querySelector(".text-preview").id = "preview";
      const copy = row.querySelector(".transfer-detail button");
      copy.id = "copy"; bind(copy, "{copy-label}");
      row.querySelector(".file-actions").id = "actions";
      const saved = row.querySelector(".file-actions + .small");
      bind(saved, "{saved}"); saved.id = "saved";
    },
  },
  "transfer-ended": {
    render() { showTransfers([0, 1, 2].map(() => transfer("Cancelled", { files: ["a"] }))); },
    rows: () => document.querySelectorAll(".transfer-row"),
    dress: rowTexts,
  },
  "open-button": {
    render() { showTransfers([transfer("Finished", { files: ["a", "b", "c"], saved_files: ["/x/a", "/x/b", "/x/c"], source: { name: "p" } }, "Inbound")]); },
    rows: () => document.querySelectorAll(".file-actions button:not(.text-button)"),
    dress(button) { bind(button, "{label}"); button.id = "open"; },
  },
};
function clearLists() {
  files = []; render_files();
  model = { peers: [], transfers: [], relocations: {} };
  render_peers(); render_transfers();
}

// --- The page: every part shown, its changing texts as bindings --------
// The parts app.js hides: each one hidden is a state of its own
// (`no-<id>`), so what hiding changes around it (collapsed margins) is
// the view's too. download-default is a span of the help line: the app
// empties it instead.
const parts = ["error", "settings", "privacy-policy", "text-compose", "file-compose", "clear", "file-empty", "peer-empty",
  "update-install", "update-restart", "update-check", "device-name-error", "download-dir-error", "download-detail", "download-browse"];
// The lists: their rows are views of their own; a list with rows is a
// state (`has-<id>`: its margins, the empty note it hides).
const lists = { "has-files": ["file-list", "file-row"], "has-peers": ["peers", "peer-row"], "has-requests": ["requests", "request"], "has-transfers": ["transfers", "transfer-done"] };
// The empty note of the activity list: the same element in every variant
// (nodes are matched by element; render_transfers makes a new one).
const emptyNote = $("transfers").querySelector(".activity-empty");
emptyNote.id = "activity-empty";
function page(state) {
  files = []; render_files();
  model = { peers: [], transfers: [], relocations: {} };
  render_peers();
  $("requests").replaceChildren();
  $("transfers").replaceChildren(emptyNote);
  set_share_mode(state === "text-mode" ? "text" : "files");
  $("visibility").className = "presence" + (state === "presence-off" ? " off" : "");
  $("download-current").className = "path folder" + (state === "unavailable" ? " unavailable" : "");
  $("settings-open").setAttribute("aria-expanded", String(state === "settings-open"));
  drop_panel.classList.toggle("drop-hover", state === "drop-hover");
  if (lists[state]) kinds[lists[state][1]].render();
  unhide();
  if (state?.startsWith("no-")) $(state.slice(3)).hidden = true;
  for (const id of ["visibility", "identity", "downloads", "update-status", "peer-count", "error", "settings-status",
    "device-name-error", "download-dir-error", "download-name", "download-detail", "download-help-text"]) text(id, "{" + id + "}");
  text("choose", "{choose}");
  text("download-default", "{download-default}");
  focusAll(state === "focus");
  hoverAll(state === "hover");
}
const pageVariants = [
  [null, "base"], ["dark", "dark"], ["narrow", "narrow"], ["dark-narrow", "dark-narrow"],
  ["text-mode", "base", "text-mode"], ["text-mode-dark", "dark", "text-mode"],
  ["presence-off", "base", "presence-off"], ["presence-off-dark", "dark", "presence-off"], ["presence-off-narrow", "narrow", "presence-off"],
  ["unavailable", "base", "unavailable"], ["unavailable-dark", "dark", "unavailable"],
  ["drop-hover", "base", "drop-hover"], ["drop-hover-dark", "dark", "drop-hover"],
  ["settings-open", "base", "settings-open"], ["settings-open-dark", "dark", "settings-open"],
  ["focus", "base", "focus"], ["focus-dark", "dark", "focus"],
  ["hover", "base", "hover"], ["hover-dark", "dark", "hover"],
  ...Object.keys(lists).map((state) => [state, "base", state]),
  ...parts.map((id) => ["no-" + id, "base", "no-" + id]),
];
for (const [variant, lookName, state] of pageVariants) {
  await look(lookName);
  page(state);
  await wait(100);
  // Lists with rows: the lists, not their rows (render_transfers fills the
  // requests and the activity together).
  const rows = (el) => [...el.children].some((c) => c !== emptyNote);
  const hollow = Object.values(lists).map(([id]) => $(id)).filter(rows);
  await __orielExport("main", { variant, media: media[lookName] ?? null, when: state ?? null, hollow });
}

// --- Each row a view: the middle one, and the first and last ------------
const rowVariants = [
  ["base", 1], ["dark", 1], ["narrow", 1], ["dark-narrow", 1],
  ["base", 1, "focus"], ["dark", 1, "focus"],
  ["base", 1, "hover"], ["dark", 1, "hover"],
  ["base", 0, "first"], ["dark", 0, "first"], ["base", 2, "last"], ["dark", 2, "last"],
];
for (const [name, kind] of Object.entries(kinds)) {
  for (const [lookName, index, state] of rowVariants) {
    await look(lookName);
    clearLists();
    kind.render();
    const all = kind.rows();
    for (const row of all) kind.dress(row);
    focusAll(state === "focus");
    hoverAll(state === "hover");
    await wait(100);
    const el = all[index];
    if (!el) throw new Error("no " + name + " to export");
    const variant = state ? (lookName === "base" ? state : state + "-" + lookName) : (lookName === "base" ? null : lookName);
    await __orielExport(name, { element: el, variant, media: media[lookName] ?? null, when: state ?? null });
  }
  focusAll(false);
  hoverAll(false);
}

__orielExportDone();
