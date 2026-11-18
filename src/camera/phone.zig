//! The phone's half of the camera protocol (protocol.zig): "Use as webcam"
//! answers discovery, waits for a computer that knows the code it shows,
//! then streams the camera to it, one computer at a time. The camera itself
//! is a `Source` (Android: CameraExtension.kt through camera_android.zig;
//! tests: a fake), started only while a computer is connected.
const std = @import("std");
const protocol = @import("protocol.zig");
const net = @import("net.zig");

const log = std.log.scoped(.camera);

pub const locked_out_error = "Too many wrong codes. Turn on Use as webcam again for a new code.";
pub const slow_camera_error = "The camera took too long to start. Open HollerShare on the phone and try again.";

pub const Facing = protocol.Facing;
pub const Size = struct { width: u32, height: u32 };

/// The phone's camera.
pub const Source = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        /// Open the camera at about `quality`; the size every frame will have.
        start: *const fn (ctx: *anyopaque, facing: Facing, quality: protocol.Quality) anyerror!Size,
        /// The newest JPEG (in `arena`), waiting for one up to about a
        /// second; null when none came.
        next: *const fn (ctx: *anyopaque, arena: std.mem.Allocator) anyerror!?[]const u8,
        /// The other camera (front/back), at the same size.
        switch_camera: *const fn (ctx: *anyopaque) anyerror!void,
        /// Turn, mirror or fit the picture (on top of upright).
        set_view: *const fn (ctx: *anyopaque, view: protocol.View) anyerror!void,
        /// A new frame rate and JPEG quality (the size stays).
        set_quality: *const fn (ctx: *anyopaque, quality: protocol.Quality) anyerror!void,
        stop: *const fn (ctx: *anyopaque) void,
    };
};

pub const Options = struct {
    discovery_port: u16 = protocol.discovery_port,
    session_port: u16 = protocol.session_port,
    /// How long a connecting computer has for the handshake, from the
    /// connection to its confirmation of the key (plus any wrong-code
    /// wait).
    handshake_ms: u32 = 3_000,
    /// How long the camera has to start once the computer is confirmed,
    /// up to the computer having the frame size (the camera itself gives
    /// up after 8 s).
    camera_start_ms: u32 = 15_000,
    /// How long a frame may go without being sent on before the session
    /// ends (the computer stopped reading).
    send_timeout_ms: u32 = 5_000,
    /// The wait before answering after one wrong code; it doubles with
    /// each further wrong code in a row, up to `max_failure_delay_ms`.
    failure_delay_ms: u32 = 1_000,
    max_failure_delay_ms: u32 = 8_000,
    /// This many wrong codes in a row turn "Use as webcam" off.
    max_failures: u8 = 10,
};

/// The wait before answering a computer after `failures` wrong codes in a row.
pub fn failureDelay(options: Options, failures: u32) u32 {
    if (failures == 0) return 0;
    const shift: u5 = @intCast(@min(failures - 1, 31));
    const delay = std.math.shlExact(u64, options.failure_delay_ms, shift) catch return options.max_failure_delay_ms;
    return @intCast(@min(delay, options.max_failure_delay_ms));
}

/// What the page shows.
pub const Status = struct {
    on: bool,
    code: []const u8,
    /// The computer the camera streams to, when one is connected.
    computer: ?[]const u8,
    streaming: bool,
    frames: u64,
    /// Whether computers can find this phone (else: by its address only).
    discoverable: bool,
    port: u16,
    /// Wrong codes in a row since the last right one.
    failures: u32,
    /// The lens streaming: the back one at first, then as the computer
    /// switches it.
    facing: Facing,
    @"error": ?[]const u8,
};

pub const Phone = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    source: Source,
    options: Options = .{},

    /// Serializes start and stop.
    lifecycle: std.Io.Mutex = .init,
    /// Guards what `status` reads (and `failures`, `client`).
    mutex: std.Io.Mutex = .init,
    /// Taking computers (false once stopped or locked out).
    running: std.atomic.Value(bool) = .init(false),
    // Set by start before the threads run, constant while they do.
    name_buf: [64]u8 = undefined,
    name_len: usize = 0,
    server: ?std.Io.net.Server = null,
    udp: ?std.Io.net.Socket = null,
    accept_thread: ?std.Thread = null,
    discovery_thread: ?std.Thread = null,
    // Under `mutex`.
    code: [protocol.code_digits]u8 = @splat('0'),
    failures: u32 = 0,
    port: u16 = 0,
    discoverable: bool = false,
    /// The connected computer's socket, to wake on stop.
    client: ?net.Handle = null,
    computer_buf: [64]u8 = undefined,
    computer_len: usize = 0,
    streaming: bool = false,
    facing: Facing = .back,
    frames: u64 = 0,
    error_buf: [160]u8 = undefined,
    error_len: usize = 0,

    /// Start answering computers as `name` with a new code (after a lockout
    /// too: that is how the user gets a new code).
    pub fn start(self: *Phone, name: []const u8) !void {
        self.lifecycle.lockUncancelable(self.io);
        defer self.lifecycle.unlock(self.io);
        if (self.running.load(.acquire)) return;
        self.teardown();

        var clean_buf: [64]u8 = undefined;
        const clean = protocol.cleanName(&clean_buf, name);
        @memcpy(self.name_buf[0..clean.len], clean);
        self.name_len = clean.len;

        var server = try listen(self.io, self.options.session_port);
        errdefer server.deinit(self.io);
        // Discovery is a convenience: the phone's address still works without it.
        const any: std.Io.net.IpAddress = .{ .ip4 = .unspecified(self.options.discovery_port) };
        var udp: ?std.Io.net.Socket = any.bind(self.io, .{ .mode = .dgram }) catch |err| blk: {
            log.warn("camera discovery unavailable: {s}", .{@errorName(err)});
            break :blk null;
        };
        errdefer if (udp) |*u| u.close(self.io);

        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.code = protocol.newCode(self.io);
            self.failures = 0;
            self.frames = 0;
            self.error_len = 0;
            self.port = server.socket.address.getPort();
            self.discoverable = udp != null;
        }
        self.server = server;
        self.udp = udp;
        self.running.store(true, .release);
        errdefer {
            self.running.store(false, .release);
            self.server = null;
            self.udp = null;
            self.mutex.lockUncancelable(self.io);
            self.discoverable = false;
            self.mutex.unlock(self.io);
        }
        self.accept_thread = try std.Thread.spawn(.{}, acceptLoop, .{self});
        if (udp != null) self.discovery_thread = std.Thread.spawn(.{}, discoveryLoop, .{self}) catch |err| blk: {
            log.warn("camera discovery unavailable: {s}", .{@errorName(err)});
            break :blk null;
        };
    }

    /// Stop the camera and close everything.
    pub fn stop(self: *Phone) void {
        self.lifecycle.lockUncancelable(self.io);
        defer self.lifecycle.unlock(self.io);
        self.teardown();
    }

    /// Under `lifecycle`: end the threads and close the sockets (also what
    /// a lockout left open).
    fn teardown(self: *Phone) void {
        self.running.store(false, .release);
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            if (self.client) |fd| net.wake(fd);
            self.discoverable = false;
        }
        if (self.server) |*s| net.wake(s.socket.handle);
        if (self.accept_thread) |t| t.join();
        if (self.discovery_thread) |t| t.join();
        self.accept_thread = null;
        self.discovery_thread = null;
        if (self.server) |*s| s.deinit(self.io);
        if (self.udp) |*u| u.close(self.io);
        self.server = null;
        self.udp = null;
    }

    /// The current state; strings are copied into `arena`.
    pub fn status(self: *Phone, arena: std.mem.Allocator) !Status {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const on = self.running.load(.acquire);
        return .{
            .on = on,
            .code = if (on) try arena.dupe(u8, &self.code) else "",
            .computer = if (self.computer_len > 0) try arena.dupe(u8, self.computer_buf[0..self.computer_len]) else null,
            .streaming = self.streaming,
            .frames = self.frames,
            .discoverable = self.discoverable,
            .port = self.port,
            .failures = self.failures,
            .facing = self.facing,
            .@"error" = if (self.error_len > 0) try arena.dupe(u8, self.error_buf[0..self.error_len]) else null,
        };
    }

    fn setError(self: *Phone, comptime fmt: []const u8, args: anytype) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.error_len = formatCut(&self.error_buf, fmt, args).len;
    }

    fn acceptLoop(self: *Phone) void {
        while (self.running.load(.acquire)) {
            const stream = self.server.?.accept(self.io) catch |err| {
                if (!self.running.load(.acquire)) return;
                log.warn("camera accept: {s}", .{@errorName(err)});
                self.io.sleep(.fromMilliseconds(200), .awake) catch {};
                continue;
            };
            self.mutex.lockUncancelable(self.io);
            self.client = stream.socket.handle;
            self.mutex.unlock(self.io);
            self.session(stream) catch |err| switch (err) {
                error.Stalled => log.info("camera: the computer stalled, ending the session", .{}),
                error.CameraTimeout => log.warn("camera: the camera took too long to start", .{}),
                error.EndOfStream, error.ReadFailed, error.WriteFailed, error.WrongCode, error.Canceled => {},
                else => log.warn("camera session: {s}", .{@errorName(err)}),
            };
            self.mutex.lockUncancelable(self.io);
            self.client = null;
            self.streaming = false;
            self.computer_len = 0;
            self.mutex.unlock(self.io);
            stream.close(self.io);
        }
    }

    /// One computer, from hello to the end of its stream; error.Stalled
    /// when the watchdog ended it, error.CameraTimeout when the camera
    /// took too long to start.
    fn session(self: *Phone, stream: std.Io.net.Stream) !void {
        // One deadline for the handshake, so a computer trickling bytes
        // can't hold the (only) accept thread, then one for the camera
        // start (see `talk`).
        var watchdog: net.Watchdog = .{ .io = self.io, .fd = stream.socket.handle };
        watchdog.arm(self.options.handshake_ms);
        try watchdog.start();
        defer watchdog.stop();
        self.talk(stream, &watchdog) catch |err| {
            if (err == error.CameraTimeout) return err;
            return if (watchdog.expired()) error.Stalled else err;
        };
    }

    fn talk(self: *Phone, stream: std.Io.net.Stream, watchdog: *net.Watchdog) !void {
        var arena_state: std.heap.ArenaAllocator = .init(self.gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var read_buf: [8192]u8 = undefined;
        var write_buf: [64 * 1024]u8 = undefined;
        var reader = stream.reader(self.io, &read_buf);
        var writer = stream.writer(self.io, &write_buf);
        const fd = stream.socket.handle;

        const phone_nonce = protocol.newNonce(self.io);
        const nonce_hex = protocol.hex(protocol.nonce_length, phone_nonce);
        var hello_buf: [protocol.max_message_bytes]u8 = undefined;
        const hello = try protocol.encodeJson(&hello_buf, protocol.Hello{ .v = protocol.version, .name = self.name_buf[0..self.name_len], .nonce = &nonce_hex });
        try protocol.writeFrame(&writer.interface, .hello, hello);
        const auth_frame = try protocol.readMessage(&reader.interface, arena);
        const auth = try protocol.parseJson(arena, protocol.Auth, auth_frame, .auth);
        const computer_nonce = try protocol.unhex(protocol.nonce_length, auth.nonce);
        const computer_share = try protocol.unhex(protocol.share_length, auth.share);

        const code, const failures = blk: {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            break :blk .{ self.code, self.failures };
        };
        var handshake = try protocol.Handshake.init(self.io, .phone, &code, phone_nonce, computer_nonce);
        defer handshake.wipe();
        handshake.absorb(hello);
        handshake.absorb(auth_frame.payload);
        var keys = try handshake.finish(computer_share);
        defer keys.wipe();

        // The answer lets the computer test one code: slow guessers down,
        // and count it as wrong unless the computer confirms the key.
        const delay = failureDelay(self.options, failures);
        watchdog.extend(delay);
        try self.pause(delay);
        var confirmed = false;
        defer if (!confirmed) self.wrongCode();
        const share_hex = protocol.hex(protocol.share_length, handshake.share);
        const confirm_hex = protocol.hex(protocol.confirm_length, keys.own());
        try protocol.writeJson(&writer.interface, .answer, protocol.Answer{ .share = &share_hex, .confirm = &confirm_hex });
        const confirm = try protocol.readJson(&reader.interface, arena, protocol.Confirm, .confirm);
        // A wrong confirmation: close, saying nothing (there is no key to
        // seal a reason with, and the computer shows no unsealed one).
        if (!keys.peerConfirms(confirm.confirm)) return error.WrongCode;
        confirmed = true;
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            self.failures = 0;
        }

        var sealer = keys.sealer();
        defer sealer.deinit(self.gpa);
        var opener = keys.opener();
        defer opener.wipe();
        // The computer is who it says: a deadline of its own for the
        // camera to start and the frame size to go out.
        watchdog.arm(self.options.camera_start_ms);
        // The handshake's deadline passed just before: that one stands.
        if (watchdog.expired()) return error.Stalled;
        const started = self.source.vtable.start(self.source.ctx, .back, auth.quality.forSession());
        if (watchdog.expired()) {
            if (started) |_| self.source.vtable.stop(self.source.ctx) else |_| {}
            self.setError("{s}", .{slow_camera_error});
            return error.CameraTimeout;
        }
        const size = started catch |err| {
            self.setError("The camera didn't start ({s}).", .{@errorName(err)});
            try sealer.writeJson(self.gpa, &writer.interface, .ready, protocol.Ready{ .ok = false, .@"error" = "The phone's camera didn't start. Open HollerShare on the phone." });
            return err;
        };
        defer self.source.vtable.stop(self.source.ctx);
        try sealer.writeJson(self.gpa, &writer.interface, .ready, protocol.Ready{ .ok = true, .width = size.width, .height = size.height });
        {
            self.mutex.lockUncancelable(self.io);
            defer self.mutex.unlock(self.io);
            var name_buf: [64]u8 = undefined;
            const name = protocol.cleanName(&name_buf, auth.name);
            @memcpy(self.computer_buf[0..name.len], name);
            self.computer_len = name.len;
            self.streaming = true;
            self.facing = .back;
            self.error_len = 0;
        }

        // Streaming: only a frame write that stalls has a deadline.
        watchdog.disarm();
        // The computer's controls arrive on their own thread.
        var over: std.atomic.Value(bool) = .init(false);
        const controls = try std.Thread.spawn(.{}, controlLoop, .{ self, &reader.interface, &opener, &over, fd });
        defer {
            net.wake(fd);
            controls.join();
        }

        var frame_arena: std.heap.ArenaAllocator = .init(self.gpa);
        defer frame_arena.deinit();
        while (self.running.load(.acquire) and !over.load(.acquire)) {
            _ = frame_arena.reset(.retain_capacity);
            const next = self.source.vtable.next(self.source.ctx, frame_arena.allocator()) catch |err| {
                self.setError("The camera stopped ({s}).", .{@errorName(err)});
                return err;
            };
            const jpeg = next orelse continue;
            try watchdog.writeAll(&writer.interface, try sealer.seal(self.gpa, .jpeg, jpeg), self.options.send_timeout_ms);
            self.mutex.lockUncancelable(self.io);
            self.frames += 1;
            self.mutex.unlock(self.io);
        }
    }

    /// Wait `ms`, unless the phone stops first.
    fn pause(self: *Phone, ms: u32) !void {
        var left = ms;
        while (left > 0) {
            if (!self.running.load(.acquire)) return error.Canceled;
            const step = @min(left, 100);
            try self.io.sleep(.fromMilliseconds(step), .awake);
            left -= step;
        }
        if (!self.running.load(.acquire)) return error.Canceled;
    }

    /// Count a wrong code; too many in a row turn the phone off until the
    /// user turns it on again (with a new code).
    fn wrongCode(self: *Phone) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.failures += 1;
        if (self.failures < self.options.max_failures) return;
        log.warn("camera: {d} wrong codes in a row, turning off", .{self.failures});
        self.error_len = formatCut(&self.error_buf, "{s}", .{locked_out_error}).len;
        self.running.store(false, .release);
        // Refuse connections from now on (stop or start closes the socket).
        net.wake(self.server.?.socket.handle);
    }

    fn controlLoop(self: *Phone, reader: *std.Io.Reader, opener: *protocol.Opener, over: *std.atomic.Value(bool), fd: net.Handle) void {
        defer {
            over.store(true, .release);
            // Unblock a frame write stuck on a computer that is gone.
            net.wake(fd);
        }
        var buf: std.ArrayList(u8) = .empty;
        defer buf.deinit(self.gpa);
        while (true) {
            const frame = opener.read(reader, self.gpa, &buf, protocol.max_message_bytes) catch |err| {
                if (err == error.AuthenticationFailed) log.warn("camera: a control failed its check, ending the session", .{});
                return;
            };
            if (frame.type != .control) continue;
            const control = std.json.parseFromSlice(protocol.Control, self.gpa, frame.payload, .{ .ignore_unknown_fields = true }) catch continue;
            defer control.deinit();
            const c = control.value;
            switch (c.type) {
                .@"switch" => if (self.source.vtable.switch_camera(self.source.ctx)) |_| {
                    self.mutex.lockUncancelable(self.io);
                    defer self.mutex.unlock(self.io);
                    self.facing = if (self.facing == .back) .front else .back;
                } else |err| log.warn("switching cameras: {s}", .{@errorName(err)}),
                .view => {
                    const view = (protocol.View{ .rotate = c.rotate, .mirror = c.mirror, .fill = c.fill }).normalized();
                    self.source.vtable.set_view(self.source.ctx, view) catch |err| log.warn("turning the picture: {s}", .{@errorName(err)});
                },
                .quality => {
                    const quality = (protocol.Quality{ .fps = c.fps, .jpeg = c.jpeg }).normalized();
                    self.source.vtable.set_quality(self.source.ctx, quality) catch |err| log.warn("changing the quality: {s}", .{@errorName(err)});
                },
                .stop => return,
            }
        }
    }

    fn discoveryLoop(self: *Phone) void {
        var buf: [512]u8 = undefined;
        while (self.running.load(.acquire)) {
            const message = self.udp.?.receiveTimeout(self.io, &buf, net.timeout(500)) catch |err| switch (err) {
                error.Timeout => continue,
                else => {
                    if (!self.running.load(.acquire)) return;
                    self.io.sleep(.fromMilliseconds(200), .awake) catch {};
                    continue;
                },
            };
            const probe = std.json.parseFromSlice(protocol.Probe, self.gpa, message.data, .{ .ignore_unknown_fields = true }) catch continue;
            defer probe.deinit();
            if (probe.value.hollershare_camera != protocol.version) continue;
            const port = blk: {
                self.mutex.lockUncancelable(self.io);
                defer self.mutex.unlock(self.io);
                break :blk self.port;
            };
            var out: [256]u8 = undefined;
            var w: std.Io.Writer = .fixed(&out);
            std.json.Stringify.value(protocol.Announce{ .hollershare_camera = protocol.version, .name = self.name_buf[0..self.name_len], .port = port }, .{}, &w) catch continue;
            self.udp.?.send(self.io, &message.from, w.buffered()) catch {};
        }
    }
};

/// `fmt` with `args` in `buf`, as `protocol.cleanText` (so cut on a UTF-8
/// boundary when it doesn't fit).
fn formatCut(buf: []u8, comptime fmt: []const u8, args: anytype) []const u8 {
    var w: std.Io.Writer = .fixed(buf);
    w.print(fmt, args) catch {};
    return protocol.cleanText(buf, w.buffered());
}

/// Listen on `port`, else on any free port.
fn listen(io: std.Io, port: u16) !std.Io.net.Server {
    const preferred: std.Io.net.IpAddress = .{ .ip4 = .unspecified(port) };
    if (preferred.listen(io, .{ .reuse_address = true })) |server| return server else |err| {
        if (port == 0) return err;
        log.info("camera port {d} unavailable ({s}): using another", .{ port, @errorName(err) });
    }
    const any: std.Io.net.IpAddress = .{ .ip4 = .unspecified(0) };
    return any.listen(io, .{ .reuse_address = true });
}

test "wrong-code delays double up to the cap" {
    const o: Options = .{};
    try std.testing.expectEqual(@as(u32, 0), failureDelay(o, 0));
    try std.testing.expectEqual(@as(u32, 1000), failureDelay(o, 1));
    try std.testing.expectEqual(@as(u32, 2000), failureDelay(o, 2));
    try std.testing.expectEqual(@as(u32, 4000), failureDelay(o, 3));
    try std.testing.expectEqual(@as(u32, 8000), failureDelay(o, 4));
    try std.testing.expectEqual(@as(u32, 8000), failureDelay(o, 9));
    try std.testing.expectEqual(@as(u32, 8000), failureDelay(o, 1000));
}

test "errors that don't fit are cut cleanly" {
    var buf: [10]u8 = undefined;
    // "é" is 2 bytes: 4 of them and "ab" fill 10; one more "é" can't be halved.
    try std.testing.expectEqualStrings("abéééé", formatCut(&buf, "ab{s}", .{"ééééé"}));
    try std.testing.expectEqualStrings("abcdefghij", formatCut(&buf, "{s}", .{"abcdefghijklmnop"}));
    try std.testing.expectEqualStrings("a€", formatCut(buf[0..6], "a€{s}", .{"€"}));
    try std.testing.expectEqualStrings("short", formatCut(&buf, "{s}", .{"short"}));
}
