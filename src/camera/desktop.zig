//! The computer's half of the camera protocol (protocol.zig): find phones
//! with "Use as webcam" on, connect to one with the code it shows, and
//! hand every frame to a `Sink` (Linux: the "HollerShare Camera" video
//! device, v4l2.zig; tests: memory).
const std = @import("std");
const protocol = @import("protocol.zig");
const Facing = protocol.Facing;
const net = @import("net.zig");

const log = std.log.scoped(.camera);

pub const Size = struct { width: u32, height: u32 };

/// Whether a frame reached the device or was dropped (it was busy).
pub const Delivery = enum { written, dropped };

/// Where frames go.
pub const Sink = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// The session starts with frames of this size; the size the sink
        /// took, which differs when a video app holds another one.
        open: *const fn (ctx: *anyopaque, width: u32, height: u32) anyerror!Size,
        write: *const fn (ctx: *anyopaque, jpeg: []const u8) anyerror!Delivery,
        close: *const fn (ctx: *anyopaque) void,
    };
};

/// The height to ask the phone for to match a device held at `size`:
/// any about-16:9 size a session can ask for (a phone without the preset
/// size streams a smaller one, like 640x360 for 480p, and a video app may
/// keep that); null when the phone can't be asked for it.
pub fn followableHeight(size: Size) ?u16 {
    const Q = protocol.Quality;
    if (size.height < Q.min_height or size.height > Q.max_height) return null;
    if (!Q.wide(size.width, size.height)) return null;
    return @intCast(size.height);
}

pub const Found = struct { name: []const u8, address: []const u8 };

/// Phones that answer a broadcast within `timeout_ms` (strings in `arena`).
pub fn discover(arena: std.mem.Allocator, io: std.Io, timeout_ms: u32, port: u16) ![]Found {
    const any: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) };
    var socket = try any.bind(io, .{ .mode = .dgram, .allow_broadcast = true });
    defer socket.close(io);
    var probe: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&probe);
    try std.json.Stringify.value(protocol.Probe{ .hollershare_camera = protocol.version }, .{}, &w);
    const targets = [_]std.Io.net.IpAddress{
        .{ .ip4 = .{ .bytes = .{ 255, 255, 255, 255 }, .port = port } },
        // This computer too, for a phone emulator or a test on loopback.
        .{ .ip4 = .loopback(port) },
    };
    for (targets) |target| socket.send(io, &target, w.buffered()) catch |err| log.debug("camera probe: {s}", .{@errorName(err)});

    var found: std.ArrayList(Found) = .empty;
    const deadline = std.Io.Clock.awake.now(io).addDuration(.fromMilliseconds(timeout_ms)).withClock(.awake);
    var buf: [512]u8 = undefined;
    while (true) {
        const message = socket.receiveTimeout(io, &buf, .{ .deadline = deadline }) catch |err| switch (err) {
            error.Timeout => break,
            else => return err,
        };
        const announce = std.json.parseFromSliceLeaky(protocol.Announce, arena, message.data, .{ .ignore_unknown_fields = true }) catch continue;
        if (announce.hollershare_camera != protocol.version) continue;
        var from = message.from;
        from.setPort(announce.port);
        const address = try std.fmt.allocPrint(arena, "{f}", .{from});
        const known = for (found.items) |f| {
            if (std.mem.eql(u8, f.address, address)) break true;
        } else false;
        if (known) continue;
        var name_buf: [64]u8 = undefined;
        try found.append(arena, .{ .name = try arena.dupe(u8, protocol.cleanName(&name_buf, announce.name)), .address = address });
    }
    return found.items;
}

pub const State = enum { idle, connecting, streaming, failed };

/// What the page shows.
pub const Status = struct {
    state: State,
    phone: ?[]const u8,
    width: u32,
    height: u32,
    frames: u64,
    /// Frames a second, over the last second or so.
    fps: u32,
    /// Frames the device was too busy to take (not in `frames`).
    dropped: u64,
    /// The height a video app holds the device at, when the stream follows
    /// it instead of `quality` (until the app closes the camera).
    held_by_app: ?u16,
    /// The phone's lens: it starts on the back one, and only this computer
    /// switches it.
    facing: Facing,
    /// How the phone turns the picture (kept across sessions).
    view: protocol.View,
    /// The size, frame rate and JPEG quality asked for (kept across sessions).
    quality: protocol.Quality,
    @"error": ?[]const u8,
};

pub const Desktop = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    sink: Sink,
    /// A phone that doesn't take the connection within this ends the try.
    connect_timeout_ms: u32 = 5_000,
    /// The handshake, from the connection to sending our confirmation
    /// (longer than the phone's 3 s plus its longest wrong-code wait, 8 s).
    handshake_timeout_ms: u32 = 15_000,
    /// Then the phone's camera start, up to its frame size (longer than
    /// the phone's own 15 s, so the phone's reason comes first).
    camera_start_timeout_ms: u32 = 20_000,
    /// No frame for this long ends the session (the phone locked or left).
    frame_timeout_ms: u32 = 10_000,

    /// Serializes begin and stop (a stop joins the session before a new
    /// one can start).
    lifecycle: std.Io.Mutex = .init,
    /// Guards the state below; never held across network writes.
    mutex: std.Io.Mutex = .init,
    state: State = .idle,
    thread: ?std.Thread = null,
    stopping: std.atomic.Value(bool) = .init(false),
    /// The session's socket, to wake on stop; cleared before it closes.
    socket: ?net.Handle = null,
    phone_buf: [64]u8 = undefined,
    phone_len: usize = 0,
    width: u32 = 0,
    height: u32 = 0,
    frames: u64 = 0,
    fps: u32 = 0,
    facing: Facing = .back,
    dropped: u64 = 0,
    held_by_app: ?u16 = null,
    view: protocol.View = .{},
    quality: protocol.Quality = .{},
    /// The last session's phone, code and name, to reconnect with.
    last_job: ?Job = null,
    error_buf: [200]u8 = undefined,
    error_len: usize = 0,

    /// Guards `link` and every write to the phone after the handshake.
    write_mutex: std.Io.Mutex = .init,
    /// The streaming session's sending half (on its thread's stack);
    /// cleared before the session ends.
    link: ?*Link = null,

    const Link = struct {
        writer: *std.Io.Writer,
        sealer: *protocol.Sealer,
    };

    /// Connect to the phone at `address` ("192.168.1.20:47311") with the
    /// `code` it shows, as `name`; the session runs on its own thread.
    pub fn connect(self: *Desktop, address: []const u8, code: []const u8, name: []const u8) !void {
        if (!protocol.validCode(code)) return error.InvalidCode;
        const target = try parseAddress(address);
        var job: Job = .{ .target = target, .code = undefined, .name = undefined, .name_len = 0 };
        @memcpy(&job.code, code[0..protocol.code_digits]);
        var name_buf: [64]u8 = undefined;
        const clean = protocol.cleanName(&name_buf, name);
        @memcpy(job.name[0..clean.len], clean);
        job.name_len = clean.len;
        try self.begin(job);
    }

    /// Start a session for `job`, ending the current one.
    fn begin(self: *Desktop, job: Job) !void {
        self.lifecycle.lockUncancelable(self.io);
        defer self.lifecycle.unlock(self.io);
        try self.beginLocked(job);
    }

    /// `begin`, under `lifecycle`.
    fn beginLocked(self: *Desktop, job: Job) !void {
        self.end();
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.last_job = job;
        self.state = .connecting;
        self.error_len = 0;
        self.frames = 0;
        self.fps = 0;
        self.dropped = 0;
        self.held_by_app = null;
        self.phone_len = 0;
        self.stopping.store(false, .release);
        self.thread = std.Thread.spawn(.{}, run, .{ self, job }) catch |err| {
            self.state = .idle;
            return err;
        };
    }

    /// End the session, if any, and wait for it.
    pub fn stop(self: *Desktop) void {
        self.lifecycle.lockUncancelable(self.io);
        defer self.lifecycle.unlock(self.io);
        self.end();
    }

    /// Under `lifecycle`: wake the session (a pending connect sees
    /// `stopping`) and join it.
    fn end(self: *Desktop) void {
        self.stopping.store(true, .release);
        self.mutex.lockUncancelable(self.io);
        if (self.socket) |fd| net.wake(fd);
        const thread = self.thread;
        self.thread = null;
        self.mutex.unlock(self.io);
        if (thread) |t| t.join();
    }

    /// Ask the phone for its other camera.
    pub fn switchCamera(self: *Desktop) !void {
        try self.send(.@"switch");
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.facing = if (self.facing == .back) .front else .back;
    }

    /// Turn, mirror or fit the picture: now, when streaming, and in every
    /// later session.
    pub fn setView(self: *Desktop, view: protocol.View) !void {
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.view = view.normalized();
        }
        self.send(.view) catch |err| switch (err) {
            error.NotStreaming => {},
            else => return err,
        };
    }

    /// A new size, frame rate or JPEG quality, for this session and the
    /// next. A new size reconnects (the phone's camera reopens at it); a
    /// frame rate or JPEG quality set while connecting is sent when the
    /// stream starts.
    pub fn setQuality(self: *Desktop, quality: protocol.Quality) !void {
        const q = quality.normalized();
        const resize = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (q.height != self.quality.height) break :blk true;
            self.quality = q;
            break :blk false;
        };
        if (resize) {
            // Whether to reconnect is decided under `lifecycle`, so a stop
            // that came first stays.
            self.lifecycle.lockUncancelable(self.io);
            defer self.lifecycle.unlock(self.io);
            const reconnect = blk: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                const new_height = q.height != self.quality.height;
                self.quality = q;
                const live = self.state == .streaming or self.state == .connecting;
                break :blk if (new_height and live) self.last_job else null;
            };
            if (reconnect) |job| return self.beginLocked(job);
        }
        self.send(.quality) catch |err| switch (err) {
            error.NotStreaming => {},
            else => return err,
        };
    }

    /// Send the phone a control built from the current state.
    fn send(self: *Desktop, kind: protocol.ControlType) !void {
        self.write_mutex.lockUncancelable(self.io);
        defer self.write_mutex.unlock(self.io);
        const link = self.link orelse return error.NotStreaming;
        const control: protocol.Control = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk switch (kind) {
                .view => self.view.control(),
                .quality => self.quality.control(),
                else => .{ .type = kind },
            };
        };
        try link.sealer.writeJson(self.gpa, link.writer, .control, control);
    }

    pub fn status(self: *Desktop, arena: std.mem.Allocator) !Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return .{
            .state = self.state,
            .phone = if (self.phone_len > 0) try arena.dupe(u8, self.phone_buf[0..self.phone_len]) else null,
            .width = self.width,
            .height = self.height,
            .frames = self.frames,
            .fps = self.fps,
            .dropped = self.dropped,
            .held_by_app = self.held_by_app,
            .facing = self.facing,
            .view = self.view,
            .quality = self.quality,
            .@"error" = if (self.error_len > 0) try arena.dupe(u8, self.error_buf[0..self.error_len]) else null,
        };
    }

    const Job = struct {
        target: std.Io.net.IpAddress,
        code: [protocol.code_digits]u8,
        name: [64]u8,
        name_len: usize,
    };

    fn run(self: *Desktop, job: Job) void {
        // A video app holding the device at a size the phone may make:
        // reconnect once, asking for it.
        var held: ?Size = null;
        while (true) {
            const retry = self.session(job, held) catch |err| {
                if (!self.stopping.load(.acquire)) self.fail(err);
                break;
            };
            if (retry == null or held != null or self.stopping.load(.acquire)) break;
            held = retry;
            log.info("camera: a video app holds the device at {d}x{d}, reconnecting at it", .{ retry.?.width, retry.?.height });
        }
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.state != .failed) self.state = .idle;
    }

    fn fail(self: *Desktop, err: anyerror) void {
        const message: []const u8 = switch (err) {
            error.ConnectionRefused => "The phone isn't taking connections. Turn on Use as webcam in HollerShare on the phone.",
            error.Timeout, error.HostUnreachable, error.NetworkUnreachable => "The phone didn't answer. Check that both devices are on the same network.",
            error.EndOfStream, error.ReadFailed => "The phone stopped the camera, or the connection dropped.",
            error.CameraStartFailed => "The phone's camera didn't start. Open HollerShare on the phone, with its screen on, and try again.",
            error.EndedBeforeReady => "The connection to the phone ended before its camera was ready. Keep HollerShare open on the phone, with its screen on, and try again.",
            error.FrameTimeout => "The phone stopped sending video. Keep HollerShare open on the phone, with its screen on.",
            error.UnsupportedVersion => "The phone runs another version of HollerShare. Update both to the same version.",
            error.AuthenticationFailed, error.BadHandshake, error.UnexpectedFrame => "The connection to the phone was tampered with or broke. Try again.",
            error.NoCameraDevice => "There is no HollerShare Camera device yet. Set it up first.",
            error.DeviceBusy => "Another program is writing to the HollerShare Camera device.",
            error.FormatRefused => "A video app has the HollerShare Camera open at another resolution. Close it, or pick the resolution it was using.",
            else => "",
        };
        log.warn("camera session ended: {s}", .{@errorName(err)});
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.state = .failed;
        if (self.error_len > 0) return; // the phone's own reason
        const text = (if (message.len > 0)
            std.fmt.bufPrint(&self.error_buf, "{s}", .{message})
        else
            std.fmt.bufPrint(&self.error_buf, "The camera stopped ({s}).", .{@errorName(err)})) catch self.error_buf[0..0];
        self.error_len = text.len;
    }

    fn setError(self: *Desktop, text: []const u8) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.error_len = protocol.cleanText(&self.error_buf, text).len;
    }

    /// One connection, at the size a video app holds when `held` is set.
    /// Null when it ended; else the size a video app holds the device at
    /// (one the phone may make), to reconnect at.
    fn session(self: *Desktop, job: Job, held: ?Size) !?Size {
        const stream = try net.connect(job.target, self.connect_timeout_ms, &self.stopping);
        defer stream.close(self.io);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.socket = stream.socket.handle;
            if (self.stopping.load(.acquire)) {
                self.socket = null;
                return error.Canceled;
            }
        }
        // Runs before the close above: stop never wakes a reused fd.
        defer {
            self.mutex.lockUncancelable(self.io);
            self.socket = null;
            self.mutex.unlock(self.io);
        }
        // One deadline for the handshake, one for the camera start, then
        // one per frame.
        var watchdog: net.Watchdog = .{ .io = self.io, .fd = stream.socket.handle };
        watchdog.arm(self.handshake_timeout_ms);
        try watchdog.start();
        defer watchdog.stop();
        var phase: Phase = .handshake;
        return self.talk(stream, &watchdog, &phase, job, held) catch |err| switch (phase) {
            .handshake => if (watchdog.expired()) error.Timeout else err,
            // Our own deadline; else a bare hang-up (the phone's camera
            // deadline, the phone turned off, the network) says only that
            // the connection ended: the phone's sealed reasons come as
            // `Refused`.
            .camera_start => if (watchdog.expired()) error.CameraStartFailed else switch (err) {
                error.EndOfStream, error.ReadFailed => error.EndedBeforeReady,
                else => err,
            },
            .streaming => if (watchdog.expired()) error.FrameTimeout else err,
        };
    }

    /// Which deadline the session is under.
    const Phase = enum { handshake, camera_start, streaming };

    fn talk(self: *Desktop, stream: std.Io.net.Stream, watchdog: *net.Watchdog, phase: *Phase, job: Job, held: ?Size) !?Size {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var read_buf: [64 * 1024]u8 = undefined;
        var write_buf: [1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var writer = stream.writer(self.io, &write_buf);

        // The key exchange (protocol.zig).
        const hello_frame = try protocol.readMessage(&reader.interface, arena);
        const hello = try protocol.parseJson(arena, protocol.Hello, hello_frame, .hello);
        if (hello.v != protocol.version) return error.UnsupportedVersion;
        const phone_nonce = try protocol.unhex(protocol.nonce_length, hello.nonce);
        const computer_nonce = protocol.newNonce(self.io);
        var handshake = try protocol.Handshake.init(self.io, .computer, &job.code, phone_nonce, computer_nonce);
        defer handshake.wipe();
        var quality = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk self.quality;
        };
        // The preference stays a preset; this session asks for the held
        // height exactly.
        if (held) |h| quality.height = @intCast(h.height);
        const nonce_hex = protocol.hex(protocol.nonce_length, computer_nonce);
        const share_hex = protocol.hex(protocol.share_length, handshake.share);
        var auth_buf: [protocol.max_message_bytes]u8 = undefined;
        const auth = try protocol.encodeJson(&auth_buf, protocol.Auth{ .name = job.name[0..job.name_len], .nonce = &nonce_hex, .share = &share_hex, .quality = quality });
        try protocol.writeFrame(&writer.interface, .auth, auth);
        handshake.absorb(hello_frame.payload);
        handshake.absorb(auth);
        const answer = try protocol.readJson(&reader.interface, arena, protocol.Answer, .answer);
        var keys = try handshake.finish(try protocol.unhex(protocol.share_length, answer.share));
        defer keys.wipe();
        // The phone proves it knows the code before anything else happens.
        if (!keys.peerConfirms(answer.confirm)) {
            self.setError(protocol.wrong_code_error);
            return error.WrongCode;
        }
        const confirm_hex = protocol.hex(protocol.confirm_length, keys.own());
        try protocol.writeJson(&writer.interface, .confirm, protocol.Confirm{ .confirm = &confirm_hex });
        phase.* = .camera_start;
        watchdog.arm(self.camera_start_timeout_ms);

        var sealer = keys.sealer();
        defer sealer.deinit(self.gpa);
        var opener = keys.opener();
        defer opener.wipe();
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);

        // The phone's answer is sealed. Anything unsealed can't be trusted:
        // a plain refusal (what an older phone sends when it finds our
        // confirmation wrong) shows the fixed wrong-code text, never its own.
        const ready_frame = try protocol.readFrame(&reader.interface, self.gpa, &buf, protocol.max_message_bytes);
        if (ready_frame.type == .ready) {
            self.setError(protocol.wrong_code_error);
            return error.WrongCode;
        }
        const ready = try protocol.parseJson(arena, protocol.Ready, try opener.open(ready_frame), .ready);
        if (!ready.ok) {
            self.setError(ready.@"error" orelse "The phone refused the connection.");
            return error.Refused;
        }
        if (ready.width == 0 or ready.height == 0 or ready.width > 4096 or ready.height > 4096) return error.BadFrameSize;
        // Asked for a held size: the phone has to make exactly that one.
        if (held) |h| if (ready.width != h.width or ready.height != h.height) return error.FormatRefused;
        const taken = try self.sink.vtable.open(self.sink.ctx, ready.width, ready.height);
        if (taken.width != ready.width or taken.height != ready.height) {
            self.sink.vtable.close(self.sink.ctx);
            // A video app holds the device at another size: ask the phone
            // for it, once, unless it was just asked for that height.
            const h = followableHeight(taken) orelse return error.FormatRefused;
            if (held != null or h == quality.height) return error.FormatRefused;
            return taken;
        }
        defer self.sink.vtable.close(self.sink.ctx);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var name_buf: [64]u8 = undefined;
            const name = protocol.cleanName(&name_buf, hello.name);
            @memcpy(self.phone_buf[0..name.len], name);
            self.phone_len = name.len;
            self.width = ready.width;
            self.height = ready.height;
            self.held_by_app = if (held) |h| @intCast(h.height) else null;
            self.facing = .back;
            self.state = .streaming;
        }

        // Controls write through the link from now on; it goes before the
        // sealer, the writer and the socket do.
        var link: Link = .{ .writer = &writer.interface, .sealer = &sealer };
        {
            self.write_mutex.lockUncancelable(self.io);
            defer self.write_mutex.unlock(self.io);
            self.link = &link;
        }
        defer {
            self.write_mutex.lockUncancelable(self.io);
            self.link = null;
            self.write_mutex.unlock(self.io);
        }
        // What changed while connecting reaches the phone now: a control
        // sent before the link was up found none (`send` reads the state
        // after taking the link, so nothing set before this is missed).
        try self.send(.view);
        try self.send(.quality);

        phase.* = .streaming;
        watchdog.arm(self.frame_timeout_ms);
        var window_start = std.Io.Clock.awake.now(self.io);
        var window_frames: u32 = 0;
        while (!self.stopping.load(.acquire)) {
            const frame = try opener.read(&reader.interface, self.gpa, &buf, protocol.max_frame_bytes);
            if (frame.type != .jpeg) continue;
            watchdog.arm(self.frame_timeout_ms);
            const delivery = try self.sink.vtable.write(self.sink.ctx, frame.payload);
            if (delivery == .written) window_frames += 1;
            const now = std.Io.Clock.awake.now(self.io);
            const elapsed_ms = window_start.durationTo(now).toMilliseconds();
            self.mutex.lockUncancelable(self.io);
            switch (delivery) {
                .written => self.frames += 1,
                .dropped => self.dropped += 1,
            }
            if (elapsed_ms >= 1000) {
                self.fps = @intCast(@divTrunc(@as(i64, window_frames) * 1000, elapsed_ms));
                window_frames = 0;
                window_start = now;
            }
            self.mutex.unlock(self.io);
        }
        return null;
    }
};

/// "192.168.1.20:47311", or an address without a port (the default one).
pub fn parseAddress(text: []const u8) !std.Io.net.IpAddress {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.lastIndexOfScalar(u8, trimmed, ':')) |colon| {
        if (std.mem.indexOfScalar(u8, trimmed, ':') == colon) {
            const port = std.fmt.parseInt(u16, trimmed[colon + 1 ..], 10) catch return error.InvalidAddress;
            return std.Io.net.IpAddress.parse(trimmed[0..colon], port) catch error.InvalidAddress;
        }
    }
    return std.Io.net.IpAddress.parse(trimmed, protocol.session_port) catch error.InvalidAddress;
}

test "addresses take a port or the default one" {
    const a = try parseAddress("192.168.1.20:5000");
    try std.testing.expectEqual(@as(u16, 5000), a.getPort());
    const b = try parseAddress(" 10.0.0.2 ");
    try std.testing.expectEqual(protocol.session_port, b.getPort());
    try std.testing.expectError(error.InvalidAddress, parseAddress("phone"));
    try std.testing.expectError(error.InvalidAddress, parseAddress("10.0.0.2:x"));
}

test "held sizes about 16:9 within range can be asked for" {
    try std.testing.expectEqual(@as(?u16, 480), followableHeight(.{ .width = 854, .height = 480 }));
    try std.testing.expectEqual(@as(?u16, 480), followableHeight(.{ .width = 853, .height = 480 }));
    try std.testing.expectEqual(@as(?u16, 720), followableHeight(.{ .width = 1280, .height = 720 }));
    try std.testing.expectEqual(@as(?u16, 1080), followableHeight(.{ .width = 1920, .height = 1080 }));
    // Off the presets: what a phone streams when it lacks the preset size.
    try std.testing.expectEqual(@as(?u16, 360), followableHeight(.{ .width = 640, .height = 360 }));
    try std.testing.expectEqual(@as(?u16, 540), followableHeight(.{ .width = 960, .height = 540 }));
    try std.testing.expectEqual(@as(?u16, null), followableHeight(.{ .width = 640, .height = 480 }));
    try std.testing.expectEqual(@as(?u16, null), followableHeight(.{ .width = 1280, .height = 700 }));
    try std.testing.expectEqual(@as(?u16, null), followableHeight(.{ .width = 320, .height = 180 }));
    try std.testing.expectEqual(@as(?u16, null), followableHeight(.{ .width = 4096, .height = 2304 }));
}

test "a resize that loses to a stop doesn't reconnect" {
    std.testing.log_level = .err;
    const io = std.testing.io;
    // A "phone" that takes the connection and says nothing: connecting.
    const any: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{});
    defer server.deinit(io);
    const NullSink = struct {
        fn open(_: *anyopaque, width: u32, height: u32) anyerror!Size {
            return .{ .width = width, .height = height };
        }
        fn write(_: *anyopaque, _: []const u8) anyerror!Delivery {
            return .written;
        }
        fn close(_: *anyopaque) void {}
        const vtable: Sink.VTable = .{ .open = open, .write = write, .close = close };
    };
    var unused: u8 = 0;
    var desktop: Desktop = .{ .io = io, .gpa = std.testing.allocator, .sink = .{ .ctx = &unused, .vtable = &NullSink.vtable } };
    defer desktop.stop();
    var address_buf: [32]u8 = undefined;
    try desktop.connect(try std.fmt.bufPrint(&address_buf, "127.0.0.1:{d}", .{server.socket.address.getPort()}), "123456", "Studio");

    // The resize starts while a stop holds the lifecycle, and the stop
    // ends the session before the resize can look at it.
    desktop.lifecycle.lockUncancelable(io);
    const resize = try std.Thread.spawn(.{}, struct {
        fn f(d: *Desktop) void {
            d.setQuality(.{ .height = 480 }) catch {};
        }
    }.f, .{&desktop});
    try io.sleep(.fromMilliseconds(50), .awake);
    desktop.end();
    desktop.lifecycle.unlock(io);
    resize.join();

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const status = try desktop.status(arena.allocator());
    try std.testing.expectEqual(State.idle, status.state);
    try std.testing.expectEqual(@as(u16, 480), status.quality.height); // kept for next time
    try std.testing.expect(desktop.thread == null);
}
