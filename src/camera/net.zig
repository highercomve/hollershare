//! Socket details std.Io.net doesn't cover, for Linux and Android (the
//! only places the phone camera runs): a watchdog that ends stalled reads
//! and writes, a connect with a deadline that can be called off, and
//! waking a thread blocked in accept, read or write on a socket that is
//! being stopped.
const std = @import("std");
const linux = std.os.linux;

pub const Handle = std.Io.net.Socket.Handle;

/// This device's IPv4 address on its network, as text in `buf` ("192.168.1.20"),
/// or null without one: the address the system would send from to a
/// documentation-only address (connecting a UDP socket sends nothing).
pub fn localIp4(buf: []u8) ?[]const u8 {
    const rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.CLOEXEC, 0);
    if (linux.errno(rc) != .SUCCESS) return null;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var to: linux.sockaddr.in = .{ .port = std.mem.nativeToBig(u16, 9), .addr = std.mem.nativeToBig(u32, 0xC0000201) }; // 192.0.2.1
    if (linux.errno(linux.connect(fd, @ptrCast(&to), @sizeOf(linux.sockaddr.in))) != .SUCCESS) return null;
    var from: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&from), &len)) != .SUCCESS) return null;
    const b: [4]u8 = @bitCast(from.addr);
    if (b[0] == 0 or b[0] == 127) return null;
    return std.fmt.bufPrint(buf, "{d}.{d}.{d}.{d}", .{ b[0], b[1], b[2], b[3] }) catch null;
}

test "this device's IPv4 address, when it has a network" {
    var buf: [16]u8 = undefined;
    // Machines without a route have none; with one it is a dotted quad.
    const ip = localIp4(&buf) orelse return;
    try std.testing.expect(std.mem.count(u8, ip, ".") == 3);
    _ = try std.Io.net.IpAddress.parse(ip, 0);
}

/// Make a thread blocked in accept, read or write on `fd` return (the fd
/// stays open: its owner closes it).
pub fn wake(fd: Handle) void {
    _ = linux.shutdown(fd, linux.SHUT.RDWR);
}

/// Ends a session's blocked reads and writes once a deadline passes, by
/// waking its socket (`wake`): they then fail like on a dropped
/// connection. (SO_RCVTIMEO and SO_SNDTIMEO would make them fail with
/// EAGAIN, which std.Io's threaded reads and writes treat as a bug.)
/// The deadline is set from the session's thread; a thread of its own
/// watches it. `stop` it before the socket closes.
///
/// Expiring is one compare-and-swap from the deadline the watcher saw to
/// `expired_mark`, and every change of the deadline is one from what it
/// is now, so a deadline moved after the watcher looked at it wins: the
/// watcher never acts on a superseded one, and nothing revives an
/// expired one.
pub const Watchdog = struct {
    io: std.Io,
    fd: Handle,
    /// Milliseconds on the awake clock; 0: none; `expired_mark`: passed.
    deadline: std.atomic.Value(i64) = .init(0),
    done: std.atomic.Value(bool) = .init(false),
    thread: ?std.Thread = null,

    /// How often the deadline is looked at.
    const tick_ms = 20;
    /// How much of a write has to go out to count as progress.
    const chunk_bytes = 16 * 1024;
    /// The deadline once it passed (never reached by the clock).
    const expired_mark = std.math.maxInt(i64);

    pub fn start(self: *Watchdog) !void {
        self.thread = try std.Thread.spawn(.{}, loop, .{self});
    }

    /// Stop watching (waits up to a tick).
    pub fn stop(self: *Watchdog) void {
        self.done.store(true, .release);
        if (self.thread) |t| t.join();
        self.thread = null;
    }

    /// End the session `ms` from now unless the deadline moves.
    pub fn arm(self: *Watchdog, ms: u32) void {
        const at = self.now() + ms;
        self.update(struct {
            fn f(_: i64, new: i64) ?i64 {
                return new;
            }
        }.f, at);
    }

    /// Push an armed deadline `ms` later.
    pub fn extend(self: *Watchdog, ms: u32) void {
        self.update(struct {
            fn f(d: i64, by: i64) ?i64 {
                return if (d == 0) null else d + by;
            }
        }.f, ms);
    }

    pub fn disarm(self: *Watchdog) void {
        self.update(struct {
            fn f(_: i64, _: i64) ?i64 {
                return 0;
            }
        }.f, 0);
    }

    /// Whether the deadline passed (the socket is woken, or about to be).
    /// Reads the same value the expiring compare-and-swap writes, so it
    /// agrees with the deadline at every instant.
    pub fn expired(self: *const Watchdog) bool {
        return self.deadline.load(.acquire) == expired_mark;
    }

    /// Write `bytes` and flush; no progress for `ms` (a chunk that doesn't
    /// go out) ends the session. Leaves the deadline off.
    pub fn writeAll(self: *Watchdog, w: *std.Io.Writer, bytes: []const u8, ms: u32) std.Io.Writer.Error!void {
        defer self.disarm();
        var rest = bytes;
        while (rest.len > 0) {
            const n = @min(rest.len, chunk_bytes);
            self.arm(ms);
            try w.writeAll(rest[0..n]);
            try w.flush();
            rest = rest[n..];
        }
    }

    /// Set the deadline to `next(current, arg)` (null: leave it), unless
    /// it already expired.
    fn update(self: *Watchdog, comptime next: fn (i64, i64) ?i64, arg: i64) void {
        var d = self.deadline.load(.acquire);
        while (d != expired_mark) {
            const new = next(d, arg) orelse return;
            d = self.deadline.cmpxchgWeak(d, new, .acq_rel, .acquire) orelse return;
        }
    }

    /// Expire the deadline `seen` if it is still the deadline and passed
    /// at `now_ms`; whether it did.
    fn expire(self: *Watchdog, seen: i64, now_ms: i64) bool {
        if (seen == 0 or seen == expired_mark or now_ms < seen) return false;
        return self.deadline.cmpxchgStrong(seen, expired_mark, .acq_rel, .acquire) == null;
    }

    fn now(self: *const Watchdog) i64 {
        return std.Io.Clock.awake.now(self.io).toMilliseconds();
    }

    fn loop(self: *Watchdog) void {
        while (!self.done.load(.acquire)) {
            if (self.expire(self.deadline.load(.acquire), self.now())) {
                wake(self.fd);
                return;
            }
            self.io.sleep(.fromMilliseconds(tick_ms), .awake) catch return;
        }
    }
};

pub fn timeout(ms: i64) std.Io.Timeout {
    return .{ .duration = .{ .raw = .fromMilliseconds(ms), .clock = .awake } };
}

pub const ConnectError = error{
    Canceled,
    Timeout,
    ConnectionRefused,
    HostUnreachable,
    NetworkUnreachable,
    SystemResources,
    Unexpected,
};

/// How often a pending connect looks at `cancel`.
const cancel_poll_ms = 50;

/// A TCP connection to `address`, given up after `timeout_ms` or as soon
/// as `cancel` is set (within ~50 ms). The stream blocks like std's.
pub fn connect(address: std.Io.net.IpAddress, timeout_ms: u32, cancel: *const std.atomic.Value(bool)) ConnectError!std.Io.net.Stream {
    var storage: extern union { in: linux.sockaddr.in, in6: linux.sockaddr.in6 } = undefined;
    const family: u32, const len: linux.socklen_t = switch (address) {
        .ip4 => |a| blk: {
            storage = .{ .in = .{ .port = std.mem.nativeToBig(u16, a.port), .addr = @bitCast(a.bytes) } };
            break :blk .{ linux.AF.INET, @sizeOf(linux.sockaddr.in) };
        },
        .ip6 => |a| blk: {
            storage = .{ .in6 = .{ .port = std.mem.nativeToBig(u16, a.port), .flowinfo = a.flow, .addr = a.bytes, .scope_id = a.interface.index } };
            break :blk .{ linux.AF.INET6, @sizeOf(linux.sockaddr.in6) };
        },
    };
    const rc = linux.socket(family, linux.SOCK.STREAM | linux.SOCK.CLOEXEC | linux.SOCK.NONBLOCK, linux.IPPROTO.TCP);
    if (linux.errno(rc) != .SUCCESS) return error.SystemResources;
    const fd: Handle = @intCast(rc);
    errdefer _ = linux.close(fd);

    switch (linux.errno(linux.connect(fd, &storage, len))) {
        .SUCCESS => {},
        .INPROGRESS => try waitConnected(fd, timeout_ms, cancel),
        else => |e| return connectError(e),
    }
    // Back to blocking: std.Io's reads and writes expect it.
    const flags = linux.fcntl(fd, linux.F.GETFL, 0);
    if (linux.errno(flags) != .SUCCESS) return error.Unexpected;
    if (linux.errno(linux.fcntl(fd, linux.F.SETFL, flags & ~@as(usize, linux.SOCK.NONBLOCK))) != .SUCCESS) return error.Unexpected;
    return .{ .socket = .{ .handle = fd, .address = address } };
}

fn waitConnected(fd: Handle, timeout_ms: u32, cancel: *const std.atomic.Value(bool)) ConnectError!void {
    var waited: u32 = 0;
    while (true) {
        if (cancel.load(.acquire)) return error.Canceled;
        if (waited >= timeout_ms) return error.Timeout;
        const slice = @min(cancel_poll_ms, timeout_ms - waited);
        var fds = [_]linux.pollfd{.{ .fd = fd, .events = linux.POLL.OUT, .revents = 0 }};
        const n = linux.poll(&fds, 1, @intCast(slice));
        switch (linux.errno(n)) {
            .SUCCESS => {},
            .INTR => continue,
            else => return error.Unexpected,
        }
        waited += slice;
        if (n == 0) continue;
        var err: i32 = 0;
        var err_len: linux.socklen_t = @sizeOf(i32);
        if (linux.errno(linux.getsockopt(fd, linux.SOL.SOCKET, linux.SO.ERROR, std.mem.asBytes(&err), &err_len)) != .SUCCESS) return error.Unexpected;
        if (err == 0) return;
        return connectError(@enumFromInt(err));
    }
}

fn connectError(e: linux.E) ConnectError {
    return switch (e) {
        .CONNREFUSED => error.ConnectionRefused,
        .HOSTUNREACH => error.HostUnreachable,
        .NETUNREACH => error.NetworkUnreachable,
        .TIMEDOUT => error.Timeout,
        .NOBUFS, .NOMEM => error.SystemResources,
        else => error.Unexpected,
    };
}

test "connect reaches a listener and is refused by a closed port" {
    const io = std.testing.io;
    var never: std.atomic.Value(bool) = .init(false);
    const any: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{});
    const port = server.socket.address.getPort();
    const stream = try connect(.{ .ip4 = .loopback(port) }, 1000, &never);
    stream.close(io);
    server.deinit(io);
    try std.testing.expectError(error.ConnectionRefused, connect(.{ .ip4 = .loopback(port) }, 1000, &never));
}

test "a watchdog ends a read that would wait forever" {
    const io = std.testing.io;
    var never: std.atomic.Value(bool) = .init(false);
    const any: std.Io.net.IpAddress = .{ .ip4 = .loopback(0) };
    var server = try any.listen(io, .{});
    defer server.deinit(io);
    const stream = try connect(.{ .ip4 = .loopback(server.socket.address.getPort()) }, 1000, &never);
    defer stream.close(io);
    const peer = try server.accept(io);
    defer peer.close(io);

    var watchdog: Watchdog = .{ .io = io, .fd = stream.socket.handle };
    watchdog.arm(100);
    try watchdog.start();
    defer watchdog.stop();
    var buf: [16]u8 = undefined;
    var reader = stream.reader(io, &buf);
    // The peer sends nothing: the read ends as on a dropped connection.
    try std.testing.expectError(error.EndOfStream, reader.interface.takeByte());
    try std.testing.expect(watchdog.expired());
}

test "a deadline moved after the watchdog looked at it wins" {
    // No thread: the steps of the watcher's loop, in a chosen order.
    var watchdog: Watchdog = .{ .io = std.testing.io, .fd = -1 };
    watchdog.arm(10);
    // The watcher reads the deadline, then the session moves it on before
    // the watcher acts, at a time past the old one.
    const seen = watchdog.deadline.load(.acquire);
    watchdog.arm(60_000);
    try std.testing.expect(!watchdog.expire(seen, seen + 1));
    try std.testing.expect(!watchdog.expired());
    // A disarm racing the same way wins too.
    const seen2 = watchdog.deadline.load(.acquire);
    watchdog.disarm();
    try std.testing.expect(!watchdog.expire(seen2, seen2 + 1));
    try std.testing.expect(!watchdog.expired());
    // The current deadline expires, and moving it afterwards doesn't
    // undo that.
    watchdog.arm(10);
    const seen3 = watchdog.deadline.load(.acquire);
    try std.testing.expect(!watchdog.expire(seen3, seen3 - 1));
    try std.testing.expect(watchdog.expire(seen3, seen3));
    try std.testing.expect(watchdog.expired());
    // `expired` is the deadline itself: the moment the swap lands, a
    // phase change sees it, with no second store to wait for.
    var other: Watchdog = .{ .io = std.testing.io, .fd = -1 };
    other.arm(10);
    const seen4 = other.deadline.load(.acquire);
    try std.testing.expectEqual(null, other.deadline.cmpxchgStrong(seen4, Watchdog.expired_mark, .acq_rel, .acquire));
    try std.testing.expect(other.expired());
    watchdog.arm(60_000);
    watchdog.extend(1000);
    watchdog.disarm();
    try std.testing.expectEqual(Watchdog.expired_mark, watchdog.deadline.load(.acquire));
}
