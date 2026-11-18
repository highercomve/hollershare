//! The phone's camera on Android: `phone.Source` over the Oriel extension
//! "hollershare.camera" (src/android/CameraExtension.kt).
const std = @import("std");
const oriel = @import("oriel");
const phone = @import("phone.zig");

const camera = oriel.extensions.get("hollershare.camera");
const log = std.log.scoped(.camera);

pub const source: phone.Source = .{ .ctx = undefined, .vtable = &vtable };
const vtable: phone.Source.VTable = .{ .start = start, .next = next, .switch_camera = switchCamera, .set_view = setView, .set_quality = setQuality, .stop = stop };

/// Ask for the camera permission (shows Android's dialog the first time).
pub fn permission(arena: std.mem.Allocator) !bool {
    const reply = try camera.call(arena, "permission", "", .{ .timeout_ms = 90_000 });
    const parsed = try std.json.parseFromSliceLeaky(struct { granted: bool }, arena, reply, .{ .ignore_unknown_fields = true });
    return parsed.granted;
}

fn start(_: *anyopaque, facing: phone.Facing, quality: @import("protocol.zig").Quality) anyerror!phone.Size {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const input = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .facing = @tagName(facing), .height = quality.height, .fps = quality.fps, .jpeg = quality.jpeg }, .{});
    var diag: oriel.extensions.Diagnostics = .{};
    const reply = camera.call(arena.allocator(), "start", input, .{ .timeout_ms = 20_000, .diag = &diag }) catch |err| {
        log.warn("camera start: {s} {s}", .{ @errorName(err), diag.message() });
        return err;
    };
    const size = try std.json.parseFromSliceLeaky(phone.Size, arena.allocator(), reply, .{ .ignore_unknown_fields = true });
    return size;
}

fn next(_: *anyopaque, arena: std.mem.Allocator) anyerror!?[]const u8 {
    const jpeg = try camera.call(arena, "frame", "", .{ .timeout_ms = 5_000 });
    return if (jpeg.len == 0) null else jpeg;
}

fn switchCamera(_: *anyopaque) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    _ = try camera.call(arena.allocator(), "switch", "", .{ .timeout_ms = 20_000 });
}

fn setView(_: *anyopaque, view: @import("protocol.zig").View) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const input = try std.json.Stringify.valueAlloc(arena.allocator(), view, .{});
    _ = try camera.call(arena.allocator(), "view", input, .{ .timeout_ms = 5_000 });
}

fn setQuality(_: *anyopaque, quality: @import("protocol.zig").Quality) anyerror!void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    const input = try std.json.Stringify.valueAlloc(arena.allocator(), .{ .fps = quality.fps, .jpeg = quality.jpeg }, .{});
    _ = try camera.call(arena.allocator(), "quality", input, .{ .timeout_ms = 5_000 });
}

fn stop(_: *anyopaque) void {
    var arena: std.heap.ArenaAllocator = .init(std.heap.smp_allocator);
    defer arena.deinit();
    _ = camera.call(arena.allocator(), "stop", "", .{ .timeout_ms = 10_000 }) catch |err|
        log.warn("camera stop: {s}", .{@errorName(err)});
}
