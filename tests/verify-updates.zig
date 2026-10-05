const std = @import("std");
const manifest = @import("manifest");

pub fn main(init: std.process.Init) !void {
    const allocator = init.arena.allocator();
    const args = try init.minimal.args.toSlice(allocator);
    if (args.len != 3) return error.ExpectedPayloadDirectoryAndPublicKey;
    const key = std.mem.trim(u8, try std.Io.Dir.cwd().readFileAlloc(init.io, args[2], allocator, .limited(128)), " \r\n");
    const path = try std.fs.path.join(allocator, &.{ args[1], "latest.json" });
    const json = try std.Io.Dir.cwd().readFileAlloc(init.io, path, allocator, .limited(1024 * 1024));
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    var entries = parsed.value.object.get("platforms").?.object.iterator();
    while (entries.next()) |entry| {
        const verified = try manifest.verifyForTarget(allocator, json, key, entry.key_ptr.*, .{});
        if (!std.mem.eql(u8, verified.app_id, "dev.hollershare.App")) return error.UnexpectedAppIdentity;
        const payload_path = try std.fs.path.join(allocator, &.{ args[1], std.fs.path.basename(verified.url) });
        const stat = try std.Io.Dir.cwd().statFile(init.io, payload_path, .{});
        if (stat.size != verified.size) return error.PayloadSizeMismatch;
        const payload = try std.Io.Dir.cwd().readFileAlloc(init.io, payload_path, allocator, .limited(1024 * 1024 * 1024));
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(payload, &hash, .{});
        const hex = std.fmt.bytesToHex(hash, .lower);
        if (!manifest.eqlSha256Hex(&hex, verified.sha256)) return error.PayloadHashMismatch;
        const tampered = try allocator.dupe(u8, json);
        const signature = std.mem.indexOf(u8, tampered, verified.signature) orelse return error.MissingSignature;
        tampered[signature] = if (tampered[signature] == 'A') 'B' else 'A';
        if (manifest.verifyForTarget(allocator, tampered, key, entry.key_ptr.*, .{})) |_| {
            return error.TamperedSignatureAccepted;
        } else |_| {}
        std.debug.print("Verified {s}: signature, size, SHA-256 and tamper rejection\n", .{entry.key_ptr.*});
        allocator.free(payload);
    }
}
