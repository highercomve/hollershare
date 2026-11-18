//! Images on the clipboard, shared as ordinary Quick Share files.
//!
//! Sending: "Paste clipboard" with an image (and no text) on the clipboard
//! saves it as a PNG in HollerShare's cache folder, named with `prefix`,
//! and adds that file to the batch. Quick Share has no clipboard flag, so
//! the name is the flag: a HollerShare receiver that gets one file named
//! like this puts it straight on its own clipboard, as it does with text.
//! Any other single image received offers "Copy image" instead.
const std = @import("std");

/// The start of a clipboard image's file name.
pub const prefix = "HollerShare clipboard";
/// The largest image read from or put on a clipboard.
pub const max_bytes = 32 * 1024 * 1024;
/// Saved clipboard images older than this are removed when a new one is saved.
const keep_seconds = 24 * 60 * 60;

/// `HollerShare clipboard 2026-11-14 10.30.05.png` for `seconds` since 1970
/// (UTC). No colons: Windows and Android's folders refuse them.
pub fn fileName(buf: []u8, seconds: i64) ![]const u8 {
    const epoch: std.time.epoch.EpochSeconds = .{ .secs = @intCast(@max(seconds, 0)) };
    const day = epoch.getEpochDay().calculateYearDay();
    const month = day.calculateMonthDay();
    const time = epoch.getDaySeconds();
    return std.fmt.bufPrint(buf, "{s} {d:0>4}-{d:0>2}-{d:0>2} {d:0>2}.{d:0>2}.{d:0>2}.png", .{
        prefix,
        day.year,
        month.month.numeric(),
        month.day_index + 1,
        time.getHoursIntoDay(),
        time.getMinutesIntoHour(),
        time.getSecondsIntoMinute(),
    });
}

/// Whether a received file is a clipboard image a HollerShare sender made.
/// A receiver may add " (1)" before the extension on a clash.
pub fn isClipboardImage(name: []const u8) bool {
    return std.mem.startsWith(u8, name, prefix) and std.ascii.endsWithIgnoreCase(name, ".png");
}

/// Whether a received file looks like a PNG, the one image format every
/// platform's clipboard takes as is (Oriel's `writeImage`): by its MIME
/// type, else (no type, or a generic one) by its extension. `isPng` checks
/// the bytes before they go on the clipboard.
pub fn isPngFile(name: []const u8, mime: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(mime, "image/png")) return true;
    if (mime.len > 0 and !std.mem.eql(u8, mime, "application/octet-stream")) return false;
    return std.ascii.endsWithIgnoreCase(name, ".png");
}

const png_signature = "\x89PNG\r\n\x1a\n";

/// Whether `bytes` start with the PNG signature.
pub fn isPng(bytes: []const u8) bool {
    return std.mem.startsWith(u8, bytes, png_signature);
}

/// Whether clipboard text is only an Android content address
/// ("content://..."): what Android's text view of an image clip is, so the
/// image is what to share.
pub fn isContentUri(text: []const u8) bool {
    const trimmed = std.mem.trim(u8, text, " \t\r\n");
    return std.mem.startsWith(u8, trimmed, "content://") and std.mem.indexOfAny(u8, trimmed, " \t\r\n") == null;
}

/// How reading the clipboard's image went.
pub const ImageRead = enum { got, none, failed };

/// What a "Paste clipboard" shares.
pub const Pick = enum {
    text,
    image,
    /// Nothing to share (or the platform's error, when reading failed).
    nothing,
    /// An Android image clip whose image couldn't be read: its content://
    /// address means nothing on another device, so it is never sent.
    unreadable_image,
};

/// The clipboard's text, unless there is none or (on Android, where an
/// image clip reads as text that way) it is only a content:// address;
/// then its image.
pub fn pick(text: []const u8, image: ImageRead, android: bool) Pick {
    const address = android and isContentUri(text);
    if (text.len > 0 and !address) return .text;
    return switch (image) {
        .got => .image,
        .none, .failed => if (address) .unreadable_image else .nothing,
    };
}

pub const Saved = struct { path: []const u8, name: []const u8, size: u64 };

/// Save `png` in `dir_path` (created if missing) under a clipboard name for
/// `now` (seconds since 1970), and remove the clipboard images saved there
/// more than a day ago. Strings are `gpa`'s.
pub fn save(gpa: std.mem.Allocator, io: std.Io, dir_path: []const u8, png: []const u8, now: i64) !Saved {
    var dir = try std.Io.Dir.cwd().createDirPathOpen(io, dir_path, .{ .open_options = .{ .iterate = true } });
    defer dir.close(io);
    removeOld(io, dir, now);
    var name_buf: [96]u8 = undefined;
    const first = try fileName(&name_buf, now);
    const stem = first[0 .. first.len - ".png".len];
    var name = first;
    // Two pastes in the same second (even at once): each claims its own
    // name by creating it exclusively, and keeps both.
    var numbered_buf: [112]u8 = undefined;
    var n: usize = 2;
    const file = while (true) : (n += 1) {
        if (dir.createFile(io, name, .{ .exclusive = true })) |file| break file else |err| switch (err) {
            error.PathAlreadyExists => {},
            else => return err,
        }
        if (n > 99) return error.PathAlreadyExists;
        name = try std.fmt.bufPrint(&numbered_buf, "{s} ({d}).png", .{ stem, n });
    };
    file.writeStreamingAll(io, png) catch |err| {
        file.close(io);
        dir.deleteFile(io, name) catch {};
        return err;
    };
    file.close(io);
    return .{
        .path = try std.fs.path.join(gpa, &.{ dir_path, name }),
        .name = try gpa.dupe(u8, name),
        .size = png.len,
    };
}

/// Delete clipboard images saved before `now - keep_seconds`; anything else
/// in the folder, and anything that can't be read, is left alone.
fn removeOld(io: std.Io, dir: std.Io.Dir, now: i64) void {
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !isClipboardImage(entry.name)) continue;
        const stat = dir.statFile(io, entry.name, .{}) catch continue;
        if (stat.mtime.toSeconds() >= now - keep_seconds) continue;
        dir.deleteFile(io, entry.name) catch {};
    }
}

test "clipboard file names carry the date and the prefix" {
    var buf: [96]u8 = undefined;
    const name = try fileName(&buf, 1_763_116_205); // 2025-11-14 10:30:05 UTC
    try std.testing.expectEqualStrings("HollerShare clipboard 2025-11-14 10.30.05.png", name);
    try std.testing.expect(isClipboardImage(name));
    try std.testing.expect(isClipboardImage("HollerShare clipboard 2025-11-14 10.30.05 (1).PNG"));
    try std.testing.expect(!isClipboardImage("Screenshot.png"));
    try std.testing.expect(!isClipboardImage("HollerShare clipboard notes.txt"));
}

test "only PNG files go on the clipboard" {
    try std.testing.expect(isPngFile("a", "image/png"));
    try std.testing.expect(isPngFile("shot.PNG", ""));
    try std.testing.expect(isPngFile("shot.png", "application/octet-stream"));
    // Other images would be mislabelled as PNG (or refused) by the clipboard.
    try std.testing.expect(!isPngFile("photo.jpg", "image/jpeg"));
    try std.testing.expect(!isPngFile("photo.jpg", ""));
    try std.testing.expect(!isPngFile("shot.png", "text/plain"));
    try std.testing.expect(isPng("\x89PNG\r\n\x1a\nrest"));
    try std.testing.expect(!isPng("\xff\xd8\xff\xe0 a JPEG"));
    try std.testing.expect(!isPng(""));
}

test "a paste shares text, else the image, and never an Android image address" {
    try std.testing.expectEqual(Pick.text, pick("hello", .got, true));
    try std.testing.expectEqual(Pick.text, pick("https://example.com/a.png", .none, true));
    try std.testing.expectEqual(Pick.image, pick("", .got, true));
    try std.testing.expectEqual(Pick.image, pick("content://provider/image.png", .got, true));
    try std.testing.expectEqual(Pick.unreadable_image, pick("content://provider/image.png", .none, true));
    try std.testing.expectEqual(Pick.unreadable_image, pick("content://provider/image.png", .failed, true));
    try std.testing.expectEqual(Pick.nothing, pick("", .none, true));
    try std.testing.expectEqual(Pick.nothing, pick("", .failed, false));
    // A desktop's clipboard text is never an image clip's address.
    try std.testing.expectEqual(Pick.text, pick("content://provider/image.png", .none, false));
    try std.testing.expectEqual(Pick.text, pick("content://provider/image.png", .got, false));
}

test "an Android image clip's text is its content address" {
    try std.testing.expect(isContentUri("content://dev.hollershare.App.fileprovider/clipboard/image.png"));
    try std.testing.expect(isContentUri(" content://media/external/images/1\n"));
    try std.testing.expect(!isContentUri("see content://x and more"));
    try std.testing.expect(!isContentUri("https://example.com/a.png"));
    try std.testing.expect(!isContentUri(""));
}

test "saving keeps same-second pastes apart and removes old ones" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const dir_path = try std.fs.path.join(gpa, &.{ base, "clipboard" });
    defer gpa.free(dir_path);

    const png = "\x89PNG\r\n\x1a\nfake";
    const now = 1_763_116_205;
    const first = try save(gpa, io, dir_path, png, now);
    defer gpa.free(first.path);
    defer gpa.free(first.name);
    const second = try save(gpa, io, dir_path, png, now);
    defer gpa.free(second.path);
    defer gpa.free(second.name);
    try std.testing.expectEqualStrings("HollerShare clipboard 2025-11-14 10.30.05.png", first.name);
    try std.testing.expectEqualStrings("HollerShare clipboard 2025-11-14 10.30.05 (2).png", second.name);
    try std.testing.expectEqual(@as(u64, png.len), first.size);

    // A day and more later, both are old (their mtime is the real "now",
    // far before this pretend time) and go when the next one is saved.
    const later = std.Io.Timestamp.now(io, .real).toSeconds() + keep_seconds + 60;
    const third = try save(gpa, io, dir_path, png, later);
    defer gpa.free(third.path);
    defer gpa.free(third.name);
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true });
    defer dir.close(io);
    var count: usize = 0;
    var it = dir.iterate();
    while (try it.next(io)) |_| count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "saves at the same moment keep every image" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", gpa);
    defer gpa.free(base);
    const now = 1_763_116_205;
    const count = 16;

    const Saver = struct {
        fn run(gate: *std.atomic.Value(bool), path: []const u8, bytes: []const u8, out: *?Saved) void {
            while (!gate.load(.acquire)) std.atomic.spinLoopHint();
            out.* = save(std.testing.allocator, std.testing.io, path, bytes, now) catch null;
        }
    };
    // Each saver's own bytes: exactly what was formatted, nothing undefined.
    var buffers: [count][16]u8 = undefined;
    var contents: [count][]const u8 = undefined;
    for (&buffers, &contents, 0..) |*b, *c, i| c.* = try std.fmt.bufPrint(b, "\x89PNG\r\n\x1a\nimg{d:0>3}", .{i});
    // Several rounds, each in a fresh folder, all savers released at once.
    for (0..10) |round| {
        var dir_buf: [32]u8 = undefined;
        const sub = try std.fmt.bufPrint(&dir_buf, "clipboard{d}", .{round});
        const dir_path = try std.fs.path.join(gpa, &.{ base, sub });
        defer gpa.free(dir_path);
        var gate: std.atomic.Value(bool) = .init(false);
        var results: [count]?Saved = @splat(null);
        var threads: [count]std.Thread = undefined;
        // Started savers are released and joined, then what they saved is
        // freed, even if a later spawn fails.
        var started: usize = 0;
        defer {
            gate.store(true, .release);
            for (threads[0..started]) |t| t.join();
            for (results) |r| if (r) |saved| {
                gpa.free(saved.path);
                gpa.free(saved.name);
            };
        }
        for (&threads, &results, contents) |*t, *r, c| {
            t.* = try std.Thread.spawn(.{}, Saver.run, .{ &gate, dir_path, c, r });
            started += 1;
        }
        gate.store(true, .release);
        for (threads) |t| t.join();
        started = 0;
        // Every save got its own file, holding its own bytes.
        for (results, contents, 0..) |r, c, i| {
            const saved = r orelse return error.SaveFailed;
            for (results[0..i]) |other| try std.testing.expect(!std.mem.eql(u8, other.?.name, saved.name));
            const got = try std.Io.Dir.cwd().readFileAlloc(io, saved.path, gpa, .limited(64));
            defer gpa.free(got);
            try std.testing.expectEqualStrings(c, got);
        }
    }
}
