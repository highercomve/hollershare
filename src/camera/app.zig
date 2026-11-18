//! The phone camera in the app: on Android, "Use as webcam" (the phone
//! streams its camera); on Linux, "Phone camera" (the computer shows a
//! phone's camera as the HollerShare Camera device). main.zig's commands
//! call these; the page shows `status`.
const std = @import("std");
const builtin = @import("builtin");
const protocol = @import("protocol.zig");
const phone_mod = @import("phone.zig");
const desktop_mod = @import("desktop.zig");
const net = @import("net.zig");

const android = builtin.abi == .android;
const desktop_linux = builtin.os.tag == .linux and !android;
const v4l2 = if (desktop_linux) @import("v4l2.zig") else struct {};
const camera_android = if (android) @import("camera_android.zig") else struct {};

const log = std.log.scoped(.camera);

pub const Role = enum { phone, computer, none };
pub const role: Role = if (android) .phone else if (desktop_linux) .computer else .none;

pub const ComputerStatus = struct {
    /// Whether the HollerShare Camera device exists (else: Set up first).
    device: bool,
    session: desktop_mod.Status,
};

pub const Status = struct {
    role: Role,
    phone: ?phone_mod.Status = null,
    /// The phone's address for a computer that can't find it ("192.168.1.20:47311").
    phone_address: ?[]const u8 = null,
    computer: ?ComputerStatus = null,
};

var phone_state: if (android) phone_mod.Phone else void = undefined;
var desktop_state: if (desktop_linux) desktop_mod.Desktop else void = undefined;
var sink_state: if (desktop_linux) v4l2.Sink else void = undefined;
var ready = false;
var ready_lock: std.Io.Mutex = .init;

fn init(io: std.Io) void {
    ready_lock.lockUncancelable(io);
    defer ready_lock.unlock(io);
    if (ready) return;
    const gpa = std.heap.smp_allocator;
    if (android) phone_state = .{ .io = io, .gpa = gpa, .source = camera_android.source };
    if (desktop_linux) {
        sink_state = .{ .io = io };
        desktop_state = .{ .io = io, .gpa = gpa, .sink = sink_state.sink() };
    }
    ready = true;
}

pub fn status(arena: std.mem.Allocator, io: std.Io) !Status {
    init(io);
    return switch (role) {
        .phone => blk: {
            const st = try phone_state.status(arena);
            var ip_buf: [16]u8 = undefined;
            const address = if (st.on) if (net.localIp4(&ip_buf)) |ip| try std.fmt.allocPrint(arena, "{s}:{d}", .{ ip, st.port }) else null else null;
            break :blk .{ .role = .phone, .phone = st, .phone_address = address };
        },
        .computer => blk: {
            var buf: [64]u8 = undefined;
            break :blk .{ .role = .computer, .computer = .{
                .device = v4l2.find(io, &buf) != null,
                .session = try desktop_state.status(arena),
            } };
        },
        .none => .{ .role = .none },
    };
}

// --- The phone ---------------------------------------------------------

/// Turn on "Use as webcam" as `name` (asks for the camera permission first).
pub fn phoneStart(arena: std.mem.Allocator, io: std.Io, name: []const u8) anyerror!void {
    if (!android) return error.Unsupported;
    init(io);
    if (!try camera_android.permission(arena)) return error.CameraPermissionDenied;
    try phone_state.start(name);
}

pub fn phoneStop(io: std.Io) void {
    if (!android) return;
    init(io);
    phone_state.stop();
}

// --- The computer ------------------------------------------------------

/// Phones with "Use as webcam" on, answering within 1.5 s.
pub fn find(arena: std.mem.Allocator, io: std.Io) ![]desktop_mod.Found {
    if (!desktop_linux) return error.Unsupported;
    return desktop_mod.discover(arena, io, 1500, protocol.discovery_port);
}

pub fn connect(io: std.Io, address: []const u8, code: []const u8, name: []const u8) anyerror!void {
    if (!desktop_linux) return error.Unsupported;
    init(io);
    try desktop_state.connect(address, code, name);
}

pub fn stop(io: std.Io) void {
    if (!desktop_linux) return;
    init(io);
    desktop_state.stop();
}

pub fn switchCamera(io: std.Io) !void {
    if (!desktop_linux) return error.Unsupported;
    init(io);
    try desktop_state.switchCamera();
}

/// Turn, mirror or fit the phone's picture; kept in `dir`/camera.json
/// (when there is a `dir`) for the next sessions.
pub fn setView(io: std.Io, dir: ?[]const u8, view: protocol.View) !void {
    if (!desktop_linux) return error.Unsupported;
    init(io);
    try desktop_state.setView(view);
    save(io, dir);
}

/// The frame size, frame rate and JPEG quality; kept like the view.
pub fn setQuality(io: std.Io, dir: ?[]const u8, quality: protocol.Quality) !void {
    if (!desktop_linux) return error.Unsupported;
    init(io);
    try desktop_state.setQuality(quality);
    save(io, dir);
}

/// camera.json: the view and the quality.
const Saved = struct {
    rotate: u16 = 0,
    mirror: bool = false,
    fill: bool = false,
    height: u16 = 720,
    fps: u8 = 30,
    jpeg: u8 = 70,
};
const saved_file = "camera.json";
var save_lock: std.Io.Mutex = .init;

fn writeSaved(io: std.Io, d: std.Io.Dir, saved: Saved) !void {
    var buf: [256]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try std.json.Stringify.value(saved, .{}, &w);
    const temporary = saved_file ++ ".tmp";
    try d.writeFile(io, .{ .sub_path = temporary, .data = w.buffered() });
    errdefer d.deleteFile(io, temporary) catch {};
    try d.rename(temporary, d, saved_file, io);
}

fn save(io: std.Io, dir: ?[]const u8) void {
    const path = dir orelse return;
    save_lock.lockUncancelable(io);
    defer save_lock.unlock(io);
    var arena_buf: [512]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&arena_buf);
    const st = desktop_state.status(fba.allocator()) catch return;
    const saved: Saved = .{ .rotate = st.view.rotate, .mirror = st.view.mirror, .fill = st.view.fill, .height = st.quality.height, .fps = st.quality.fps, .jpeg = st.quality.jpeg };
    var d = std.Io.Dir.openDirAbsolute(io, path, .{}) catch |err| return log.warn("saving the camera settings: {s}", .{@errorName(err)});
    defer d.close(io);
    writeSaved(io, d, saved) catch |err| log.warn("saving the camera settings: {s}", .{@errorName(err)});
}

/// The view and quality saved before, for the first session.
pub fn loadSaved(io: std.Io, dir: ?[]const u8) void {
    if (!desktop_linux) return;
    init(io);
    const path = dir orelse return;
    var d = std.Io.Dir.openDirAbsolute(io, path, .{}) catch return;
    defer d.close(io);
    var buf: [256]u8 = undefined;
    const text = d.readFile(io, saved_file, &buf) catch return;
    var fba_buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    const saved = std.json.parseFromSliceLeaky(Saved, fba.allocator(), text, .{ .ignore_unknown_fields = true }) catch return;
    desktop_state.setView(.{ .rotate = saved.rotate, .mirror = saved.mirror, .fill = saved.fill }) catch {};
    desktop_state.setQuality(.{ .height = saved.height, .fps = saved.fps, .jpeg = saved.jpeg }) catch {};
}

pub const SetupResult = struct { ok: bool, message: []const u8 };

fn lastNonEmptyLine(text: []const u8) ?[]const u8 {
    var it = std.mem.splitBackwardsScalar(u8, text, '\n');
    while (it.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (trimmed.len > 0) return trimmed;
    }
    return null;
}

fn setupFailureMessage(stdout: []const u8, stderr: []const u8) []const u8 {
    return lastNonEmptyLine(stdout) orelse
        lastNonEmptyLine(stderr) orelse
        "Setting up the camera device failed.";
}

/// Make the HollerShare Camera device, as root through pkexec (the
/// desktop's password dialog).
pub fn setup(arena: std.mem.Allocator, io: std.Io) !SetupResult {
    if (!desktop_linux) return error.Unsupported;
    const result = std.process.run(arena, io, .{
        .argv = &.{ "pkexec", "/bin/sh", "-c", v4l2.setup_script },
        .stdout_limit = .limited(16 * 1024),
        .stderr_limit = .limited(16 * 1024),
    }) catch |err| return switch (err) {
        error.FileNotFound => .{ .ok = false, .message = "pkexec isn't installed, so HollerShare can't ask for the administrator password. Run the setup by hand (see the README)." },
        else => err,
    };
    const code: u32 = switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
    if (code == 0) return .{ .ok = true, .message = "The HollerShare Camera is ready. Apps list it with their cameras." };
    // pkexec: 126 dismissed, 127 not authorized.
    if (code == 126 or code == 127) return .{ .ok = false, .message = "The administrator password is needed to add the camera device." };
    log.warn("camera setup failed ({d}); stdout: {s}; stderr: {s}", .{ code, result.stdout, result.stderr });
    return .{ .ok = false, .message = setupFailureMessage(result.stdout, result.stderr) };
}

/// Stop everything before the app quits.
pub fn shutdown(io: std.Io) void {
    ready_lock.lockUncancelable(io);
    const was_ready = ready;
    ready_lock.unlock(io);
    if (!was_ready) return;
    if (android) phone_state.stop();
    if (desktop_linux) desktop_state.stop();
}

test "camera.json writes atomically without leaving a temporary file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    try writeSaved(io, tmp.dir, .{ .rotate = 90, .mirror = true, .fill = true, .height = 1080, .fps = 24, .jpeg = 85 });
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, saved_file ++ ".tmp", .{}));

    var buf: [256]u8 = undefined;
    const text = try tmp.dir.readFile(io, saved_file, &buf);
    var fba_buf: [1024]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&fba_buf);
    const loaded = try std.json.parseFromSliceLeaky(Saved, fba.allocator(), text, .{});
    try std.testing.expectEqual(@as(u16, 90), loaded.rotate);
    try std.testing.expect(loaded.mirror);
    try std.testing.expect(loaded.fill);
    try std.testing.expectEqual(@as(u16, 1080), loaded.height);
    try std.testing.expectEqual(@as(u8, 24), loaded.fps);
    try std.testing.expectEqual(@as(u8, 85), loaded.jpeg);

    // Overwriting keeps valid JSON and cleans up the temporary file.
    try writeSaved(io, tmp.dir, .{ .rotate = 180, .height = 480, .fps = 15, .jpeg = 50 });
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, saved_file ++ ".tmp", .{}));
    const text2 = try tmp.dir.readFile(io, saved_file, &buf);
    fba.reset();
    const loaded2 = try std.json.parseFromSliceLeaky(Saved, fba.allocator(), text2, .{});
    try std.testing.expectEqual(@as(u16, 180), loaded2.rotate);
    try std.testing.expectEqual(@as(u16, 480), loaded2.height);
}

test "setup failure picks the last non-empty output line" {
    try std.testing.expectEqualStrings("The real error", setupFailureMessage("first line\nThe real error\n   \n\r\n", "ignored stderr"));
    try std.testing.expectEqualStrings("stderr error", setupFailureMessage("   \n\n", "warn\n  stderr error  \n\n"));
    try std.testing.expectEqualStrings("Setting up the camera device failed.", setupFailureMessage("", " \n\t "));
}
