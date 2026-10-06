const std = @import("std");
const builtin = @import("builtin");
const oriel = @import("oriel");
const config = @import("hollershare_config");
const android = builtin.abi == .android;
const target = if (android) @tagName(builtin.cpu.arch) ++ "-android" else oriel.updater.DEFAULT_TARGET;
const base: oriel.updater.Config = .{
    .app_id = "dev.hollershare.App",
    .manifest_url = "https://github.com/highercomve/hollershare/releases/latest/download/latest.json",
    .current_version = config.version,
    .public_key_b64 = std.mem.trim(u8, @embedFile("update-public-key.txt"), " \r\n"),
    .target = target,
};
const Raw = oriel.updater.Commands(base);
const Image = oriel.updater.Commands(blk: {
    var image = base;
    image.target = target ++ "-appimage";
    break :blk image;
});
const Info = struct { version: []const u8, android: bool, play_store: bool };
pub fn info() Info {
    return .{ .version = config.version, .android = android, .play_store = android and config.play_store };
}
pub fn check(allocator: std.mem.Allocator, io: std.Io) !Raw.CheckResult {
    if (android and config.play_store) return .{ .available = false, .version = config.version };
    if (try oriel.updater.runningAsAppImage(io, allocator)) {
        const result = try Image.updater_check(allocator, io);
        return .{ .available = result.available, .version = result.version };
    }
    return Raw.updater_check(allocator, io);
}
pub fn install(allocator: std.mem.Allocator, io: std.Io) !bool {
    if (android and config.play_store) return oriel.ipc.fail("Updates are managed by Google Play", .{});
    if (android) return oriel.ipc.fail("Download the APK from the release page and install it with Android", .{});
    return Raw.updater_install(allocator, io);
}
pub fn restart(allocator: std.mem.Allocator, io: std.Io) !void {
    if (android) return error.UnsupportedPlatform;
    try Raw.updater_restart(allocator, io);
}
