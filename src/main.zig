const std = @import("std");
const oriel = @import("oriel");
const builtin = @import("builtin");
const desktop_linux = builtin.os.tag == .linux and builtin.abi != .android;
const android = builtin.abi == .android;
/// Where oriel.dialog.openFolder works: every desktop and Android.
const folder_picker = builtin.os.tag != .ios;
const app = @import("oriel_app");
const updates = @import("updates.zig");
const cli = @import("cli.zig");
const settings = @import("settings.zig");
const android_multicast = if (builtin.abi == .android) @import("android_multicast.zig") else struct {
    pub fn acquire() void {}
    pub fn release() void {}
};
const android_beacon = if (builtin.abi == .android) @import("android_beacon.zig") else struct {
    pub fn start() void {}
    pub fn stop() void {}
};

pub const std_options: std.Options = .{ .logFn = oriel.log.logFn };
extern fn ghostshare_start(directory: [*:0]const u8) ?[*:0]u8;
extern fn ghostshare_request(request: [*:0]const u8) ?[*:0]u8;
extern fn ghostshare_free(pointer: [*:0]u8) void;
extern fn ghostshare_stop() void;
extern fn ghostshare_set_device_name(name: ?[*:0]const u8) void;
extern fn ghostshare_set_event_callback(callback: ?*const fn ([*:0]const u8) callconv(.c) void) void;
extern fn ghostshare_desktop_init(application: ?*anyopaque, window: ?*anyopaque) void;
extern fn ghostshare_desktop_cleanup() void;
extern fn ghostshare_desktop_dark() c_int;
extern fn ghostshare_desktop_quit() void;
extern fn ghostshare_desktop_notify(id: [*:0]const u8, kind: [*:0]const u8, name: [*:0]const u8, pin: [*:0]const u8, text: c_int) void;
extern fn ghostshare_open_path(path: [*:0]const u8) c_int;
var tray: ?*oriel.tray.Tray = null;
var startup_error: ?[]const u8 = null;
/// Where received files go: set by `main` before `start_engine`.
var engine_directory: [:0]const u8 = "";
/// The platform's default download folder, as `ghostshare_start` takes it:
/// "" on desktop (the engine's default), `<external files>/Received` on Android.
var default_directory: [:0]const u8 = "";
const app_id = "dev.ghostshare.App";
var app_io: std.Io = undefined;
/// The app's data directory, where settings.json lives (null: unavailable).
var data_dir: ?[]const u8 = null;
/// The saved settings (strings owned by `smp_allocator`), under `settings_lock`.
var saved_settings: settings.Settings = .{};
var settings_lock: std.Io.Mutex = .init;
var device_visible: std.atomic.Value(bool) = .init(true);
/// The download folder in Settings can't be used any more (Android: the
/// grant was revoked or the folder is gone; desktop: the folder is gone):
/// the page asks the user to choose again. Cleared by a new choice.
var folder_unavailable: std.atomic.Value(bool) = .init(false);

const ClipboardText = struct { text: []const u8 };
const FileSelection = struct { path: []const u8, name: []const u8, size: u64 };
fn request_json(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    const terminated = try allocator.dupeZ(u8, json);
    defer allocator.free(terminated);
    const response = ghostshare_request(terminated) orelse return error.QuickShareUnavailable;
    defer ghostshare_free(response);
    return allocator.dupe(u8, std.mem.span(response));
}
pub const Events = struct {
    system_theme: struct { dark: bool },
    tray_send: bool,
    tray_clipboard: bool,
    tray_visibility: bool,
    tray_update: bool,
    notification_error: []const u8,
    review_request: struct { id: []const u8 },
    /// Received files couldn't be saved to the folder chosen in Settings.
    folder_error: []const u8,
};
fn show_window() void {
    oriel.App.showWindow();
    if (oriel.App.getWindow("main")) |window| window.focus();
}
fn tray_menu(id: []const u8, checked: ?bool) void {
    if (std.mem.eql(u8, id, "visible")) {
        oriel.App.spawn(tray_set_visibility, .{checked orelse !device_visible.load(.acquire)}) catch {
            oriel.App.runOnMain({}, sync_tray_visibility);
        };
        return;
    }
    if (std.mem.eql(u8, id, "quit")) {
        request_quit();
        return;
    }
    show_window();
    if (std.mem.eql(u8, id, "updates")) oriel.App.events(Events).emit(.tray_update, true);
    if (std.mem.eql(u8, id, "clipboard")) oriel.App.events(Events).emit(.tray_clipboard, true);
    if (std.mem.eql(u8, id, "send")) oriel.App.events(Events).emit(.tray_send, true);
}
fn sync_tray_visibility(_: void) void {
    const visible = device_visible.load(.acquire);
    if (tray) |icon| icon.setChecked("visible", visible);
    oriel.App.events(Events).emit(.tray_visibility, visible);
}
fn set_visibility(allocator: std.mem.Allocator, visible: bool) ![]const u8 {
    const response = try request_json(allocator, .{ .command = "visibility", .visible = visible });
    errdefer allocator.free(response);
    const parsed = try std.json.parseFromSlice(struct { ok: bool }, allocator, response, .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    if (parsed.value.ok) device_visible.store(visible, .release);
    oriel.App.runOnMain({}, sync_tray_visibility);
    return response;
}
fn tray_set_visibility(visible: bool) void {
    const allocator = std.heap.smp_allocator;
    const response = set_visibility(allocator, visible) catch {
        oriel.App.runOnMain({}, sync_tray_visibility);
        return;
    };
    defer allocator.free(response);
}
/// Read settings.json from the app's data directory; without one, the
/// defaults.
fn load_settings(io: std.Io) void {
    const gpa = std.heap.smp_allocator;
    const path = oriel.store.dataDir(gpa, app_id) catch |err| {
        std.log.warn("no app data directory, settings won't be kept: {s}", .{@errorName(err)});
        return;
    };
    data_dir = path;
    var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return;
    defer dir.close(io);
    saved_settings = settings.load(gpa, io, dir) catch return;
}
/// A copy of the saved settings, owned by `gpa`.
fn current_settings(gpa: std.mem.Allocator) !settings.Settings {
    settings_lock.lockUncancelable(app_io);
    defer settings_lock.unlock(app_io);
    return saved_settings.clone(gpa);
}
/// The name nearby devices see: the one saved in Settings, else the
/// platform's device name (on Android, Settings > About phone) instead of
/// the host name, which is "localhost" there. Caller frees.
fn advertised_name(gpa: std.mem.Allocator) ![]u8 {
    const saved = try current_settings(gpa);
    defer saved.deinit(gpa);
    if (saved.device_name.len > 0) return gpa.dupe(u8, saved.device_name);
    return oriel.system.deviceName(gpa);
}
/// Give the engine the advertised name; a running engine re-announces
/// itself with it (mDNS), and new connections use it. Failures leave the
/// engine on its current name (at first, the host name).
fn set_device_name(gpa: std.mem.Allocator) void {
    const name = advertised_name(gpa) catch return;
    defer gpa.free(name);
    const name_z = gpa.dupeZ(u8, name) catch return;
    defer gpa.free(name_z);
    ghostshare_set_device_name(name_z);
}
/// Start the Quick Share engine; a failure it reports is kept for the page
/// (`snapshot`).
fn start_engine(gpa: std.mem.Allocator) !void {
    set_device_name(gpa);
    // Before the engine starts browsing, so its first mDNS answers get through.
    android_multicast.acquire();
    const response = ghostshare_start(engine_directory) orelse return error.QuickShareUnavailable;
    defer ghostshare_free(response);
    const result = try std.json.parseFromSlice(struct { ok: bool }, gpa, std.mem.span(response), .{ .ignore_unknown_fields = true });
    defer result.deinit();
    if (!result.value.ok) startup_error = try gpa.dupe(u8, std.mem.span(response));
}
fn android_start_engine() void {
    start_engine(std.heap.smp_allocator) catch |err| android_start_engine_failed(err);
}
fn android_start_engine_failed(err: anyerror) void {
    startup_error = std.fmt.allocPrint(std.heap.smp_allocator, "{{\"ok\":false,\"error\":\"Quick Share could not start: {s}\"}}", .{@errorName(err)}) catch null;
}
fn setup() !void {
    // Android: oriel.system.deviceName asks the UI thread, which runs only
    // once oriel.main has started, so the engine starts from here, on its own
    // thread: waiting for it (up to 10 s) on the UI thread would freeze the
    // app. Until it's up, snapshot fails and the page polls again.
    if (builtin.abi == .android) {
        const thread = std.Thread.spawn(.{}, android_start_engine, .{}) catch |err| blk: {
            android_start_engine_failed(err);
            break :blk null;
        };
        if (thread) |t| t.detach();
    }
    // Wake nearby phones so discovery finds them (Linux does this in the
    // engine, with BlueZ). The helper waits for the permission and the adapter.
    if (builtin.abi == .android) android_beacon.start();
    if (desktop_linux) ghostshare_desktop_init(oriel.App.gtk_app, oriel.App.main_window);
    tray = oriel.tray.Tray.create(std.heap.smp_allocator, .{
        .id = "dev.ghostshare.App",
        .title = "GhostShare",
        .tooltip = "Share files nearby",
        .icon = .{ .png = @import("tray_icon").bytes },
        .menu = &.{
            .{ .item = .{ .id = "show", .label = "Show GhostShare" } },
            .{ .item = .{ .id = "send", .label = "Send files…" } },
            .{ .item = .{ .id = "clipboard", .label = "Send clipboard…" } },
            .{ .check = .{ .id = "visible", .label = "Visible to nearby devices", .checked = true } },
            .separator,
            .{ .item = .{ .id = "updates", .label = "Check for updates" } },
            .separator,
            .{ .item = .{ .id = "quit", .label = "Quit GhostShare" } },
        },
        .on_menu = tray_menu,
        .on_activate = show_window,
    }) catch null;
    if (@hasDecl(oriel.notification, "onAction")) oriel.notification.onAction(notification_action);
    ghostshare_set_event_callback(transfer_event);
}
export fn ghostshare_theme_changed(dark: c_int) void {
    oriel.App.events(Events).emit(.system_theme, .{ .dark = dark != 0 });
}
export fn ghostshare_review_transfer(id: [*:0]const u8) void {
    notification_action(std.mem.span(id), null);
}
const NotificationEvent = struct { bytes: [4096]u8, len: usize };
fn transfer_event(json: [*:0]const u8) callconv(.c) void {
    const source = std.mem.span(json);
    if (android) relocation.onEvent(source);
    if (source.len > 4096) return;
    var event: NotificationEvent = .{ .bytes = undefined, .len = source.len };
    @memcpy(event.bytes[0..source.len], source);
    oriel.App.runOnMain(event, notify_main);
}
fn notify_main(event: NotificationEvent) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = std.json.parseFromSlice(struct { id: []const u8, kind: []const u8, name: []const u8, pin: ?[]const u8 = null, text: bool = false }, allocator, event.bytes[0..event.len], .{}) catch return;
    const dismiss = std.mem.eql(u8, parsed.value.kind, "dismiss");
    if (desktop_linux and (dismiss or !@hasDecl(oriel.notification, "onAction"))) {
        const id = allocator.dupeZ(u8, parsed.value.id) catch return;
        const kind = allocator.dupeZ(u8, parsed.value.kind) catch return;
        const name = allocator.dupeZ(u8, parsed.value.name) catch return;
        const pin = allocator.dupeZ(u8, parsed.value.pin orelse "") catch return;
        ghostshare_desktop_notify(id, kind, name, pin, @intFromBool(parsed.value.text));
        return;
    }
    if (dismiss) return;
    const incoming = std.mem.eql(u8, parsed.value.kind, "request");
    const body = std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ parsed.value.name, if (incoming) (if (parsed.value.text) " wants to share text. Compare this code before accepting: " else " wants to share files. Compare this code before accepting: ") else (if (parsed.value.text) " · Text is ready to copy in GhostShare." else " · Files are ready. Open GhostShare to view them."), (if (incoming) parsed.value.pin orelse "" else ""), if (incoming and !parsed.value.text) " · Accept saves to the default folder." else "" }) catch return;
    if (@hasDecl(oriel.notification, "onAction")) {
        oriel.notification.notify(.{
            .id = parsed.value.id,
            .title = if (parsed.value.text) (if (incoming) "Incoming text" else "Text received") else (if (incoming) "Incoming files" else "Files received"),
            .body = body,
            .actions = if (incoming) (if (parsed.value.pin != null) &.{
                .{ .id = "accept", .label = "Accept" },
                .{ .id = "review", .label = "Review" },
                .{ .id = "decline", .label = "Deny" },
            } else &.{ .{ .id = "review", .label = "Review" }, .{ .id = "decline", .label = "Deny" } }) else if (parsed.value.text) &.{ .{ .id = "copy_text", .label = "Copy text" }, .{ .id = "review", .label = "Review" } } else if (android) &.{
                // Android can't open received files from here (see open_transfer).
                .{ .id = "review", .label = "Review" },
            } else &.{
                .{ .id = "open_file", .label = "Open file" },
                .{ .id = "open_folder", .label = "Open folder" },
            },
        }) catch {};
    } else {
        oriel.notification.notify(.{ .id = parsed.value.id, .title = if (parsed.value.text) (if (incoming) "Incoming text" else "Text received") else (if (incoming) "Incoming files" else "Files received"), .body = body }) catch {};
    }
}
const NotificationTask = struct {
    id: [256]u8,
    len: usize,
    action: enum { accept, decline, open_file, open_folder, copy_text },
};
export fn ghostshare_notification_action(id: [*:0]const u8, action: [*:0]const u8) void {
    notification_action(std.mem.span(id), std.mem.span(action));
}
fn notification_action(id: []const u8, action: ?[]const u8) void {
    if (action) |selected| {
        const kind = std.meta.stringToEnum(@FieldType(NotificationTask, "action"), selected);
        if (kind) |value| {
            if (id.len > 256) return;
            var task: NotificationTask = .{ .id = undefined, .len = id.len, .action = value };
            @memcpy(task.id[0..id.len], id);
            oriel.App.spawn(notification_task, .{task}) catch {
                show_window();
                oriel.App.events(Events).emit(.notification_error, "Could not perform notification action. Please review the transfer.");
            };
            return;
        }
    }
    show_window();
    oriel.App.events(Events).emit(.review_request, .{ .id = id });
}
fn notification_task(task: NotificationTask) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    perform_notification_task(arena.allocator(), task) catch {
        oriel.App.runOnMain({}, notification_failed);
    };
}
fn perform_notification_task(allocator: std.mem.Allocator, task: NotificationTask) !void {
    const id = task.id[0..task.len];
    switch (task.action) {
        .copy_text => try Commands.copy_transfer(allocator, .{ .id = id }),
        .open_file, .open_folder => try Commands.open_transfer(allocator, .{ .id = id, .folder = task.action == .open_folder }),
        .accept, .decline => {
            const response = try Commands.decide(allocator, .{ .id = id, .accept = task.action == .accept });
            const parsed = try std.json.parseFromSlice(struct { ok: bool }, allocator, response, .{ .ignore_unknown_fields = true });
            defer parsed.deinit();
            if (!parsed.value.ok) return error.RequestExpired;
        },
    }
}
fn notification_failed(_: void) void {
    show_window();
    oriel.App.events(Events).emit(.notification_error, "This notification is no longer available. Review the transfer in GhostShare.");
}
/// Android: received files move from GhostShare's own folder (where the
/// engine writes them) into the folder chosen in Settings, a Storage Access
/// Framework tree, once their transfer finishes. `oriel.dialog.saveToFolder`
/// copies each one (it blocks: the copy runs on a thread of its own), then
/// the staged copy is deleted. The engine keeps the outcome for the page
/// (`relocations[id]` in snapshots). Files that can't be saved stay where
/// they were received; if the folder can't be used any more (its access was
/// revoked), the page says so and Settings asks for a folder again.
const relocation = struct {
    /// The engine's event (on the engine's thread): a finished inbound file
    /// transfer starts a move. The engine is asked for the files from the
    /// new thread, once this event has been recorded.
    fn onEvent(json: []const u8) void {
        if (std.mem.indexOf(u8, json, "\"kind\":\"finished\"") == null) return;
        if (!folderChosen()) return;
        const copy = std.heap.smp_allocator.dupe(u8, json) catch return;
        const thread = std.Thread.spawn(.{}, run, .{copy}) catch {
            std.heap.smp_allocator.free(copy);
            return;
        };
        thread.detach();
    }

    fn folderChosen() bool {
        settings_lock.lockUncancelable(app_io);
        defer settings_lock.unlock(app_io);
        return settings.usableFolderId(saved_settings.download_folder, true);
    }

    fn run(json: []u8) void {
        defer std.heap.smp_allocator.free(json);
        var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
        defer arena.deinit();
        const gpa = arena.allocator();
        const event = std.json.parseFromSliceLeaky(struct { id: []const u8, kind: []const u8, text: bool = false }, gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        if (!std.mem.eql(u8, event.kind, "finished") or event.text) return;
        const saved = current_settings(gpa) catch return;
        if (!settings.usableFolderId(saved.download_folder, true)) return;
        move(gpa, event.id, saved.download_folder, saved.download_folder_name) catch |err| {
            std.log.warn("moving transfer {s} to the download folder: {s}", .{ event.id, @errorName(err) });
            report(gpa, event.id, .{ .state = "failed", .folder = saved.download_folder_name, .@"error" = "GhostShare couldn't move the files. They're in GhostShare's folder." });
        };
    }

    const File = struct { path: []const u8, name: []const u8, mime: []const u8 = "" };
    const Outcome = struct {
        /// "moving", "moved" (all), "partial" or "failed" (none).
        state: []const u8,
        /// The folder's display name.
        folder: []const u8,
        /// The names the moved files got there (" (1)" on a clash).
        names: []const []const u8 = &.{},
        /// Files left in GhostShare's folder.
        kept: usize = 0,
        @"error": ?[]const u8 = null,
    };

    fn move(gpa: std.mem.Allocator, id: []const u8, folder: []const u8, folder_name: []const u8) !void {
        const response = try request_json(gpa, .{ .command = "received_files", .id = id });
        const listed = try std.json.parseFromSliceLeaky(struct { ok: bool, data: ?[]const File = null, @"error": ?[]const u8 = null }, gpa, response, .{ .ignore_unknown_fields = true });
        if (!listed.ok) return error.TransferUnavailable;
        const files = listed.data orelse return;
        if (files.len == 0) return;
        report(gpa, id, .{ .state = "moving", .folder = folder_name });

        var names: std.ArrayList([]const u8) = .empty;
        var problem: ?[]const u8 = null;
        var revoked = false;
        for (files) |file| {
            const saved_as = oriel.dialog.saveToFolder(gpa, app_io, folder, file.path, file.name, mimeHint(file)) catch |err| {
                std.log.warn("saving {s} to the download folder: {s}", .{ file.name, @errorName(err) });
                if (err == error.FolderUnavailable) {
                    revoked = true;
                    break; // nothing more will go there
                }
                problem = switch (err) {
                    error.FileNotFound => "A received file was missing.",
                    error.InvalidName => "A file name can't be used in that folder.",
                    else => "A file couldn't be saved there.",
                };
                continue;
            };
            try names.append(gpa, saved_as);
            std.Io.Dir.deleteFileAbsolute(app_io, file.path) catch |err|
                std.log.warn("removing {s} after moving it: {s}", .{ file.path, @errorName(err) });
        }
        const kept = files.len - names.items.len;
        if (revoked) problem = "GhostShare can't save to this folder any more. Choose a folder again in Settings.";
        report(gpa, id, .{
            .state = if (kept == 0) "moved" else if (names.items.len == 0) "failed" else "partial",
            .folder = folder_name,
            .names = names.items,
            .kept = kept,
            .@"error" = problem,
        });
        if (revoked) {
            folder_unavailable.store(true, .release);
            var message: FolderMessage = .{ .bytes = undefined, .len = 0 };
            const text = std.fmt.bufPrint(&message.bytes, "GhostShare can't save to “{s}” any more, so received files stay in GhostShare’s folder. Choose a folder again in Settings.", .{folder_name}) catch blk: {
                const short = "GhostShare can't save to the chosen folder any more. Choose a folder again in Settings.";
                @memcpy(message.bytes[0..short.len], short);
                break :blk message.bytes[0..short.len];
            };
            message.len = text.len;
            oriel.App.runOnMain(message, folderError);
        }
    }

    /// The sender's MIME type for a file without an extension (null: from
    /// the extension). With an extension, Android's providers append the
    /// type's own extension when the two disagree ("x.heic" + image/heif:
    /// "x.heic.heif"), so the name decides.
    fn mimeHint(file: File) ?[]const u8 {
        if (file.mime.len == 0 or std.mem.eql(u8, file.mime, "application/octet-stream")) return null;
        if (std.mem.indexOfScalar(u8, file.mime, '/') == null or std.mem.indexOfScalar(u8, file.mime, '*') != null) return null;
        const dot = std.mem.lastIndexOfScalar(u8, file.name, '.') orelse return file.mime;
        return if (dot == 0) file.mime else null;
    }

    fn report(gpa: std.mem.Allocator, id: []const u8, outcome: Outcome) void {
        const response = request_json(gpa, .{ .command = "relocation", .id = id, .relocation = outcome }) catch return;
        gpa.free(response);
    }

    const FolderMessage = struct { bytes: [512]u8, len: usize };
    fn folderError(message: FolderMessage) void {
        oriel.App.events(Events).emit(.folder_error, message.bytes[0..message.len]);
    }
};
fn second_instance(args: []const []const u8) void {
    _ = args;
    show_window();
}
fn request_quit() void {
    if (desktop_linux) ghostshare_desktop_quit() else ghostshare_quit_requested();
}
export fn ghostshare_quit_requested() void {
    ghostshare_set_event_callback(null);
    oriel.App.quit(0);
}

pub const Commands = struct {
    pub const async_commands = .{ "settings_get", "settings_save", "settings_folder", "snapshot", "select_file", "send_files", "read_clipboard", "send_text", "copy_transfer", "decide", "cancel", "visibility", "select_folder", "open_transfer", "updater_check", "updater_install", "updater_restart" };
    pub const update_info = updates.info;
    pub const updater_check = updates.check;
    pub const updater_install = updates.install;
    pub fn updater_restart(allocator: std.mem.Allocator, io: std.Io) !void {
        const response = try request_json(allocator, .{ .command = "snapshot" });
        defer allocator.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        const data = parsed.value.object.get("data") orelse return error.QuickShareUnavailable;
        for (data.object.get("transfers").?.array.items) |transfer| {
            const state = transfer.object.get("state") orelse continue;
            if (state != .string) return error.TransfersActive;
            const terminal = [_][]const u8{ "Finished", "Rejected", "Cancelled", "Disconnected" };
            const finished = for (terminal) |name| {
                if (std.mem.eql(u8, name, state.string)) break true;
            } else false;
            if (!finished) return oriel.ipc.fail("Finish or cancel current transfers before restarting", .{});
        }
        try updates.restart(allocator, io);
    }
    pub fn settings_get(allocator: std.mem.Allocator, io: std.Io) !SettingsView {
        return settings_view(allocator, io);
    }
    /// Save the device name (empty: the system's name), which takes effect
    /// at once (mDNS re-announces it). `default_folder` also goes back to
    /// the default download folder ("Reset to defaults").
    pub fn settings_save(allocator: std.mem.Allocator, io: std.Io, args: struct { device_name: []const u8 = "", default_folder: bool = false }) !SettingsView {
        const name = settings.normalizeName(args.device_name) catch |err| return oriel.ipc.fail("{s}", .{settings.nameErrorMessage(err)});
        if (args.default_folder) try apply_folder(allocator, io, null);
        var next = try current_settings(allocator);
        next.device_name = name;
        try store_settings(allocator, io, next);
        set_device_name(allocator);
        return settings_view(allocator, io);
    }
    /// Change the download folder: `choose` asks for one with the system's
    /// folder picker (oriel.dialog.openFolder; cancelling changes nothing),
    /// else back to the default folder. Applies to transfers accepted from
    /// now on, and is saved at once.
    pub fn settings_folder(allocator: std.mem.Allocator, io: std.Io, args: struct { choose: bool }) !SettingsView {
        if (!args.choose) {
            try apply_folder(allocator, io, null);
            return settings_view(allocator, io);
        }
        if (!folder_picker) return oriel.ipc.fail("Choosing a folder isn't available on this device", .{});
        const folder = try oriel.dialog.openFolder(allocator, .{ .title = "Save received files in…" }) orelse return settings_view(allocator, io);
        defer folder.deinit(allocator);
        try apply_folder(allocator, io, folder);
        return settings_view(allocator, io);
    }
    pub fn snapshot(allocator: std.mem.Allocator) ![]const u8 {
        if (startup_error) |message| return allocator.dupe(u8, message);
        return request_json(allocator, .{ .command = "snapshot" });
    }
    pub fn select_file(allocator: std.mem.Allocator, io: std.Io) !?FileSelection {
        const path = try oriel.dialog.openFile(allocator, .{ .title = "Choose a file to share" }) orelse return null;
        errdefer allocator.free(path);
        const file = try std.Io.Dir.cwd().openFile(io, path, .{});
        defer file.close(io);
        const stat = try file.stat(io);
        if (stat.kind != .file) return error.NotARegularFile;
        return .{ .path = path, .name = try allocator.dupe(u8, std.fs.path.basename(path)), .size = stat.size };
    }
    pub fn send_files(allocator: std.mem.Allocator, args: struct { address: []const u8, name: []const u8, paths: []const []const u8 }) ![]const u8 {
        return request_json(allocator, .{ .command = "send", .address = args.address, .name = args.name, .paths = args.paths });
    }
    pub fn read_clipboard(allocator: std.mem.Allocator) !ClipboardText {
        const text = try oriel.clipboard.readText(allocator);
        if (text.len > 1024 * 1024) return oriel.ipc.fail("Clipboard text exceeds 1 MB", .{});
        return .{ .text = text };
    }
    pub fn send_text(allocator: std.mem.Allocator, args: struct { address: []const u8, name: []const u8, text: []const u8 }) ![]const u8 {
        return request_json(allocator, .{ .command = "send_text", .address = args.address, .name = args.name, .text = args.text });
    }
    pub fn copy_transfer(allocator: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        const response = try request_json(allocator, .{ .command = "resolve_text", .id = args.id });
        defer allocator.free(response);
        const parsed = try std.json.parseFromSlice(struct { ok: bool, data: ?[]const u8 = null, @"error": ?[]const u8 = null }, allocator, response, .{});
        defer parsed.deinit();
        if (!parsed.value.ok) return oriel.ipc.fail("{s}", .{parsed.value.@"error" orelse "Text unavailable"});
        try oriel.clipboard.writeText(parsed.value.data orelse return error.MissingText);
    }
    pub fn decide(allocator: std.mem.Allocator, args: struct { id: []const u8, accept: bool, directory: ?[]const u8 = null }) ![]const u8 {
        return request_json(allocator, .{ .command = "decide", .id = args.id, .accept = args.accept, .directory = args.directory });
    }
    /// A folder for one incoming transfer ("Choose folder…"): its path, or
    /// null if cancelled. Desktops only: on Android the engine can only
    /// write to its own folder (received files move to the Settings folder
    /// afterwards).
    pub fn select_folder(allocator: std.mem.Allocator) !?[]const u8 {
        if (android or !folder_picker) return oriel.ipc.fail("Choose the folder for received files in Settings", .{});
        const folder = try oriel.dialog.openFolder(allocator, .{ .title = "Save incoming files in…" }) orelse return null;
        allocator.free(folder.name);
        return folder.id; // the folder's path on desktops
    }
    pub fn system_info() struct { dark: ?bool, android: bool } {
        return .{ .dark = if (desktop_linux) ghostshare_desktop_dark() != 0 else null, .android = android };
    }
    pub fn quit() void {
        request_quit();
    }
    pub fn open_transfer(allocator: std.mem.Allocator, args: struct { id: []const u8, index: usize = 0, folder: bool = false }) !void {
        const response = try request_json(allocator, .{ .command = "resolve_path", .id = args.id, .index = args.index, .folder = args.folder });
        defer allocator.free(response);
        const parsed = try std.json.parseFromSlice(struct { ok: bool, data: ?[]const u8 = null, @"error": ?[]const u8 = null }, allocator, response, .{});
        defer parsed.deinit();
        if (!parsed.value.ok) return oriel.ipc.fail("{s}", .{parsed.value.@"error" orelse "File unavailable"});
        const path = try allocator.dupeZ(u8, parsed.value.data orelse return error.MissingPath);
        defer allocator.free(path);
        if (desktop_linux) {
            if (ghostshare_open_path(path) == 0) return oriel.ipc.fail("Could not open this file or folder", .{});
        } else if (android) {
            // Oriel's openExternal can't hand another app a file of
            // GhostShare's (no content:// grant), nor a document of the
            // chosen folder: open received files from the Files app.
            return oriel.ipc.fail("Open received files from your Files app", .{});
        } else return oriel.ipc.fail("Opening files is currently supported on Linux", .{});
    }
    pub fn cancel(allocator: std.mem.Allocator, args: struct { id: []const u8 }) ![]const u8 {
        return request_json(allocator, .{ .command = "cancel", .id = args.id });
    }
    pub fn visibility(allocator: std.mem.Allocator, args: struct { visible: bool }) ![]const u8 {
        return set_visibility(allocator, args.visible);
    }
};
const SettingsView = struct {
    /// The saved name; empty means the system's name.
    device_name: []const u8,
    /// The default name (the platform's device name), for the placeholder.
    system_name: []const u8,
    /// The chosen download folder (an Oriel folder id: a path on desktops,
    /// a tree URI on Android) and its display name; empty: the default.
    download_folder: []const u8,
    download_folder_name: []const u8,
    /// False when the chosen folder can't be used any more: choose again.
    folder_available: bool,
    /// Whether "Choose…" works here (oriel.dialog.openFolder).
    folder_picker: bool,
    /// Android: the engine receives into GhostShare's folder, and finished
    /// transfers move to the chosen folder.
    android: bool,
};
fn settings_view(allocator: std.mem.Allocator, io: std.Io) !SettingsView {
    const saved = try current_settings(allocator);
    var name = saved.download_folder_name;
    var available = !folder_unavailable.load(.acquire);
    if (saved.download_folder.len > 0 and available) {
        if (oriel.dialog.folderName(allocator, io, saved.download_folder)) |current| {
            if (current.len > 0) name = current;
        } else |err| switch (err) {
            error.FolderUnavailable => {
                available = false;
                folder_unavailable.store(true, .release);
            },
            else => std.log.warn("download folder: {s}", .{@errorName(err)}),
        }
    }
    return .{
        .device_name = saved.device_name,
        .system_name = oriel.system.deviceName(allocator) catch try allocator.dupe(u8, ""),
        .download_folder = saved.download_folder,
        .download_folder_name = name,
        .folder_available = saved.download_folder.len == 0 or available,
        .folder_picker = folder_picker,
        .android = android,
    };
}
/// Write `next` to settings.json and make it the current settings.
fn store_settings(allocator: std.mem.Allocator, io: std.Io, next: settings.Settings) !void {
    const path = data_dir orelse return oriel.ipc.fail("Settings can't be saved: there is no app data folder", .{});
    {
        var dir = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return oriel.ipc.fail("Settings can't be saved: the app data folder is unavailable", .{});
        defer dir.close(io);
        settings.save(allocator, io, dir, next) catch |err| return oriel.ipc.fail("Settings can't be saved: {s}", .{@errorName(err)});
    }
    const owned = try next.clone(std.heap.smp_allocator);
    settings_lock.lockUncancelable(app_io);
    defer settings_lock.unlock(app_io);
    saved_settings.deinit(std.heap.smp_allocator);
    saved_settings = owned;
}
/// Make `folder` (null: the default) where received files go, and save it.
/// Desktop: the engine checks it (an existing, writable folder) and writes
/// there from now on. Android: the engine keeps receiving into its own
/// folder, and `relocation` moves finished transfers into this one. The
/// previous folder's access is given up (Android's persisted grants are
/// limited); if this one can't be used, its new grant is.
fn apply_folder(allocator: std.mem.Allocator, io: std.Io, folder: ?oriel.dialog.Folder) !void {
    var next = try current_settings(allocator);
    const previous = next.download_folder;
    const id = if (folder) |f| f.id else "";
    errdefer if (folder != null and !std.mem.eql(u8, id, previous)) oriel.dialog.forgetFolder(id);
    next.download_folder = id;
    next.download_folder_name = if (folder) |f| f.name else "";
    if (!android) {
        // The engine answers with the folder's full path: the id from now on.
        const response = try request_json(allocator, .{ .command = "download_dir", .directory = if (folder != null) id else default_directory, .create = folder == null });
        defer allocator.free(response);
        const result = try std.json.parseFromSlice(struct { ok: bool, data: ?[]const u8 = null, @"error": ?[]const u8 = null }, allocator, response, .{});
        defer result.deinit();
        if (!result.value.ok) return oriel.ipc.fail("{s}", .{result.value.@"error" orelse "This folder can't be used"});
        if (folder != null) next.download_folder = try allocator.dupe(u8, result.value.data orelse id);
    } else if (folder != null and !settings.usableFolderId(id, true)) {
        return oriel.ipc.fail("This folder can't be used", .{});
    }
    try store_settings(allocator, io, next);
    folder_unavailable.store(false, .release);
    if (previous.len > 0 and !std.mem.eql(u8, previous, next.download_folder)) oriel.dialog.forgetFolder(previous);
}
/// The folder saved in Settings while it is still a folder, else the
/// platform default (a folder on a drive that's gone isn't recreated).
/// Android: always GhostShare's own folder, the staging area for
/// `relocation`.
fn start_directory(io: std.Io) []const u8 {
    const saved = saved_settings.download_folder;
    if (android or saved.len == 0) return default_directory;
    if (!settings.usableFolderId(saved, false)) return default_directory;
    var dir = std.Io.Dir.openDirAbsolute(io, saved, .{}) catch |err| {
        std.log.warn("download folder {s} unavailable ({s}); using the default", .{ saved, @errorName(err) });
        folder_unavailable.store(true, .release);
        return default_directory;
    };
    dir.close(io);
    return saved;
}
pub fn main(init: std.process.Init) !u8 {
    app_io = init.io;
    load_settings(init.io);
    if (builtin.abi != .android) {
        const arena = init.arena.allocator();
        const all_args = try init.minimal.args.toSlice(arena);
        const argv = try arena.alloc([]const u8, all_args.len -| 1);
        for (argv, 1..) |*a, i| a.* = all_args[i];

        if (cli.isCliCommand(argv)) {
            set_device_name(init.gpa);
            return cli.run(init, argv);
        }
    }

    const directory = if (builtin.abi == .android) try std.fs.path.join(init.arena.allocator(), &.{ oriel.platform.impl.paths.externalFilesDir() orelse return error.MissingAndroidStorage, "Received" }) else "";
    default_directory = try init.arena.allocator().dupeZ(u8, directory);
    engine_directory = try init.arena.allocator().dupeZ(u8, start_directory(init.io));
    defer android_multicast.release();
    defer android_beacon.stop();
    if (builtin.abi != .android) try start_engine(init.arena.allocator());
    defer ghostshare_stop();
    defer {
        ghostshare_set_event_callback(null);
        if (@hasDecl(oriel.notification, "onAction")) oriel.notification.onAction(null);
        if (tray) |icon| icon.deinit();
        if (desktop_linux) ghostshare_desktop_cleanup();
    }
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .setup = setup,
        .on_close = if (builtin.abi == .android) .quit else .hide,
        .on_second_instance = second_instance,
        .id = "dev.ghostshare.App",
        .title = "GhostShare",
        .width = 980,
        .height = 860,
        .assets = app.assets,
        .dev = app.dev,
        .deep_link_schemes = app.url_schemes,
        .permissions = app.permissions,
        .security = .{ .isolation = app.isolation },
    });
}
