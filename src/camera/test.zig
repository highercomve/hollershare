//! The phone and the computer halves of the camera protocol, end to end on
//! loopback: discovery, a wrong code, streaming, switching cameras, and
//! stopping from either side.
const std = @import("std");
const protocol = @import("protocol.zig");
const phone_mod = @import("phone.zig");
const desktop_mod = @import("desktop.zig");

const net = @import("net.zig");

test {
    _ = protocol;
    _ = desktop_mod;
    _ = phone_mod;
    _ = net;
}

/// Wrong codes cost little in tests.
const fast: phone_mod.Options = .{ .discovery_port = 0, .session_port = 0, .failure_delay_ms = 5, .max_failure_delay_ms = 20 };

const FakeCamera = struct {
    started: std.atomic.Value(u32) = .init(0),
    stopped: std.atomic.Value(u32) = .init(0),
    switches: std.atomic.Value(u32) = .init(0),
    views: std.atomic.Value(u32) = .init(0),
    height: std.atomic.Value(u32) = .init(0),
    jpeg: std.atomic.Value(u32) = .init(0),
    /// The last view, packed: rotate | mirror << 12 | fill << 13.
    view: std.atomic.Value(u32) = .init(0),
    /// Frames this big instead of tiny ones (0: tiny).
    frame_bytes: usize = 0,
    /// How long opening the camera takes.
    start_ms: u32 = 0,
    /// The sizes the camera has, picked from like the phone's camera code
    /// does (empty: exactly 16:9 at every height asked for).
    sizes: []const phone_mod.Size = &.{},
    io: std.Io,

    const vtable: phone_mod.Source.VTable = .{ .start = start, .next = next, .switch_camera = switchCamera, .set_view = setView, .set_quality = setQuality, .stop = stop };

    fn source(self: *FakeCamera) phone_mod.Source {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn start(ctx: *anyopaque, _: phone_mod.Facing, quality: protocol.Quality) anyerror!phone_mod.Size {
        const self: *FakeCamera = @ptrCast(@alignCast(ctx));
        if (self.start_ms > 0) try self.io.sleep(.fromMilliseconds(self.start_ms), .awake);
        _ = self.started.fetchAdd(1, .acq_rel);
        self.height.store(quality.height, .release);
        return self.choose(quality.height);
    }
    /// The size at `height`, else the largest no bigger than the 16:9 one.
    fn choose(self: *const FakeCamera, height: u16) phone_mod.Size {
        const width = protocol.Quality.widthOf(height);
        if (self.sizes.len == 0) return .{ .width = width, .height = height };
        for (self.sizes) |s| if (s.height == height and protocol.Quality.wide(s.width, s.height)) return s;
        var best = self.sizes[0];
        for (self.sizes) |s| {
            if (s.width * s.height <= width * height and s.width * s.height > best.width * best.height) best = s;
        }
        return best;
    }
    fn setQuality(ctx: *anyopaque, quality: protocol.Quality) anyerror!void {
        const self: *FakeCamera = @ptrCast(@alignCast(ctx));
        self.jpeg.store(quality.jpeg, .release);
    }
    fn next(ctx: *anyopaque, arena: std.mem.Allocator) anyerror!?[]const u8 {
        const self: *FakeCamera = @ptrCast(@alignCast(ctx));
        try self.io.sleep(.fromMilliseconds(5), .awake);
        if (self.frame_bytes > 0) {
            const big = try arena.alloc(u8, self.frame_bytes);
            @memset(big, 0xab);
            return big;
        }
        return try std.fmt.allocPrint(arena, "\xff\xd8frame{d}\xff\xd9", .{self.switches.load(.acquire)});
    }
    fn switchCamera(ctx: *anyopaque) anyerror!void {
        const self: *FakeCamera = @ptrCast(@alignCast(ctx));
        _ = self.switches.fetchAdd(1, .acq_rel);
    }
    fn setView(ctx: *anyopaque, view: protocol.View) anyerror!void {
        const self: *FakeCamera = @ptrCast(@alignCast(ctx));
        self.view.store(packView(view), .release);
        _ = self.views.fetchAdd(1, .acq_rel);
    }
    fn stop(ctx: *anyopaque) void {
        const self: *FakeCamera = @ptrCast(@alignCast(ctx));
        _ = self.stopped.fetchAdd(1, .acq_rel);
    }
};

fn packView(view: protocol.View) u32 {
    return @as(u32, view.rotate) | @as(u32, @intFromBool(view.mirror)) << 12 | @as(u32, @intFromBool(view.fill)) << 13;
}

const MemorySink = struct {
    mutex: std.Io.Mutex = .init,
    io: std.Io,
    width: u32 = 0,
    /// Frames written (not dropped).
    frames: u32 = 0,
    /// Every write, dropped or not.
    writes: u32 = 0,
    /// Drop every nth frame, as a busy device does (0: none).
    drop_every: u32 = 0,
    /// The size a video app holds the device at (null: none).
    held: ?desktop_mod.Size = null,
    last: [64]u8 = undefined,
    last_len: usize = 0,
    closed: u32 = 0,

    const vtable: desktop_mod.Sink.VTable = .{ .open = open, .write = write, .close = close };

    fn sink(self: *MemorySink) desktop_mod.Sink {
        return .{ .ctx = self, .vtable = &vtable };
    }
    fn open(ctx: *anyopaque, width: u32, height: u32) anyerror!desktop_mod.Size {
        const self: *MemorySink = @ptrCast(@alignCast(ctx));
        const taken = self.held orelse desktop_mod.Size{ .width = width, .height = height };
        self.width = taken.width;
        return taken;
    }
    fn write(ctx: *anyopaque, jpeg: []const u8) anyerror!desktop_mod.Delivery {
        const self: *MemorySink = @ptrCast(@alignCast(ctx));
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        self.writes += 1;
        if (self.drop_every > 0 and self.writes % self.drop_every == 0) return .dropped;
        self.frames += 1;
        self.last_len = @min(jpeg.len, self.last.len);
        @memcpy(self.last[0..self.last_len], jpeg[0..self.last_len]);
        return .written;
    }
    fn close(ctx: *anyopaque) void {
        const self: *MemorySink = @ptrCast(@alignCast(ctx));
        self.closed += 1;
    }
    fn count(self: *MemorySink) u32 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        return self.frames;
    }
};

fn waitFor(io: std.Io, comptime what: []const u8, ctx: anytype, comptime ok: fn (@TypeOf(ctx)) bool) !void {
    for (0..300) |_| {
        if (ok(ctx)) return;
        try io.sleep(.fromMilliseconds(10), .awake);
    }
    std.debug.print("timed out waiting for {s}\n", .{what});
    return error.TimedOut;
}

test "a computer finds the phone, needs its code, and gets its frames" {
    // The sessions this ends on purpose log warnings.
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // Ports of their own, so a running HollerShare doesn't answer.
    var options = fast;
    options.discovery_port = 47390;

    var camera: FakeCamera = .{ .io = io };
    var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = options };
    try phone.start("Test Phone\n");
    defer phone.stop();

    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const found = try desktop_mod.discover(arena, io, 500, options.discovery_port);
    try std.testing.expect(found.len >= 1);
    try std.testing.expectEqualStrings("Test Phone", found[0].name);
    const address = found[0].address;

    var sink: MemorySink = .{ .io = io };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();
    // A view set before connecting reaches the phone when it streams.
    try desktop.setView(.{ .rotate = 90 });

    // A wrong code: the phone's reason, and its camera never starts.
    const status = try phone.status(arena);
    var wrong = status.code[0..6].*;
    wrong[0] = if (wrong[0] == '9') '0' else wrong[0] + 1;
    try desktop.connect(address, &wrong, "Studio");
    try waitFor(io, "the refusal", &desktop, struct {
        fn f(d: *desktop_mod.Desktop) bool {
            var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer a.deinit();
            return (d.status(a.allocator()) catch return false).state == .failed;
        }
    }.f);
    const refused = try desktop.status(arena);
    try std.testing.expectEqualStrings("Wrong code. Check the code on the phone.", refused.@"error".?);
    try std.testing.expectEqual(@as(u32, 0), camera.started.load(.acquire));

    // The right code: frames arrive at the phone's size.
    try desktop.connect(address, status.code, "Studio");
    try waitFor(io, "frames", &sink, struct {
        fn f(s: *MemorySink) bool {
            return s.count() >= 5;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 1280), sink.width);
    const streaming = try desktop.status(arena);
    try std.testing.expectEqual(desktop_mod.State.streaming, streaming.state);
    try std.testing.expectEqualStrings("Test Phone", streaming.phone.?);
    const on_phone = try phone.status(arena);
    try std.testing.expect(on_phone.streaming);
    try std.testing.expectEqualStrings("Studio", on_phone.computer.?);

    // The view set before connecting arrived; a new one arrives too.
    try waitFor(io, "the first view", &camera, struct {
        fn f(c: *FakeCamera) bool {
            return c.views.load(.acquire) >= 1;
        }
    }.f);
    try std.testing.expectEqual(packView(.{ .rotate = 90 }), camera.view.load(.acquire));
    try desktop.setView(.{ .rotate = 181, .mirror = true, .fill = true });
    try waitFor(io, "the new view", &camera, struct {
        fn f(c: *FakeCamera) bool {
            return c.view.load(.acquire) == packView(.{ .rotate = 180, .mirror = true, .fill = true });
        }
    }.f);
    try std.testing.expectEqual(@as(u16, 180), (try desktop.status(arena)).view.rotate);

    // A new JPEG quality changes live; a new size reconnects at it.
    try desktop.setQuality(.{ .height = 720, .fps = 30, .jpeg = 90 });
    try waitFor(io, "the new quality", &camera, struct {
        fn f(c: *FakeCamera) bool {
            return c.jpeg.load(.acquire) == 90;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 1), camera.started.load(.acquire));
    try desktop.setQuality(.{ .height = 480, .fps = 30, .jpeg = 90 });
    try waitFor(io, "the reconnect at 480", &sink, struct {
        fn f(s: *MemorySink) bool {
            return s.width == 854 and s.count() >= 10;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 480), camera.height.load(.acquire));
    try desktop.setQuality(.{ .height = 720, .fps = 30, .jpeg = 90 });
    try waitFor(io, "the reconnect at 720", &sink, struct {
        fn f(s: *MemorySink) bool {
            return s.width == 1280;
        }
    }.f);
    try waitFor(io, "streaming again", &desktop, struct {
        fn f(d: *desktop_mod.Desktop) bool {
            var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer a.deinit();
            return (d.status(a.allocator()) catch return false).state == .streaming;
        }
    }.f);

    // Switching cameras reaches the phone's camera, and both ends say which
    // lens streams: the back one at first, then the front one.
    try std.testing.expectEqual(protocol.Facing.back, (try desktop.status(arena)).facing);
    try std.testing.expectEqual(protocol.Facing.back, (try phone.status(arena)).facing);
    try desktop.switchCamera();
    try waitFor(io, "the switch", &camera, struct {
        fn f(c: *FakeCamera) bool {
            return c.switches.load(.acquire) == 1;
        }
    }.f);
    try std.testing.expectEqual(protocol.Facing.front, (try desktop.status(arena)).facing);
    try waitFor(io, "the phone to say front", &phone, struct {
        fn f(p: *phone_mod.Phone) bool {
            var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer a.deinit();
            return (p.status(a.allocator()) catch return false).facing == .front;
        }
    }.f);

    // The computer stops: the phone's camera stops and it waits again.
    desktop.stop();
    try std.testing.expectEqual(@as(u32, 3), sink.closed); // two reconnects, then the stop
    try waitFor(io, "the phone's camera to stop", &camera, struct {
        fn f(c: *FakeCamera) bool {
            return c.stopped.load(.acquire) == 3;
        }
    }.f);

    // The phone stops while streaming: the computer reports it.
    sink.mutex.lockUncancelable(io);
    sink.frames = 0;
    sink.mutex.unlock(io);
    try desktop.connect(address, status.code, "Studio");
    try waitFor(io, "frames again", &sink, struct {
        fn f(s: *MemorySink) bool {
            return s.count() >= 5;
        }
    }.f);
    phone.stop();
    try waitFor(io, "the end of the session", &desktop, struct {
        fn f(d: *desktop_mod.Desktop) bool {
            var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer a.deinit();
            return (d.status(a.allocator()) catch return false).state == .failed;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 4), camera.stopped.load(.acquire));
}

fn stateIs(comptime want: desktop_mod.State) fn (*desktop_mod.Desktop) bool {
    return struct {
        fn f(d: *desktop_mod.Desktop) bool {
            var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
            defer a.deinit();
            return (d.status(a.allocator()) catch return false).state == want;
        }
    }.f;
}

fn phoneAddress(buf: []u8, phone: *phone_mod.Phone) ![]const u8 {
    var a: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer a.deinit();
    return std.fmt.bufPrint(buf, "127.0.0.1:{d}", .{(try phone.status(a.allocator())).port});
}

test "too many wrong codes turn the phone off until it is turned on again" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var camera: FakeCamera = .{ .io = io };
    var options = fast;
    options.max_failures = 4;
    var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = options };
    try phone.start("Phone");
    defer phone.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const first = (try phone.status(arena)).code;
    var address_buf: [32]u8 = undefined;
    const address = try phoneAddress(&address_buf, &phone);

    var sink: MemorySink = .{ .io = io };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();
    var wrong = first[0..6].*;
    wrong[5] = if (wrong[5] == '9') '0' else wrong[5] + 1;

    // A right code in between resets the count.
    for (0..options.max_failures - 1) |_| {
        try desktop.connect(address, &wrong, "Guesser");
        try waitFor(io, "a refusal", &desktop, stateIs(.failed));
        try std.testing.expectEqualStrings(protocol.wrong_code_error, (try desktop.status(arena)).@"error".?);
    }
    try std.testing.expectEqual(@as(u32, options.max_failures - 1), (try phone.status(arena)).failures);
    try desktop.connect(address, first, "Owner");
    try waitFor(io, "streaming", &desktop, stateIs(.streaming));
    try std.testing.expectEqual(@as(u32, 0), (try phone.status(arena)).failures);
    desktop.stop();

    for (0..options.max_failures) |_| {
        try desktop.connect(address, &wrong, "Guesser");
        try waitFor(io, "a refusal", &desktop, stateIs(.failed));
    }
    // Locked out: off, saying why, and refusing even the right code.
    const locked = try phone.status(arena);
    try std.testing.expect(!locked.on);
    try std.testing.expectEqualStrings(phone_mod.locked_out_error, locked.@"error".?);
    try desktop.connect(address, first, "Owner");
    try waitFor(io, "the refusal", &desktop, stateIs(.failed));
    try std.testing.expect(std.mem.indexOf(u8, (try desktop.status(arena)).@"error".?, "isn't taking connections") != null);
    try std.testing.expectEqual(@as(u32, 1), camera.started.load(.acquire));

    // Turning it on again: a new code, which works.
    try phone.start("Phone");
    const again = try phone.status(arena);
    try std.testing.expect(again.on and again.@"error" == null);
    const second = try phoneAddress(&address_buf, &phone);
    try desktop.connect(second, again.code, "Owner");
    try waitFor(io, "streaming again", &desktop, stateIs(.streaming));
}

test "wrong codes slow the next answer down" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var camera: FakeCamera = .{ .io = io };
    var options = fast;
    options.failure_delay_ms = 150;
    options.max_failure_delay_ms = 300;
    var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = options };
    try phone.start("Phone");
    defer phone.stop();
    var address_buf: [32]u8 = undefined;
    const address = try phoneAddress(&address_buf, &phone);
    var sink: MemorySink = .{ .io = io };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();
    const wrong = "000000";
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    if (std.mem.eql(u8, (try phone.status(arena_state.allocator())).code, wrong)) return error.SkipZigTest;

    // Three wrong codes: no wait, then 150 ms, then 300 ms.
    const before = std.Io.Clock.awake.now(io);
    for (0..3) |_| {
        try desktop.connect(address, wrong, "Guesser");
        try waitFor(io, "a refusal", &desktop, stateIs(.failed));
    }
    const took = before.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expect(took >= 450);
}

/// A listener that never accepts, with its backlog full: connecting to it
/// hangs (Linux drops the SYN), on loopback, deterministically.
const Blackhole = struct {
    server: std.Io.net.Server,
    queued: [8]?std.Io.net.Stream = @splat(null),
    port: u16,

    fn init(io: std.Io) !Blackhole {
        const any: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
        var self: Blackhole = .{ .server = try any.listen(io, .{ .kernel_backlog = 0 }), .port = 0 };
        self.port = self.server.socket.address.getPort();
        var never: std.atomic.Value(bool) = .init(false);
        for (&self.queued) |*slot| {
            slot.* = net.connect(.{ .ip4 = .loopback(self.port) }, 200, &never) catch |err| switch (err) {
                error.Timeout => return self,
                else => return err,
            };
        }
        return error.BacklogNeverFilled;
    }

    fn deinit(self: *Blackhole, io: std.Io) void {
        for (self.queued) |s| if (s) |stream| stream.close(io);
        self.server.deinit(io);
    }
};

test "a connect that hangs times out, and stop ends it at once" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var hole = try Blackhole.init(io);
    defer hole.deinit(io);
    var address_buf: [32]u8 = undefined;
    const address = try std.fmt.bufPrint(&address_buf, "127.0.0.1:{d}", .{hole.port});

    var sink: MemorySink = .{ .io = io };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink(), .connect_timeout_ms = 300 };
    defer desktop.stop();
    try desktop.connect(address, "123456", "Studio");
    try waitFor(io, "the timeout", &desktop, stateIs(.failed));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    try std.testing.expect(std.mem.indexOf(u8, (try desktop.status(arena_state.allocator())).@"error".?, "didn't answer") != null);

    // With the full timeout, stop doesn't wait for it.
    desktop.connect_timeout_ms = 5_000;
    try desktop.connect(address, "123456", "Studio");
    try io.sleep(.fromMilliseconds(100), .awake);
    const before = std.Io.Clock.awake.now(io);
    desktop.stop();
    const took = before.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
    try std.testing.expect(took < 1000);
    try std.testing.expectEqual(desktop_mod.State.idle, (try desktop.status(arena_state.allocator())).state);
}

test "controls racing the end of sessions, and connects racing stops" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var camera: FakeCamera = .{ .io = io };
    var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = fast };
    try phone.start("Phone");
    defer phone.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const code = (try phone.status(arena_state.allocator())).code;
    var address_buf: [32]u8 = undefined;
    const address = try phoneAddress(&address_buf, &phone);
    var hole = try Blackhole.init(io);
    defer hole.deinit(io);
    var hole_buf: [32]u8 = undefined;
    const hole_address = try std.fmt.bufPrint(&hole_buf, "127.0.0.1:{d}", .{hole.port});

    var sink: MemorySink = .{ .io = io };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();

    const Hammer = struct {
        fn controls(d: *desktop_mod.Desktop, done: *std.atomic.Value(bool)) void {
            var i: u16 = 0;
            while (!done.load(.acquire)) : (i +%= 1) {
                d.setView(.{ .rotate = (i % 4) * 90 }) catch {};
                d.switchCamera() catch {};
                d.setQuality(.{ .height = 720, .fps = 30, .jpeg = @intCast(40 + i % 50) }) catch {};
            }
        }
        fn lifecycle(d: *desktop_mod.Desktop, phone_at: []const u8, hole_at: []const u8, c: []const u8, done: *std.atomic.Value(bool)) void {
            var i: usize = 0;
            while (!done.load(.acquire)) : (i += 1) {
                d.connect(if (i % 3 == 2) hole_at else phone_at, c, "Racer") catch {};
                if (i % 2 == 0) d.stop();
            }
        }
    };
    var done: std.atomic.Value(bool) = .init(false);
    const hammers = [_]std.Thread{
        try std.Thread.spawn(.{}, Hammer.controls, .{ &desktop, &done }),
        try std.Thread.spawn(.{}, Hammer.controls, .{ &desktop, &done }),
        try std.Thread.spawn(.{}, Hammer.lifecycle, .{ &desktop, address, hole_address, code, &done }),
    };
    // Sessions start and end under the controls for a while.
    for (0..20) |i| {
        try desktop.connect(address, code, "Studio");
        try io.sleep(.fromMilliseconds(15), .awake);
        if (i % 2 == 0) desktop.stop();
    }
    done.store(true, .release);
    for (hammers) |t| t.join();
    desktop.stop();
    try std.testing.expectEqual(desktop_mod.State.idle, (try desktop.status(arena_state.allocator())).state);
    try std.testing.expectError(error.NotStreaming, desktop.switchCamera());

    // Still works afterwards.
    try desktop.connect(address, code, "Studio");
    try waitFor(io, "streaming", &desktop, stateIs(.streaming));
    try desktop.switchCamera();
}

/// The computer's side of the handshake, by hand (for computers that
/// misbehave afterwards): the session keys.
fn handshakeAsComputer(io: std.Io, r: *std.Io.Reader, w: *std.Io.Writer, arena: std.mem.Allocator, code: []const u8) !protocol.Keys {
    const hello_frame = try protocol.readMessage(r, arena);
    const hello = try protocol.parseJson(arena, protocol.Hello, hello_frame, .hello);
    const nonce = protocol.newNonce(io);
    var handshake = try protocol.Handshake.init(io, .computer, code, try protocol.unhex(protocol.nonce_length, hello.nonce), nonce);
    defer handshake.wipe();
    const nonce_hex = protocol.hex(protocol.nonce_length, nonce);
    const share_hex = protocol.hex(protocol.share_length, handshake.share);
    var buf: [protocol.max_message_bytes]u8 = undefined;
    const auth = try protocol.encodeJson(&buf, protocol.Auth{ .name = "Fake", .nonce = &nonce_hex, .share = &share_hex });
    try protocol.writeFrame(w, .auth, auth);
    handshake.absorb(hello_frame.payload);
    handshake.absorb(auth);
    const answer = try protocol.readJson(r, arena, protocol.Answer, .answer);
    const keys = try handshake.finish(try protocol.unhex(protocol.share_length, answer.share));
    if (!keys.peerConfirms(answer.confirm)) return error.WrongCode;
    const confirm_hex = protocol.hex(protocol.confirm_length, keys.own());
    try protocol.writeJson(w, .confirm, protocol.Confirm{ .confirm = &confirm_hex });
    return keys;
}

/// A phone that does the handshake by hand (code "123456"), then
/// misbehaves as `behavior` says; one connection.
const FakePhone = struct {
    io: std.Io,
    server: std.Io.net.Server,
    behavior: Behavior,
    thread: ?std.Thread = null,

    const code = "123456";
    const Behavior = enum {
        /// Says hello, then nothing.
        silent_after_hello,
        /// After both confirmations, a plain refusal with its own text.
        plain_refusal,
        /// Streams nothing after a good ready.
        no_frames,
        /// Hangs up after both confirmations, without a ready.
        close_after_confirm,
    };

    fn start(self: *FakePhone) !void {
        self.thread = try std.Thread.spawn(.{}, run, .{self});
    }

    fn address(self: *FakePhone, buf: []u8) ![]const u8 {
        return std.fmt.bufPrint(buf, "127.0.0.1:{d}", .{self.server.socket.address.getPort()});
    }

    /// After the computer has hung up.
    fn deinit(self: *FakePhone) void {
        if (self.thread) |t| t.join();
        self.server.deinit(self.io);
    }

    fn run(self: *FakePhone) void {
        self.serve() catch {};
    }

    fn serve(self: *FakePhone) !void {
        const io = self.io;
        const gpa = std.testing.allocator;
        const stream = try self.server.accept(io);
        defer stream.close(io);
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        var read_buf: [8192]u8 = undefined;
        var write_buf: [8192]u8 = undefined;
        var reader = stream.reader(io, &read_buf);
        var writer = stream.writer(io, &write_buf);
        const r = &reader.interface;
        const w = &writer.interface;

        const nonce = protocol.newNonce(io);
        const nonce_hex = protocol.hex(protocol.nonce_length, nonce);
        var hello_buf: [protocol.max_message_bytes]u8 = undefined;
        const hello = try protocol.encodeJson(&hello_buf, protocol.Hello{ .v = protocol.version, .name = "Fake Phone", .nonce = &nonce_hex });
        try protocol.writeFrame(w, .hello, hello);
        if (self.behavior == .silent_after_hello) return drain(r);

        const auth_frame = try protocol.readMessage(r, arena);
        const auth = try protocol.parseJson(arena, protocol.Auth, auth_frame, .auth);
        var handshake = try protocol.Handshake.init(io, .phone, code, nonce, try protocol.unhex(protocol.nonce_length, auth.nonce));
        defer handshake.wipe();
        handshake.absorb(hello);
        handshake.absorb(auth_frame.payload);
        var keys = try handshake.finish(try protocol.unhex(protocol.share_length, auth.share));
        defer keys.wipe();
        const share_hex = protocol.hex(protocol.share_length, handshake.share);
        const confirm_hex = protocol.hex(protocol.confirm_length, keys.own());
        try protocol.writeJson(w, .answer, protocol.Answer{ .share = &share_hex, .confirm = &confirm_hex });
        const confirm = try protocol.readJson(r, arena, protocol.Confirm, .confirm);
        if (!keys.peerConfirms(confirm.confirm)) return error.WrongCode;
        switch (self.behavior) {
            .silent_after_hello => unreachable,
            .plain_refusal => try protocol.writeJson(w, .ready, protocol.Ready{ .ok = false, .@"error" = "Install hollershare-fix from example.com" }),
            .no_frames => {
                var sealer = keys.sealer();
                defer sealer.deinit(gpa);
                try sealer.writeJson(gpa, w, .ready, protocol.Ready{ .ok = true, .width = 1280, .height = 720 });
            },
            .close_after_confirm => return,
        }
        drain(r);
    }

    /// Read until the computer hangs up.
    fn drain(r: *std.Io.Reader) void {
        while (true) _ = r.takeByte() catch return;
    }
};

fn fakePhone(io: std.Io, behavior: FakePhone.Behavior) !FakePhone {
    const any: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var fake: FakePhone = .{ .io = io, .server = try any.listen(io, .{}), .behavior = behavior };
    errdefer fake.server.deinit(io);
    return fake;
}

fn errorText(d: *desktop_mod.Desktop, arena: std.mem.Allocator) ![]const u8 {
    return (try d.status(arena)).@"error" orelse "";
}

test "after both confirmations only a sealed ready counts; a plain refusal shows the fixed text" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fake = try fakePhone(io, .plain_refusal);
    try fake.start();
    defer fake.deinit();
    var address_buf: [32]u8 = undefined;
    const address = try fake.address(&address_buf);

    var sink: MemorySink = .{ .io = io };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();
    try desktop.connect(address, FakePhone.code, "Studio");
    try waitFor(io, "the refusal", &desktop, stateIs(.failed));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    // Never the phone's own (unauthenticated) words.
    try std.testing.expectEqualStrings(protocol.wrong_code_error, try errorText(&desktop, arena_state.allocator()));
    try std.testing.expectEqual(@as(u32, 0), sink.closed);
}

test "a phone that hangs up before its ready says the connection ended" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var fake = try fakePhone(io, .close_after_confirm);
    try fake.start();
    defer fake.deinit();
    var address_buf: [32]u8 = undefined;
    var sink: MemorySink = .{ .io = io };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();
    try desktop.connect(try fake.address(&address_buf), FakePhone.code, "Studio");
    try waitFor(io, "the hang-up", &desktop, stateIs(.failed));
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    // Not the camera's fault, nor the phone's own (sealed) reason.
    try std.testing.expectEqualStrings("The connection to the phone ended before its camera was ready. Keep HollerShare open on the phone, with its screen on, and try again.", try errorText(&desktop, arena_state.allocator()));
    try std.testing.expectEqual(@as(u32, 0), sink.closed);
}

test "a phone that stops answering ends the session (no panic in Debug)" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    var address_buf: [32]u8 = undefined;
    var sink: MemorySink = .{ .io = io };

    // Silent in the handshake: the handshake deadline.
    {
        var fake = try fakePhone(io, .silent_after_hello);
        try fake.start();
        defer fake.deinit();
        var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink(), .handshake_timeout_ms = 300 };
        defer desktop.stop();
        const before = std.Io.Clock.awake.now(io);
        try desktop.connect(try fake.address(&address_buf), FakePhone.code, "Studio");
        try waitFor(io, "the handshake deadline", &desktop, stateIs(.failed));
        try std.testing.expect(before.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 2000);
        try std.testing.expect(std.mem.indexOf(u8, try errorText(&desktop, arena_state.allocator()), "didn't answer") != null);
    }
    // Streaming, but no frame comes: the frame deadline.
    {
        var fake = try fakePhone(io, .no_frames);
        try fake.start();
        defer fake.deinit();
        var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink(), .frame_timeout_ms = 300 };
        defer desktop.stop();
        try desktop.connect(try fake.address(&address_buf), FakePhone.code, "Studio");
        try waitFor(io, "streaming", &desktop, stateIs(.streaming));
        try waitFor(io, "the frame deadline", &desktop, stateIs(.failed));
        // Not the network's fault: the phone stopped sending.
        try std.testing.expectEqualStrings("The phone stopped sending video. Keep HollerShare open on the phone, with its screen on.", try errorText(&desktop, arena_state.allocator()));
        try std.testing.expectEqual(@as(u32, 1), sink.closed);
    }
}

test "a computer trickling bytes is dropped at the handshake deadline" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var camera: FakeCamera = .{ .io = io };
    var options = fast;
    options.handshake_ms = 500;
    var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = options };
    try phone.start("Phone");
    defer phone.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const status = try phone.status(arena);

    var never: std.atomic.Value(bool) = .init(false);
    const before = std.Io.Clock.awake.now(io);
    const stream = try net.connect(.{ .ip4 = .loopback(status.port) }, 1000, &never);
    defer stream.close(io);
    var read_buf: [1024]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    _ = try protocol.readMessage(&reader.interface, arena);
    // An auth of 4000 bytes, announced, then a byte at a time, each well
    // within the deadline of the one before.
    const header = [_]u8{ 0, 0, 0x0f, 0xa0, @intFromEnum(protocol.FrameType.auth) };
    try std.testing.expectEqual(header.len, std.os.linux.write(stream.socket.handle, &header, header.len));
    const closed_after = for (0..40) |_| {
        var fds = [_]std.os.linux.pollfd{.{ .fd = stream.socket.handle, .events = std.os.linux.POLL.IN, .revents = 0 }};
        if (std.os.linux.poll(&fds, 1, 150) == 1) break before.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds();
        _ = std.os.linux.sendto(stream.socket.handle, "{", 1, std.os.linux.MSG.NOSIGNAL, null, 0);
    } else return error.NeverDropped;
    // The phone hung up (nothing to read but the end) near the deadline.
    try std.testing.expectEqual(@as(usize, 0), std.os.linux.read(stream.socket.handle, &read_buf, read_buf.len));
    try std.testing.expect(closed_after >= 400 and closed_after < 1500);

    // The accept thread is free for the real computer.
    var address_buf: [32]u8 = undefined;
    var sink: MemorySink = .{ .io = io };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();
    try desktop.connect(try phoneAddress(&address_buf, &phone), status.code, "Studio");
    try waitFor(io, "streaming", &desktop, stateIs(.streaming));
}

test "a computer that stops reading ends the phone's session (no panic in Debug)" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var camera: FakeCamera = .{ .io = io, .frame_bytes = 512 * 1024 };
    var options = fast;
    options.send_timeout_ms = 300;
    var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = options };
    try phone.start("Phone");
    defer phone.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const status = try phone.status(arena);

    var never: std.atomic.Value(bool) = .init(false);
    const stream = try net.connect(.{ .ip4 = .loopback(status.port) }, 1000, &never);
    defer stream.close(io);
    var read_buf: [8192]u8 = undefined;
    var write_buf: [8192]u8 = undefined;
    var reader = stream.reader(io, &read_buf);
    var writer = stream.writer(io, &write_buf);
    var keys = try handshakeAsComputer(io, &reader.interface, &writer.interface, arena, status.code);
    defer keys.wipe();
    // The phone streams; this computer never reads another byte.
    try waitFor(io, "the camera", &camera, struct {
        fn f(c: *FakeCamera) bool {
            return c.started.load(.acquire) == 1;
        }
    }.f);
    try waitFor(io, "the stalled session to end", &camera, struct {
        fn f(c: *FakeCamera) bool {
            return c.stopped.load(.acquire) == 1;
        }
    }.f);
    const after = try phone.status(arena);
    try std.testing.expect(after.on and !after.streaming);
}

fn waitStreamingAgain(io: std.Io, desktop: *desktop_mod.Desktop) !void {
    try waitFor(io, "streaming", desktop, stateIs(.streaming));
}

test "quality changes made while connecting reach the phone" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var camera: FakeCamera = .{ .io = io };
    var options = fast;
    // A wrong code first, so the next handshake pauses this long.
    options.failure_delay_ms = 400;
    options.max_failure_delay_ms = 400;
    var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = options };
    try phone.start("Phone");
    defer phone.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const code = (try phone.status(arena)).code;
    var wrong = code[0..6].*;
    wrong[0] = if (wrong[0] == '9') '0' else wrong[0] + 1;
    var address_buf: [32]u8 = undefined;
    const address = try phoneAddress(&address_buf, &phone);
    var sink: MemorySink = .{ .io = io };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();

    // A new JPEG quality during the paused handshake.
    try desktop.connect(address, &wrong, "Studio");
    try waitFor(io, "a refusal", &desktop, stateIs(.failed));
    try desktop.connect(address, code, "Studio");
    try io.sleep(.fromMilliseconds(150), .awake);
    try std.testing.expectEqual(desktop_mod.State.connecting, (try desktop.status(arena)).state);
    try desktop.setQuality(.{ .height = 720, .fps = 24, .jpeg = 91 });
    try waitStreamingAgain(io, &desktop);
    try waitFor(io, "the quality set while connecting", &camera, struct {
        fn f(c: *FakeCamera) bool {
            return c.jpeg.load(.acquire) == 91;
        }
    }.f);
    try std.testing.expectEqual(@as(u32, 720), camera.height.load(.acquire));

    // A new size during the paused handshake reconnects at it.
    try desktop.connect(address, &wrong, "Studio");
    try waitFor(io, "a refusal", &desktop, stateIs(.failed));
    try desktop.connect(address, code, "Studio");
    try io.sleep(.fromMilliseconds(150), .awake);
    try desktop.setQuality(.{ .height = 480, .fps = 24, .jpeg = 91 });
    try waitStreamingAgain(io, &desktop);
    try std.testing.expectEqual(@as(u32, 480), camera.height.load(.acquire));
    try std.testing.expectEqual(@as(u32, 854), sink.width);
}

test "a video app holding the device at one of our sizes is followed" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var camera: FakeCamera = .{ .io = io };
    var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = fast };
    try phone.start("Phone");
    defer phone.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const code = (try phone.status(arena)).code;
    var address_buf: [32]u8 = undefined;
    const address = try phoneAddress(&address_buf, &phone);

    // The app holds 1280x720; the user asked for 1080.
    var sink: MemorySink = .{ .io = io, .held = .{ .width = 1280, .height = 720 } };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();
    try desktop.setQuality(.{ .height = 1080 });
    try desktop.connect(address, code, "Studio");
    try waitFor(io, "streaming at the held size", &desktop, stateIs(.streaming));
    const held = try desktop.status(arena);
    try std.testing.expectEqual(@as(?u16, 720), held.held_by_app);
    try std.testing.expectEqual(@as(u16, 1080), held.quality.height); // the preference stays
    try std.testing.expectEqual(@as(u32, 1280), held.width);
    try std.testing.expectEqual(@as(u32, 720), camera.height.load(.acquire));
    try std.testing.expectEqual(@as(u32, 2), camera.started.load(.acquire));
    desktop.stop();

    // A size that isn't one of ours still fails.
    sink.held = .{ .width = 1000, .height = 700 };
    try desktop.connect(address, code, "Studio");
    try waitFor(io, "the refusal", &desktop, stateIs(.failed));
    try std.testing.expect(std.mem.indexOf(u8, try errorText(&desktop, arena), "another resolution") != null);
    try std.testing.expectEqual(@as(?u16, null), (try desktop.status(arena)).held_by_app);
}

test "a held size the phone streamed off the presets is followed, once" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    // No 854x480: 480p streams 640x360, as some phones do.
    var camera: FakeCamera = .{ .io = io, .sizes = &.{
        .{ .width = 640, .height = 360 },
        .{ .width = 1280, .height = 720 },
        .{ .width = 1920, .height = 1080 },
    } };
    var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = fast };
    try phone.start("Phone");
    defer phone.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const code = (try phone.status(arena)).code;
    var address_buf: [32]u8 = undefined;
    const address = try phoneAddress(&address_buf, &phone);
    var sink: MemorySink = .{ .io = io };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();

    try desktop.setQuality(.{ .height = 480 });
    try desktop.connect(address, code, "Studio");
    try waitFor(io, "streaming at 480p", &desktop, stateIs(.streaming));
    try std.testing.expectEqual(@as(u32, 640), sink.width);

    // A video app keeps the device at 640x360; 720p asks the phone for 360.
    sink.held = .{ .width = 640, .height = 360 };
    try desktop.setQuality(.{ .height = 720 });
    try waitStreamingAgain(io, &desktop);
    const held = try desktop.status(arena);
    try std.testing.expectEqual(@as(?u16, 360), held.held_by_app);
    try std.testing.expectEqual(@as(u16, 720), held.quality.height); // the preference stays
    try std.testing.expectEqual(@as(u32, 640), held.width);
    try std.testing.expectEqual(@as(u32, 360), held.height);
    try std.testing.expectEqual(@as(u32, 360), camera.height.load(.acquire));
    desktop.stop();

    // The app let go: the next session is at the preset again.
    sink.held = null;
    try desktop.connect(address, code, "Studio");
    try waitFor(io, "streaming at 720p", &desktop, stateIs(.streaming));
    const free = try desktop.status(arena);
    try std.testing.expectEqual(@as(?u16, null), free.held_by_app);
    try std.testing.expectEqual(@as(u32, 1280), free.width);
    try std.testing.expectEqual(@as(u32, 720), camera.height.load(.acquire));
    desktop.stop();

    // Held at a size the phone can't make (960x540 gives 640x360): one
    // retry, then a clear failure.
    sink.held = .{ .width = 960, .height = 540 };
    const started = camera.started.load(.acquire);
    try desktop.connect(address, code, "Studio");
    try waitFor(io, "the refusal", &desktop, stateIs(.failed));
    try std.testing.expect(std.mem.indexOf(u8, try errorText(&desktop, arena), "another resolution") != null);
    try std.testing.expectEqual(@as(u32, 540), camera.height.load(.acquire));
    try std.testing.expectEqual(started + 2, camera.started.load(.acquire));
    try std.testing.expectEqual(@as(?u16, null), (try desktop.status(arena)).held_by_app);
}

test "frames the device drops don't count as delivered" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var camera: FakeCamera = .{ .io = io };
    var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = fast };
    try phone.start("Phone");
    defer phone.stop();
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var address_buf: [32]u8 = undefined;
    var sink: MemorySink = .{ .io = io, .drop_every = 2 };
    var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
    defer desktop.stop();
    try desktop.connect(try phoneAddress(&address_buf, &phone), (try phone.status(arena)).code, "Studio");
    try waitFor(io, "frames", &sink, struct {
        fn f(s: *MemorySink) bool {
            return s.count() >= 10;
        }
    }.f);
    desktop.stop();
    const status = try desktop.status(arena);
    try std.testing.expectEqual(@as(u64, sink.frames), status.frames);
    try std.testing.expectEqual(@as(u64, sink.writes - sink.frames), status.dropped);
    try std.testing.expect(status.dropped > 0);
}

test "the camera start has a deadline of its own, after the handshake's" {
    std.testing.log_level = .err;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var address_buf: [32]u8 = undefined;
    var options = fast;
    options.handshake_ms = 300;
    options.camera_start_ms = 1500;

    // Slower than the handshake deadline, well within the camera's: streams.
    {
        var camera: FakeCamera = .{ .io = io, .start_ms = 700 };
        var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = options };
        try phone.start("Phone");
        defer phone.stop();
        var sink: MemorySink = .{ .io = io };
        var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink(), .handshake_timeout_ms = 300 };
        defer desktop.stop();
        try desktop.connect(try phoneAddress(&address_buf, &phone), (try phone.status(arena)).code, "Studio");
        try waitFor(io, "frames", &sink, struct {
            fn f(s: *MemorySink) bool {
                return s.count() >= 3;
            }
        }.f);
    }
    // Slower than the camera's deadline: the phone says its camera didn't
    // start and hangs up (it can't seal a reason on a socket its deadline
    // shut), so the computer says the connection ended; the phone takes
    // the next computer.
    {
        var camera: FakeCamera = .{ .io = io, .start_ms = 2000 };
        var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = options };
        try phone.start("Phone");
        defer phone.stop();
        var sink: MemorySink = .{ .io = io };
        var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink() };
        defer desktop.stop();
        try desktop.connect(try phoneAddress(&address_buf, &phone), (try phone.status(arena)).code, "Studio");
        try waitFor(io, "the camera deadline", &desktop, stateIs(.failed));
        try std.testing.expect(std.mem.indexOf(u8, try errorText(&desktop, arena), "ended before its camera was ready") != null);
        try waitFor(io, "the phone's camera to stop", &camera, struct {
            fn f(c: *FakeCamera) bool {
                return c.stopped.load(.acquire) == 1;
            }
        }.f);
        const on_phone = try phone.status(arena);
        try std.testing.expectEqualStrings(phone_mod.slow_camera_error, on_phone.@"error".?);
        try std.testing.expect(on_phone.on and !on_phone.streaming);
        try std.testing.expectEqual(@as(u32, 0), sink.closed);
    }
    // The computer's own camera deadline, when the phone's is longer. The
    // text tells it from the phone hanging up (above), so the timing bound
    // can be loose: the camera would be ready at 1600 ms and stream.
    {
        var long = options;
        long.camera_start_ms = 5000;
        var camera: FakeCamera = .{ .io = io, .start_ms = 1600 };
        var phone: phone_mod.Phone = .{ .io = io, .gpa = gpa, .source = camera.source(), .options = long };
        try phone.start("Phone");
        defer phone.stop();
        var sink: MemorySink = .{ .io = io };
        var desktop: desktop_mod.Desktop = .{ .io = io, .gpa = gpa, .sink = sink.sink(), .camera_start_timeout_ms = 400 };
        defer desktop.stop();
        const before = std.Io.Clock.awake.now(io);
        try desktop.connect(try phoneAddress(&address_buf, &phone), (try phone.status(arena)).code, "Studio");
        try waitFor(io, "the computer's camera deadline", &desktop, stateIs(.failed));
        try std.testing.expect(before.durationTo(std.Io.Clock.awake.now(io)).toMilliseconds() < 1500);
        try std.testing.expect(std.mem.indexOf(u8, try errorText(&desktop, arena), "camera didn't start") != null);
        try std.testing.expectEqual(@as(u32, 0), sink.closed);
    }
}
