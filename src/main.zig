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
const clipboard_image = @import("clipboard_image.zig");
const camera = @import("camera/app.zig");
const android_multicast = if (builtin.abi == .android) @import("android_multicast.zig") else struct {
    pub fn acquire() void {}
    pub fn release() void {}
};
const android_beacon = if (builtin.abi == .android) @import("android_beacon.zig") else struct {
    pub fn start() void {}
    pub fn stop() void {}
};

pub const std_options: std.Options = .{ .logFn = oriel.log.logFn };
extern fn hollershare_start(directory: [*:0]const u8) ?[*:0]u8;
extern fn hollershare_request(request: [*:0]const u8) ?[*:0]u8;
extern fn hollershare_free(pointer: [*:0]u8) void;
extern fn hollershare_stop() void;
extern fn hollershare_set_device_name(name: ?[*:0]const u8) void;
extern fn hollershare_set_event_callback(callback: ?*const fn ([*:0]const u8) callconv(.c) void) void;
extern fn hollershare_desktop_init(window: *anyopaque) void;
extern fn hollershare_desktop_cleanup() void;
extern fn hollershare_desktop_dark() c_int;
extern fn hollershare_desktop_quit() void;
extern fn hollershare_desktop_notify(id: [*:0]const u8, kind: [*:0]const u8, name: [*:0]const u8, pin: [*:0]const u8, text: c_int) void;
extern fn hollershare_open_path(path: [*:0]const u8) c_int;
var tray: if (oriel.tray.available) ?*oriel.tray.Tray else void = if (oriel.tray.available) null else {};
/// The main window's GtkWindow (Linux), from `oriel.hooks`' window_created:
/// `setup` hands it to desktop_linux.c, which gets the GtkApplication from it.
var main_gtk_window: ?*anyopaque = null;
var startup_error: ?[]const u8 = null;
/// Where received files go: set by `main` before `start_engine`.
var engine_directory: [:0]const u8 = "";
/// The platform's default download folder, as `hollershare_start` takes it:
/// "" on desktop (the engine's default), `<external files>/Received` on Android.
var default_directory: [:0]const u8 = "";
const app_id = "dev.hollershare.App";
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

/// What "Paste clipboard" found: its text, or (no text) an image saved as a
/// PNG file to add to the batch.
const ClipboardContent = struct { text: []const u8, image: ?FileSelection = null };
const FileSelection = struct { path: []const u8, name: []const u8, size: u64 };
fn request_json(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    const terminated = try allocator.dupeZ(u8, json);
    defer allocator.free(terminated);
    const response = hollershare_request(terminated) orelse return error.QuickShareUnavailable;
    defer hollershare_free(response);
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
    share_target: []const u8,
};
fn show_window() void {
    if (oriel.App.getWindow("main")) |window| {
        window.show();
        window.focus();
    }
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
    if (oriel.tray.available) if (tray) |icon| icon.setChecked("visible", visible);
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
/// The folder settings.json lives in: `oriel.paths.appData`. On Android
/// that is the files dir itself, while HollerShare up to 1.0.4 (Oriel's old
/// `store.dataDir`) kept it in `<files dir>/dev.hollershare.App`: that folder
/// stays, so existing settings are found where they are.
fn settings_dir(gpa: std.mem.Allocator, io: std.Io) ![]const u8 {
    const base = try oriel.paths.appData(gpa, .{ .name = app_id });
    if (!android) return base;
    defer gpa.free(base);
    const path = try std.fs.path.join(gpa, &.{ base, app_id });
    errdefer gpa.free(path);
    try std.Io.Dir.cwd().createDirPath(io, path);
    return path;
}
/// Read settings.json from the app's data directory; without one, the
/// defaults.
fn load_settings(io: std.Io) void {
    const gpa = std.heap.smp_allocator;
    const path = settings_dir(gpa, io) catch |err| {
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
    hollershare_set_device_name(name_z);
}
/// Start the Quick Share engine; a failure it reports is kept for the page
/// (`snapshot`).
fn start_engine(gpa: std.mem.Allocator) !void {
    set_device_name(gpa);
    // Before the engine starts browsing, so its first mDNS answers get through.
    android_multicast.acquire();
    const response = hollershare_start(engine_directory) orelse return error.QuickShareUnavailable;
    defer hollershare_free(response);
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
fn window_created(window: oriel.hooks.Window) void {
    if (std.mem.eql(u8, window.label, "main") and window.native == .gtk) main_gtk_window = window.native.gtk;
}
fn window_destroyed(window: oriel.hooks.Window) void {
    if (std.mem.eql(u8, window.label, "main")) main_gtk_window = null;
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
    if (desktop_linux) if (main_gtk_window) |window| hollershare_desktop_init(window);
    if (oriel.tray.available) tray = oriel.tray.Tray.create(std.heap.smp_allocator, .{
        .id = "dev.hollershare.App",
        .title = "HollerShare",
        .tooltip = "Share files nearby",
        // Linux panels are dark on most desktops (GNOME's even in light
        // mode), where the green mark disappears: use the dark-panel mark.
        .icon = .{ .png = if (builtin.os.tag == .linux) @import("tray_icon").dark_bytes else @import("tray_icon").bytes },
        .menu = &.{
            .{ .item = .{ .id = "show", .label = "Show HollerShare" } },
            .{ .item = .{ .id = "send", .label = "Send files…" } },
            .{ .item = .{ .id = "clipboard", .label = "Send clipboard…" } },
            .{ .check = .{ .id = "visible", .label = "Visible to nearby devices", .checked = true } },
            .separator,
            .{ .item = .{ .id = "updates", .label = "Check for updates" } },
            .separator,
            .{ .item = .{ .id = "quit", .label = "Quit HollerShare" } },
        },
        .on_menu = tray_menu,
        .on_activate = show_window,
    }) catch null;
    if (@hasDecl(oriel.notification, "onAction")) oriel.notification.onAction(notification_action);
    hollershare_set_event_callback(transfer_event);
}
export fn hollershare_theme_changed(dark: c_int) void {
    oriel.App.events(Events).emit(.system_theme, .{ .dark = dark != 0 });
}
export fn hollershare_review_transfer(id: [*:0]const u8) void {
    notification_action(std.mem.span(id), null);
}
const NotificationEvent = struct { bytes: [4096]u8, len: usize };
fn transfer_event(json: [*:0]const u8) callconv(.c) void {
    const source = std.mem.span(json);
    // Finished files: a thread of their own looks for a single image (to
    // copy it, or offer to), then notifies and, on Android, moves them.
    if (received.start(source)) return;
    if (source.len > 4096) return;
    var event: NotificationEvent = .{ .bytes = undefined, .len = source.len };
    @memcpy(event.bytes[0..source.len], source);
    oriel.App.runOnMain(event, notify_main);
}
fn notify_main(event: NotificationEvent) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const parsed = std.json.parseFromSlice(struct { id: []const u8, kind: []const u8, name: []const u8, pin: ?[]const u8 = null, text: bool = false, image: received.Image = .none }, allocator, event.bytes[0..event.len], .{ .ignore_unknown_fields = true }) catch return;
    const dismiss = std.mem.eql(u8, parsed.value.kind, "dismiss");
    if (desktop_linux and (dismiss or !@hasDecl(oriel.notification, "onAction"))) {
        const id = allocator.dupeZ(u8, parsed.value.id) catch return;
        const kind = allocator.dupeZ(u8, parsed.value.kind) catch return;
        const name = allocator.dupeZ(u8, parsed.value.name) catch return;
        const pin = allocator.dupeZ(u8, parsed.value.pin orelse "") catch return;
        hollershare_desktop_notify(id, kind, name, pin, @intFromBool(parsed.value.text));
        return;
    }
    if (dismiss) return;
    const incoming = std.mem.eql(u8, parsed.value.kind, "request");
    // A finished text transfer is the sender's clipboard: put it on this
    // device's clipboard right away instead of asking for a tap (Android 10+
    // restricts clipboard reads, not writes). The notification reports it;
    // the "Copy text" action stays for when the clipboard moved on.
    if (!incoming and parsed.value.text) {
        copy_received_text(parsed.value.id, parsed.value.name);
        return;
    }
    if (!incoming and parsed.value.image != .none) {
        notify_image(allocator, parsed.value.id, parsed.value.name, parsed.value.image);
        return;
    }
    const body = std.fmt.allocPrint(allocator, "{s}{s}{s}{s}", .{ parsed.value.name, if (incoming) (if (parsed.value.text) " wants to share text. Compare this code before accepting: " else " wants to share files. Compare this code before accepting: ") else " · Files are ready. Open HollerShare to view them.", (if (incoming) parsed.value.pin orelse "" else ""), if (incoming and !parsed.value.text) " · Accept saves to the default folder." else "" }) catch return;
    if (@hasDecl(oriel.notification, "onAction")) {
        oriel.notification.notify(.{
            .id = parsed.value.id,
            .title = if (incoming) (if (parsed.value.text) "Incoming text" else "Incoming files") else "Files received",
            .body = body,
            .actions = if (incoming) (if (parsed.value.pin != null) &.{
                .{ .id = "accept", .label = "Accept" },
                .{ .id = "review", .label = "Review" },
                .{ .id = "decline", .label = "Deny" },
            } else &.{ .{ .id = "review", .label = "Review" }, .{ .id = "decline", .label = "Deny" } }) else if (android) &.{
                // Android can't open received files from here (see open_transfer).
                .{ .id = "review", .label = "Review" },
            } else &.{
                .{ .id = "open_file", .label = "Open file" },
                .{ .id = "open_folder", .label = "Open folder" },
            },
        }) catch {};
    } else {
        oriel.notification.notify(.{ .id = parsed.value.id, .title = if (incoming) (if (parsed.value.text) "Incoming text" else "Incoming files") else "Files received", .body = body }) catch {};
    }
}
/// A received text transfer to copy: the engine's id and the sender's name,
/// both bounded like `NotificationTask`.
const TextCopy = struct {
    id: [256]u8,
    len: usize,
    name: [256]u8,
    name_len: usize,
};
/// How the copy went, for the notification shown on the main thread.
const TextCopyOutcome = struct {
    id: [256]u8,
    len: usize,
    name: [256]u8,
    name_len: usize,
    copied: bool,
};
fn copy_received_text(id: []const u8, name: []const u8) void {
    if (id.len > 256) return;
    var task: TextCopy = .{ .id = undefined, .len = id.len, .name = undefined, .name_len = @min(name.len, 256) };
    @memcpy(task.id[0..id.len], id);
    @memcpy(task.name[0..task.name_len], name[0..task.name_len]);
    oriel.App.spawn(text_copy_task, .{task}) catch {
        // Couldn't start the copy: ask for a tap instead.
        notify_text_outcome(.{ .id = task.id, .len = task.len, .name = task.name, .name_len = task.name_len, .copied = false });
    };
}
fn text_copy_task(task: TextCopy) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    var copied = true;
    Commands.copy_transfer(arena.allocator(), .{ .id = task.id[0..task.len] }) catch |err| {
        std.log.warn("copying received text to the clipboard: {s}", .{@errorName(err)});
        copied = false;
    };
    oriel.App.runOnMain(TextCopyOutcome{ .id = task.id, .len = task.len, .name = task.name, .name_len = task.name_len, .copied = copied }, notify_text_outcome);
}
fn notify_text_outcome(outcome: TextCopyOutcome) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const body = std.fmt.allocPrint(allocator, "{s} · {s}", .{ outcome.name[0..outcome.name_len], if (outcome.copied) "Copied to your clipboard." else "Text is ready to copy in HollerShare." }) catch return;
    oriel.notification.notify(.{
        .id = outcome.id[0..outcome.len],
        .title = "Text received",
        .body = body,
        .actions = &.{
            .{ .id = "copy_text", .label = "Copy text" },
            .{ .id = "review", .label = "Review" },
        },
    }) catch {};
}
/// "Image received": already on the clipboard (a HollerShare clipboard
/// image), or with a Copy image action.
fn notify_image(allocator: std.mem.Allocator, id: []const u8, name: []const u8, image: received.Image) void {
    const copied = image == .copied;
    const body = std.fmt.allocPrint(allocator, "{s} · {s}", .{ name, if (copied) "Copied to your clipboard." else "Copy it to paste it anywhere." }) catch return;
    const open: []const oriel.notification.Action = if (android) &.{
        .{ .id = "review", .label = "Review" },
    } else &.{
        .{ .id = "open_file", .label = "Open file" },
        .{ .id = "open_folder", .label = "Open folder" },
    };
    const with_copy: []const oriel.notification.Action = if (android) &.{
        .{ .id = "copy_image", .label = "Copy image" },
        .{ .id = "review", .label = "Review" },
    } else &.{
        .{ .id = "copy_image", .label = "Copy image" },
        .{ .id = "open_file", .label = "Open file" },
        .{ .id = "open_folder", .label = "Open folder" },
    };
    oriel.notification.notify(.{
        .id = id,
        .title = "Image received",
        .body = body,
        .actions = if (copied) open else with_copy,
    }) catch {};
}
/// Finished inbound file transfers, on a thread of their own (the engine's
/// event thread must not wait on files or the clipboard): one image is put
/// on the clipboard if a HollerShare sender copied it there, and otherwise
/// offered with Copy image; then the notification is shown, and on Android
/// the files move to the folder chosen in Settings (`relocation`), which is
/// why the image is read first.
const received = struct {
    const Image = enum { none, copied, available };

    /// Start handling `json` if it's a finished file transfer (true): the
    /// caller then leaves its notification to this.
    fn start(json: []const u8) bool {
        if (std.mem.indexOf(u8, json, "\"kind\":\"finished\"") == null) return false;
        if (json.len > 4096) return false;
        const copy = std.heap.smp_allocator.dupe(u8, json) catch return false;
        const thread = std.Thread.spawn(.{}, run, .{copy}) catch {
            std.heap.smp_allocator.free(copy);
            if (android) relocation.onEvent(json);
            return false;
        };
        thread.detach();
        return true;
    }

    fn run(json: []u8) void {
        defer std.heap.smp_allocator.free(json);
        var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
        defer arena.deinit();
        const gpa = arena.allocator();
        const event = std.json.parseFromSliceLeaky(struct { id: []const u8, kind: []const u8, name: []const u8 = "", text: bool = false }, gpa, json, .{ .ignore_unknown_fields = true }) catch return;
        const image: Image = if (event.text) .none else check(gpa, event.id) catch |err| blk: {
            std.log.warn("looking for a received image in {s}: {s}", .{ event.id, @errorName(err) });
            break :blk .none;
        };
        notify(gpa, json, image);
        if (android and !event.text) relocation.process(gpa, event.id);
    }

    /// Whether the transfer `id` is one image, and copy it when its name
    /// says it came from a clipboard.
    fn check(gpa: std.mem.Allocator, id: []const u8) !Image {
        const file = try single_image(gpa, id) orelse return .none;
        // Android: Copy image would read the file after it moved away.
        const offer: Image = if (android and relocation.folderChosen()) .none else .available;
        if (!clipboard_image.isClipboardImage(file.name)) return offer;
        copy_file(gpa, file.path) catch |err| {
            std.log.warn("copying a received clipboard image: {s}", .{@errorName(err)});
            return offer;
        };
        return .copied;
    }

    /// Hand the notification to the main thread: the engine's event with
    /// what became of the image added.
    fn notify(gpa: std.mem.Allocator, json: []const u8, image: Image) void {
        var event: NotificationEvent = .{ .bytes = undefined, .len = 0 };
        const text = if (image == .none) json else blk: {
            const close = std.mem.lastIndexOfScalar(u8, json, '}') orelse return;
            break :blk std.fmt.allocPrint(gpa, "{s},\"image\":\"{s}\"}}", .{ json[0..close], @tagName(image) }) catch json;
        };
        // Too long with the image added: the plain event still notifies.
        const fits = if (text.len <= event.bytes.len) text else json;
        if (fits.len > event.bytes.len) return;
        @memcpy(event.bytes[0..fits.len], fits);
        event.len = fits.len;
        oriel.App.runOnMain(event, notify_main);
    }
};
/// The one received file of transfer `id` when it's an image, else null.
fn single_image(gpa: std.mem.Allocator, id: []const u8) !?relocation.File {
    const response = try request_json(gpa, .{ .command = "received_files", .id = id });
    const listed = try std.json.parseFromSliceLeaky(struct { ok: bool, data: ?[]const relocation.File = null }, gpa, response, .{ .ignore_unknown_fields = true });
    if (!listed.ok) return error.TransferUnavailable;
    const files = listed.data orelse return null;
    if (files.len != 1 or !clipboard_image.isPngFile(files[0].name, files[0].mime)) return null;
    return files[0];
}
/// Put the image file at `path` on the clipboard (any thread).
fn copy_file(gpa: std.mem.Allocator, path: []const u8) !void {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(app_io, path, gpa, .limited(clipboard_image.max_bytes));
    defer gpa.free(bytes);
    // A file named .png can hold anything: only PNG goes on the clipboard.
    if (!clipboard_image.isPng(bytes)) return error.NotPng;
    try oriel.clipboard.writeImage(bytes);
}
const NotificationTask = struct {
    id: [256]u8,
    len: usize,
    action: enum { accept, decline, open_file, open_folder, copy_text, copy_image },
};
export fn hollershare_notification_action(id: [*:0]const u8, action: [*:0]const u8) void {
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
        .copy_image => try Commands.copy_image(allocator, .{ .id = id }),
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
    oriel.App.events(Events).emit(.notification_error, "This notification is no longer available. Review the transfer in HollerShare.");
}
/// Android: received files move from HollerShare's own folder (where the
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
    /// new thread, once this event has been recorded. Normally `received`
    /// calls `process` instead; this is its fallback.
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
        process(gpa, event.id);
    }

    /// Move the finished transfer `id` to the folder chosen in Settings, if
    /// one is (on a thread that may block).
    fn process(gpa: std.mem.Allocator, id: []const u8) void {
        const saved = current_settings(gpa) catch return;
        if (!settings.usableFolderId(saved.download_folder, true)) return;
        move(gpa, id, saved.download_folder, saved.download_folder_name) catch |err| {
            std.log.warn("moving transfer {s} to the download folder: {s}", .{ id, @errorName(err) });
            report(gpa, id, .{ .state = "failed", .folder = saved.download_folder_name, .@"error" = "HollerShare couldn't move the files. They're in HollerShare's folder." });
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
        /// Files left in HollerShare's folder.
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
        if (revoked) problem = "HollerShare can't save to this folder any more. Choose a folder again in Settings.";
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
            const text = std.fmt.bufPrint(&message.bytes, "HollerShare can't save to “{s}” any more, so received files stay in HollerShare’s folder. Choose a folder again in Settings.", .{folder_name}) catch blk: {
                const short = "HollerShare can't save to the chosen folder any more. Choose a folder again in Settings.";
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

var pending_share_lock: std.Io.Mutex = .init;
var pending_share_json: ?[]const u8 = null;

const SharedPayloadFile = struct {
    path: []const u8,
    name: []const u8,
    size: u64,
};

const SharedPayloadView = struct {
    mode: []const u8,
    files: []const SharedPayloadFile,
};

fn set_pending_share_json(json: []const u8) void {
    pending_share_lock.lockUncancelable(app_io);
    defer pending_share_lock.unlock(app_io);
    if (pending_share_json) |old| {
        std.heap.smp_allocator.free(old);
    }
    pending_share_json = std.heap.smp_allocator.dupe(u8, json) catch null;
    if (pending_share_json) |payload| {
        oriel.App.events(Events).emit(.share_target, payload);
    }
}

fn handle_share_args(args: []const []const u8) void {
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        if (std.mem.eql(u8, args[i], "--share-payload")) {
            if (i + 1 < args.len) {
                set_pending_share_json(args[i + 1]);
                return;
            }
        }
    }
}

fn handle_desktop_file_args(allocator: std.mem.Allocator, args: []const []const u8) void {
    var file_list: std.ArrayList(SharedPayloadFile) = .empty;
    defer file_list.deinit(allocator);

    for (args) |arg| {
        if (std.mem.startsWith(u8, arg, "-")) continue;
        const file = std.Io.Dir.cwd().openFile(app_io, arg, .{}) catch continue;
        defer file.close(app_io);
        const stat = file.stat(app_io) catch continue;
        if (stat.kind != .file) continue;

        file_list.append(allocator, .{
            .path = arg,
            .name = std.fs.path.basename(arg),
            .size = stat.size,
        }) catch continue;
    }

    if (file_list.items.len == 0) return;

    const payload = SharedPayloadView{
        .mode = "files",
        .files = file_list.items,
    };
    const json = std.json.Stringify.valueAlloc(allocator, payload, .{}) catch return;
    defer allocator.free(json);
    set_pending_share_json(json);
}

fn second_instance(args: []const []const u8) void {
    handle_share_args(args);
    if (builtin.abi != .android) handle_desktop_file_args(std.heap.smp_allocator, args);
    show_window();
}
fn request_quit() void {
    if (desktop_linux) hollershare_desktop_quit() else hollershare_quit_requested();
}
export fn hollershare_quit_requested() void {
    hollershare_set_event_callback(null);
    oriel.App.quit(0);
}

pub const Commands = struct {
    pub const async_commands = .{ "settings_get", "settings_save", "settings_folder", "snapshot", "select_file", "send_files", "read_clipboard", "send_text", "copy_transfer", "copy_image", "decide", "cancel", "visibility", "select_folder", "open_transfer", "updater_check", "updater_install", "updater_restart", "get_pending_share", "camera_status", "camera_phone_start", "camera_phone_stop", "camera_find", "camera_connect", "camera_stop", "camera_switch", "camera_view", "camera_quality", "camera_setup" };
    pub const update_info = updates.info;
    pub const updater_check = updates.check;
    pub const updater_install = updates.install;
    pub fn updater_restart(allocator: std.mem.Allocator, io: std.Io) !void {
        const response = try request_json(allocator, .{ .command = "snapshot" });
        defer allocator.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        // The engine's answer is checked, not assumed: a malformed one must
        // not panic the restart.
        if (parsed.value != .object) return error.QuickShareUnavailable;
        const data = parsed.value.object.get("data") orelse return error.QuickShareUnavailable;
        if (data != .object) return error.QuickShareUnavailable;
        const transfers = data.object.get("transfers") orelse return error.QuickShareUnavailable;
        if (transfers != .array) return error.QuickShareUnavailable;
        for (transfers.array.items) |transfer| {
            if (transfer != .object) return error.QuickShareUnavailable;
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
    pub fn get_pending_share(allocator: std.mem.Allocator, io: std.Io) ![]const u8 {
        pending_share_lock.lockUncancelable(io);
        defer pending_share_lock.unlock(io);
        if (pending_share_json) |json| {
            defer {
                std.heap.smp_allocator.free(json);
                pending_share_json = null;
            }
            return std.fmt.allocPrint(allocator, "{{\"ok\":true,\"data\":{s}}}", .{json});
        }
        return allocator.dupe(u8, "{\"ok\":true,\"data\":null}");
    }
    pub fn settings_get(allocator: std.mem.Allocator, io: std.Io) !SettingsView {
        return settings_view(allocator, io);
    }
    /// Save the device name (empty: the system's name), which takes effect
    /// at once (mDNS re-announces it). `default_folder` also goes back to
    /// the platform default (empty in the settings file).
    pub fn settings_save(allocator: std.mem.Allocator, io: std.Io, args: struct { device_name: []const u8 = "", default_folder: bool = false }) !SettingsView {
        const trimmed = std.mem.trim(u8, args.device_name, " \t\r\n");
        if (trimmed.len > 64) return oriel.ipc.fail("Device names can be up to 64 characters long", .{});
        // Back to the default folder the way Settings' own control does it,
        // so the engine saves there from now on (not only after a restart).
        if (args.default_folder) try apply_folder(allocator, io, null);
        var next = try current_settings(allocator);
        next.device_name = trimmed;
        try store_settings(allocator, io, next);
        set_device_name(allocator);
        return settings_view(allocator, io);
    }
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
    const unreadable_clipboard_image = "The image on the clipboard couldn't be read. Copy it again, or share it as a file";
    /// The clipboard's text, or with no text, its image saved as a PNG in
    /// HollerShare's cache folder (named so a HollerShare receiver puts it
    /// on its own clipboard). Neither: empty text.
    pub fn read_clipboard(allocator: std.mem.Allocator, io: std.Io) !ClipboardContent {
        var text_error: ?anyerror = null;
        const text = oriel.clipboard.readText(allocator) catch |err| blk: {
            text_error = err;
            break :blk "";
        };
        if (text.len > 1024 * 1024) return oriel.ipc.fail("Clipboard text exceeds 1 MB", .{});
        // Android's text view of an image clip is its content:// address
        // (clipboard_image.pick decides): only read the image when needed.
        var image_error: ?anyerror = null;
        const png: ?[]u8 = if (clipboard_image.pick(text, .none, android) == .text) null else oriel.clipboard.readImage(allocator) catch |err| blk: {
            image_error = err;
            break :blk null;
        };
        const read: clipboard_image.ImageRead = if (png != null) .got else if (image_error != null) .failed else .none;
        const bytes = switch (clipboard_image.pick(text, read, android)) {
            .text => return .{ .text = text },
            .unreadable_image => return oriel.ipc.fail(unreadable_clipboard_image, .{}),
            .nothing => {
                if (text_error) |err| return err;
                if (image_error) |err| return err;
                return .{ .text = "" };
            },
            .image => png.?,
        };
        defer allocator.free(bytes);
        if (bytes.len > clipboard_image.max_bytes) return oriel.ipc.fail("Clipboard images can be up to 32 MB", .{});
        const cache = try oriel.paths.appCache(allocator, .{ .name = app_id });
        defer allocator.free(cache);
        const dir = try std.fs.path.join(allocator, &.{ cache, "clipboard" });
        defer allocator.free(dir);
        const now = std.Io.Timestamp.now(io, .real).toSeconds();
        const saved = clipboard_image.save(allocator, io, dir, bytes, now) catch |err|
            return oriel.ipc.fail("The clipboard image couldn't be saved for sharing: {s}", .{@errorName(err)});
        return .{ .text = "", .image = .{ .path = saved.path, .name = saved.name, .size = saved.size } };
    }
    /// Put the one image a transfer received on the clipboard.
    pub fn copy_image(allocator: std.mem.Allocator, args: struct { id: []const u8 }) !void {
        var arena: std.heap.ArenaAllocator = .init(allocator);
        defer arena.deinit();
        const file = try single_image(arena.allocator(), args.id) orelse return oriel.ipc.fail("This transfer isn't a single image", .{});
        copy_file(arena.allocator(), file.path) catch |err| return switch (err) {
            error.FileNotFound => oriel.ipc.fail("The image isn't where it was received any more", .{}),
            error.StreamTooLong => oriel.ipc.fail("Images over 32 MB can't go on the clipboard", .{}),
            error.NotPng => oriel.ipc.fail("Only PNG images can go on the clipboard, and this file isn't one", .{}),
            else => oriel.ipc.fail("The image couldn't be copied: {s}", .{@errorName(err)}),
        };
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
        return .{ .dark = if (desktop_linux) hollershare_desktop_dark() != 0 else null, .android = android };
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
            if (hollershare_open_path(path) == 0) return oriel.ipc.fail("Could not open this file or folder", .{});
        } else if (android) {
            // Oriel's openExternal can't hand another app a file of
            // HollerShare's (no content:// grant), nor a document of the
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
    // The phone camera (src/camera/app.zig): "Use as webcam" on Android,
    // "Phone camera" on Linux.
    pub fn camera_status(allocator: std.mem.Allocator, io: std.Io) !camera.Status {
        return camera.status(allocator, io);
    }
    pub fn camera_phone_start(allocator: std.mem.Allocator, io: std.Io) !camera.Status {
        const name = try advertised_name(allocator);
        camera.phoneStart(allocator, io, name) catch |err| return switch (err) {
            error.CameraPermissionDenied => oriel.ipc.fail("HollerShare needs the camera permission to be a webcam", .{}),
            else => oriel.ipc.fail("The webcam couldn't start: {s}", .{@errorName(err)}),
        };
        return camera.status(allocator, io);
    }
    pub fn camera_phone_stop(allocator: std.mem.Allocator, io: std.Io) !camera.Status {
        camera.phoneStop(io);
        return camera.status(allocator, io);
    }
    pub fn camera_find(allocator: std.mem.Allocator, io: std.Io) ![]const @import("camera/desktop.zig").Found {
        return camera.find(allocator, io) catch |err| oriel.ipc.fail("Looking for phones failed: {s}", .{@errorName(err)});
    }
    pub fn camera_connect(allocator: std.mem.Allocator, io: std.Io, args: struct { address: []const u8, code: []const u8 }) !camera.Status {
        const name = try advertised_name(allocator);
        camera.connect(io, args.address, args.code, name) catch |err| return switch (err) {
            error.InvalidCode => oriel.ipc.fail("Type the 6-digit code the phone shows", .{}),
            error.InvalidAddress => oriel.ipc.fail("Use the phone's address, like 192.168.1.20:47311", .{}),
            else => oriel.ipc.fail("Couldn't connect: {s}", .{@errorName(err)}),
        };
        return camera.status(allocator, io);
    }
    pub fn camera_stop(allocator: std.mem.Allocator, io: std.Io) !camera.Status {
        camera.stop(io);
        return camera.status(allocator, io);
    }
    pub fn camera_switch(io: std.Io) !void {
        camera.switchCamera(io) catch |err| return oriel.ipc.fail("Couldn't switch cameras: {s}", .{@errorName(err)});
    }
    pub fn camera_view(allocator: std.mem.Allocator, io: std.Io, args: struct { rotate: u16, mirror: bool, fill: bool }) !camera.Status {
        camera.setView(io, data_dir, .{ .rotate = args.rotate, .mirror = args.mirror, .fill = args.fill }) catch |err| return oriel.ipc.fail("Couldn't turn the picture: {s}", .{@errorName(err)});
        return camera.status(allocator, io);
    }
    pub fn camera_quality(allocator: std.mem.Allocator, io: std.Io, args: struct { height: u16, fps: u8, jpeg: u8 }) !camera.Status {
        camera.setQuality(io, data_dir, .{ .height = args.height, .fps = args.fps, .jpeg = args.jpeg }) catch |err| return oriel.ipc.fail("Couldn't change the quality: {s}", .{@errorName(err)});
        return camera.status(allocator, io);
    }
    pub fn camera_setup(allocator: std.mem.Allocator, io: std.Io) !camera.SetupResult {
        return camera.setup(allocator, io);
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
    /// Android: the engine receives into HollerShare's folder, and finished
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
/// Android: always HollerShare's own folder, the staging area for
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
    camera.loadSaved(init.io, data_dir);
    const arena = init.arena.allocator();
    if (init.minimal.args.toSlice(arena)) |all_args| {
        handle_share_args(all_args);
    } else |_| {}
    if (builtin.abi != .android) {
        const all_args = try init.minimal.args.toSlice(arena);
        const argv = try arena.alloc([]const u8, all_args.len -| 1);
        for (argv, 1..) |*a, i| a.* = all_args[i];

        if (cli.isCliCommand(argv)) {
            set_device_name(init.gpa);
            return cli.run(init, argv);
        }
        handle_desktop_file_args(arena, argv);
    }

    const directory = if (builtin.abi == .android) try std.fs.path.join(init.arena.allocator(), &.{ try oriel.paths.appExternal(init.arena.allocator(), .{ .name = app_id }), "Received" }) else "";
    default_directory = try init.arena.allocator().dupeZ(u8, directory);
    engine_directory = try init.arena.allocator().dupeZ(u8, start_directory(init.io));
    defer android_multicast.release();
    defer android_beacon.stop();
    if (builtin.abi != .android) try start_engine(init.arena.allocator());
    defer hollershare_stop();
    defer camera.shutdown(app_io);
    defer {
        hollershare_set_event_callback(null);
        if (@hasDecl(oriel.notification, "onAction")) oriel.notification.onAction(null);
        if (oriel.tray.available) if (tray) |icon| icon.deinit();
        if (desktop_linux) hollershare_desktop_cleanup();
    }
    if (desktop_linux) try oriel.hooks.subscribe(.{ .window_created = window_created, .window_destroyed = window_destroyed });
    if (oriel.options.zig_ui) @import("oriel_frontend.zig").configure(init.io);
    return oriel.main(init, .{ .commands = Commands, .events = Events }, .{
        .app = app.build,
        .window = .{
            .title = "HollerShare",
            .width = 980,
            .height = 860,
            .hide_on_close = builtin.abi != .android,
        },
        .setup = setup,
        .on_second_instance = second_instance,
    });
}
