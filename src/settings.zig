//! GhostShare's settings: the name nearby devices see and the folder
//! received files go to, kept as JSON (`settings.json`) in the app's data
//! directory. An empty (or missing) value means the default: the system's
//! device name, and the platform's default download folder.
//!
//! The folder is an Oriel folder id (`oriel.dialog.openFolder`): its path on
//! desktops, a Storage Access Framework tree URI on Android. Its display
//! name is kept beside it for the page. Settings from before folder ids had
//! `download_dir`, a path: read as the id (on desktops a path is one), with
//! its last component as the name.

const std = @import("std");

pub const file_name = "settings.json";
/// Longest device name, in characters.
pub const max_name_chars = 64;
/// Longest device name, in UTF-8 bytes: the mDNS TXT entry that carries it
/// ("n=" and the base64 of 18 bytes plus the name) must fit in 255 bytes.
/// Only names with many 3- or 4-byte characters reach it.
pub const max_name_bytes = 170;

pub const Settings = struct {
    device_name: []const u8 = "",
    /// The Oriel folder id received files go to; empty: the default folder.
    download_folder: []const u8 = "",
    /// Its display name ("Downloads"), for the page.
    download_folder_name: []const u8 = "",

    /// A copy whose strings `gpa` owns (free with `deinit`).
    pub fn clone(self: Settings, gpa: std.mem.Allocator) !Settings {
        const name = try gpa.dupe(u8, self.device_name);
        errdefer gpa.free(name);
        const folder = try gpa.dupe(u8, self.download_folder);
        errdefer gpa.free(folder);
        return .{ .device_name = name, .download_folder = folder, .download_folder_name = try gpa.dupe(u8, self.download_folder_name) };
    }

    pub fn deinit(self: Settings, gpa: std.mem.Allocator) void {
        gpa.free(self.device_name);
        gpa.free(self.download_folder);
        gpa.free(self.download_folder_name);
    }
};

/// settings.json as written: today's fields and the ones older versions
/// wrote (read, never written).
const Stored = struct {
    device_name: []const u8 = "",
    download_folder: []const u8 = "",
    download_folder_name: []const u8 = "",
    /// Before folder ids: the download folder's path.
    download_dir: []const u8 = "",
};

/// The display name of a desktop folder path: its last component, or the
/// path itself for a root ("/"). (oriel.dialog.common.pathName.)
pub fn pathName(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    return if (base.len == 0) path else base;
}

/// Whether `id` can be a download folder here: a SAF tree URI on Android
/// (`content://<authority>/tree/<id>`), an absolute path elsewhere. Saved
/// settings with another kind (a path carried to Android, say) are the
/// default folder.
pub fn usableFolderId(id: []const u8, android: bool) bool {
    if (std.mem.indexOfAny(u8, id, "\n\x00") != null) return false;
    if (!android) return std.fs.path.isAbsolute(id);
    const scheme = "content://";
    if (!std.mem.startsWith(u8, id, scheme)) return false;
    const rest = id[scheme.len..];
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse return false;
    return slash > 0 and std.mem.startsWith(u8, rest[slash..], "/tree/") and rest.len > slash + "/tree/".len;
}

pub const NameError = error{ NameTooLong, NameNotUtf8, NameHasControlCharacters };

/// The name to save: `name` trimmed of surrounding white space; empty means
/// the system's device name. Fails for more than `max_name_chars`
/// characters (or `max_name_bytes` bytes), invalid UTF-8, or control
/// characters.
pub fn normalizeName(name: []const u8) NameError![]const u8 {
    const trimmed = std.mem.trim(u8, name, " \t\r\n");
    const view = std.unicode.Utf8View.init(trimmed) catch return error.NameNotUtf8;
    var chars: usize = 0;
    var it = view.iterator();
    while (it.nextCodepoint()) |c| {
        chars += 1;
        // C0, DEL and C1 controls.
        if (c < 0x20 or (c >= 0x7f and c <= 0x9f)) return error.NameHasControlCharacters;
    }
    if (chars > max_name_chars or trimmed.len > max_name_bytes) return error.NameTooLong;
    return trimmed;
}

/// What the page shows for a `NameError`.
pub fn nameErrorMessage(err: NameError) []const u8 {
    return switch (err) {
        error.NameTooLong => "Use a shorter name (up to 64 characters)",
        error.NameNotUtf8 => "The name has characters GhostShare can't use",
        error.NameHasControlCharacters => "The name can't contain control characters",
    };
}

/// Settings from JSON text; unknown fields are ignored, and a malformed
/// document or an invalid name gives the defaults for those values.
/// `gpa` owns the strings of the result.
pub fn parse(gpa: std.mem.Allocator, json: []const u8) !Settings {
    const parsed = std.json.parseFromSlice(Stored, gpa, json, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Settings.clone(.{}, gpa),
    };
    defer parsed.deinit();
    const stored = parsed.value;
    const name = normalizeName(stored.device_name) catch "";
    const folder = std.mem.trim(u8, stored.download_folder, " \t\r\n");
    if (folder.len > 0) {
        const folder_name = if (stored.download_folder_name.len > 0) stored.download_folder_name else pathName(folder);
        return Settings.clone(.{ .device_name = name, .download_folder = folder, .download_folder_name = folder_name }, gpa);
    }
    // Migrate a path from before folder ids: on desktops it is the id.
    const path = std.mem.trim(u8, stored.download_dir, " \t\r\n");
    return Settings.clone(.{ .device_name = name, .download_folder = path, .download_folder_name = if (path.len > 0) pathName(path) else "" }, gpa);
}

/// Settings saved in `dir`, or the defaults when there are none (or they
/// can't be read). `gpa` owns the strings of the result.
pub fn load(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir) !Settings {
    const json = dir.readFileAlloc(io, file_name, gpa, .limited(64 * 1024)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return Settings.clone(.{}, gpa),
    };
    defer gpa.free(json);
    return parse(gpa, json);
}

/// Save `settings` to `dir`, replacing the file atomically (a temporary
/// file renamed over it).
pub fn save(gpa: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, settings: Settings) !void {
    const json = try std.json.Stringify.valueAlloc(gpa, settings, .{ .whitespace = .indent_2 });
    defer gpa.free(json);
    const temporary = file_name ++ ".tmp";
    try dir.writeFile(io, .{ .sub_path = temporary, .data = json });
    errdefer dir.deleteFile(io, temporary) catch {};
    try dir.rename(temporary, dir, file_name, io);
}

const testing = std.testing;

test "names are trimmed and empty means the system name" {
    try testing.expectEqualStrings("Desk", try normalizeName("  Desk\t"));
    try testing.expectEqualStrings("", try normalizeName("   "));
    try testing.expectEqualStrings("Sergio's Café ☕", try normalizeName("Sergio's Café ☕"));
}

test "names are 64 characters at most, counted as characters" {
    try testing.expectEqualStrings("a" ** 64, try normalizeName("a" ** 64));
    try testing.expectError(error.NameTooLong, normalizeName("a" ** 65));
    // 64 two-byte characters (128 bytes) are fine.
    try testing.expectEqualStrings("é" ** 64, try normalizeName("é" ** 64));
    try testing.expectError(error.NameTooLong, normalizeName("é" ** 65));
    // 56 three-byte characters (168 bytes) fit the mDNS record; 57 don't.
    try testing.expectEqualStrings("☕" ** 56, try normalizeName("☕" ** 56));
    try testing.expectError(error.NameTooLong, normalizeName("☕" ** 57));
}

test "names reject control characters and invalid UTF-8" {
    try testing.expectError(error.NameHasControlCharacters, normalizeName("a\nb"));
    try testing.expectError(error.NameHasControlCharacters, normalizeName("a\x00b"));
    try testing.expectError(error.NameHasControlCharacters, normalizeName("a\x7fb"));
    try testing.expectError(error.NameHasControlCharacters, normalizeName("a\u{85}b"));
    try testing.expectError(error.NameNotUtf8, normalizeName("a\xffb"));
}

test "parse ignores unknown fields and falls back on bad input" {
    const gpa = testing.allocator;
    const full = try parse(gpa, "{\"device_name\":\" Desk \",\"download_folder\":\"/tmp/x\",\"download_folder_name\":\"x\",\"other\":1}");
    defer full.deinit(gpa);
    try testing.expectEqualStrings("Desk", full.device_name);
    try testing.expectEqualStrings("/tmp/x", full.download_folder);
    try testing.expectEqualStrings("x", full.download_folder_name);

    const partial = try parse(gpa, "{\"download_folder\":\"/tmp/y\"}");
    defer partial.deinit(gpa);
    try testing.expectEqualStrings("", partial.device_name);
    try testing.expectEqualStrings("/tmp/y", partial.download_folder);
    // No name saved: the path's last component.
    try testing.expectEqualStrings("y", partial.download_folder_name);

    const malformed = try parse(gpa, "{not json");
    defer malformed.deinit(gpa);
    try testing.expectEqualStrings("", malformed.device_name);
    try testing.expectEqualStrings("", malformed.download_folder);
    try testing.expectEqualStrings("", malformed.download_folder_name);

    const bad_name = try parse(gpa, "{\"device_name\":\"a\\nb\",\"download_folder\":\"/d\"}");
    defer bad_name.deinit(gpa);
    try testing.expectEqualStrings("", bad_name.device_name);
    try testing.expectEqualStrings("/d", bad_name.download_folder);
}

test "load gives defaults without a file, and what save wrote" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const empty = try load(gpa, io, tmp.dir);
    defer empty.deinit(gpa);
    try testing.expectEqualStrings("", empty.device_name);
    try testing.expectEqualStrings("", empty.download_folder);

    try save(gpa, io, tmp.dir, .{ .device_name = "Desk \"2\"", .download_folder = "/home/me/In", .download_folder_name = "In" });
    const saved = try load(gpa, io, tmp.dir);
    defer saved.deinit(gpa);
    try testing.expectEqualStrings("Desk \"2\"", saved.device_name);
    try testing.expectEqualStrings("/home/me/In", saved.download_folder);
    try testing.expectEqualStrings("In", saved.download_folder_name);

    // Saving the defaults again: an empty settings file, read as defaults.
    try save(gpa, io, tmp.dir, .{});
    const reset = try load(gpa, io, tmp.dir);
    defer reset.deinit(gpa);
    try testing.expectEqualStrings("", reset.device_name);
    try testing.expectEqualStrings("", reset.download_folder);
    try testing.expectEqualStrings("", reset.download_folder_name);
    // No temporary file left behind.
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, file_name ++ ".tmp", .{}));
}

test "a download_dir path from before folder ids becomes the folder id" {
    const gpa = testing.allocator;
    const old = try parse(gpa, "{\"device_name\":\"Desk\",\"download_dir\":\" /home/me/Incoming \"}");
    defer old.deinit(gpa);
    try testing.expectEqualStrings("Desk", old.device_name);
    try testing.expectEqualStrings("/home/me/Incoming", old.download_folder);
    try testing.expectEqualStrings("Incoming", old.download_folder_name);
    try testing.expect(usableFolderId(old.download_folder, false));
    // Carried to Android, a path isn't a folder id there: the default folder.
    try testing.expect(!usableFolderId(old.download_folder, true));

    // A trailing separator and the root keep a name.
    const slash = try parse(gpa, "{\"download_dir\":\"/home/me/In/\"}");
    defer slash.deinit(gpa);
    try testing.expectEqualStrings("In", slash.download_folder_name);
    const root = try parse(gpa, "{\"download_dir\":\"/\"}");
    defer root.deinit(gpa);
    try testing.expectEqualStrings("/", root.download_folder_name);

    // An empty old path is the default; a folder id wins over an old path.
    const none = try parse(gpa, "{\"download_dir\":\"\"}");
    defer none.deinit(gpa);
    try testing.expectEqualStrings("", none.download_folder);
    try testing.expectEqualStrings("", none.download_folder_name);
    const both = try parse(gpa, "{\"download_dir\":\"/old\",\"download_folder\":\"/new\",\"download_folder_name\":\"New\"}");
    defer both.deinit(gpa);
    try testing.expectEqualStrings("/new", both.download_folder);
    try testing.expectEqualStrings("New", both.download_folder_name);
}

test "a migrated file is saved with folder ids only" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = file_name, .data = "{\"device_name\":\"\",\"download_dir\":\"/srv/drop\"}" });
    const migrated = try load(gpa, io, tmp.dir);
    defer migrated.deinit(gpa);
    try save(gpa, io, tmp.dir, migrated);
    const json = try tmp.dir.readFileAlloc(io, file_name, gpa, .limited(4096));
    defer gpa.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "download_dir") == null);
    const again = try parse(gpa, json);
    defer again.deinit(gpa);
    try testing.expectEqualStrings("/srv/drop", again.download_folder);
    try testing.expectEqualStrings("drop", again.download_folder_name);
}

test "folder ids and display names round-trip through settings.json" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const cases = [_]Settings{
        // Android: a SAF tree URI (percent-encoded) and the provider's name.
        .{ .device_name = "Pixel", .download_folder = "content://com.android.externalstorage.documents/tree/primary%3ADownload%2FQuick%20Share", .download_folder_name = "Quick Share" },
        // Desktop: a path with spaces, quotes and non-ASCII characters.
        .{ .download_folder = "/home/me/Mis \"descargas\" ☕", .download_folder_name = "Mis \"descargas\" ☕" },
        // A name that isn't the path's last component is kept as saved.
        .{ .download_folder = "/media/usb", .download_folder_name = "USB stick" },
    };
    for (cases) |case| {
        try save(gpa, io, tmp.dir, case);
        const loaded = try load(gpa, io, tmp.dir);
        defer loaded.deinit(gpa);
        try testing.expectEqualStrings(case.device_name, loaded.device_name);
        try testing.expectEqualStrings(case.download_folder, loaded.download_folder);
        try testing.expectEqualStrings(case.download_folder_name, loaded.download_folder_name);
    }
}

test "usable folder ids per platform" {
    try testing.expect(usableFolderId("content://com.android.externalstorage.documents/tree/primary%3ADownload", true));
    try testing.expect(!usableFolderId("content://com.android.externalstorage.documents/document/primary%3ADownload", true));
    try testing.expect(!usableFolderId("content://a/tree/", true));
    try testing.expect(!usableFolderId("content:///tree/x", true));
    try testing.expect(!usableFolderId("/storage/emulated/0/Download", true));
    try testing.expect(usableFolderId("/home/me/In", false));
    try testing.expect(!usableFolderId("relative/In", false));
    try testing.expect(!usableFolderId("content://a/tree/x", false));
    try testing.expect(!usableFolderId("/home/me\nx", false));
}
