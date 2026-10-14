//! HollerShare on the Oriel renderer (-Drenderer=oriel): frontend/app.js in
//! Zig, drawing the .oriel views exported from the page (views/export.js),
//! so it looks the same. The commands are the page's (main.zig Commands),
//! called through the engine's command pool; their answers come back in
//! `resolved`.
const std = @import("std");
const oriel = @import("oriel");
const ui = oriel.ui;

const Main = ui.View(@embedFile("main.oriel"));
const FileRow = ui.View(@embedFile("file-row.oriel"));
const PeerRow = ui.View(@embedFile("peer-row.oriel"));
const Request = ui.View(@embedFile("request.oriel"));
const RequestText = ui.View(@embedFile("request-text.oriel"));
const TransferActive = ui.View(@embedFile("transfer-active.oriel"));
const TransferDone = ui.View(@embedFile("transfer-done.oriel"));
const TransferText = ui.View(@embedFile("transfer-text.oriel"));
const TransferEnded = ui.View(@embedFile("transfer-ended.oriel"));
const OpenButton = ui.View(@embedFile("open-button.oriel"));

// Node ids: the page, then each list's rows (a row's view numbers its
// nodes from its base). Style ids: each view's, apart.
const main_id: i64 = 10;
const row_stride: i64 = 64;
const max_rows = 256;
const file_rows: i64 = 1_000_000;
const peer_rows: i64 = 2_000_000;
const request_rows: i64 = 3_000_000;
const transfer_rows: i64 = 4_000_000;
const open_rows: i64 = 5_000_000;
const max_open = 16;

const styles = .{
    .{ Main, 100_000 },         .{ FileRow, 110_000 },       .{ PeerRow, 111_000 },
    .{ Request, 112_000 },      .{ RequestText, 113_000 },   .{ TransferActive, 114_000 },
    .{ TransferDone, 115_000 }, .{ TransferText, 116_000 },  .{ TransferEnded, 117_000 },
    .{ OpenButton, 118_000 },
};
fn styleOf(comptime V: type) i64 {
    inline for (styles) |v| if (v[0] == V) return v[1];
    @compileError("no style ids for this view");
}

// The commands' answers, by what asked.
const Ask = enum(u32) {
    snapshot = 1,
    system_info,
    pending_share,
    settings_load,
    settings_open,
    settings_save,
    settings_folder,
    select_file,
    send,
    read_clipboard,
    decide,
    decide_folder,
    copy_transfer,
    open_transfer,
    cancel,
    visibility,
    update_info,
    updater_check,
    updater_install,
    updater_restart,
    quit,
};

const poll_timer: u32 = 100;
const update_timer: u32 = 101;
const update_every_ms: u32 = 6 * 60 * 60 * 1000;

const File = struct { path: []u8, name: []u8, size: u64 };
const RowKind = enum { none, active, done, text, ended };
const terminal = [_][]const u8{ "Finished", "Rejected", "Cancelled", "Disconnected" };
const state_names = [_][2][]const u8{
    .{ "Initial", "Connecting" },                   .{ "ReceivedConnectionRequest", "Connecting" },
    .{ "SentIntroduction", "Waiting for receiver" }, .{ "WaitingForUserConsent", "Waiting for approval" },
    .{ "ReceivingFiles", "Receiving" },              .{ "SendingFiles", "Sending" },
    .{ "Finished", "Complete" },                     .{ "Rejected", "Declined" },
    .{ "Cancelled", "Cancelled" },                   .{ "Disconnected", "Disconnected" },
};

/// The page's texts that change (main.oriel's bindings), owned here.
const texts = [_][]const u8{ "visibility", "identity", "downloads", "update-status", "peer-count", "error", "settings-status", "device-name-error", "download-dir-error", "download-name", "download-detail", "download-help-text", "choose", "download-default" };

const State = struct {
    gpa: std.mem.Allocator = undefined,
    io: std.Io = undefined,
    booted: bool = false,
    text: [texts.len]std.ArrayList(u8) = @splat(.empty),
    files: std.ArrayList(File) = .empty,
    /// The last snapshot (`data`), and its peers' and transfers' JSON (a list
    /// is drawn again when it changes).
    model: ?std.json.Parsed(std.json.Value) = null,
    previous_peers: std.ArrayList(u8) = .empty,
    previous_transfers: std.ArrayList(u8) = .empty,
    settings: ?std.json.Parsed(std.json.Value) = null,
    text_mode: bool = false,
    sending: bool = false,
    polling: bool = false,
    poll_failed: bool = false,
    android: bool = false,
    theme_event: bool = false,
    settings_open: bool = false,
    settings_busy: bool = false,
    folder_before: std.ArrayList(u8) = .empty,
    update_busy: bool = false,
    update_android: bool = false,
    update_version: std.ArrayList(u8) = .empty,
    restart_ready: bool = false,
    /// What the fields hold (their "input" events).
    clipboard: std.ArrayList(u8) = .empty,
    address: std.ArrayList(u8) = .empty,
    device_name: std.ArrayList(u8) = .empty,
    /// The rows drawn: each slot's view, and the transfers' ids by slot.
    file_count: usize = 0,
    peer_count: usize = 0,
    request_count: usize = 0,
    transfer_kinds: [max_rows]RowKind = @splat(.none),
    transfer_count: usize = 0,
    transfer_ids: [max_rows]std.ArrayList(u8) = @splat(.empty),
    request_ids: [max_rows]std.ArrayList(u8) = @splat(.empty),
    /// A text's card (no folder to choose) or a files' one, by slot.
    request_text: [max_rows]?bool = @splat(null),
    peer_ids: [max_rows][2]std.ArrayList(u8) = @splat(.{ .empty, .empty }),
    open_counts: [max_rows]usize = @splat(0),
    /// A decision waiting for its folder, a send waiting for its answer.
    pending_decision: std.ArrayList(u8) = .empty,
    drop_hover: bool = false,
    copied_slot: ?usize = null,
};
var s: State = .{};

pub fn configure(io: std.Io) void {
    s.io = io;
    ui.configure(.{ .boot = boot, .event = event, .timer = timer, .resolved = resolved, .shutdown = shutdown, .drag = drag });
}

// --- The tree ------------------------------------------------------------

fn mid(comptime name: []const u8) i64 {
    return Main.id(name, main_id);
}

/// Shown or not (the page's `hidden`).
fn display(e: *ui.Engine, id: i64, on: bool) !void {
    const n = e.tree.get(id) orelse return;
    if (n.props.none == !on) return;
    var props = n.props;
    props.none = !on;
    try e.tree.updateUiProps(id, props);
}

/// One of the page's parts shown or hidden (the page's `hidden`): its
/// `no-<part>` state, which also has what hiding it changes around it.
fn show(e: *ui.Engine, comptime part: []const u8, on: bool) !void {
    try Main.setState(&e.tree, main_id, "no-" ++ part, !on);
}

/// A row's place in its list (its view's `first` and `last` looks, where
/// the page styles them: borders between rows, margins at the ends).
fn position(comptime V: type, e: *ui.Engine, base: i64, i: usize, count: usize) !void {
    inline for (.{ "first", "last" }) |name| {
        const on = if (comptime std.mem.eql(u8, name, "first")) i == 0 else i + 1 == count;
        V.setStateNamed(&e.tree, base, name, on) catch |err| switch (err) {
            error.UnknownState => {},
            else => return err,
        };
    }
}

/// A button's `disabled`: its look (button:disabled, opacity 0.45) and state.
fn disable(e: *ui.Engine, id: i64, on: bool) !void {
    const n = e.tree.get(id) orelse return;
    if (n.props.dis == on) return;
    var props = n.props;
    props.dis = on;
    props.op = if (on) 0.45 else null;
    try e.tree.updateUiProps(id, props);
}

fn setValue(e: *ui.Engine, id: i64, value: []const u8) !void {
    const n = e.tree.get(id) orelse return;
    var props = n.props;
    props.val = value;
    try e.tree.updateUiProps(id, props);
}

fn setPlaceholder(e: *ui.Engine, id: i64, value: []const u8) !void {
    const n = e.tree.get(id) orelse return;
    var props = n.props;
    props.ph = value;
    try e.tree.updateUiProps(id, props);
}

/// The rows `from` to `to` of a list (rows a list no longer has).
fn destroyRows(e: *ui.Engine, base: i64, from: usize, to: usize) void {
    var i = from;
    while (i < to) : (i += 1) e.tree.destroy(base + @as(i64, @intCast(i)) * row_stride);
}

/// Is `id` the node `target` or in it (a click lands on a button's text)?
fn within(e: *ui.Engine, id: i64, target: i64) bool {
    // A link's run (an inline button) is its own id, with no node.
    if (id == target) return true;
    var node = e.tree.get(id);
    var depth: usize = 0;
    while (node) |n| : (depth += 1) {
        if (n.id == target) return true;
        if (depth > 64) return false;
        node = n.parent;
    }
    return false;
}

/// One of the page's texts, then the page drawn with them.
fn setText(e: *ui.Engine, comptime name: []const u8, value: []const u8) !void {
    const i = comptime for (texts, 0..) |t, i| {
        if (std.mem.eql(u8, t, name)) break i;
    } else @compileError("no text " ++ name);
    if (std.mem.eql(u8, s.text[i].items, value)) return;
    s.text[i].clearRetainingCapacity();
    try s.text[i].appendSlice(s.gpa, value);
    try drawTexts(e);
}

fn drawTexts(e: *ui.Engine) !void {
    var bindings: [texts.len]ui.Binding = undefined;
    for (texts, 0..) |t, i| bindings[i] = .{ .name = t, .value = s.text[i].items };
    try Main.update(&e.tree, main_id, &bindings);
}

fn setTextFmt(e: *ui.Engine, comptime name: []const u8, comptime f: []const u8, args: anytype) !void {
    const value = try std.fmt.allocPrint(s.gpa, f, args);
    defer s.gpa.free(value);
    try setText(e, name, value);
}

fn copyInto(list: *std.ArrayList(u8), value: []const u8) !void {
    list.clearRetainingCapacity();
    try list.appendSlice(s.gpa, value);
}

// --- Boot ------------------------------------------------------------------

fn boot(e: *ui.Engine) !void {
    s.gpa = e.gpa;
    inline for (styles) |v| try v[0].prepare(&e.tree, v[1]);
    var bindings: [texts.len]ui.Binding = undefined;
    for (texts, 0..) |t, i| bindings[i] = .{ .name = t, .value = "" };
    _ = try Main.mount(&e.tree, main_id, styleOf(Main), &bindings);
    e.tree.root = e.tree.get(main_id);
    // The page's parts its HTML hides at first.
    inline for (.{ "error", "settings", "privacy-policy", "text-compose", "clear", "update-install", "update-restart", "device-name-error", "download-dir-error" }) |name| try show(e, name, false);
    s.booted = true;
    try setText(e, "visibility", "Starting Quick Share…");
    try setText(e, "identity", "Connecting…");
    try setText(e, "downloads", "Received files stay on this computer.");
    try setText(e, "update-status", "Checking for updates…");
    try setText(e, "peer-count", "0");
    try setText(e, "download-help-text", "New transfers are saved here.");
    try renderFiles(e);
    try poll(e);
    e.backend.add_timer(e.backend.ctx, e, poll_timer, 800);
    try ui.invoke(e, @intFromEnum(Ask.system_info), "system_info", .{});
    try ui.invoke(e, @intFromEnum(Ask.pending_share), "get_pending_share", .{});
    try ui.invoke(e, @intFromEnum(Ask.settings_load), "settings_get", .{});
    e.backend.add_timer(e.backend.ctx, e, update_timer, 1500);
}

fn shutdown(_: *ui.Engine) void {
    if (!s.booted) return;
    s.booted = false;
    for (&s.text) |*t| t.deinit(s.gpa);
    for (s.files.items) |f| freeFile(f);
    s.files.deinit(s.gpa);
    if (s.model) |m| m.deinit();
    if (s.settings) |m| m.deinit();
    s.model = null;
    s.settings = null;
    inline for (.{ &s.previous_peers, &s.previous_transfers, &s.folder_before, &s.update_version, &s.clipboard, &s.address, &s.device_name, &s.pending_decision }) |l| l.deinit(s.gpa);
    for (&s.transfer_ids) |*l| l.deinit(s.gpa);
    for (&s.request_ids) |*l| l.deinit(s.gpa);
    for (&s.peer_ids) |*p| {
        p[0].deinit(s.gpa);
        p[1].deinit(s.gpa);
    }
}

fn freeFile(f: File) void {
    s.gpa.free(f.path);
    s.gpa.free(f.name);
}

fn timer(e: *ui.Engine, id: u32) !void {
    if (id == poll_timer) {
        try poll(e);
        e.backend.add_timer(e.backend.ctx, e, poll_timer, 800);
    } else if (id == update_timer) {
        if (!s.restart_ready) try checkUpdates(e);
        e.backend.add_timer(e.backend.ctx, e, update_timer, update_every_ms);
    }
}

// --- Answers -------------------------------------------------------------

/// A command's answer as a value: a JSON string holding JSON (the engine's
/// replies) is read again, and `{ok, data, error}` gives its data or fails.
fn answer(ok: bool, json: []const u8) !std.json.Parsed(std.json.Value) {
    if (!ok) return error.CommandFailed;
    var parsed = try std.json.parseFromSlice(std.json.Value, s.gpa, json, .{});
    if (parsed.value == .string) {
        const inner = try std.json.parseFromSlice(std.json.Value, s.gpa, parsed.value.string, .{});
        parsed.deinit();
        parsed = inner;
    }
    return parsed;
}

/// The message of a failed answer (the command's error, or `error` of
/// `{ok: false}`) into `out`.
fn failure(ok: bool, json: []const u8, out: *std.ArrayList(u8)) !bool {
    out.clearRetainingCapacity();
    if (!ok) {
        const msg = std.json.parseFromSlice([]const u8, s.gpa, json, .{}) catch {
            try out.appendSlice(s.gpa, json);
            return true;
        };
        defer msg.deinit();
        try out.appendSlice(s.gpa, msg.value);
        return true;
    }
    const parsed = answer(ok, json) catch return false;
    defer parsed.deinit();
    if (parsed.value == .object) if (parsed.value.object.get("ok")) |v| if (v == .bool and !v.bool) {
        const message = if (parsed.value.object.get("error")) |m| if (m == .string) m.string else "Failed" else "Failed";
        try out.appendSlice(s.gpa, message);
        return true;
    };
    return false;
}

/// The data of `{ok: true, data}` (or the whole value).
fn dataOf(v: std.json.Value) std.json.Value {
    if (v == .object) if (v.object.get("ok")) |_| return v.object.get("data") orelse .null;
    return v;
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .string) x.string else null;
}

fn num(v: ?std.json.Value) f64 {
    const x = v orelse return 0;
    return switch (x) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string => |n| std.fmt.parseFloat(f64, n) catch 0,
        else => 0,
    };
}

fn boolOf(v: ?std.json.Value) bool {
    const x = v orelse return false;
    return x == .bool and x.bool;
}

fn field(v: std.json.Value, name: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(name) else null;
}

fn showError(e: *ui.Engine, message: []const u8) !void {
    try setText(e, "error", message);
    try show(e, "error", true);
}

fn resolved(e: *ui.Engine, id: u32, ok: bool, json: []const u8) !void {
    var message: std.ArrayList(u8) = .empty;
    defer message.deinit(s.gpa);
    const failed = try failure(ok, json, &message);
    switch (@as(Ask, @enumFromInt(id))) {
        .snapshot => {
            s.polling = false;
            if (failed) {
                s.poll_failed = true;
                try showError(e, message.items);
                try setText(e, "visibility", "Quick Share unavailable");
                return;
            }
            const parsed = try answer(ok, json);
            if (s.model) |m| m.deinit();
            s.model = parsed;
            try renderModel(e);
        },
        .system_info => {
            if (failed) return showError(e, message.items);
            const parsed = try answer(ok, json);
            defer parsed.deinit();
            s.android = boolOf(field(parsed.value, "android"));
            if (!s.theme_event) if (field(parsed.value, "dark")) |d| if (d == .bool) try setTheme(e, d.bool);
            s.previous_transfers.clearRetainingCapacity();
            try poll(e);
        },
        .pending_share => if (!failed) {
            const parsed = try answer(ok, json);
            defer parsed.deinit();
            try applySharePayload(e, dataOf(parsed.value));
        },
        .settings_load => if (!failed) {
            try keepSettings(ok, json);
            try renderFolder(e);
        },
        .settings_open => {
            if (failed) return fieldError(e, "download-dir-error", message.items);
            try keepSettings(ok, json);
            try renderSettings(e);
            if (e.tree.get(mid("device-name"))) |n| e.backend.focus(e.backend.ctx, n);
        },
        .settings_save => {
            s.settings_busy = false;
            try settingsDisabled(e, false);
            if (failed) {
                const name_error = std.ascii.indexOfIgnoreCase(message.items, "name") != null;
                if (name_error) try fieldError(e, "device-name-error", message.items) else try fieldError(e, "download-dir-error", message.items);
                return;
            }
            try keepSettings(ok, json);
            try poll(e);
            try renderSettings(e);
            const name = if (s.model) |m| str(field(m.value.object.get("data") orelse m.value, "name")) else null;
            const shown = name orelse if (s.settings) |st| (if (str(field(st.value, "device_name"))) |d| (if (d.len > 0) d else str(field(st.value, "system_name")) orelse "") else "") else "";
            try setTextFmt(e, "settings-status", "Saved · Nearby devices now see {s}", .{shown});
        },
        .settings_folder => {
            s.settings_busy = false;
            try settingsDisabled(e, false);
            if (failed) return fieldError(e, "download-dir-error", message.items);
            try keepSettings(ok, json);
            try poll(e);
            try renderFolder(e);
            s.previous_transfers.clearRetainingCapacity();
            if (s.model != null) try renderTransfers(e);
            const st = s.settings.?.value;
            const folder = str(field(st, "download_folder")) orelse "";
            if (!std.mem.eql(u8, folder, s.folder_before.items)) {
                if (folder.len > 0) try setTextFmt(e, "settings-status", "Saved · Received files go to {s}", .{str(field(st, "download_folder_name")) orelse folder}) else try setText(e, "settings-status", if (s.android) "Saved · Received files go to HollerShare’s folder" else "Saved · Received files go to the default folder");
            }
        },
        .select_file => {
            try disable(e, mid("choose"), false);
            if (failed) return showError(e, message.items);
            const parsed = try answer(ok, json);
            defer parsed.deinit();
            const v = parsed.value;
            if (v == .object) try addFile(str(field(v, "path")) orelse return, str(field(v, "name")) orelse "", @intFromFloat(num(field(v, "size"))));
            try renderFiles(e);
            try renderPeers(e);
        },
        .send => {
            if (failed) try showError(e, message.items) else {
                if (s.text_mode) {
                    s.clipboard.clearRetainingCapacity();
                    try setValue(e, mid("clipboard-text"), "");
                } else clearFiles();
                try show(e, "error", false);
            }
            s.sending = false;
            inline for (.{ "clipboard-text", "mode-files", "mode-text", "read-clipboard", "choose", "clear" }) |name| try disable(e, mid(name), false);
            try renderFiles(e);
            try renderPeers(e);
            try poll(e);
        },
        .read_clipboard => {
            try disable(e, mid("read-clipboard"), false);
            if (failed) try showError(e, message.items) else {
                const parsed = try answer(ok, json);
                defer parsed.deinit();
                const text = str(field(parsed.value, "text")) orelse "";
                try copyInto(&s.clipboard, text);
                try setValue(e, mid("clipboard-text"), text);
                if (text.len == 0) try showError(e, "The clipboard has no text to share.") else try show(e, "error", false);
            }
            try renderFiles(e);
            try renderPeers(e);
        },
        .decide_folder => {
            if (failed) return showError(e, message.items);
            const parsed = try answer(ok, json);
            defer parsed.deinit();
            const folder = str(parsed.value) orelse return; // cancelled
            try ui.invoke(e, @intFromEnum(Ask.decide), "decide", .{ .id = s.pending_decision.items, .accept = true, .directory = folder });
        },
        .decide, .cancel, .visibility => {
            if (failed) try showError(e, message.items);
            if (@as(Ask, @enumFromInt(id)) == .visibility) try disable(e, mid("visibility"), false);
            try poll(e);
        },
        .copy_transfer => {
            if (failed) return showError(e, message.items);
            // The button says so until the list is drawn again (app.js).
            if (s.copied_slot) |slot| if (s.transfer_kinds[slot] == .text) try setLabel(e, TransferText.id("copy", transfer_rows + @as(i64, @intCast(slot)) * row_stride), "Copied");
        },
        .open_transfer => if (failed) try showError(e, message.items),
        .update_info => {
            if (failed) return updateFailed(e);
            const parsed = try answer(ok, json);
            defer parsed.deinit();
            s.update_android = boolOf(field(parsed.value, "android"));
            try copyInto(&s.update_version, str(field(parsed.value, "version")) orelse "");
            if (boolOf(field(parsed.value, "play_store"))) {
                try setTextFmt(e, "update-status", "HollerShare {s} · Updates through Google Play", .{s.update_version.items});
                try show(e, "update-check", false);
                try show(e, "update-install", false);
                return updateDone(e);
            }
            try ui.invoke(e, @intFromEnum(Ask.updater_check), "updater_check", .{});
        },
        .updater_check => {
            if (failed) return updateFailed(e);
            const parsed = try answer(ok, json);
            defer parsed.deinit();
            const available = boolOf(field(parsed.value, "available"));
            if (available) try setTextFmt(e, "update-status", "HollerShare {s} is available", .{str(field(parsed.value, "version")) orelse ""}) else try setTextFmt(e, "update-status", "HollerShare {s} · Up to date", .{s.update_version.items});
            try show(e, "update-install", available);
            try updateDone(e);
        },
        .updater_install => {
            s.update_busy = false;
            try disable(e, mid("update-install"), false);
            try disable(e, mid("update-check"), false);
            if (failed) return setTextFmt(e, "update-status", "Update failed: {s}", .{message.items});
            try setText(e, "update-status", "Update installed · Restart when your transfers are finished");
            try show(e, "update-install", false);
            try show(e, "update-restart", true);
            try show(e, "update-check", false);
            s.restart_ready = true;
        },
        .updater_restart => if (failed) try setText(e, "update-status", message.items),
        .quit => {},
    }
}

fn keepSettings(ok: bool, json: []const u8) !void {
    const parsed = try answer(ok, json);
    if (s.settings) |old| old.deinit();
    s.settings = parsed;
}

// --- Polling and the model ---------------------------------------------

fn poll(e: *ui.Engine) !void {
    if (s.polling) return;
    s.polling = true;
    errdefer s.polling = false;
    try ui.invoke(e, @intFromEnum(Ask.snapshot), "snapshot", .{});
}

fn model() ?std.json.Value {
    const m = s.model orelse return null;
    return dataOf(m.value);
}

fn renderModel(e: *ui.Engine) !void {
    const data = model() orelse return;
    if (s.poll_failed) {
        s.poll_failed = false;
        try show(e, "error", false);
    }
    const visible = boolOf(field(data, "visible"));
    try setText(e, "visibility", if (visible) "● Visible to nearby devices" else "○ Hidden from nearby devices");
    try Main.setState(&e.tree, main_id, "presence-off", !visible);
    try setTextFmt(e, "identity", "This computer · {s}", .{str(field(data, "name")) orelse ""});
    try renderDownloads(e);
    if (str(field(data, "error"))) |message| try showError(e, message);
    var peers: std.Io.Writer.Allocating = .init(s.gpa);
    defer peers.deinit();
    try std.json.Stringify.value(field(data, "peers") orelse .null, .{}, &peers.writer);
    if (!std.mem.eql(u8, peers.written(), s.previous_peers.items)) {
        try copyInto(&s.previous_peers, peers.written());
        try renderPeers(e);
    }
    var transfers: std.Io.Writer.Allocating = .init(s.gpa);
    defer transfers.deinit();
    try std.json.Stringify.value(.{ field(data, "transfers") orelse .null, field(data, "relocations") orelse .null }, .{}, &transfers.writer);
    if (!std.mem.eql(u8, transfers.written(), s.previous_transfers.items)) {
        try copyInto(&s.previous_transfers, transfers.written());
        try renderTransfers(e);
    }
}

/// Where received files go (the request card's and the footer's).
fn folderLabel(buf: []u8) []const u8 {
    if (s.android) {
        if (s.settings) |st| if (str(field(st.value, "download_folder"))) |folder| if (folder.len > 0) {
            return std.fmt.bufPrint(buf, "{s}{s}", .{ str(field(st.value, "download_folder_name")) orelse folder, if (boolOf(field(st.value, "folder_available"))) "" else " (unavailable)" }) catch folder;
        };
        return "HollerShare’s folder";
    }
    const data = model() orelse return "";
    return str(field(data, "download_dir")) orelse "";
}

fn renderDownloads(e: *ui.Engine) !void {
    if (model() == null) return;
    var buf: [1024]u8 = undefined;
    try setTextFmt(e, "downloads", "Save to {s}", .{folderLabel(&buf)});
}

// --- Files ---------------------------------------------------------------

fn readyToSend() bool {
    return if (s.text_mode) s.clipboard.items.len > 0 else s.files.items.len > 0;
}

fn addFile(path: []const u8, name: []const u8, size: u64) !void {
    for (s.files.items) |f| if (std.mem.eql(u8, f.path, path)) return;
    if (s.files.items.len == max_rows) return error.TooManyFiles;
    const p = try s.gpa.dupe(u8, path);
    errdefer s.gpa.free(p);
    try s.files.append(s.gpa, .{ .path = p, .name = try s.gpa.dupe(u8, name), .size = size });
}

fn clearFiles() void {
    for (s.files.items) |f| freeFile(f);
    s.files.clearRetainingCapacity();
}

/// `bytes(value)` of app.js.
fn bytes(buf: []u8, value: f64) []const u8 {
    if (value < 1024) return std.fmt.bufPrint(buf, "{d} B", .{@as(u64, @intFromFloat(@max(0, value)))}) catch "";
    const units = [_][]const u8{ "KB", "MB", "GB", "TB" };
    var v = value;
    var i: usize = 0;
    v /= 1024;
    while (v >= 1024 and i < units.len - 1) : (i += 1) v /= 1024;
    return (if (v < 10) std.fmt.bufPrint(buf, "{d:.1} {s}", .{ v, units[i] }) else std.fmt.bufPrint(buf, "{d:.0} {s}", .{ v, units[i] })) catch "";
}

fn setShareMode(e: *ui.Engine, text: bool) !void {
    s.text_mode = text;
    try show(e, "file-compose", !text);
    try show(e, "text-compose", text);
    try Main.setState(&e.tree, main_id, "text-mode", text);
    try renderFiles(e);
    try renderPeers(e);
}

fn renderFiles(e: *ui.Engine) !void {
    var ids: [max_rows]i64 = undefined;
    const count = @min(s.files.items.len, max_rows);
    for (s.files.items[0..count], 0..) |f, i| {
        const base = file_rows + @as(i64, @intCast(i)) * row_stride;
        var size: [32]u8 = undefined;
        _ = try FileRow.mount(&e.tree, base, styleOf(FileRow), &.{ .{ .name = "name", .value = f.name }, .{ .name = "size", .value = bytes(&size, @floatFromInt(f.size)) } });
        try disable(e, FileRow.id("remove", base), s.sending);
        try position(FileRow, e, base, i, count);
        ids[i] = base;
    }
    if (!try e.tree.stampKids(mid("file-list"), ids[0..count])) return error.InvalidTemplate;
    destroyRows(e, file_rows, count, s.file_count);
    s.file_count = count;
    try Main.setState(&e.tree, main_id, "has-files", count > 0);
    try show(e, "file-empty", count == 0);
    try show(e, "clear", !s.text_mode and count > 0);
    try setText(e, "choose", if (count > 0) "Add another file ＋" else "Choose files ＋");
    try disable(e, mid("manual-send"), !readyToSend() or s.sending or std.mem.trim(u8, s.address.items, " \t").len == 0);
}

// --- Peers ---------------------------------------------------------------

fn renderPeers(e: *ui.Engine) !void {
    const data = model();
    const list: []const std.json.Value = if (data) |d| (if (field(d, "peers")) |p| (if (p == .array) p.array.items else &.{}) else &.{}) else &.{};
    var ids: [max_rows]i64 = undefined;
    const count = @min(list.len, max_rows);
    for (list[0..count], 0..) |peer, i| {
        const base = peer_rows + @as(i64, @intCast(i)) * row_stride;
        const name = str(field(peer, "name")) orelse "";
        const shown = if (name.len > 0) name else "Nearby device";
        const rtype = str(field(peer, "rtype"));
        const id = str(field(peer, "id")) orelse "";
        const detail = try std.fmt.allocPrint(s.gpa, "{s} · {s}", .{ rtype orelse "Device", id });
        defer s.gpa.free(detail);
        const phone = rtype != null and std.mem.eql(u8, rtype.?, "Phone");
        _ = try PeerRow.mount(&e.tree, base, styleOf(PeerRow), &.{ .{ .name = "icon", .value = if (phone) "▯" else "▱" }, .{ .name = "name", .value = shown }, .{ .name = "detail", .value = detail } });
        try disable(e, PeerRow.id("send", base), !readyToSend() or s.sending);
        try position(PeerRow, e, base, i, count);
        try copyInto(&s.peer_ids[i][0], id);
        try copyInto(&s.peer_ids[i][1], shown);
        ids[i] = base;
    }
    if (!try e.tree.stampKids(mid("peers"), ids[0..count])) return error.InvalidTemplate;
    destroyRows(e, peer_rows, count, s.peer_count);
    s.peer_count = count;
    try Main.setState(&e.tree, main_id, "has-peers", count > 0);
    try show(e, "peer-empty", count == 0);
    var buf: [16]u8 = undefined;
    try setText(e, "peer-count", try std.fmt.bufPrint(&buf, "{d}", .{list.len}));
}

fn send(e: *ui.Engine, address: []const u8, name: []const u8) !void {
    if (!readyToSend() or s.sending) return;
    s.sending = true;
    inline for (.{ "choose", "clear", "clipboard-text", "mode-files", "mode-text", "read-clipboard" }) |n| try disable(e, mid(n), true);
    try renderFiles(e);
    try renderPeers(e);
    if (s.text_mode) {
        try ui.invoke(e, @intFromEnum(Ask.send), "send_text", .{ .address = address, .name = name, .text = s.clipboard.items });
    } else {
        var paths: [max_rows][]const u8 = undefined;
        for (s.files.items, 0..) |f, i| paths[i] = f.path;
        try ui.invoke(e, @intFromEnum(Ask.send), "send_files", .{ .address = address, .name = name, .paths = paths[0..s.files.items.len] });
    }
}

// --- Transfers -------------------------------------------------------------

fn stateName(state: []const u8) []const u8 {
    for (state_names) |n| if (std.mem.eql(u8, n[0], state)) return n[1];
    return "Connecting securely";
}

fn isTerminal(state: []const u8) bool {
    for (terminal) |t| if (std.mem.eql(u8, t, state)) return true;
    return false;
}

fn basename(path: []const u8) []const u8 {
    const at = std.mem.lastIndexOfAny(u8, path, "/\\") orelse return path;
    return path[at + 1 ..];
}

/// A transfer's names, as the page shows them.
fn namesOf(buf: *std.ArrayList(u8), meta: std.json.Value, state: []const u8) ![]const u8 {
    buf.clearRetainingCapacity();
    if (field(meta, "files")) |f| if (f == .array and f.array.items.len > 0) {
        for (f.array.items, 0..) |name, i| {
            if (i > 0) try buf.appendSlice(s.gpa, ", ");
            try buf.appendSlice(s.gpa, basename(str(name) orelse ""));
        }
        return buf.items;
    };
    if (str(field(meta, "text_description"))) |d| if (d.len > 0) return d;
    const no_files = field(meta, "files") == null or field(meta, "files").? == .null;
    if (no_files and (std.mem.eql(u8, state, "WaitingForUserConsent") or std.mem.eql(u8, state, "Finished"))) return "Clipboard text";
    return "Preparing transfer";
}

fn renderTransfers(e: *ui.Engine) !void {
    const data = model() orelse return;
    const all: []const std.json.Value = if (field(data, "transfers")) |t| (if (t == .array) t.array.items else &.{}) else &.{};
    var request_ids: [max_rows]i64 = undefined;
    var requests: usize = 0;
    var row_ids: [max_rows]i64 = undefined;
    var rows: usize = 0;
    var names_buf: std.ArrayList(u8) = .empty;
    defer names_buf.deinit(s.gpa);
    var folder_buf: [1024]u8 = undefined;
    var i: usize = all.len;
    // Newest first.
    while (i > 0 and rows < max_rows) {
        i -= 1;
        const t = all[i];
        const meta = field(t, "meta") orelse std.json.Value{ .object = .empty };
        const state = str(field(t, "state")) orelse "";
        const incoming = std.mem.eql(u8, str(field(t, "rtype")) orelse "", "Inbound");
        const source = field(meta, "source");
        const peer = if (source) |src| str(field(src, "name")) orelse "Nearby device" else "Nearby device";
        const names = try namesOf(&names_buf, meta, state);
        var size_buf: [32]u8 = undefined;
        const size = bytes(&size_buf, num(field(meta, "total_bytes")));
        const id = str(field(t, "id")) orelse "";
        const done = isTerminal(state);
        const is_text = field(meta, "files") == null or field(meta, "files").? == .null;
        if (incoming and std.mem.eql(u8, state, "WaitingForUserConsent") and requests < max_rows) {
            const base = request_rows + @as(i64, @intCast(requests)) * row_stride;
            const title = try std.fmt.allocPrint(s.gpa, "{s} wants to share", .{peer});
            defer s.gpa.free(title);
            const summary = try std.fmt.allocPrint(s.gpa, "{s} · {s}", .{ names, size });
            defer s.gpa.free(summary);
            const pin = str(field(meta, "pin_code")) orelse "—";
            if (s.request_text[requests] != is_text) e.tree.destroy(base);
            s.request_text[requests] = is_text;
            if (is_text) {
                _ = try RequestText.mount(&e.tree, base, styleOf(RequestText), &.{ .{ .name = "title", .value = title }, .{ .name = "summary", .value = summary }, .{ .name = "pin", .value = pin } });
            } else {
                const folder = try std.fmt.allocPrint(s.gpa, "{s}{s}", .{ if (s.android) "Saves to " else "Default folder · ", folderLabel(&folder_buf) });
                defer s.gpa.free(folder);
                _ = try Request.mount(&e.tree, base, styleOf(Request), &.{ .{ .name = "title", .value = title }, .{ .name = "summary", .value = summary }, .{ .name = "pin", .value = pin }, .{ .name = "folder", .value = folder } });
                try display(e, Request.id("choose-folder", base), !s.android);
            }
            try copyInto(&s.request_ids[requests], id);
            request_ids[requests] = base;
            requests += 1;
        }
        const slot = rows;
        const base = transfer_rows + @as(i64, @intCast(slot)) * row_stride;
        const detail = try std.fmt.allocPrint(s.gpa, "{s}{s} · {s}", .{ if (incoming) "From " else "Sending", if (incoming) peer else "", size });
        defer s.gpa.free(detail);
        const status = stateName(state);
        const text_payload = str(field(meta, "text_payload"));
        const finished = std.mem.eql(u8, state, "Finished");
        const paths_value = if (incoming) field(meta, "saved_files") else field(meta, "files");
        const paths: []const std.json.Value = if (paths_value) |p| (if (p == .array) p.array.items else &.{}) else &.{};
        const kind: RowKind = if (!done) .active else if (finished and text_payload != null) .text else if (finished and !s.android and paths.len > 0) .done else .ended;
        if (s.transfer_kinds[slot] != kind) {
            destroyRows(e, open_rows + @as(i64, @intCast(slot)) * max_open * row_stride, 0, s.open_counts[slot]);
            s.open_counts[slot] = 0;
            e.tree.destroy(base);
        }
        s.transfer_kinds[slot] = kind;
        try copyInto(&s.transfer_ids[slot], id);
        switch (kind) {
            .active => {
                const code = try std.fmt.allocPrint(s.gpa, "Code {s}", .{str(field(meta, "pin_code")) orelse ""});
                defer s.gpa.free(code);
                _ = try TransferActive.mount(&e.tree, base, styleOf(TransferActive), &.{ .{ .name = "name", .value = names }, .{ .name = "detail", .value = detail }, .{ .name = "status", .value = status }, .{ .name = "code", .value = code } });
                try display(e, TransferActive.id("code", base), str(field(meta, "pin_code")) != null and !incoming);
                const total = num(field(meta, "total_bytes"));
                const pct: f32 = @floatCast(@min(100, if (total > 0) num(field(meta, "ack_bytes")) / total * 100 else 0));
                const fill = TransferActive.id("fill", base);
                var props = e.tree.get(fill).?.props;
                props.w = .{ .pct = pct };
                try e.tree.updateUiProps(fill, props);
            },
            .text => {
                // app.js: a received transfer with saved_files (a text's is
                // empty) has its actions' row, and where it was saved.
                const saved = if (incoming) str(field(meta, "destination")) else null;
                const saved_text = try std.fmt.allocPrint(s.gpa, "Saved in {s}", .{saved orelse ""});
                defer s.gpa.free(saved_text);
                _ = try TransferText.mount(&e.tree, base, styleOf(TransferText), &.{ .{ .name = "name", .value = names }, .{ .name = "detail", .value = detail }, .{ .name = "status", .value = status }, .{ .name = "text", .value = text_payload.? }, .{ .name = "copy-label", .value = "Copy text" }, .{ .name = "saved", .value = saved_text } });
                const has_actions = !s.android and paths_value != null and paths_value.? == .array;
                try display(e, TransferText.id("actions", base), has_actions);
                try display(e, TransferText.id("saved", base), has_actions and saved != null);
            },
            .done => {
                const saved = if (incoming) str(field(meta, "destination")) else null;
                const saved_text = try std.fmt.allocPrint(s.gpa, "Saved in {s}", .{saved orelse ""});
                defer s.gpa.free(saved_text);
                const open_label = try std.fmt.allocPrint(s.gpa, "Open {s}", .{basename(str(paths[0]) orelse "")});
                defer s.gpa.free(open_label);
                _ = try TransferDone.mount(&e.tree, base, styleOf(TransferDone), &.{ .{ .name = "name", .value = names }, .{ .name = "detail", .value = detail }, .{ .name = "status", .value = status }, .{ .name = "saved", .value = saved_text }, .{ .name = "open-label", .value = if (paths.len == 1) "Open file" else open_label } });
                try display(e, TransferDone.id("saved", base), saved != null);
                try openButtons(e, slot, base, paths);
            },
            .ended => _ = try TransferEnded.mount(&e.tree, base, styleOf(TransferEnded), &.{ .{ .name = "name", .value = names }, .{ .name = "detail", .value = detail }, .{ .name = "status", .value = status } }),
            .none => unreachable,
        }
        row_ids[rows] = base;
        rows += 1;
    }
    for (request_ids[0..requests], 0..) |base, r| {
        if (s.request_text[r].?) try position(RequestText, e, base, r, requests) else try position(Request, e, base, r, requests);
    }
    for (row_ids[0..rows], 0..) |base, r| switch (s.transfer_kinds[r]) {
        .active => try position(TransferActive, e, base, r, rows),
        .done => try position(TransferDone, e, base, r, rows),
        .text => try position(TransferText, e, base, r, rows),
        .ended => try position(TransferEnded, e, base, r, rows),
        .none => {},
    };
    try Main.setState(&e.tree, main_id, "has-requests", requests > 0);
    try Main.setState(&e.tree, main_id, "has-transfers", rows > 0);
    if (!try e.tree.stampKids(mid("requests"), request_ids[0..requests])) return error.InvalidTemplate;
    destroyRows(e, request_rows, requests, s.request_count);
    for (requests..@max(requests, s.request_count)) |r| s.request_text[r] = null;
    s.request_count = requests;
    if (rows == 0) {
        row_ids[0] = mid("activity-empty");
        e.tree.get(mid("activity-empty")).?.stamp_owned = false;
    }
    if (!try e.tree.stampKids(mid("transfers"), row_ids[0..@max(rows, 1)])) return error.InvalidTemplate;
    destroyRows(e, transfer_rows, rows, s.transfer_count);
    for (rows..@max(rows, s.transfer_count)) |r| s.transfer_kinds[r] = .none;
    s.transfer_count = rows;
}

/// A button's label: its text (a button with only text is one).
fn setLabel(e: *ui.Engine, id: i64, value: []const u8) !void {
    const n = e.tree.get(id) orelse return;
    const text = if (n.kind == .text) n else if (n.kids.items.len > 0 and n.kids.items[0].kind == .text) n.kids.items[0] else return;
    if (!try e.tree.updateText(text.id, value)) return error.InvalidTextNode;
}

/// A finished transfer's "Open …" buttons (one per file when there are
/// several), then "Open folder".
fn openButtons(e: *ui.Engine, slot: usize, base: i64, paths: []const std.json.Value) !void {
    const actions = TransferDone.id("actions", base);
    const open = TransferDone.id("open", base);
    const folder = TransferDone.id("open-folder", base);
    const old = s.open_counts[slot];
    const first = open_rows + @as(i64, @intCast(slot)) * max_open * row_stride;
    if (paths.len <= 1) {
        destroyRows(e, first, 0, old);
        s.open_counts[slot] = 0;
        return;
    }
    var ids: [max_open + 1]i64 = undefined;
    const count = @min(paths.len, max_open);
    for (paths[0..count], 0..) |p, j| {
        const ob = open_rows + (@as(i64, @intCast(slot)) * max_open + @as(i64, @intCast(j))) * row_stride;
        const label = try std.fmt.allocPrint(s.gpa, "Open {s}", .{basename(str(p) orelse "")});
        defer s.gpa.free(label);
        _ = try OpenButton.mount(&e.tree, ob, styleOf(OpenButton), &.{.{ .name = "label", .value = label }});
        try position(OpenButton, e, ob, j, count);
        ids[j] = ob;
    }
    ids[count] = folder;
    e.tree.get(folder).?.stamp_owned = false;
    e.tree.get(open).?.stamp_owned = false;
    if (!try e.tree.stampKids(actions, ids[0 .. count + 1])) return error.InvalidTemplate;
    destroyRows(e, first, count, old);
    s.open_counts[slot] = count;
}

// --- Settings ------------------------------------------------------------

fn fieldError(e: *ui.Engine, comptime id: []const u8, message: []const u8) !void {
    try setText(e, id, message);
    try show(e, id, message.len > 0);
}

fn settingsDisabled(e: *ui.Engine, on: bool) !void {
    inline for (.{ "settings-save", "settings-reset", "download-browse", "download-default" }) |n| try disable(e, mid(n), on);
}

fn renderSettings(e: *ui.Engine) !void {
    const st = (s.settings orelse return).value;
    const name = str(field(st, "device_name")) orelse "";
    try copyInto(&s.device_name, name);
    try setValue(e, mid("device-name"), name);
    const system = str(field(st, "system_name")) orelse "";
    try setPlaceholder(e, mid("device-name"), if (system.len > 0) system else "This device");
    try renderFolder(e);
}

fn renderFolder(e: *ui.Engine) !void {
    const st = (s.settings orelse return).value;
    const folder = str(field(st, "download_folder")) orelse "";
    const chosen = folder.len > 0;
    const available = boolOf(field(st, "folder_available"));
    const android = boolOf(field(st, "android"));
    try setText(e, "download-name", if (chosen) str(field(st, "download_folder_name")) orelse folder else if (s.android) "HollerShare’s folder" else "Default folder");
    const detail: []const u8 = if (chosen and !available) "Unavailable · HollerShare can’t save here any more. Choose the folder again, or use the default folder." else if (chosen) (if (android) "Finished transfers move here" else folder) else if (model()) |d| str(field(d, "download_dir")) orelse "" else "";
    try setText(e, "download-detail", detail);
    try show(e, "download-detail", detail.len > 0);
    try Main.setState(&e.tree, main_id, "unavailable", chosen and !available);
    try show(e, "download-browse", boolOf(field(st, "folder_picker")));
    // An inline button (a run of the help line): shown by its label.
    try setText(e, "download-default", if (chosen) "Use default folder" else "");
    try setText(e, "download-help-text", if (android) (if (chosen) "HollerShare receives into its own folder, then moves each finished transfer here." else "Received files stay in HollerShare’s own folder. Choose a folder to move them somewhere you can find them.") else "New transfers are saved here.");
    try renderDownloads(e);
}

/// The same rules as src/settings.zig: up to 64 characters, no control
/// characters.
fn nameProblem(name: []const u8) []const u8 {
    var chars: usize = 0;
    var view = std.unicode.Utf8View.init(name) catch return "Use a shorter name (up to 64 characters)";
    var it = view.iterator();
    while (it.nextCodepoint()) |c| {
        if (c < 0x20 or (c >= 0x7f and c <= 0x9f)) return "The name can't contain control characters";
        chars += 1;
    }
    if (chars > 64 or name.len > 170) return "Use a shorter name (up to 64 characters)";
    return "";
}

fn openSettings(e: *ui.Engine) !void {
    s.settings_open = true;
    try show(e, "settings", true);
    try Main.setState(&e.tree, main_id, "settings-open", true);
    try fieldError(e, "device-name-error", "");
    try fieldError(e, "download-dir-error", "");
    try setText(e, "settings-status", "");
    try ui.invoke(e, @intFromEnum(Ask.settings_open), "settings_get", .{});
}

fn closeSettings(e: *ui.Engine) !void {
    s.settings_open = false;
    try show(e, "settings", false);
    try Main.setState(&e.tree, main_id, "settings-open", false);
}

fn saveSettings(e: *ui.Engine, name: []const u8, default_folder: bool) !void {
    if (s.settings_busy) return;
    try fieldError(e, "device-name-error", "");
    try fieldError(e, "download-dir-error", "");
    try setText(e, "settings-status", "");
    const problem = nameProblem(std.mem.trim(u8, name, " \t\r\n"));
    if (problem.len > 0) return fieldError(e, "device-name-error", problem);
    s.settings_busy = true;
    try settingsDisabled(e, true);
    try ui.invoke(e, @intFromEnum(Ask.settings_save), "settings_save", .{ .device_name = name, .default_folder = default_folder });
}

fn changeFolder(e: *ui.Engine, choose: bool) !void {
    if (s.settings_busy) return;
    try fieldError(e, "download-dir-error", "");
    try setText(e, "settings-status", "");
    s.settings_busy = true;
    try settingsDisabled(e, true);
    try copyInto(&s.folder_before, if (s.settings) |st| str(field(st.value, "download_folder")) orelse "" else "");
    try ui.invoke(e, @intFromEnum(Ask.settings_folder), "settings_folder", .{ .choose = choose });
}

// --- Updates -------------------------------------------------------------

fn checkUpdates(e: *ui.Engine) !void {
    if (s.update_busy or s.restart_ready) return;
    s.update_busy = true;
    try disable(e, mid("update-check"), true);
    try setText(e, "update-status", "Checking for updates…");
    try ui.invoke(e, @intFromEnum(Ask.update_info), "update_info", .{});
}

fn updateDone(e: *ui.Engine) !void {
    s.update_busy = false;
    try disable(e, mid("update-check"), false);
}

fn updateFailed(e: *ui.Engine) !void {
    try setText(e, "update-status", "Updates unavailable · Try again later");
    try updateDone(e);
}

fn activeTransfers() bool {
    const data = model() orelse return false;
    const all = field(data, "transfers") orelse return false;
    if (all != .array) return false;
    for (all.array.items) |t| if (!isTerminal(str(field(t, "state")) orelse "")) return true;
    return false;
}

// --- Theme and shares ------------------------------------------------------

/// The desktop's appearance (system_info, system_theme): the views' dark
/// blocks, as the page's data-theme.
fn setTheme(e: *ui.Engine, dark: bool) !void {
    try e.setColorScheme(dark);
}

fn applySharePayload(e: *ui.Engine, value: std.json.Value) !void {
    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |p| p.deinit();
    var payload = value;
    if (payload == .string) {
        parsed = std.json.parseFromSlice(std.json.Value, s.gpa, payload.string, .{}) catch return;
        payload = parsed.?.value;
    }
    const mode = str(field(payload, "mode")) orelse return;
    if (std.mem.eql(u8, mode, "text")) {
        const text = str(field(payload, "text")) orelse "";
        try copyInto(&s.clipboard, text);
        try setValue(e, mid("clipboard-text"), text);
        try setShareMode(e, true);
    } else if (std.mem.eql(u8, mode, "files")) {
        const list = field(payload, "files") orelse return;
        if (list != .array or list.array.items.len == 0) return;
        for (list.array.items) |f| try addFile(str(field(f, "path")) orelse continue, str(field(f, "name")) orelse "", @intFromFloat(num(field(f, "size"))));
        try setShareMode(e, false);
    }
}

// --- Events ---------------------------------------------------------------

fn event(e: *ui.Engine, id: i64, kind: []const u8, data: []const u8) bool {
    return handleEvent(e, id, kind, data) catch |err| {
        std.log.err("HollerShare UI: {s}", .{@errorName(err)});
        return true;
    };
}

fn handleEvent(e: *ui.Engine, id: i64, kind: []const u8, data: []const u8) !bool {
    const eq = std.mem.eql;
    if (eq(u8, kind, "message")) return appEvent(e, data);
    if (eq(u8, kind, "input")) {
        const value = std.json.parseFromSlice([]const u8, s.gpa, data, .{}) catch return false;
        defer value.deinit();
        if (id == mid("clipboard-text")) {
            try copyInto(&s.clipboard, value.value);
            try renderFiles(e);
            try renderPeers(e);
        } else if (id == mid("address")) {
            try copyInto(&s.address, value.value);
            try disable(e, mid("manual-send"), !readyToSend() or s.sending or std.mem.trim(u8, value.value, " \t").len == 0);
        } else if (id == mid("device-name")) {
            try copyInto(&s.device_name, value.value);
            const problem = nameProblem(std.mem.trim(u8, value.value, " \t\r\n"));
            try fieldError(e, "device-name-error", problem);
        }
        return false;
    }
    if (!eq(u8, kind, "click")) return false;
    // A disabled button does nothing.
    var node = e.tree.get(id);
    var depth: usize = 0;
    while (node) |n| : (depth += 1) {
        if (n.props.dis or depth > 64) return true;
        node = n.parent;
    }
    if (within(e, id, mid("mode-files"))) return clicked(setShareMode(e, false));
    if (within(e, id, mid("mode-text"))) return clicked(setShareMode(e, true));
    if (within(e, id, mid("read-clipboard"))) {
        try setShareMode(e, true);
        try disable(e, mid("read-clipboard"), true);
        try ui.invoke(e, @intFromEnum(Ask.read_clipboard), "read_clipboard", .{});
        return true;
    }
    if (within(e, id, mid("choose"))) return clicked(chooseFiles(e));
    if (within(e, id, mid("clear"))) {
        clearFiles();
        try renderFiles(e);
        try renderPeers(e);
        return true;
    }
    if (within(e, id, mid("manual-send"))) return clicked(send(e, std.mem.trim(u8, s.address.items, " \t"), "Nearby device"));
    if (within(e, id, mid("visibility"))) {
        const data_model = model() orelse return true;
        try disable(e, mid("visibility"), true);
        try ui.invoke(e, @intFromEnum(Ask.visibility), "visibility", .{ .visible = !boolOf(field(data_model, "visible")) });
        return true;
    }
    if (within(e, id, mid("settings-open"))) return clicked(if (s.settings_open) closeSettings(e) else openSettings(e));
    if (within(e, id, mid("settings-close"))) return clicked(closeSettings(e));
    if (within(e, id, mid("settings-save"))) return clicked(saveSettings(e, s.device_name.items, false));
    if (within(e, id, mid("settings-reset"))) return clicked(saveSettings(e, "", true));
    if (within(e, id, mid("download-default"))) return clicked(changeFolder(e, false));
    if (within(e, id, mid("download-browse"))) return clicked(changeFolder(e, true));
    if (within(e, id, mid("privacy-open"))) {
        try show(e, "privacy-policy", true);
        e.tree.layout();
        if (e.tree.get(mid("privacy-policy"))) |n| e.tree.scrollIntoView(n, "start");
        if (e.tree.get(mid("privacy-close"))) |n| e.backend.focus(e.backend.ctx, n);
        return true;
    }
    if (within(e, id, mid("privacy-close"))) {
        try show(e, "privacy-policy", false);
        e.tree.layout();
        if (e.tree.get(mid("privacy-open"))) |n| {
            e.tree.scrollIntoView(n, "nearest");
            e.backend.focus(e.backend.ctx, n);
        }
        return true;
    }
    if (within(e, id, mid("quit"))) return clicked(ui.invoke(e, @intFromEnum(Ask.quit), "quit", .{}));
    if (within(e, id, mid("update-check"))) return clicked(checkUpdates(e));
    if (within(e, id, mid("update-install"))) {
        if (s.update_busy) return true;
        if (activeTransfers()) return clicked(setText(e, "update-status", "Finish or cancel your transfers before updating"));
        s.update_busy = true;
        try disable(e, mid("update-install"), true);
        try disable(e, mid("update-check"), true);
        try setText(e, "update-status", "Downloading and verifying update…");
        try ui.invoke(e, @intFromEnum(Ask.updater_install), "updater_install", .{});
        return true;
    }
    if (within(e, id, mid("update-restart"))) {
        if (activeTransfers()) return clicked(setText(e, "update-status", "Finish or cancel your transfers before restarting"));
        try ui.invoke(e, @intFromEnum(Ask.updater_restart), "updater_restart", .{});
        return true;
    }
    // The lists' rows.
    for (0..s.file_count) |i| {
        const base = file_rows + @as(i64, @intCast(i)) * row_stride;
        if (within(e, id, FileRow.id("remove", base))) {
            const f = s.files.orderedRemove(i);
            freeFile(f);
            try renderFiles(e);
            try renderPeers(e);
            return true;
        }
    }
    for (0..s.peer_count) |i| {
        const base = peer_rows + @as(i64, @intCast(i)) * row_stride;
        if (within(e, id, PeerRow.id("send", base))) {
            const address = try s.gpa.dupe(u8, s.peer_ids[i][0].items);
            defer s.gpa.free(address);
            const name = try s.gpa.dupe(u8, s.peer_ids[i][1].items);
            defer s.gpa.free(name);
            try send(e, address, name);
            return true;
        }
    }
    for (0..s.request_count) |i| {
        const base = request_rows + @as(i64, @intCast(i)) * row_stride;
        const tid = s.request_ids[i].items;
        const text = s.request_text[i] orelse continue;
        const accept = if (text) RequestText.id("accept", base) else Request.id("accept", base);
        const decline = if (text) RequestText.id("decline", base) else Request.id("decline", base);
        if (within(e, id, accept)) return clicked(ui.invoke(e, @intFromEnum(Ask.decide), "decide", .{ .id = tid, .accept = true }));
        if (within(e, id, decline)) return clicked(ui.invoke(e, @intFromEnum(Ask.decide), "decide", .{ .id = tid, .accept = false }));
        if (!text and within(e, id, Request.id("choose-folder", base))) {
            try copyInto(&s.pending_decision, tid);
            try ui.invoke(e, @intFromEnum(Ask.decide_folder), "select_folder", .{});
            return true;
        }
    }
    for (0..s.transfer_count) |slot| {
        const base = transfer_rows + @as(i64, @intCast(slot)) * row_stride;
        const tid = s.transfer_ids[slot].items;
        switch (s.transfer_kinds[slot]) {
            .active => if (within(e, id, TransferActive.id("cancel", base))) return clicked(ui.invoke(e, @intFromEnum(Ask.cancel), "cancel", .{ .id = tid })),
            .text => if (within(e, id, TransferText.id("copy", base))) {
                s.copied_slot = slot;
                return clicked(ui.invoke(e, @intFromEnum(Ask.copy_transfer), "copy_transfer", .{ .id = tid }));
            },
            .done => {
                if (within(e, id, TransferDone.id("open", base))) return clicked(ui.invoke(e, @intFromEnum(Ask.open_transfer), "open_transfer", .{ .id = tid, .index = @as(usize, 0), .folder = false }));
                if (within(e, id, TransferDone.id("open-folder", base))) return clicked(ui.invoke(e, @intFromEnum(Ask.open_transfer), "open_transfer", .{ .id = tid, .index = @as(usize, 0), .folder = true }));
                for (0..s.open_counts[slot]) |j| {
                    const ob = open_rows + (@as(i64, @intCast(slot)) * max_open + @as(i64, @intCast(j))) * row_stride;
                    if (within(e, id, ob)) return clicked(ui.invoke(e, @intFromEnum(Ask.open_transfer), "open_transfer", .{ .id = tid, .index = j, .folder = false }));
                }
            },
            else => {},
        }
    }
    return false;
}

fn clicked(result: anyerror!void) !bool {
    try result;
    return true;
}

fn chooseFiles(e: *ui.Engine) !void {
    try disable(e, mid("choose"), true);
    try ui.invoke(e, @intFromEnum(Ask.select_file), "select_file", .{});
}

fn pasteClipboard(e: *ui.Engine) !void {
    try setShareMode(e, true);
    try disable(e, mid("read-clipboard"), true);
    try ui.invoke(e, @intFromEnum(Ask.read_clipboard), "read_clipboard", .{});
}

/// The app's events (main.zig Events), as the page's oriel.listen.
fn appEvent(e: *ui.Engine, data: []const u8) !bool {
    const parsed = std.json.parseFromSlice(std.json.Value, s.gpa, data, .{}) catch return false;
    defer parsed.deinit();
    const name = str(field(parsed.value, "__oriel_event")) orelse return false;
    const payload = field(parsed.value, "payload") orelse .null;
    const eq = std.mem.eql;
    if (eq(u8, name, "system_theme")) {
        s.theme_event = true;
        if (field(payload, "dark")) |d| if (d == .bool) try setTheme(e, d.bool);
    } else if (eq(u8, name, "share_target")) {
        try applySharePayload(e, payload);
    } else if (eq(u8, name, "tray_send")) {
        try setShareMode(e, false);
        try chooseFiles(e);
    } else if (eq(u8, name, "tray_clipboard")) {
        try pasteClipboard(e);
    } else if (eq(u8, name, "tray_visibility") or eq(u8, name, "review_request")) {
        try poll(e);
    } else if (eq(u8, name, "tray_update")) {
        try checkUpdates(e);
    } else if (eq(u8, name, "notification_error")) {
        try showError(e, str(payload) orelse "");
    } else if (eq(u8, name, "folder_error")) {
        try showError(e, str(payload) orelse "");
        if (s.settings) |*st| if (st.value == .object) {
            try st.value.object.put(st.arena.allocator(), "folder_available", .{ .bool = false });
            try renderFolder(e);
        };
    }
    return true;
}

// --- Drag and drop onto the "Choose what to share" card -------------------

/// ["enter"|"over"|"leave"|"drop", x, y, allowed, suggested, mods,
/// session, items]: files and text are taken (a copy) over the files panel.
fn drag(e: *ui.Engine, id: i64, data: []const u8) u8 {
    return handleDrag(e, id, data) catch |err| {
        std.log.err("HollerShare drop: {s}", .{@errorName(err)});
        return 0;
    };
}

fn handleDrag(e: *ui.Engine, id: i64, data: []const u8) !u8 {
    const parsed = try std.json.parseFromSlice(std.json.Value, s.gpa, data, .{});
    defer parsed.deinit();
    if (parsed.value != .array or parsed.value.array.items.len == 0) return 0;
    const items = parsed.value.array.items;
    const kind = str(items[0]) orelse return 0;
    const over_panel = within(e, id, filesPanel(e));
    const eq = std.mem.eql;
    if (eq(u8, kind, "leave") or !over_panel) {
        try dropHover(e, false);
        return 0;
    }
    if (!eq(u8, kind, "drop")) {
        try dropHover(e, true);
        return 1;
    }
    try dropHover(e, false);
    const list: []const std.json.Value = if (items.len > 7 and items[7] == .array) items[7].array.items else &.{};
    var added: usize = 0;
    var lost: usize = 0;
    var files: usize = 0;
    var text: ?[]const u8 = null;
    for (list) |item| {
        if (item != .array or item.array.items.len < 3) continue;
        const what = str(item.array.items[0]) orelse continue;
        if (eq(u8, what, "file") and item.array.items.len >= 6) {
            files += 1;
            const name = str(item.array.items[2]) orelse "a file";
            const size: u64 = @intFromFloat(@max(0, num(item.array.items[3])));
            const handle: u32 = @intFromFloat(@max(0, num(item.array.items[5])));
            const path = e.drops.nativePath(s.gpa, handle) catch {
                lost += 1;
                continue;
            };
            defer s.gpa.free(path);
            try addFile(path, if (name.len > 0) name else basename(path), size);
            added += 1;
        } else if (eq(u8, what, "string") and text == null) {
            if (eq(u8, str(item.array.items[1]) orelse "", "text/plain")) text = str(item.array.items[2]);
        }
    }
    if (files == 0) {
        const t = text orelse return 0;
        try copyInto(&s.clipboard, t);
        try setValue(e, mid("clipboard-text"), t);
        try setShareMode(e, true);
        return 1;
    }
    if (added > 0) {
        try setShareMode(e, false);
        try show(e, "error", false);
    }
    if (lost > 0) {
        if (lost == files) try showError(e, "These files can't be shared from where they came from.") else if (added > 0) try setTextFmt(e, "error", "{d} of the dropped files can't be shared from where they came from.", .{lost}) else try showError(e, "The dropped file can't be shared from where it came from.");
        try show(e, "error", true);
    }
    try renderFiles(e);
    try renderPeers(e);
    return 1;
}

/// The files panel: the section around the file chooser.
fn filesPanel(e: *ui.Engine) i64 {
    var node = e.tree.get(mid("file-compose"));
    // file-compose → the panel (its parent).
    if (node) |n| node = n.parent;
    return if (node) |n| n.id else 0;
}

fn dropHover(e: *ui.Engine, on: bool) !void {
    if (s.drop_hover == on) return;
    s.drop_hover = on;
    try Main.setState(&e.tree, main_id, "drop-hover", on);
}
