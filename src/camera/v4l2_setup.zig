//! The root script that makes the "HollerShare Camera" v4l2loopback device
//! (run through pkexec by app.zig). It never changes another program's
//! v4l2loopback setup: with the driver already loaded by someone else (OBS,
//! say) or configured by another file, it only adds a device for now
//! (v4l2loopback-ctl), and Setup is needed again after a restart. A run
//! decides by the device itself: when the HollerShare Camera exists at the
//! end (even if a tool reported an error, or the run was interrupted), it
//! keeps its boot files; otherwise files it created are removed and files
//! it changed get their old contents back.

/// Prints one line, "ready" or the reason it couldn't, and exits 0, 3 (no
/// driver), 4 (the driver is in use without the tool that adds a device)
/// or 1. One run at a time (a lock in /run). Its first argument, a scratch
/// root, is for the tests only: app.zig passes none.
pub const script =
    \\set -u
    \\# Tests pass a scratch tree; app.zig passes nothing (the real root).
    \\R="${1:-}"
    \\NAME="HollerShare Camera"
    \\MODPROBE_CONF="$R"/etc/modprobe.d/hollershare-camera.conf
    \\MODULES_CONF="$R"/etc/modules-load.d/hollershare-camera.conf
    \\CLEANUP=""
    \\RESTORE=""
    \\COMMITTED=0
    \\# Undo: remove what this run created, put back what it changed; once
    \\# committed (even halfway through dropping the backups) nothing is undone.
    \\cleanup() {
    \\  [ "$COMMITTED" = 1 ] && return 0
    \\  for f in $CLEANUP; do rm -f "$f"; done
    \\  for f in $RESTORE; do mv -f "$f.hollershare-old" "$f"; done
    \\}
    \\# Keep what this run changed: committed first, then the backups go.
    \\commit() {
    \\  COMMITTED=1
    \\  for f in $RESTORE; do rm -f "$f.hollershare-old"; done
    \\}
    \\fail() {
    \\  cleanup
    \\  echo "$2"
    \\  exit "$1"
    \\}
    \\# Interrupted: undo, unless this run already succeeded (committed, or
    \\# its device appeared while loading): then finish committing.
    \\on_signal() {
    \\  if [ "$COMMITTED" = 1 ] || { [ "$LOADING" = 1 ] && have; }; then commit; echo ready; exit 0; fi
    \\  cleanup
    \\  exit 1
    \\}
    \\LOADING=0
    \\trap on_signal INT TERM HUP
    \\# One setup at a time: another run's rollback must not undo this one.
    \\# Nothing changes without the lock.
    \\command -v flock >/dev/null 2>&1 || fail 1 "Setting up the camera needs flock (from util-linux). Install it, then try again."
    \\mkdir -p "$R"/run
    \\LOCK="$R"/run/hollershare-camera-setup.lock
    \\( : >>"$LOCK" ) 2>/dev/null || fail 1 "Couldn't take the setup lock ($LOCK)."
    \\exec 9>>"$LOCK"
    \\# Some flock builds (BusyBox) can't wait with -w: say so, not "busy".
    \\flock --help 2>&1 | grep -q -- '-w' || fail 1 "Setting up the camera needs the flock from util-linux (the installed one can't wait for a lock). Install util-linux, then try again."
    \\flock -w 120 9 || fail 1 "Another camera setup is still running. Try again in a moment."
    \\have() {
    \\  for n in "$R"/sys/class/video4linux/*/name; do
    \\    [ -r "$n" ] && [ "$(cat "$n")" = "$NAME" ] && return 0
    \\  done
    \\  return 1
    \\}
    \\# Another file, in any directory modprobe reads, configuring v4l2loopback.
    \\has_other_config() {
    \\  for f in "$R"/etc/modprobe.d/* "$R"/run/modprobe.d/* "$R"/usr/local/lib/modprobe.d/* "$R"/usr/lib/modprobe.d/* "$R"/lib/modprobe.d/*; do
    \\    [ -f "$f" ] || continue
    \\    [ "$f" = "$MODPROBE_CONF" ] && continue
    \\    grep -Eq '^[[:space:]]*options[[:space:]]+v4l2loopback([[:space:]]|$)' "$f" 2>/dev/null && return 0
    \\  done
    \\  return 1
    \\}
    \\# Write $2 to the file $1, so that cleanup undoes it: a new file is
    \\# removed, an existing one gets its old contents back.
    \\write_file() {
    \\  if [ -e "$1" ]; then
    \\    [ "$(cat "$1")" = "$2" ] && return 0
    \\    cp -p "$1" "$1.hollershare-old" || fail 1 "Backing up $1 failed."
    \\    RESTORE="$RESTORE $1"
    \\  else
    \\    CLEANUP="$CLEANUP $1"
    \\  fi
    \\  printf '%s\n' "$2" > "$1" || fail 1 "Writing $1 failed."
    \\}
    \\one_line() { printf '%s' "$1" | tr '\r\n' '  '; }
    \\if have; then echo ready; exit 0; fi
    \\if ! modinfo v4l2loopback >/dev/null 2>&1; then
    \\  fail 3 "The v4l2loopback driver isn't installed. Install your distribution's v4l2loopback package, then try again."
    \\fi
    \\WAS_LOADED=0
    \\[ -d "$R"/sys/module/v4l2loopback ] && WAS_LOADED=1
    \\HAS_CTL=0
    \\command -v v4l2loopback-ctl >/dev/null 2>&1 && HAS_CTL=1
    \\if [ "$WAS_LOADED" -eq 1 ] || has_other_config; then
    \\  # Someone else's v4l2loopback: add our device beside theirs, now only.
    \\  [ "$HAS_CTL" -eq 1 ] || fail 4 "Another program already uses the v4l2loopback driver. Install v4l2loopback-ctl (part of v4l2loopback-utils) to add the HollerShare Camera beside it."
    \\  LOADING=1
    \\  if [ "$WAS_LOADED" -eq 0 ]; then
    \\    out=$(modprobe v4l2loopback 2>&1) || fail 1 "Loading v4l2loopback failed: $(one_line "$out")"
    \\    have && { echo ready; exit 0; }
    \\  fi
    \\  if ! out=$(v4l2loopback-ctl add --name "$NAME" --exclusive-caps 1 2>&1) \
    \\     && ! out=$(v4l2loopback-ctl add -n "$NAME" -x 1 2>&1); then
    \\    fail 1 "Adding the HollerShare Camera device failed: $(one_line "$out")"
    \\  fi
    \\  have && { echo ready; exit 0; }
    \\  fail 1 "v4l2loopback-ctl ran, but the HollerShare Camera didn't appear."
    \\fi
    \\# Ours alone: the device now and at every boot.
    \\mkdir -p "$R"/etc/modprobe.d "$R"/etc/modules-load.d || fail 1 "Creating /etc/modprobe.d failed."
    \\write_file "$MODPROBE_CONF" "options v4l2loopback devices=1 card_label=\"$NAME\" exclusive_caps=1"
    \\write_file "$MODULES_CONF" "v4l2loopback"
    \\LOADING=1
    \\if ! out=$(modprobe v4l2loopback 2>&1); then
    \\  # An error after the device appeared (an install hook, say) is still
    \\  # a working camera: keep its boot files.
    \\  have && { commit; echo ready; exit 0; }
    \\  case "$out" in
    \\    *"Key was rejected"*|*"Required key not available"*)
    \\      fail 1 "Secure Boot refused the v4l2loopback driver. Sign it or enroll its key (mokutil), then try again." ;;
    \\    *) fail 1 "Loading v4l2loopback failed: $(one_line "$out")" ;;
    \\  esac
    \\fi
    \\have && { commit; echo ready; exit 0; }
    \\fail 1 "The driver loaded, but the HollerShare Camera didn't appear."
;

// --- Tests: the script against a scratch tree, with stand-in tools -------

const std = @import("std");
const builtin = @import("builtin");

const Fixture = struct {
    tmp: std.testing.TmpDir,
    root: []const u8,
    bin: []const u8,

    /// A scratch root with /etc and /sys, and stand-ins for modinfo,
    /// modprobe (makes the device unless FAIL_MODPROBE is set) and
    /// v4l2loopback-ctl (adds the device).
    fn init(gpa: std.mem.Allocator, io: std.Io) !Fixture {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        for ([_][]const u8{ "root/etc/modprobe.d", "root/etc/modules-load.d", "root/sys/class/video4linux", "bin" }) |dir| try tmp.dir.createDirPath(io, dir);
        const tools = [_][2][]const u8{
            .{ "bin/modinfo", "#!/bin/sh\nexit 0\n" },
            .{ "bin/modprobe", "#!/bin/sh\n# The script: the topmost ancestor whose arguments include the scratch\n# root ($(...) may or may not add a subshell, depending on the shell).\nscript_pid=; p=$PPID\nwhile [ \"$p\" -gt 1 ]; do tr '\\0' '\\n' < /proc/$p/cmdline 2>/dev/null | grep -qx \"$STANDIN_ROOT\" && script_pid=$p; p=$(cut -d' ' -f4 /proc/$p/stat); done\n[ -n \"${FAIL_AFTER_DEVICE:-}\" ] && { mkdir -p \"$STANDIN_ROOT/sys/class/video4linux/video9\"; echo 'HollerShare Camera' > \"$STANDIN_ROOT/sys/class/video4linux/video9/name\"; echo 'modprobe: install hook failed'; exit 1; }\n[ -n \"${SIGNAL_MODPROBE:-}\" ] && { kill -TERM $script_pid; exit 1; }\n[ -n \"${SIGNAL_AFTER_DEVICE:-}\" ] && { mkdir -p \"$STANDIN_ROOT/sys/class/video4linux/video9\"; echo 'HollerShare Camera' > \"$STANDIN_ROOT/sys/class/video4linux/video9/name\"; kill -TERM $script_pid; exit 0; }\n[ -n \"${SLOW_MODPROBE:-}\" ] && sleep 1\n[ -n \"${FAIL_MODPROBE:-}\" ] && { echo 'modprobe: ERROR: boom'; exit 1; }\nmkdir -p \"$STANDIN_ROOT/sys/class/video4linux/video9\" \"$STANDIN_ROOT/sys/module/v4l2loopback\"\necho 'HollerShare Camera' > \"$STANDIN_ROOT/sys/class/video4linux/video9/name\"\n" },
            .{ "bin/v4l2loopback-ctl", "#!/bin/sh\nmkdir -p \"$STANDIN_ROOT/sys/class/video4linux/video8\"\necho 'HollerShare Camera' > \"$STANDIN_ROOT/sys/class/video4linux/video8/name\"\n" },
        };
        for (tools) |tool| try tmp.dir.writeFile(io, .{ .sub_path = tool[0], .data = tool[1], .flags = .{ .permissions = .executable_file } });
        const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
        defer gpa.free(base);
        const root = try std.fs.path.join(gpa, &.{ base, "root" });
        errdefer gpa.free(root);
        return .{ .tmp = tmp, .root = root, .bin = try std.fs.path.join(gpa, &.{ base, "bin" }) };
    }

    fn deinit(self: *Fixture, gpa: std.mem.Allocator) void {
        gpa.free(self.root);
        gpa.free(self.bin);
        self.tmp.cleanup();
    }

    fn write(self: *Fixture, io: std.Io, path: []const u8, data: []const u8) !void {
        try self.tmp.dir.writeFile(io, .{ .sub_path = path, .data = data });
    }

    /// The file's contents, or null when it doesn't exist (in `gpa`).
    fn read(self: *Fixture, gpa: std.mem.Allocator, io: std.Io, path: []const u8) !?[]u8 {
        return self.tmp.dir.readFileAlloc(io, path, gpa, .limited(4096)) catch |err| switch (err) {
            error.FileNotFound => null,
            else => err,
        };
    }

    /// The stand-ins' environment (in `gpa`; deinit it).
    fn environ(self: *Fixture, gpa: std.mem.Allocator, fail_modprobe: bool, slow_modprobe: bool) !std.process.Environ.Map {
        var map: std.process.Environ.Map = .init(gpa);
        errdefer map.deinit();
        const path = try std.fmt.allocPrint(gpa, "{s}:/usr/bin:/bin", .{self.bin});
        defer gpa.free(path);
        try map.put("PATH", path);
        try map.put("STANDIN_ROOT", self.root);
        if (fail_modprobe) try map.put("FAIL_MODPROBE", "1");
        if (slow_modprobe) try map.put("SLOW_MODPROBE", "1");
        return map;
    }

    /// Run the script; its exit code and its one line (in `gpa`).
    fn run(self: *Fixture, gpa: std.mem.Allocator, io: std.Io, fail_modprobe: bool) !struct { code: u8, line: []u8 } {
        var map = try self.environ(gpa, fail_modprobe, false);
        defer map.deinit();
        const result = try std.process.run(gpa, io, .{ .argv = &.{ "/bin/sh", "-c", script, "setup", self.root }, .environ_map = &map });
        defer gpa.free(result.stderr);
        defer gpa.free(result.stdout);
        const code: u8 = switch (result.term) {
            .exited => |c| c,
            else => 255,
        };
        return .{ .code = code, .line = try gpa.dupe(u8, std.mem.trim(u8, result.stdout, " \n")) };
    }
};

/// The script refuses to run without flock: these tests need it.
fn requireFlock(gpa: std.mem.Allocator, io: std.Io) !void {
    const probe = std.process.run(gpa, io, .{ .argv = &.{ "/bin/sh", "-c", "command -v flock" } }) catch return error.SkipZigTest;
    gpa.free(probe.stdout);
    gpa.free(probe.stderr);
    if (probe.term != .exited or probe.term.exited != 0) return error.SkipZigTest;
}

const modprobe_conf = "root/etc/modprobe.d/hollershare-camera.conf";
const modules_conf = "root/etc/modules-load.d/hollershare-camera.conf";
const ours = "options v4l2loopback devices=1 card_label=\"HollerShare Camera\" exclusive_caps=1\n";

fn expectFile(f: *Fixture, gpa: std.mem.Allocator, io: std.Io, path: []const u8, expected: ?[]const u8) !void {
    const got = try f.read(gpa, io, path);
    defer if (got) |g| gpa.free(g);
    if (expected) |e| {
        try std.testing.expect(got != null);
        try std.testing.expectEqualStrings(e, got.?);
    } else try std.testing.expect(got == null);
}

test "setup makes the device and its boot configuration" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try requireFlock(gpa, io);
    var f = try Fixture.init(gpa, io);
    defer f.deinit(gpa);
    const r = try f.run(gpa, io, false);
    defer gpa.free(r.line);
    try std.testing.expectEqualStrings("ready", r.line);
    try std.testing.expectEqual(@as(u8, 0), r.code);
    try expectFile(&f, gpa, io, modprobe_conf, ours);
    try expectFile(&f, gpa, io, modules_conf, "v4l2loopback\n");
}

test "a failed setup removes what it created and restores what it changed" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try requireFlock(gpa, io);
    {
        var f = try Fixture.init(gpa, io);
        defer f.deinit(gpa);
        const r = try f.run(gpa, io, true);
        defer gpa.free(r.line);
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try std.testing.expect(std.mem.startsWith(u8, r.line, "Loading v4l2loopback failed: modprobe: ERROR: boom"));
        try expectFile(&f, gpa, io, modprobe_conf, null);
        try expectFile(&f, gpa, io, modules_conf, null);
    }
    {
        var f = try Fixture.init(gpa, io);
        defer f.deinit(gpa);
        try f.write(io, modprobe_conf, "options v4l2loopback devices=2 card_label=Custom\n");
        try f.write(io, modules_conf, "custom\n");
        const r = try f.run(gpa, io, true);
        defer gpa.free(r.line);
        try std.testing.expectEqual(@as(u8, 1), r.code);
        try expectFile(&f, gpa, io, modprobe_conf, "options v4l2loopback devices=2 card_label=Custom\n");
        try expectFile(&f, gpa, io, modules_conf, "custom\n");
        try expectFile(&f, gpa, io, modprobe_conf ++ ".hollershare-old", null);
    }
}

test "setup leaves another program's v4l2loopback alone" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try requireFlock(gpa, io);
    {
        // The driver loaded by someone else (OBS): a device for now, no boot config.
        var f = try Fixture.init(gpa, io);
        defer f.deinit(gpa);
        try f.tmp.dir.createDirPath(io, "root/sys/module/v4l2loopback");
        const r = try f.run(gpa, io, false);
        defer gpa.free(r.line);
        try std.testing.expectEqualStrings("ready", r.line);
        try expectFile(&f, gpa, io, modprobe_conf, null);
        try expectFile(&f, gpa, io, modules_conf, null);
    }
    {
        // Another file configures it: untouched, and no config of ours.
        var f = try Fixture.init(gpa, io);
        defer f.deinit(gpa);
        try f.write(io, "root/etc/modprobe.d/obs.conf", "options v4l2loopback card_label=OBS\n");
        const r = try f.run(gpa, io, false);
        defer gpa.free(r.line);
        try std.testing.expectEqualStrings("ready", r.line);
        try expectFile(&f, gpa, io, "root/etc/modprobe.d/obs.conf", "options v4l2loopback card_label=OBS\n");
        try expectFile(&f, gpa, io, modprobe_conf, null);
    }
}

test "a setup waits for one already running, so its rollback can't undo this one" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try requireFlock(gpa, io);
    var f = try Fixture.init(gpa, io);
    defer f.deinit(gpa);
    // The first run creates the boot files, then its (slow) modprobe fails.
    var slow_env = try f.environ(gpa, true, true);
    defer slow_env.deinit();
    var first = try std.process.spawn(io, .{ .argv = &.{ "/bin/sh", "-c", script, "setup", f.root }, .environ_map = &slow_env, .stdout = .ignore, .stderr = .ignore });
    try io.sleep(.fromMilliseconds(400), .awake);
    // The second starts meanwhile and succeeds: it must wait for the first.
    const r = try f.run(gpa, io, false);
    defer gpa.free(r.line);
    const first_term = try first.wait(io);
    try std.testing.expectEqual(@as(u8, 1), switch (first_term) {
        .exited => |c| c,
        else => 255,
    });
    try std.testing.expectEqualStrings("ready", r.line);
    try expectFile(&f, gpa, io, modprobe_conf, ours);
    try expectFile(&f, gpa, io, modules_conf, "v4l2loopback\n");
}

test "without flock, setup changes nothing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var f = try Fixture.init(gpa, io);
    defer f.deinit(gpa);
    try f.write(io, modprobe_conf, "options v4l2loopback devices=2 card_label=Custom\n");
    // A PATH with the stand-ins and the shell tools the script uses, but no flock.
    try f.tmp.dir.createDirPath(io, "tools");
    for ([_][]const u8{ "mkdir", "cat", "grep", "cp", "mv", "rm", "tr" }) |tool| {
        const found = try std.process.run(gpa, io, .{ .argv = &.{ "/bin/sh", "-c", "command -v \"$0\"", tool } });
        defer gpa.free(found.stderr);
        defer gpa.free(found.stdout);
        const target = std.mem.trim(u8, found.stdout, " \n");
        if (target.len == 0) return error.SkipZigTest;
        var link_buf: [64]u8 = undefined;
        try f.tmp.dir.symLink(io, target, try std.fmt.bufPrint(&link_buf, "tools/{s}", .{tool}), .{});
    }
    const base = try f.tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    var map: std.process.Environ.Map = .init(gpa);
    defer map.deinit();
    const path = try std.fmt.allocPrint(gpa, "{s}:{s}/tools", .{ f.bin, base });
    defer gpa.free(path);
    try map.put("PATH", path);
    try map.put("STANDIN_ROOT", f.root);
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "/bin/sh", "-c", script, "setup", f.root }, .environ_map = &map });
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    try std.testing.expect(result.term == .exited and result.term.exited == 1);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "flock") != null);
    try expectFile(&f, gpa, io, modprobe_conf, "options v4l2loopback devices=2 card_label=Custom\n");
    try expectFile(&f, gpa, io, modules_conf, null);
}

/// Run the script with an extra stand-in or variable; its exit code.
fn runWith(f: *Fixture, gpa: std.mem.Allocator, io: std.Io, name: []const u8, value: []const u8) !u8 {
    var map = try f.environ(gpa, false, false);
    defer map.deinit();
    try map.put(name, value);
    const result = try std.process.run(gpa, io, .{ .argv = &.{ "/bin/sh", "-c", script, "setup", f.root }, .environ_map = &map });
    defer gpa.free(result.stderr);
    defer gpa.free(result.stdout);
    return switch (result.term) {
        .exited => |c| c,
        else => 255,
    };
}

test "an interrupted setup undoes its changes, but never a committed one" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    try requireFlock(gpa, io);
    const old_modprobe = "options v4l2loopback devices=2 card_label=Custom\n";
    {
        // A signal before the commit: both files get their old contents back.
        var f = try Fixture.init(gpa, io);
        defer f.deinit(gpa);
        try f.write(io, modprobe_conf, old_modprobe);
        try f.write(io, modules_conf, "custom\n");
        try std.testing.expectEqual(@as(u8, 1), try runWith(&f, gpa, io, "SIGNAL_MODPROBE", "1"));
        try expectFile(&f, gpa, io, modprobe_conf, old_modprobe);
        try expectFile(&f, gpa, io, modules_conf, "custom\n");
    }
    {
        // A signal once the device appeared, before the commit: this run
        // succeeded, so its boot files stay (a retry would only say ready).
        var f = try Fixture.init(gpa, io);
        defer f.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), try runWith(&f, gpa, io, "SIGNAL_AFTER_DEVICE", "1"));
        try expectFile(&f, gpa, io, modprobe_conf, ours);
        try expectFile(&f, gpa, io, modules_conf, "v4l2loopback\n");
    }
    {
        // A signal while the commit drops the backups: the new files stay,
        // both of them (no mix of old and new).
        var f = try Fixture.init(gpa, io);
        defer f.deinit(gpa);
        try f.write(io, modprobe_conf, old_modprobe);
        try f.write(io, modules_conf, "custom\n");
        const rm_tool = "#!/bin/sh\ncase \"$*\" in *.hollershare-old*) [ -e \"$STANDIN_ROOT/signalled\" ] || { : > \"$STANDIN_ROOT/signalled\"; script_pid=; p=$PPID; while [ \"$p\" -gt 1 ]; do tr '\\0' '\\n' < /proc/$p/cmdline 2>/dev/null | grep -qx \"$STANDIN_ROOT\" && script_pid=$p; p=$(cut -d' ' -f4 /proc/$p/stat); done; kill -TERM $script_pid; } ;; esac\nexec /bin/rm \"$@\"\n";
        try f.tmp.dir.writeFile(io, .{ .sub_path = "bin/rm", .data = rm_tool, .flags = .{ .permissions = .executable_file } });
        // It finishes committing and reports success: no backup is left.
        try std.testing.expectEqual(@as(u8, 0), try runWith(&f, gpa, io, "UNUSED", "1"));
        try expectFile(&f, gpa, io, modprobe_conf, ours);
        try expectFile(&f, gpa, io, modules_conf, "v4l2loopback\n");
        try expectFile(&f, gpa, io, modprobe_conf ++ ".hollershare-old", null);
        try expectFile(&f, gpa, io, modules_conf ++ ".hollershare-old", null);
    }
    {
        // A loader that makes the device and then reports an error: the
        // camera works, so its boot files stay (a retry would only say ready).
        var f = try Fixture.init(gpa, io);
        defer f.deinit(gpa);
        try std.testing.expectEqual(@as(u8, 0), try runWith(&f, gpa, io, "FAIL_AFTER_DEVICE", "1"));
        try expectFile(&f, gpa, io, modprobe_conf, ours);
        try expectFile(&f, gpa, io, modules_conf, "v4l2loopback\n");
    }
}
