const std = @import("std");
const builtin = @import("builtin");
const config = @import("hollershare_config");

extern fn hollershare_start(directory: [*:0]const u8) ?[*:0]u8;
extern fn hollershare_request(request: [*:0]const u8) ?[*:0]u8;
extern fn hollershare_free(pointer: [*:0]u8) void;
extern fn hollershare_stop() void;

pub fn isCliCommand(argv: []const []const u8) bool {
    if (argv.len == 0) return false;
    const cmd = argv[0];
    const commands = [_][]const u8{
        "send",
        "send-text",
        "scan",
        "devices",
        "list",
        "receive",
        "listen",
        "help",
        "--help",
        "-h",
        "version",
        "--version",
        "-v",
    };
    for (commands) |name| {
        if (std.mem.eql(u8, cmd, name)) return true;
    }
    return false;
}

pub fn run(init: std.process.Init, argv: []const []const u8) !u8 {
    const io = init.io;
    const arena = init.arena.allocator();
    const gpa = init.gpa;

    if (argv.len == 0) return 0;
    const cmd = argv[0];

    if (std.mem.eql(u8, cmd, "--help") or std.mem.eql(u8, cmd, "-h") or std.mem.eql(u8, cmd, "help")) {
        printUsage(io);
        return 0;
    }

    if (std.mem.eql(u8, cmd, "--version") or std.mem.eql(u8, cmd, "-v") or std.mem.eql(u8, cmd, "version")) {
        printOut(io, "HollerShare {s}\n", .{config.version});
        return 0;
    }

    if (std.mem.eql(u8, cmd, "scan") or std.mem.eql(u8, cmd, "devices") or std.mem.eql(u8, cmd, "list")) {
        return runScan(gpa, arena, io, argv[1..]);
    }

    if (std.mem.eql(u8, cmd, "send")) {
        return runSend(gpa, arena, io, argv[1..]);
    }

    if (std.mem.eql(u8, cmd, "send-text")) {
        return runSendText(gpa, arena, io, argv[1..]);
    }

    if (std.mem.eql(u8, cmd, "receive") or std.mem.eql(u8, cmd, "listen")) {
        return runReceive(gpa, arena, io, argv[1..]);
    }

    printErr(io, "Unknown command: {s}\nRun 'hollershare --help' for usage.\n", .{cmd});
    return 1;
}

fn printUsage(io: std.Io) void {
    printOut(io,
        \\HollerShare {s} - Share files and text with Android Quick Share and nearby devices
        \\
        \\Usage:
        \\  hollershare                                Launch desktop GUI app
        \\  hollershare send <files...> [options]       Send one or more files
        \\  hollershare send-text <text> [options]     Send plain text or URL (- for stdin)
        \\  hollershare scan [options]                 Scan for nearby Quick Share receivers
        \\  hollershare receive [options]              Run headless receiver
        \\  hollershare -h, --help                     Show this help message
        \\  hollershare -v, --version                  Show version
        \\
        \\Options:
        \\  --to <target>        Target device name (e.g. "Pixel 8") or address (IP:port)
        \\  --name <sender>      Custom sender name displayed on receiving device
        \\  --timeout <secs>     Discovery timeout in seconds (default: 5)
        \\  --dir <path>         Download folder for receive command (default: current dir)
        \\  --auto-accept        Automatically accept incoming transfers in receive mode
        \\
        \\Examples:
        \\  hollershare scan
        \\  hollershare send ./photo.jpg --to "Pixel 8"
        \\  hollershare send ./doc.pdf --to 192.168.1.50:54321
        \\  hollershare send-text "https://github.com" --to "Pixel 8"
        \\  cat log.txt | hollershare send-text - --to "Pixel 8"
        \\
    , .{config.version});
}

fn printOut(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [4096]u8 = undefined;
    var writer = std.Io.File.stdout().writerStreaming(io, &buf);
    writer.interface.print(fmt, args) catch {};
    writer.interface.flush() catch {};
}

fn printErr(io: std.Io, comptime fmt: []const u8, args: anytype) void {
    var buf: [2048]u8 = undefined;
    var writer = std.Io.File.stderr().writerStreaming(io, &buf);
    writer.interface.print(fmt, args) catch {};
    writer.interface.flush() catch {};
}

fn requestJson(allocator: std.mem.Allocator, value: anytype) ![]const u8 {
    const json = try std.json.Stringify.valueAlloc(allocator, value, .{});
    defer allocator.free(json);
    const terminated = try allocator.dupeZ(u8, json);
    defer allocator.free(terminated);
    const response = hollershare_request(terminated) orelse return error.QuickShareUnavailable;
    defer hollershare_free(response);
    return allocator.dupe(u8, std.mem.span(response));
}

const DiscoveredPeer = struct {
    id: []const u8,
    name: []const u8,
    ip: ?[]const u8,
    port: ?[]const u8,
    rtype: []const u8,
};

fn parseSnapshotPeers(allocator: std.mem.Allocator, data_obj: std.json.ObjectMap) ![]DiscoveredPeer {
    const peers_val = data_obj.get("peers") orelse return &.{};
    if (peers_val != .array) return &.{};

    var list: std.ArrayList(DiscoveredPeer) = .empty;
    defer list.deinit(allocator);

    for (peers_val.array.items) |item| {
        if (item != .object) continue;
        const id_val = item.object.get("id") orelse continue;
        if (id_val != .string or id_val.string.len == 0) continue;

        const name_val = item.object.get("name");
        const name = if (name_val != null and name_val.? == .string) name_val.?.string else "Nearby device";

        const ip_val = item.object.get("ip");
        const ip = if (ip_val != null and ip_val.? == .string) ip_val.?.string else null;

        const port_val = item.object.get("port");
        const port = if (port_val != null and port_val.? == .string) port_val.?.string else null;

        const rtype_val = item.object.get("rtype");
        const rtype = if (rtype_val != null and rtype_val.? == .string) rtype_val.?.string else "Device";

        try list.append(allocator, .{
            .id = try allocator.dupe(u8, id_val.string),
            .name = try allocator.dupe(u8, name),
            .ip = if (ip) |s| try allocator.dupe(u8, s) else null,
            .port = if (port) |s| try allocator.dupe(u8, s) else null,
            .rtype = try allocator.dupe(u8, rtype),
        });
    }
    return try list.toOwnedSlice(allocator);
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0) return true;
    if (haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i <= haystack.len - needle.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

fn isSocketAddress(str: []const u8) bool {
    const colon_idx = std.mem.lastIndexOfScalar(u8, str, ':') orelse return false;
    const port_str = str[colon_idx + 1 ..];
    if (port_str.len == 0) return false;
    for (port_str) |c| {
        if (!std.ascii.isDigit(c)) return false;
    }
    return true;
}

fn formatBytes(buf: []u8, count: u64) []const u8 {
    const units = [_][]const u8{ "B", "KB", "MB", "GB", "TB" };
    var val: f64 = @floatFromInt(count);
    var unit_idx: usize = 0;
    while (val >= 1024.0 and unit_idx < units.len - 1) : (unit_idx += 1) {
        val /= 1024.0;
    }
    if (unit_idx == 0) {
        return std.fmt.bufPrint(buf, "{d} B", .{count}) catch "0 B";
    } else if (val < 10.0) {
        return std.fmt.bufPrint(buf, "{d:.1} {s}", .{ val, units[unit_idx] }) catch "0 B";
    } else {
        return std.fmt.bufPrint(buf, "{d:.0} {s}", .{ val, units[unit_idx] }) catch "0 B";
    }
}

fn runScan(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var timeout_secs: u32 = 5;
    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--timeout") and i + 1 < args.len) {
            i += 1;
            timeout_secs = std.fmt.parseInt(u32, args[i], 10) catch 5;
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_secs = std.fmt.parseInt(u32, arg["--timeout=".len..], 10) catch 5;
        }
    }

    const start_resp = hollershare_start("") orelse {
        printErr(io, "Error: Failed to start Quick Share engine.\n", .{});
        return 1;
    };
    defer hollershare_free(start_resp);
    defer hollershare_stop();

    _ = requestJson(arena, .{ .command = "visibility", .visible = false }) catch {};

    printOut(io, "Scanning for nearby Quick Share receivers ({d}s)...\n", .{timeout_secs});

    var discovered: std.ArrayList(DiscoveredPeer) = .empty;
    defer {
        for (discovered.items) |p| {
            gpa.free(p.id);
            gpa.free(p.name);
            if (p.ip) |ip| gpa.free(ip);
            if (p.port) |pt| gpa.free(pt);
            gpa.free(p.rtype);
        }
        discovered.deinit(gpa);
    }

    const start_time = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const deadline = start_time + @as(i64, timeout_secs) * 1000;

    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        io.sleep(.fromMilliseconds(250), .awake) catch {};

        const snap_resp = requestJson(arena, .{ .command = "snapshot" }) catch continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, snap_resp, .{}) catch continue;
        const data_obj = if (parsed.value == .object) parsed.value.object.get("data") else null;
        if (data_obj == null or data_obj.? != .object) continue;

        const current_peers = parseSnapshotPeers(arena, data_obj.?.object) catch continue;
        for (current_peers) |peer| {
            var already = false;
            for (discovered.items) |existing| {
                if (std.mem.eql(u8, existing.id, peer.id)) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                try discovered.append(gpa, .{
                    .id = try gpa.dupe(u8, peer.id),
                    .name = try gpa.dupe(u8, peer.name),
                    .ip = if (peer.ip) |s| try gpa.dupe(u8, s) else null,
                    .port = if (peer.port) |s| try gpa.dupe(u8, s) else null,
                    .rtype = try gpa.dupe(u8, peer.rtype),
                });
                printOut(io, "  • {s} ({s}) [{s}]\n", .{ peer.name, peer.id, peer.rtype });
            }
        }
    }

    if (discovered.items.len == 0) {
        printOut(io, "\nNo devices found.\nEnsure Quick Share is enabled and visible on the receiving device.\n", .{});
    } else {
        printOut(io, "\nFound {d} device(s).\n", .{discovered.items.len});
    }
    return 0;
}

const ResolvedTarget = struct {
    address: []const u8,
    name: []const u8,
};

fn resolveTarget(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, target: ?[]const u8, timeout_secs: u32) !?ResolvedTarget {
    if (target) |tgt| {
        if (isSocketAddress(tgt)) {
            return .{ .address = tgt, .name = "Receiver" };
        }
    }

    const tgt_desc = if (target) |t| t else "device";
    printOut(io, "Looking for {s} (up to {d}s)...\n", .{ tgt_desc, timeout_secs });

    const start_time = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const deadline = start_time + @as(i64, timeout_secs) * 1000;

    var latest_peers: std.ArrayList(DiscoveredPeer) = .empty;
    defer {
        for (latest_peers.items) |p| {
            gpa.free(p.id);
            gpa.free(p.name);
            if (p.ip) |ip| gpa.free(ip);
            if (p.port) |pt| gpa.free(pt);
            gpa.free(p.rtype);
        }
        latest_peers.deinit(gpa);
    }

    while (std.Io.Timestamp.now(io, .awake).toMilliseconds() < deadline) {
        io.sleep(.fromMilliseconds(250), .awake) catch {};

        const snap_resp = requestJson(arena, .{ .command = "snapshot" }) catch continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, snap_resp, .{}) catch continue;
        const data_obj = if (parsed.value == .object) parsed.value.object.get("data") else null;
        if (data_obj == null or data_obj.? != .object) continue;

        const current_peers = parseSnapshotPeers(arena, data_obj.?.object) catch continue;
        for (current_peers) |peer| {
            var already = false;
            for (latest_peers.items) |existing| {
                if (std.mem.eql(u8, existing.id, peer.id)) {
                    already = true;
                    break;
                }
            }
            if (!already) {
                try latest_peers.append(gpa, .{
                    .id = try gpa.dupe(u8, peer.id),
                    .name = try gpa.dupe(u8, peer.name),
                    .ip = if (peer.ip) |s| try gpa.dupe(u8, s) else null,
                    .port = if (peer.port) |s| try gpa.dupe(u8, s) else null,
                    .rtype = try gpa.dupe(u8, peer.rtype),
                });
            }

            if (target) |tgt| {
                const match = containsIgnoreCase(peer.name, tgt) or
                    std.ascii.eqlIgnoreCase(peer.id, tgt) or
                    (peer.ip != null and std.mem.eql(u8, peer.ip.?, tgt));
                if (match) {
                    return .{
                        .address = try arena.dupe(u8, peer.id),
                        .name = try arena.dupe(u8, peer.name),
                    };
                }
            }
        }
    }

    if (target == null) {
        if (latest_peers.items.len == 1) {
            const peer = latest_peers.items[0];
            return .{
                .address = try arena.dupe(u8, peer.id),
                .name = try arena.dupe(u8, peer.name),
            };
        } else if (latest_peers.items.len > 1) {
            printErr(io, "Error: Multiple devices found. Specify one with --to <name|address>:\n", .{});
            for (latest_peers.items) |p| {
                printErr(io, "  • {s} ({s})\n", .{ p.name, p.id });
            }
            return null;
        } else {
            printErr(io, "Error: No Quick Share devices found nearby.\n", .{});
            return null;
        }
    }

    printErr(io, "Error: Could not find device matching \"{s}\".\n", .{target.?});
    if (latest_peers.items.len > 0) {
        printErr(io, "Discovered devices:\n", .{});
        for (latest_peers.items) |p| {
            printErr(io, "  • {s} ({s})\n", .{ p.name, p.id });
        }
    }
    return null;
}

fn runSend(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var target: ?[]const u8 = null;
    var sender_name: ?[]const u8 = null;
    var timeout_secs: u32 = 5;
    var files: std.ArrayList([]const u8) = .empty;
    defer files.deinit(arena);

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--to") and i + 1 < args.len) {
            i += 1;
            target = args[i];
        } else if (std.mem.startsWith(u8, arg, "--to=")) {
            target = arg["--to=".len..];
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            sender_name = args[i];
        } else if (std.mem.startsWith(u8, arg, "--name=")) {
            sender_name = arg["--name=".len..];
        } else if (std.mem.eql(u8, arg, "--timeout") and i + 1 < args.len) {
            i += 1;
            timeout_secs = std.fmt.parseInt(u32, args[i], 10) catch 5;
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_secs = std.fmt.parseInt(u32, arg["--timeout=".len..], 10) catch 5;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            try files.append(arena, arg);
        } else {
            printErr(io, "Unknown option: {s}\n", .{arg});
            return 1;
        }
    }

    if (files.items.len == 0) {
        printErr(io, "Error: No files specified to send.\nUsage: hollershare send <files...> --to <target>\n", .{});
        return 1;
    }

    // Validate files and convert to canonical absolute paths
    var canonical_paths: std.ArrayList([]const u8) = .empty;
    defer canonical_paths.deinit(arena);
    for (files.items) |path| {
        const file = std.Io.Dir.cwd().openFile(io, path, .{}) catch |err| {
            printErr(io, "Error: Cannot open file '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
        const stat = file.stat(io) catch |err| {
            file.close(io);
            printErr(io, "Error: Cannot stat file '{s}': {s}\n", .{ path, @errorName(err) });
            return 1;
        };
        file.close(io);
        if (stat.kind == .directory) {
            printErr(io, "Error: '{s}' is a directory. Quick Share sends individual files.\n", .{path});
            return 1;
        }
        const real = if (std.fs.path.isAbsolute(path))
            std.Io.Dir.realPathFileAbsoluteAlloc(io, path, arena) catch |err| {
                printErr(io, "Error: Cannot resolve absolute path for '{s}': {s}\n", .{ path, @errorName(err) });
                return 1;
            }
        else
            std.Io.Dir.cwd().realPathFileAlloc(io, path, arena) catch |err| {
                printErr(io, "Error: Cannot resolve absolute path for '{s}': {s}\n", .{ path, @errorName(err) });
                return 1;
            };
        try canonical_paths.append(arena, real);
    }

    const start_resp = hollershare_start("") orelse {
        printErr(io, "Error: Failed to start Quick Share engine.\n", .{});
        return 1;
    };
    defer hollershare_free(start_resp);
    defer hollershare_stop();

    _ = requestJson(arena, .{ .command = "visibility", .visible = false }) catch {};

    const resolved = try resolveTarget(gpa, arena, io, target, timeout_secs) orelse return 1;

    const snap_resp = requestJson(arena, .{ .command = "snapshot" }) catch "";
    var default_name: []const u8 = "HollerShare";
    if (std.json.parseFromSlice(std.json.Value, arena, snap_resp, .{})) |parsed| {
        if (parsed.value == .object) {
            if (parsed.value.object.get("data")) |d| {
                if (d == .object and d.object.get("name") != null and d.object.get("name").? == .string) {
                    default_name = d.object.get("name").?.string;
                }
            }
        }
    } else |_| {}

    const my_name = sender_name orelse default_name;

    printOut(io, "Sending {d} file(s) to {s} ({s})...\n", .{ canonical_paths.items.len, resolved.name, resolved.address });

    const send_res = requestJson(arena, .{
        .command = "send",
        .address = resolved.address,
        .name = my_name,
        .paths = canonical_paths.items,
    }) catch |err| {
        printErr(io, "Error initiating send: {s}\n", .{@errorName(err)});
        return 1;
    };

    if (std.json.parseFromSlice(struct { ok: bool, @"error": ?[]const u8 = null }, arena, send_res, .{ .ignore_unknown_fields = true })) |parsed| {
        if (!parsed.value.ok) {
            printErr(io, "Send failed: {s}\n", .{parsed.value.@"error" orelse "unknown error"});
            return 1;
        }
    } else |_| {}

    return monitorTransfer(arena, io, resolved.address, resolved.name, true);
}

fn runSendText(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    var target: ?[]const u8 = null;
    var sender_name: ?[]const u8 = null;
    var timeout_secs: u32 = 5;
    var text_arg: ?[]const u8 = null;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--to") and i + 1 < args.len) {
            i += 1;
            target = args[i];
        } else if (std.mem.startsWith(u8, arg, "--to=")) {
            target = arg["--to=".len..];
        } else if (std.mem.eql(u8, arg, "--name") and i + 1 < args.len) {
            i += 1;
            sender_name = args[i];
        } else if (std.mem.startsWith(u8, arg, "--name=")) {
            sender_name = arg["--name=".len..];
        } else if (std.mem.eql(u8, arg, "--timeout") and i + 1 < args.len) {
            i += 1;
            timeout_secs = std.fmt.parseInt(u32, args[i], 10) catch 5;
        } else if (std.mem.startsWith(u8, arg, "--timeout=")) {
            timeout_secs = std.fmt.parseInt(u32, arg["--timeout=".len..], 10) catch 5;
        } else if (!std.mem.startsWith(u8, arg, "-")) {
            text_arg = arg;
        } else if (std.mem.eql(u8, arg, "-")) {
            text_arg = "-";
        } else {
            printErr(io, "Unknown option: {s}\n", .{arg});
            return 1;
        }
    }

    if (text_arg == null) {
        printErr(io, "Error: No text specified.\nUsage: hollershare send-text <text> --to <target>\nPass '-' to read text from stdin.\n", .{});
        return 1;
    }

    var payload: []const u8 = text_arg.?;
    if (std.mem.eql(u8, payload, "-")) {
        const stdin_file = std.Io.File.stdin();
        var buf: [4096]u8 = undefined;
        var reader = stdin_file.readerStreaming(io, &buf);
        var list: std.ArrayList(u8) = .empty;
        defer list.deinit(arena);
        var chunk: [4096]u8 = undefined;
        while (true) {
            const n = try reader.interface.readSliceShort(&chunk);
            if (n == 0) break;
            try list.appendSlice(arena, chunk[0..n]);
            if (list.items.len > 1024 * 1024) {
                printErr(io, "Error: Text payload exceeds 1 MB limit.\n", .{});
                return 1;
            }
        }
        payload = list.items;
    }

    if (payload.len == 0) {
        printErr(io, "Error: Text payload is empty.\n", .{});
        return 1;
    }

    const start_resp = hollershare_start("") orelse {
        printErr(io, "Error: Failed to start Quick Share engine.\n", .{});
        return 1;
    };
    defer hollershare_free(start_resp);
    defer hollershare_stop();

    _ = requestJson(arena, .{ .command = "visibility", .visible = false }) catch {};

    const resolved = try resolveTarget(gpa, arena, io, target, timeout_secs) orelse return 1;

    const snap_resp = requestJson(arena, .{ .command = "snapshot" }) catch "";
    var default_name: []const u8 = "HollerShare";
    if (std.json.parseFromSlice(std.json.Value, arena, snap_resp, .{})) |parsed| {
        if (parsed.value == .object) {
            if (parsed.value.object.get("data")) |d| {
                if (d == .object and d.object.get("name") != null and d.object.get("name").? == .string) {
                    default_name = d.object.get("name").?.string;
                }
            }
        }
    } else |_| {}

    const my_name = sender_name orelse default_name;

    printOut(io, "Sending text to {s} ({s})...\n", .{ resolved.name, resolved.address });

    const send_res = requestJson(arena, .{
        .command = "send_text",
        .address = resolved.address,
        .name = my_name,
        .text = payload,
    }) catch |err| {
        printErr(io, "Error initiating send: {s}\n", .{@errorName(err)});
        return 1;
    };

    if (std.json.parseFromSlice(struct { ok: bool, @"error": ?[]const u8 = null }, arena, send_res, .{ .ignore_unknown_fields = true })) |parsed| {
        if (!parsed.value.ok) {
            printErr(io, "Send failed: {s}\n", .{parsed.value.@"error" orelse "unknown error"});
            return 1;
        }
    } else |_| {}

    return monitorTransfer(arena, io, resolved.address, resolved.name, false);
}

fn monitorTransfer(arena: std.mem.Allocator, io: std.Io, address: []const u8, peer_name: []const u8, is_files: bool) !u8 {
    _ = is_files;
    const is_tty = std.Io.File.stdout().isTty(io) catch false;
    var printed_pin = false;
    var last_pct: u8 = 255;
    var last_state: []const u8 = "";

    var transfer_id_buf: [256]u8 = undefined;
    var transfer_id: ?[]const u8 = null;

    const start_time = std.Io.Timestamp.now(io, .awake).toMilliseconds();
    const connect_deadline = start_time + 30_000;

    var byte_buf1: [32]u8 = undefined;
    var byte_buf2: [32]u8 = undefined;

    while (true) {
        io.sleep(.fromMilliseconds(100), .awake) catch {};

        const snap_resp = requestJson(arena, .{ .command = "snapshot" }) catch continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, snap_resp, .{}) catch continue;
        const data_obj = if (parsed.value == .object) parsed.value.object.get("data") else null;
        if (data_obj == null or data_obj.? != .object) continue;

        const transfers_val = data_obj.?.object.get("transfers");
        if (transfers_val == null or transfers_val.? != .array) continue;

        var current_transfer: ?std.json.ObjectMap = null;
        for (transfers_val.?.array.items) |t| {
            if (t != .object) continue;
            const rtype = t.object.get("rtype");
            if (rtype == null or rtype.? != .string or !std.mem.eql(u8, rtype.?.string, "Outbound")) continue;

            const tid = t.object.get("id");
            if (tid == null or tid.? != .string) continue;

            if (transfer_id) |known_id| {
                if (std.mem.eql(u8, tid.?.string, known_id)) {
                    current_transfer = t.object;
                    break;
                }
            } else if (std.mem.startsWith(u8, tid.?.string, address)) {
                @memcpy(transfer_id_buf[0..tid.?.string.len], tid.?.string);
                transfer_id = transfer_id_buf[0..tid.?.string.len];
                current_transfer = t.object;
                break;
            }
        }

        if (current_transfer == null) {
            if (std.Io.Timestamp.now(io, .awake).toMilliseconds() > connect_deadline) {
                printErr(io, "\nError: Connection to {s} timed out.\n", .{peer_name});
                return 1;
            }
            continue;
        }

        const t = current_transfer.?;
        const state_val = t.get("state");
        const state = if (state_val != null and state_val.? == .string) state_val.?.string else "";

        const meta_val = t.get("meta");
        const meta = if (meta_val != null and meta_val.? == .object) meta_val.?.object else null;

        if (!std.mem.eql(u8, state, last_state)) {
            last_state = state;
        }

        if (std.mem.eql(u8, state, "WaitingForUserConsent") or std.mem.eql(u8, state, "SendingFiles")) {
            if (!printed_pin and meta != null) {
                if (meta.?.get("pin_code")) |pin| {
                    if (pin == .string and pin.string.len > 0) {
                        printOut(io, "PIN code: {s}\nWaiting for {s} to accept transfer...\n", .{ pin.string, peer_name });
                        printed_pin = true;
                    }
                }
            }
        }

        if (std.mem.eql(u8, state, "SendingFiles") and meta != null) {
            var total: u64 = 0;
            var ack: u64 = 0;
            if (meta.?.get("total_bytes")) |tb| {
                if (tb == .integer and tb.integer >= 0) total = @intCast(tb.integer);
            }
            if (meta.?.get("ack_bytes")) |ab| {
                if (ab == .integer and ab.integer >= 0) ack = @intCast(ab.integer);
            }

            const pct: u8 = if (total > 0) @intCast(@min(100, (ack * 100) / total)) else 0;
            if (is_tty) {
                printOut(io, "\rSending: {d}% ({s} / {s})   ", .{
                    pct,
                    formatBytes(&byte_buf1, ack),
                    formatBytes(&byte_buf2, total),
                });
            } else if (pct != last_pct and pct % 25 == 0) {
                printOut(io, "Progress: {d}%\n", .{pct});
            }
            last_pct = pct;
        }

        if (std.mem.eql(u8, state, "Finished")) {
            if (is_tty) printOut(io, "\n", .{});
            printOut(io, "Transfer complete! Successfully sent to {s}.\n", .{peer_name});
            return 0;
        }

        if (std.mem.eql(u8, state, "Rejected")) {
            if (is_tty) printOut(io, "\n", .{});
            printErr(io, "Transfer declined by {s}.\n", .{peer_name});
            return 1;
        }

        if (std.mem.eql(u8, state, "Cancelled")) {
            if (is_tty) printOut(io, "\n", .{});
            printErr(io, "Transfer was cancelled.\n", .{});
            return 1;
        }

        if (std.mem.eql(u8, state, "Disconnected")) {
            if (is_tty) printOut(io, "\n", .{});
            printErr(io, "Transfer failed: connection lost or declined.\n", .{});
            return 1;
        }
    }
}

fn runReceive(gpa: std.mem.Allocator, arena: std.mem.Allocator, io: std.Io, args: []const []const u8) !u8 {
    _ = gpa;
    var download_dir: ?[]const u8 = null;
    var auto_accept = false;

    var i: usize = 0;
    while (i < args.len) : (i += 1) {
        const arg = args[i];
        if (std.mem.eql(u8, arg, "--dir") and i + 1 < args.len) {
            i += 1;
            download_dir = args[i];
        } else if (std.mem.startsWith(u8, arg, "--dir=")) {
            download_dir = arg["--dir=".len..];
        } else if (std.mem.eql(u8, arg, "--auto-accept")) {
            auto_accept = true;
        } else {
            printErr(io, "Unknown option: {s}\n", .{arg});
            return 1;
        }
    }

    const target_dir = download_dir orelse ".";
    const canonical_dir = if (std.fs.path.isAbsolute(target_dir))
        std.Io.Dir.realPathFileAbsoluteAlloc(io, target_dir, arena) catch |err| {
            printErr(io, "Error resolving directory '{s}': {s}\n", .{ target_dir, @errorName(err) });
            return 1;
        }
    else
        std.Io.Dir.cwd().realPathFileAlloc(io, target_dir, arena) catch |err| {
            printErr(io, "Error resolving directory '{s}': {s}\n", .{ target_dir, @errorName(err) });
            return 1;
        };
    const dir_z = try arena.dupeZ(u8, canonical_dir);

    const start_resp = hollershare_start(dir_z) orelse {
        printErr(io, "Error: Failed to start Quick Share engine.\n", .{});
        return 1;
    };
    defer hollershare_free(start_resp);
    defer hollershare_stop();

    _ = requestJson(arena, .{ .command = "visibility", .visible = true }) catch {};

    printOut(io, "HollerShare receiver active.\nSaving to: {s}\nVisible to nearby devices. Press Ctrl+C to stop.\n\n", .{canonical_dir});

    var seen_requests: std.ArrayList([]const u8) = .empty;
    defer seen_requests.deinit(arena);

    while (true) {
        io.sleep(.fromMilliseconds(250), .awake) catch {};

        const snap_resp = requestJson(arena, .{ .command = "snapshot" }) catch continue;
        const parsed = std.json.parseFromSlice(std.json.Value, arena, snap_resp, .{}) catch continue;
        const data_obj = if (parsed.value == .object) parsed.value.object.get("data") else null;
        if (data_obj == null or data_obj.? != .object) continue;

        const transfers_val = data_obj.?.object.get("transfers");
        if (transfers_val == null or transfers_val.? != .array) continue;

        for (transfers_val.?.array.items) |t| {
            if (t != .object) continue;
            const rtype = t.object.get("rtype");
            if (rtype == null or rtype.? != .string or !std.mem.eql(u8, rtype.?.string, "Inbound")) continue;

            const tid_val = t.object.get("id");
            if (tid_val == null or tid_val.? != .string) continue;
            const tid = tid_val.?.string;

            const state_val = t.object.get("state");
            const state = if (state_val != null and state_val.? == .string) state_val.?.string else "";

            const meta_val = t.object.get("meta");
            const meta = if (meta_val != null and meta_val.? == .object) meta_val.?.object else null;

            if (std.mem.eql(u8, state, "WaitingForUserConsent")) {
                var seen = false;
                for (seen_requests.items) |s| {
                    if (std.mem.eql(u8, s, tid)) {
                        seen = true;
                        break;
                    }
                }
                if (seen) continue;
                try seen_requests.append(arena, try arena.dupe(u8, tid));

                var sender: []const u8 = "Nearby device";
                var pin_str: []const u8 = "----";
                if (meta) |m| {
                    if (m.get("source")) |s| {
                        if (s == .object and s.object.get("name") != null and s.object.get("name").? == .string) {
                            sender = s.object.get("name").?.string;
                        }
                    }
                    if (m.get("pin_code")) |p| {
                        if (p == .string) pin_str = p.string;
                    }
                }

                printOut(io, "Incoming transfer from {s}\nPIN: {s}\n", .{ sender, pin_str });

                if (auto_accept) {
                    printOut(io, "Auto-accepting transfer...\n", .{});
                    _ = requestJson(arena, .{ .command = "decide", .id = tid, .accept = true }) catch {};
                } else {
                    printOut(io, "Accept transfer? [Y/n]: ", .{});
                    const stdin_file = std.Io.File.stdin();
                    var buf: [64]u8 = undefined;
                    var reader = stdin_file.readerStreaming(io, &buf);
                    const line = (reader.interface.takeDelimiter('\n') catch null) orelse "";
                    const trimmed = std.mem.trim(u8, line, " \t\r\n");
                    const accept = (trimmed.len == 0 or std.ascii.eqlIgnoreCase(trimmed, "y") or std.ascii.eqlIgnoreCase(trimmed, "yes"));

                    if (accept) {
                        _ = requestJson(arena, .{ .command = "decide", .id = tid, .accept = true }) catch {};
                        printOut(io, "Accepted.\n", .{});
                    } else {
                        _ = requestJson(arena, .{ .command = "decide", .id = tid, .accept = false }) catch {};
                        printOut(io, "Declined.\n", .{});
                    }
                }
            } else if (std.mem.eql(u8, state, "Finished")) {
                for (seen_requests.items, 0..) |s, idx| {
                    if (std.mem.eql(u8, s, tid)) {
                        _ = seen_requests.swapRemove(idx);
                        printOut(io, "Transfer completed successfully.\n", .{});
                        break;
                    }
                }
            }
        }
    }
}
