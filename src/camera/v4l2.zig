//! The "HollerShare Camera" video device on Linux: a v4l2loopback device
//! that HollerShare writes the phone's frames into and every app (browsers,
//! Zoom, OBS) reads as a webcam. Frames are written as they arrive, MJPEG,
//! so nothing decodes them here.
//!
//! The device is made once, as root (`setup_script`, run with pkexec):
//! v4l2loopback is a kernel module, from the distribution's package
//! (v4l2loopback-dkms, v4l2loopback-utils, akmod-v4l2loopback…).
const std = @import("std");
const linux = std.os.linux;

pub const device_name = "HollerShare Camera";

/// The device's path ("/dev/video4") in `buf`, or null when there is none.
pub fn find(io: std.Io, buf: []u8) ?[]const u8 {
    var dir = std.Io.Dir.openDirAbsolute(io, "/sys/class/video4linux", .{ .iterate = true }) catch return null;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        var path_buf: [128]u8 = undefined;
        const name_path = std.fmt.bufPrint(&path_buf, "{s}/name", .{entry.name}) catch continue;
        var name_buf: [64]u8 = undefined;
        const name = dir.readFile(io, name_path, &name_buf) catch continue;
        if (!std.mem.eql(u8, std.mem.trimEnd(u8, name, "\n"), device_name)) continue;
        return std.fmt.bufPrint(buf, "/dev/{s}", .{entry.name}) catch null;
    }
    return null;
}

/// The root script that makes the device (src/camera/v4l2_setup.zig).
pub const setup_script = @import("v4l2_setup.zig").script;

// <linux/videodev2.h>
const buf_type_video_output = 2;
const field_none = 1;
const colorspace_srgb = 8;
const fourcc_mjpeg: u32 = 'M' | @as(u32, 'J') << 8 | @as(u32, 'P') << 16 | @as(u32, 'G') << 24;

const PixFormat = extern struct {
    width: u32,
    height: u32,
    pixelformat: u32,
    field: u32,
    bytesperline: u32,
    sizeimage: u32,
    colorspace: u32,
    priv: u32,
    flags: u32,
    ycbcr_enc: u32,
    quantization: u32,
    xfer_func: u32,
};

/// `struct v4l2_format`: the union is 200 bytes, aligned like a pointer
/// (it holds `struct v4l2_window`), so 208 bytes on 64-bit systems.
const Format = extern struct {
    type: u32,
    fmt: extern union {
        pix: PixFormat,
        raw: [200]u8,
        alignment: ?*anyopaque,
    },
};

/// `_IOWR('V', 5, struct v4l2_format)`.
const vidioc_s_fmt: u32 = (3 << 30) | (@as(u32, @sizeOf(Format)) << 16) | ('V' << 8) | 5;

comptime {
    if (@sizeOf(usize) == 8) std.debug.assert(@sizeOf(Format) == 208);
}

/// The size the device took: v4l2loopback keeps the one a reading app
/// holds, whatever was asked. Another pixel format is refused.
fn takenSize(pix: PixFormat, pixelformat: u32) error{FormatRefused}!desktop.Size {
    if (pix.pixelformat != pixelformat or pix.width == 0 or pix.height == 0) return error.FormatRefused;
    return .{ .width = pix.width, .height = pix.height };
}

fn checkWrite(written: usize, expected: usize) error{ShortWrite}!void {
    if (written < expected) return error.ShortWrite;
}

const desktop = @import("desktop.zig");

/// The device opened for writing frames.
pub const Output = struct {
    fd: linux.fd_t,
    /// The frame size the device took (see `takenSize`).
    size: desktop.Size,

    /// Open `path` and declare MJPEG frames of `width` x `height`; `size`
    /// tells what the device took.
    pub fn open(path: []const u8, width: u32, height: u32) !Output {
        var path_buf: [64]u8 = undefined;
        const path_z = try std.fmt.bufPrintZ(&path_buf, "{s}", .{path});
        const rc = linux.open(path_z, .{ .ACCMODE = .RDWR, .CLOEXEC = true }, 0);
        switch (linux.errno(rc)) {
            .SUCCESS => {},
            .NOENT, .NODEV, .NXIO => return error.NoCameraDevice,
            .ACCES, .PERM => return error.AccessDenied,
            .BUSY => return error.DeviceBusy,
            else => |e| return std.posix.unexpectedErrno(e),
        }
        const fd: linux.fd_t = @intCast(rc);
        errdefer _ = linux.close(fd);
        var format: Format = .{ .type = buf_type_video_output, .fmt = .{ .raw = @splat(0) } };
        format.fmt.pix = .{
            .width = width,
            .height = height,
            .pixelformat = fourcc_mjpeg,
            .field = field_none,
            .bytesperline = 0,
            // v4l2loopback sizes compressed frames itself (generously).
            .sizeimage = width * height * 2,
            .colorspace = colorspace_srgb,
            .priv = 0,
            .flags = 0,
            .ycbcr_enc = 0,
            .quantization = 0,
            .xfer_func = 0,
        };
        switch (linux.errno(linux.ioctl(fd, vidioc_s_fmt, @intFromPtr(&format)))) {
            .SUCCESS => {},
            // Another program set a different format and still holds it.
            .BUSY => return error.DeviceBusy,
            .INVAL => return error.FormatRefused,
            else => |e| return std.posix.unexpectedErrno(e),
        }
        return .{ .fd = fd, .size = try takenSize(format.fmt.pix, fourcc_mjpeg) };
    }

    /// One frame, in one write (v4l2loopback takes a frame per write);
    /// dropped when the device is busy.
    pub fn write(self: Output, jpeg: []const u8) !desktop.Delivery {
        const rc = linux.write(self.fd, jpeg.ptr, jpeg.len);
        switch (linux.errno(rc)) {
            .SUCCESS => {
                try checkWrite(rc, jpeg.len);
                return .written;
            },
            .AGAIN, .INTR => return .dropped,
            else => |e| return std.posix.unexpectedErrno(e),
        }
    }

    pub fn close(self: Output) void {
        _ = linux.close(self.fd);
    }
};

/// A `desktop.Sink` writing to the HollerShare Camera device.
pub const Sink = struct {
    io: std.Io,
    output: ?Output = null,

    const vtable: desktop.Sink.VTable = .{ .open = openFn, .write = writeFn, .close = closeFn };

    pub fn sink(self: *Sink) desktop.Sink {
        return .{ .ctx = self, .vtable = &vtable };
    }

    fn openFn(ctx: *anyopaque, width: u32, height: u32) anyerror!desktop.Size {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        var buf: [64]u8 = undefined;
        const path = find(self.io, &buf) orelse return error.NoCameraDevice;
        const output = try Output.open(path, width, height);
        self.output = output;
        return output.size;
    }
    fn writeFn(ctx: *anyopaque, jpeg: []const u8) anyerror!desktop.Delivery {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        return (self.output orelse return error.NoCameraDevice).write(jpeg);
    }
    fn closeFn(ctx: *anyopaque) void {
        const self: *Sink = @ptrCast(@alignCast(ctx));
        if (self.output) |o| o.close();
        self.output = null;
    }
};

test "frames go into the HollerShare Camera when there is one" {
    const io = std.testing.io;
    var sink_state: Sink = .{ .io = io };
    const s = sink_state.sink();
    var buf: [64]u8 = undefined;
    if (find(io, &buf) == null) return error.SkipZigTest;
    // HOLLERSHARE_TEST_JPEG: a real frame to write (the test reads it back
    // with ffmpeg by hand); otherwise just the open and a write.
    // A video app reading the device keeps its size: skip rather than fail.
    const taken = s.vtable.open(s.ctx, 1280, 720) catch |err| switch (err) {
        error.FormatRefused, error.DeviceBusy => return error.SkipZigTest,
        else => return err,
    };
    defer s.vtable.close(s.ctx);
    if (taken.width != 1280 or taken.height != 720) return error.SkipZigTest;
    _ = try s.vtable.write(s.ctx, "\xff\xd8\xff\xd9");
}

test "the format ioctl matches the kernel's" {
    if (@sizeOf(usize) == 8) try std.testing.expectEqual(@as(u32, 0xc0d05605), vidioc_s_fmt);
    try std.testing.expectEqual(@as(u32, 0x47504a4d), fourcc_mjpeg);
}

test "the device's size is reported, another pixel format refused" {
    const base: PixFormat = .{
        .width = 1280,
        .height = 720,
        .pixelformat = fourcc_mjpeg,
        .field = field_none,
        .bytesperline = 0,
        .sizeimage = 1280 * 720 * 2,
        .colorspace = colorspace_srgb,
        .priv = 0,
        .flags = 0,
        .ycbcr_enc = 0,
        .quantization = 0,
        .xfer_func = 0,
    };
    try std.testing.expectEqual(desktop.Size{ .width = 1280, .height = 720 }, try takenSize(base, fourcc_mjpeg));

    // A reader holds another size: reported, for the desktop to decide.
    var held = base;
    held.width = 640;
    held.height = 480;
    try std.testing.expectEqual(desktop.Size{ .width = 640, .height = 480 }, try takenSize(held, fourcc_mjpeg));

    var empty = base;
    empty.width = 0;
    try std.testing.expectError(error.FormatRefused, takenSize(empty, fourcc_mjpeg));

    var bad_fmt = base;
    bad_fmt.pixelformat = 'Y' | @as(u32, 'U') << 8 | @as(u32, 'Y') << 16 | @as(u32, 'V') << 24;
    try std.testing.expectError(error.FormatRefused, takenSize(bad_fmt, fourcc_mjpeg));
}

test "short writes fail with ShortWrite" {
    try checkWrite(100, 100);
    try std.testing.expectError(error.ShortWrite, checkWrite(99, 100));
    try std.testing.expectError(error.ShortWrite, checkWrite(0, 1));

    var fds: [2]linux.fd_t = undefined;
    if (linux.errno(linux.pipe2(&fds, .{ .NONBLOCK = true, .CLOEXEC = true })) != .SUCCESS) {
        return error.SkipZigTest;
    }
    defer _ = linux.close(fds[0]);
    defer _ = linux.close(fds[1]);

    // Fill the pipe until EAGAIN, then drain 4096 bytes so an 8192-byte write
    // (> PIPE_BUF) performs a partial write of 4096 bytes.
    const page: [4096]u8 = @splat(0xaa);
    while (linux.errno(linux.write(fds[1], &page, page.len)) == .SUCCESS) {}
    var drain: [4096]u8 = undefined;
    const drained = linux.read(fds[0], &drain, drain.len);
    try std.testing.expectEqual(@as(usize, 4096), drained);

    const two_pages: [8192]u8 = @splat(0xbb);
    const out: Output = .{ .fd = fds[1], .size = .{ .width = 0, .height = 0 } };
    try std.testing.expectError(error.ShortWrite, out.write(&two_pages));

    // A full pipe: the frame is dropped, not counted as written.
    while (linux.errno(linux.write(fds[1], &page, page.len)) == .SUCCESS) {}
    try std.testing.expectEqual(desktop.Delivery.dropped, try out.write("\xff\xd8\xff\xd9"));
}
