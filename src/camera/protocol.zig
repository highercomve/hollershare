//! The phone camera protocol: an Android phone running HollerShare streams
//! its camera to a computer running HollerShare, which shows it to every
//! app as a webcam. Both ends are this Zig code (the phone's camera itself
//! is Kotlin: src/android/CameraExtension.kt).
//!
//! Discovery (UDP, port `discovery_port`): the computer broadcasts
//! `{"hollershare_camera":2}`; a phone with "Use as webcam" on answers the
//! sender with `{"hollershare_camera":2,"name":"Pixel 8","port":47311}`.
//!
//! Session (TCP, the phone listens): every message is a frame, a u32
//! big-endian length (of what follows), a type byte, then the payload.
//! The handshake is plain JSON; everything after it is sealed.
//!
//!   phone    -> computer  hello   {"v":2,"name":"Pixel 8","nonce":"<32 hex>"}
//!   computer -> phone     auth    {"name":"Studio","nonce":"<32 hex>",
//!                                  "share":"<64 hex>",
//!                                  "quality":{"height":720,"fps":30,"jpeg":70}}
//!   phone    -> computer  answer  {"share":"<64 hex>","confirm":"<64 hex>"}
//!   computer -> phone     confirm {"confirm":"<64 hex>"}
//!   phone    -> computer  ready   (sealed) {"ok":true,"width":1280,"height":720}
//!                                 or {"ok":false,"error":"…"} and closes
//!                                 (a phone that finds the computer's
//!                                 confirmation wrong just closes)
//!   phone    -> computer  jpeg    (sealed) one camera frame, a baseline JPEG
//!   computer -> phone     control (sealed) {"type":"switch"}
//!   computer -> phone     control (sealed) {"type":"view","rotate":90,"mirror":false,"fill":false}
//!   computer -> phone     control (sealed) {"type":"quality","fps":24,"jpeg":85}
//!
//! The quality's height picks the frame size (16:9, so 720 is 1280x720) for
//! the session; its frame rate and JPEG quality also change live. The
//! computer sends the current view and quality as soon as the stream
//! starts (they may have changed during the handshake).
//!
//! The phone turns its picture upright for how it is held; a view turns it
//! further (clockwise, in quarter turns), mirrors it, and fits it into the
//! frame (black bars) or fills the frame (cropped) when it is portrait.
//!
//! Keys (CPace on ristretto255): the 6-digit code the phone shows is the
//! only secret, and it never travels, not even as a hash. With
//! sid = phone nonce || computer nonce (16 random bytes each):
//!
//!   G   = Ristretto255.fromUniform(SHA-512(lv(dsi) lv(code) lv(sid)))
//!   y   = a random scalar, a fresh one each session and side
//!   Y   = y*G ("share"; an invalid or identity share ends the session)
//!   K   = y*Y_peer
//!   ISK = HKDF-SHA512-Extract(salt = dsi, sid || K || Y_phone || Y_computer)
//!   T   = SHA-512(lv(hello payload) lv(auth payload) Y_phone Y_computer)
//!
//! where lv(x) is x after its length as a big-endian u16. Each side
//! confirms the key with HMAC-SHA256(HKDF-Expand(ISK, "phone confirm") or
//! HKDF-Expand(ISK, "computer confirm"), T) (32-byte keys), and checks
//! the other's (in constant time) before anything else: the computer
//! checks the phone's before it answers or opens its video device, the
//! phone checks the computer's before its camera starts. A wrong code is
//! a failed confirmation; someone watching the network learns nothing to
//! test codes against, and a guesser gets one guess per connection (the
//! phone slows guesses down and stops after too many).
//!
//! Sealed frames (type `sealed`): ChaCha20-Poly1305 with the key
//! HKDF-Expand(ISK, "phone to computer" || T) or "computer to phone",
//! over (inner type byte || payload), with the frame's 5-byte header as
//! associated data and, as nonce, 4 zero bytes then a per-direction u64
//! big-endian counter starting at 0. The counter isn't sent: a frame
//! dropped, replayed, reordered or changed fails its tag and ends the
//! session.
const std = @import("std");
const Ristretto255 = std.crypto.ecc.Ristretto255;
const Sha512 = std.crypto.hash.sha2.Sha512;
const HkdfSha512 = std.crypto.kdf.hkdf.HkdfSha512;
const HmacSha256 = std.crypto.auth.hmac.sha2.HmacSha256;
const Aead = std.crypto.aead.chacha_poly.ChaCha20Poly1305;

pub const version = 2;

/// Which of the phone's lenses streams.
pub const Facing = enum { back, front };
pub const discovery_port: u16 = 47310;
/// The phone's preferred TCP port (another one if this is taken: it is
/// announced in the discovery answer).
pub const session_port: u16 = 47311;
/// Frames bigger than this end the session (a 1280x720 JPEG is ~100 KB).
pub const max_frame_bytes = 8 * 1024 * 1024;
/// Handshake messages are small JSON.
pub const max_message_bytes = 4096;
pub const code_digits = 6;
/// What the computer shows when the key confirmation fails.
pub const wrong_code_error = "Wrong code. Check the code on the phone.";

/// CPace's domain separation string for this protocol.
const dsi = "hollershare-camera-v2 CPaceRistretto255";

pub const FrameType = enum(u8) {
    hello = 1,
    auth = 2,
    ready = 3,
    answer = 4,
    confirm = 5,
    jpeg = 0x10,
    control = 0x20,
    /// An encrypted frame: holds one of the others.
    sealed = 0x30,
    _,
};

pub const Hello = struct { v: u32, name: []const u8, nonce: []const u8 };
pub const Auth = struct { name: []const u8, nonce: []const u8, share: []const u8, quality: Quality = .{} };
pub const Answer = struct { share: []const u8, confirm: []const u8 };
pub const Confirm = struct { confirm: []const u8 };
pub const Ready = struct { ok: bool, width: u32 = 0, height: u32 = 0, @"error": ?[]const u8 = null };

pub const ControlType = enum { @"switch", view, quality, stop };
/// A control of an unknown type doesn't parse (the phone ignores it).
pub const Control = struct {
    type: ControlType,
    rotate: u16 = 0,
    mirror: bool = false,
    fill: bool = false,
    fps: u8 = 30,
    jpeg: u8 = 70,
};

/// Frame size, frame rate and JPEG quality.
pub const Quality = struct {
    /// Frame height of a 16:9 frame: 480, 720 or 1080.
    height: u16 = 720,
    /// Frames a second: 5 to 30.
    fps: u8 = 30,
    /// JPEG quality: 30 to 95.
    jpeg: u8 = 70,

    pub const heights = [_]u16{ 480, 720, 1080 };
    /// The heights a session may ask for: a preset, or for one retry the
    /// exact height a video app holds the computer's device at.
    pub const min_height = 240;
    pub const max_height = 2160;

    /// Whether `width`x`height` is about 16:9, as cameras make it (854x480
    /// and 853x480 both are; the phone's camera code uses the same test).
    pub fn wide(width: u32, height: u32) bool {
        const w = @as(i64, width) * 9;
        const h = @as(i64, height) * 16;
        return @abs(w - h) <= 16;
    }

    /// The width of a 16:9 frame `height` high, as cameras make it
    /// (rounded to an even width: 854 for 480, 1280 for 720, 1920 for 1080).
    pub fn widthOf(height: u16) u32 {
        return (@as(u32, height) * 16 / 9 + 1) & ~@as(u32, 1);
    }

    /// Within the ranges above (the nearest height).
    pub fn normalized(self: Quality) Quality {
        var best = heights[0];
        for (heights) |h| {
            if (@abs(@as(i32, h) - self.height) < @abs(@as(i32, best) - self.height)) best = h;
        }
        return .{ .height = best, .fps = std.math.clamp(self.fps, 5, 30), .jpeg = std.math.clamp(self.jpeg, 30, 95) };
    }

    /// What a phone opens its camera at: `normalized`, except that a
    /// height within `min_height`..`max_height` stays exact (the computer
    /// asks for one off the presets only to match a held device).
    pub fn forSession(self: Quality) Quality {
        var q = self.normalized();
        if (self.height >= min_height and self.height <= max_height) q.height = self.height;
        return q;
    }

    pub fn control(self: Quality) Control {
        const q = self.normalized();
        return .{ .type = .quality, .fps = q.fps, .jpeg = q.jpeg };
    }
};

/// How the picture is turned on top of upright, mirrored and fitted.
pub const View = struct {
    /// Clockwise degrees: 0, 90, 180 or 270.
    rotate: u16 = 0,
    mirror: bool = false,
    /// Portrait pictures fill the landscape frame (cropped) rather than fit it.
    fill: bool = false,

    /// `rotate` snapped to a quarter turn.
    pub fn normalized(self: View) View {
        return .{ .rotate = @intCast((@as(u32, self.rotate) + 45) / 90 % 4 * 90), .mirror = self.mirror, .fill = self.fill };
    }

    pub fn control(self: View) Control {
        const v = self.normalized();
        return .{ .type = .view, .rotate = v.rotate, .mirror = v.mirror, .fill = v.fill };
    }
};
pub const Probe = struct { hollershare_camera: u32 };
pub const Announce = struct { hollershare_camera: u32, name: []const u8, port: u16 };

pub const Frame = struct { type: FrameType, payload: []u8 };

/// Write one frame and flush it.
pub fn writeFrame(w: *std.Io.Writer, kind: FrameType, payload: []const u8) !void {
    if (payload.len + 1 > max_frame_bytes) return error.FrameTooLarge;
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], @intCast(payload.len + 1), .big);
    header[4] = @intFromEnum(kind);
    try w.writeAll(&header);
    try w.writeAll(payload);
    try w.flush();
}

/// `value` as JSON, in `buf`.
pub fn encodeJson(buf: *[max_message_bytes]u8, value: anytype) ![]const u8 {
    var fixed: std.Io.Writer = .fixed(buf);
    try std.json.Stringify.value(value, .{}, &fixed);
    return fixed.buffered();
}

/// Write `value` as a JSON frame.
pub fn writeJson(w: *std.Io.Writer, kind: FrameType, value: anytype) !void {
    var buf: [max_message_bytes]u8 = undefined;
    try writeFrame(w, kind, try encodeJson(&buf, value));
}

/// Read one frame of at most `limit` bytes into `buf` (grown as needed).
pub fn readFrame(r: *std.Io.Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), limit: usize) !Frame {
    var header: [5]u8 = undefined;
    try r.readSliceAll(&header);
    const len = std.mem.readInt(u32, header[0..4], .big);
    if (len == 0 or len > limit) return error.FrameTooLarge;
    try buf.resize(gpa, len - 1);
    try r.readSliceAll(buf.items);
    return .{ .type = @enumFromInt(header[4]), .payload = buf.items };
}

/// A handshake message frame (in `arena`), to parse with `parseJson`.
pub fn readMessage(r: *std.Io.Reader, arena: std.mem.Allocator) !Frame {
    var buf: std.ArrayList(u8) = .empty;
    return readFrame(r, arena, &buf, max_message_bytes);
}

/// `frame` as `T`, when it is of type `kind` (strings in `arena`).
pub fn parseJson(arena: std.mem.Allocator, comptime T: type, frame: Frame, kind: FrameType) !T {
    if (frame.type != kind) return error.UnexpectedFrame;
    return std.json.parseFromSliceLeaky(T, arena, frame.payload, .{ .ignore_unknown_fields = true });
}

/// Read a JSON frame of type `kind` as `T` (strings in `arena`).
pub fn readJson(r: *std.Io.Reader, arena: std.mem.Allocator, comptime T: type, kind: FrameType) !T {
    return parseJson(arena, T, try readMessage(r, arena), kind);
}

/// A random 6-digit code, "000000" to "999999".
pub fn newCode(io: std.Io) [code_digits]u8 {
    var raw: [8]u8 = undefined;
    io.random(&raw);
    var n = std.mem.readInt(u64, &raw, .little) % 1_000_000;
    var code: [code_digits]u8 = undefined;
    var i: usize = code_digits;
    while (i > 0) {
        i -= 1;
        code[i] = '0' + @as(u8, @intCast(n % 10));
        n /= 10;
    }
    return code;
}

/// Whether `code` is 6 digits (the page checks it before connecting).
pub fn validCode(code: []const u8) bool {
    if (code.len != code_digits) return false;
    for (code) |c| if (!std.ascii.isDigit(c)) return false;
    return true;
}

// --- Keys ----------------------------------------------------------------

pub const nonce_length = 16;
pub const share_length = Ristretto255.encoded_length;
pub const confirm_length = HmacSha256.mac_length;
pub const key_length = Aead.key_length;
pub const Nonce = [nonce_length]u8;
pub const Share = [share_length]u8;

/// A fresh random nonce.
pub fn newNonce(io: std.Io) Nonce {
    var raw: Nonce = undefined;
    io.random(&raw);
    return raw;
}

/// Bytes as lowercase hex.
pub fn hex(comptime n: usize, bytes: [n]u8) [2 * n]u8 {
    return std.fmt.bytesToHex(bytes, .lower);
}

/// Exactly `n` bytes from `2n` hex digits.
pub fn unhex(comptime n: usize, text: []const u8) ![n]u8 {
    if (text.len != 2 * n) return error.BadHandshake;
    var out: [n]u8 = undefined;
    _ = std.fmt.hexToBytes(&out, text) catch return error.BadHandshake;
    return out;
}

pub const Role = enum { phone, computer };

/// One side of the key exchange. `init` once both nonces are known; feed
/// the hello and auth payloads to `absorb`, then `finish` with the other
/// side's share.
pub const Handshake = struct {
    role: Role,
    sid: [2 * nonce_length]u8,
    secret: [32]u8,
    /// This side's share, Y = y*G.
    share: Share,
    transcript: Sha512,

    pub fn init(io: std.Io, role: Role, code: []const u8, phone_nonce: Nonce, computer_nonce: Nonce) !Handshake {
        var sid: [2 * nonce_length]u8 = undefined;
        @memcpy(sid[0..nonce_length], &phone_nonce);
        @memcpy(sid[nonce_length..], &computer_nonce);
        const g = generator(code, sid);
        var secret = Ristretto255.scalar.random(io);
        defer std.crypto.secureZero(u8, &secret);
        const y = g.mul(secret) catch return error.BadHandshake;
        return .{ .role = role, .sid = sid, .secret = secret, .share = y.toBytes(), .transcript = .init(.{}) };
    }

    /// Forget the secret scalar (`finish` does too); safe to call twice.
    pub fn wipe(self: *Handshake) void {
        std.crypto.secureZero(u8, &self.secret);
    }

    /// Add a handshake message (hello, then auth) to the transcript.
    pub fn absorb(self: *Handshake, payload: []const u8) void {
        lv(&self.transcript, payload);
    }

    /// The session keys, from the other side's share.
    pub fn finish(self: *Handshake, peer: Share) !Keys {
        defer std.crypto.secureZero(u8, &self.secret);
        const point = Ristretto255.fromBytes(peer) catch return error.BadHandshake;
        point.rejectIdentity() catch return error.BadHandshake;
        const k = point.mul(self.secret) catch return error.BadHandshake;
        const y_phone = if (self.role == .phone) self.share else peer;
        const y_computer = if (self.role == .phone) peer else self.share;

        var ikm: [2 * nonce_length + 3 * share_length]u8 = undefined;
        @memcpy(ikm[0..32], &self.sid);
        @memcpy(ikm[32..64], &k.toBytes());
        @memcpy(ikm[64..96], &y_phone);
        @memcpy(ikm[96..128], &y_computer);
        defer std.crypto.secureZero(u8, &ikm);
        var isk = HkdfSha512.extract(dsi, &ikm);
        defer std.crypto.secureZero(u8, &isk);

        var t = self.transcript;
        t.update(&y_phone);
        t.update(&y_computer);
        var transcript: [Sha512.digest_length]u8 = undefined;
        t.final(&transcript);

        var keys: Keys = .{ .role = self.role, .confirm_phone = undefined, .confirm_computer = undefined, .phone_to_computer = undefined, .computer_to_phone = undefined };
        keys.confirm_phone = confirmation(isk, "phone confirm", transcript);
        keys.confirm_computer = confirmation(isk, "computer confirm", transcript);
        keys.phone_to_computer = expand(isk, "phone to computer", transcript);
        keys.computer_to_phone = expand(isk, "computer to phone", transcript);
        return keys;
    }
};

/// What a finished handshake gives each side.
pub const Keys = struct {
    role: Role,
    confirm_phone: [confirm_length]u8,
    confirm_computer: [confirm_length]u8,
    phone_to_computer: [key_length]u8,
    computer_to_phone: [key_length]u8,

    /// The confirmation this side sends.
    pub fn own(self: *const Keys) [confirm_length]u8 {
        return if (self.role == .phone) self.confirm_phone else self.confirm_computer;
    }

    /// Whether `given` (hex) is the other side's confirmation, in constant time.
    pub fn peerConfirms(self: *const Keys, given: []const u8) bool {
        const mac = unhex(confirm_length, given) catch return false;
        const expected = if (self.role == .phone) self.confirm_computer else self.confirm_phone;
        return std.crypto.timing_safe.eql([confirm_length]u8, expected, mac);
    }

    pub fn sealer(self: *const Keys) Sealer {
        return .{ .key = if (self.role == .phone) self.phone_to_computer else self.computer_to_phone };
    }

    pub fn opener(self: *const Keys) Opener {
        return .{ .key = if (self.role == .phone) self.computer_to_phone else self.phone_to_computer };
    }

    pub fn wipe(self: *Keys) void {
        std.crypto.secureZero(u8, std.mem.asBytes(self));
    }
};

fn generator(code: []const u8, sid: [2 * nonce_length]u8) Ristretto255 {
    var h: Sha512 = .init(.{});
    lv(&h, dsi);
    lv(&h, code);
    lv(&h, &sid);
    var uniform: [64]u8 = undefined;
    h.final(&uniform);
    return Ristretto255.fromUniform(uniform);
}

/// `bytes` after its length as a big-endian u16 (handshake messages are
/// at most `max_message_bytes`).
fn lv(h: *Sha512, bytes: []const u8) void {
    var len: [2]u8 = undefined;
    std.mem.writeInt(u16, &len, @intCast(bytes.len), .big);
    h.update(&len);
    h.update(bytes);
}

fn expand(isk: [HkdfSha512.prk_length]u8, comptime what: []const u8, transcript: [Sha512.digest_length]u8) [32]u8 {
    var info: [what.len + transcript.len]u8 = undefined;
    @memcpy(info[0..what.len], what);
    @memcpy(info[what.len..], &transcript);
    var out: [32]u8 = undefined;
    HkdfSha512.expand(&out, &info, isk);
    return out;
}

fn confirmation(isk: [HkdfSha512.prk_length]u8, comptime what: []const u8, transcript: [Sha512.digest_length]u8) [confirm_length]u8 {
    var key: [32]u8 = undefined;
    HkdfSha512.expand(&key, what, isk);
    defer std.crypto.secureZero(u8, &key);
    var mac: [confirm_length]u8 = undefined;
    HmacSha256.create(&mac, &transcript, &key);
    return mac;
}

// --- Sealed frames -------------------------------------------------------

const tag_length = Aead.tag_length;
/// The most a sealed frame can carry.
pub const max_sealed_payload = max_frame_bytes - 1 - tag_length - 1;

fn nonceFor(counter: u64) [Aead.nonce_length]u8 {
    var n: [Aead.nonce_length]u8 = @splat(0);
    std.mem.writeInt(u64, n[4..12], counter, .big);
    return n;
}

/// The sending half of a session.
pub const Sealer = struct {
    key: [key_length]u8,
    counter: u64 = 0,
    buf: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *Sealer, gpa: std.mem.Allocator) void {
        self.buf.deinit(gpa);
        std.crypto.secureZero(u8, &self.key);
    }

    /// Encrypt a frame of type `kind` and write it, flushed.
    pub fn write(self: *Sealer, gpa: std.mem.Allocator, w: *std.Io.Writer, kind: FrameType, payload: []const u8) !void {
        try w.writeAll(try self.seal(gpa, kind, payload));
        try w.flush();
    }

    /// Encrypt a frame of type `kind`: the bytes to send, valid until the
    /// next call.
    pub fn seal(self: *Sealer, gpa: std.mem.Allocator, kind: FrameType, payload: []const u8) ![]const u8 {
        if (payload.len > max_sealed_payload) return error.FrameTooLarge;
        if (self.counter == std.math.maxInt(u64)) return error.CounterExhausted;
        const body = 1 + payload.len;
        try self.buf.resize(gpa, 5 + body + tag_length);
        const out = self.buf.items;
        std.mem.writeInt(u32, out[0..4], @intCast(body + tag_length + 1), .big);
        out[4] = @intFromEnum(FrameType.sealed);
        out[5] = @intFromEnum(kind);
        @memcpy(out[6..][0..payload.len], payload);
        const text = out[5..][0..body];
        Aead.encrypt(text, out[5 + body ..][0..tag_length], text, out[0..5], nonceFor(self.counter), self.key);
        self.counter += 1;
        return out;
    }

    /// Write `value` as a sealed JSON frame.
    pub fn writeJson(self: *Sealer, gpa: std.mem.Allocator, w: *std.Io.Writer, kind: FrameType, value: anytype) !void {
        var buf: [max_message_bytes]u8 = undefined;
        try self.write(gpa, w, kind, try encodeJson(&buf, value));
    }
};

/// The receiving half of a session.
pub const Opener = struct {
    key: [key_length]u8,
    counter: u64 = 0,

    pub fn wipe(self: *Opener) void {
        std.crypto.secureZero(u8, &self.key);
    }

    /// Read and open the next sealed frame (in `buf`); a frame that isn't
    /// the next one sealed with this key fails with AuthenticationFailed.
    pub fn read(self: *Opener, r: *std.Io.Reader, gpa: std.mem.Allocator, buf: *std.ArrayList(u8), limit: usize) !Frame {
        const frame = try readFrame(r, gpa, buf, limit);
        return self.open(frame);
    }

    /// Open a sealed frame already read.
    pub fn open(self: *Opener, frame: Frame) !Frame {
        if (frame.type != .sealed) return error.UnexpectedFrame;
        if (frame.payload.len < 1 + tag_length) return error.AuthenticationFailed;
        if (self.counter == std.math.maxInt(u64)) return error.CounterExhausted;
        var header: [5]u8 = undefined;
        std.mem.writeInt(u32, header[0..4], @intCast(frame.payload.len + 1), .big);
        header[4] = @intFromEnum(FrameType.sealed);
        const text = frame.payload[0 .. frame.payload.len - tag_length];
        const tag = frame.payload[text.len..][0..tag_length].*;
        try Aead.decrypt(text, text, tag, &header, nonceFor(self.counter), self.key);
        self.counter += 1;
        return .{ .type = @enumFromInt(text[0]), .payload = text[1..] };
    }
};

/// A device name cut to something a UI can show: at most 64 bytes of
/// `cleanText`.
pub fn cleanName(buf: []u8, name: []const u8) []const u8 {
    const clean = cleanText(buf[0..@min(buf.len, 64)], name);
    return if (clean.len == 0) "Unknown device" else clean;
}

/// `text` in `buf` as something a UI can show: only valid UTF-8 (other
/// bytes are dropped), without control or text-direction characters, cut
/// on a character boundary to fit. `buf` may hold `text` itself.
pub fn cleanText(buf: []u8, text: []const u8) []const u8 {
    var n: usize = 0;
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + len > text.len) {
            i += 1;
            continue;
        }
        const char = text[i..][0..len];
        const cp = std.unicode.utf8Decode(char) catch {
            i += 1;
            continue;
        };
        i += len;
        if (!showable(cp)) continue;
        if (n + len > buf.len) break;
        @memmove(buf[n..][0..len], char);
        n += len;
    }
    return buf[0..n];
}

fn showable(cp: u21) bool {
    return switch (cp) {
        0...0x1f, 0x7f...0x9f => false, // C0, DEL, C1
        0x200e, 0x200f, 0x202a...0x202e, 0x2066...0x2069 => false, // direction
        else => true,
    };
}

test "codes are six digits" {
    const io = std.testing.io;
    for (0..50) |_| {
        const code = newCode(io);
        try std.testing.expect(validCode(&code));
    }
    try std.testing.expect(!validCode("12345"));
    try std.testing.expect(!validCode("12a456"));
}

/// Both sides of a handshake in memory: the phone with `phone_code`, the
/// computer with `computer_code`.
const TestPair = struct {
    phone: Keys,
    computer: Keys,
    hello: []const u8 = "{\"v\":2}",
    auth: []const u8 = "{\"name\":\"Studio\"}",

    fn run(phone_code: []const u8, computer_code: []const u8) !TestPair {
        const io = std.testing.io;
        const pn = newNonce(io);
        const cn = newNonce(io);
        var pair: TestPair = .{ .phone = undefined, .computer = undefined };
        var c = try Handshake.init(io, .computer, computer_code, pn, cn);
        c.absorb(pair.hello);
        c.absorb(pair.auth);
        var p = try Handshake.init(io, .phone, phone_code, pn, cn);
        p.absorb(pair.hello);
        p.absorb(pair.auth);
        pair.phone = try p.finish(c.share);
        pair.computer = try c.finish(p.share);
        return pair;
    }
};

test "the right code confirms both ways and gives matching keys" {
    const pair = try TestPair.run("123456", "123456");
    const phone_says = hex(confirm_length, pair.phone.own());
    const computer_says = hex(confirm_length, pair.computer.own());
    try std.testing.expect(pair.computer.peerConfirms(&phone_says));
    try std.testing.expect(pair.phone.peerConfirms(&computer_says));
    // A side's own confirmation isn't the other's (no reflecting it back).
    try std.testing.expect(!pair.phone.peerConfirms(&phone_says));
    try std.testing.expect(!pair.computer.peerConfirms(computer_says[0..63]));
    try std.testing.expectEqual(pair.phone.phone_to_computer, pair.computer.phone_to_computer);
    try std.testing.expect(!std.mem.eql(u8, &pair.phone.phone_to_computer, &pair.phone.computer_to_phone));
}

test "a wrong code fails the confirmation on both sides" {
    const pair = try TestPair.run("123456", "123457");
    const phone_says = hex(confirm_length, pair.phone.own());
    const computer_says = hex(confirm_length, pair.computer.own());
    try std.testing.expect(!pair.computer.peerConfirms(&phone_says));
    try std.testing.expect(!pair.phone.peerConfirms(&computer_says));
}

test "nothing on the wire lets an observer test a code offline" {
    // The messages carry nonces, shares and confirmations: no field is a
    // function of the code alone (as v1's proof was).
    inline for (.{ Hello, Auth, Answer, Confirm }) |T| {
        inline for (@typeInfo(T).@"struct".fields) |f| {
            try std.testing.expect(std.mem.indexOf(u8, f.name, "proof") == null);
        }
    }
    // The confirmations hang on K = y*Y_peer. An observer who knows the
    // right code and both nonces, but neither secret scalar, gets other
    // keys: their own handshake against the recorded share doesn't match.
    const io = std.testing.io;
    const pn = newNonce(io);
    const cn = newNonce(io);
    var p = try Handshake.init(io, .phone, "123456", pn, cn);
    var c = try Handshake.init(io, .computer, "123456", pn, cn);
    const real = try c.finish(p.share);
    var observer = try Handshake.init(io, .phone, "123456", pn, cn);
    const guess = try observer.finish(c.share);
    try std.testing.expect(!std.mem.eql(u8, &guess.confirm_phone, &real.confirm_phone));
    try std.testing.expectEqual(real.confirm_phone, (try p.finish(c.share)).confirm_phone);
}

test "a handshake that ends early forgets its secret" {
    const io = std.testing.io;
    var handshake = try Handshake.init(io, .computer, "123456", newNonce(io), newNonce(io));
    try std.testing.expect(!std.mem.allEqual(u8, &handshake.secret, 0));
    handshake.wipe();
    try std.testing.expect(std.mem.allEqual(u8, &handshake.secret, 0));
}

test "invalid shares are refused" {
    const io = std.testing.io;
    var h = try Handshake.init(io, .phone, "123456", newNonce(io), newNonce(io));
    const identity: Share = @splat(0);
    try std.testing.expectError(error.BadHandshake, h.finish(identity));
    var h2 = try Handshake.init(io, .phone, "123456", newNonce(io), newNonce(io));
    try std.testing.expectError(error.BadHandshake, h2.finish(@splat(0xff)));
}

test "sealed frames round-trip in order" {
    const gpa = std.testing.allocator;
    const pair = try TestPair.run("000111", "000111");
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    var sealer = pair.phone.sealer();
    defer sealer.deinit(gpa);
    try sealer.write(gpa, &out.writer, .jpeg, "\xff\xd8jpeg\xff\xd9");
    try sealer.writeJson(gpa, &out.writer, .ready, Ready{ .ok = true, .width = 1280, .height = 720 });
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "jpeg") == null);

    var r: std.Io.Reader = .fixed(out.written());
    var opener = pair.computer.opener();
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const f = try opener.read(&r, gpa, &buf, max_frame_bytes);
    try std.testing.expectEqual(FrameType.jpeg, f.type);
    try std.testing.expectEqualStrings("\xff\xd8jpeg\xff\xd9", f.payload);
    const g = try opener.read(&r, gpa, &buf, max_frame_bytes);
    try std.testing.expectEqual(FrameType.ready, g.type);
    const ready = try std.json.parseFromSlice(Ready, gpa, g.payload, .{});
    defer ready.deinit();
    try std.testing.expectEqual(@as(u32, 720), ready.value.height);
    try std.testing.expectError(error.EndOfStream, opener.read(&r, gpa, &buf, max_frame_bytes));

    // The other direction's key doesn't open them.
    var wrong = pair.phone.opener();
    var r2: std.Io.Reader = .fixed(out.written());
    try std.testing.expectError(error.AuthenticationFailed, wrong.read(&r2, gpa, &buf, max_frame_bytes));
}

test "tampered, replayed and reordered frames are refused" {
    const gpa = std.testing.allocator;
    const pair = try TestPair.run("424242", "424242");
    var first: std.Io.Writer.Allocating = .init(gpa);
    defer first.deinit();
    var second: std.Io.Writer.Allocating = .init(gpa);
    defer second.deinit();
    var sealer = pair.computer.sealer();
    defer sealer.deinit(gpa);
    try sealer.writeJson(gpa, &first.writer, .control, Control{ .type = .@"switch" });
    try sealer.writeJson(gpa, &second.writer, .control, (View{ .rotate = 90 }).control());
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);

    // Tampered: one flipped bit anywhere (header or body) fails.
    for ([_]usize{ 4, 5, first.written().len - 1 }) |at| {
        const copy = try gpa.dupe(u8, first.written());
        defer gpa.free(copy);
        copy[at] ^= 1;
        var opener = pair.phone.opener();
        var r: std.Io.Reader = .fixed(copy);
        if (opener.read(&r, gpa, &buf, max_frame_bytes)) |_| return error.TestUnexpectedResult else |_| {}
    }

    // Reordered: the second frame first.
    {
        var opener = pair.phone.opener();
        var r: std.Io.Reader = .fixed(second.written());
        try std.testing.expectError(error.AuthenticationFailed, opener.read(&r, gpa, &buf, max_frame_bytes));
    }
    // Replayed: the first frame twice.
    {
        var opener = pair.phone.opener();
        var r: std.Io.Reader = .fixed(first.written());
        _ = try opener.read(&r, gpa, &buf, max_frame_bytes);
        var again: std.Io.Reader = .fixed(first.written());
        try std.testing.expectError(error.AuthenticationFailed, opener.read(&again, gpa, &buf, max_frame_bytes));
    }
    // A plain frame where a sealed one belongs.
    {
        var plain: std.Io.Writer.Allocating = .init(gpa);
        defer plain.deinit();
        try writeJson(&plain.writer, .control, Control{ .type = .stop });
        var opener = pair.phone.opener();
        var r: std.Io.Reader = .fixed(plain.written());
        try std.testing.expectError(error.UnexpectedFrame, opener.read(&r, gpa, &buf, max_frame_bytes));
    }
}

test "controls are typed; unknown types don't parse" {
    const gpa = std.testing.allocator;
    const c = try std.json.parseFromSlice(Control, gpa, "{\"type\":\"switch\"}", .{ .ignore_unknown_fields = true });
    defer c.deinit();
    try std.testing.expectEqual(ControlType.@"switch", c.value.type);
    try std.testing.expectError(error.InvalidEnumTag, std.json.parseFromSlice(Control, gpa, "{\"type\":\"zoom\"}", .{ .ignore_unknown_fields = true }));
    var buf: [max_message_bytes]u8 = undefined;
    try std.testing.expectEqualStrings("{\"type\":\"switch\",\"rotate\":0,\"mirror\":false,\"fill\":false,\"fps\":30,\"jpeg\":70}", try encodeJson(&buf, Control{ .type = .@"switch" }));
}

test "names are cut and cleaned" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("Pixel 8", cleanName(&buf, "Pixel\x07 8"));
    try std.testing.expectEqualStrings("Unknown device", cleanName(&buf, "\xff\xfe"));
    const long = "é" ** 40; // 80 bytes
    try std.testing.expectEqual(@as(usize, 64), cleanName(&buf, long).len);
}

test "text for the UI is valid UTF-8 without control characters" {
    var buf: [8]u8 = undefined;
    // Cut on a boundary: "é" is 2 bytes, the fifth one doesn't fit.
    try std.testing.expectEqualStrings("éééé", cleanText(&buf, "ééééé"));
    try std.testing.expectEqualStrings("a[2Jb", cleanText(&buf, "a\x1b[2Jb\u{202e}\u{85}"));
    try std.testing.expectEqualStrings("okyes", cleanText(&buf, "ok\xff\xc3yes"));
    try std.testing.expectEqualStrings("end", cleanText(&buf, "end\xe2\x82"));
    // In place.
    var same = "x\ty\nz".*;
    try std.testing.expectEqualStrings("xyz", cleanText(&same, &same));
}

test "frames round-trip" {
    const gpa = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(gpa);
    defer out.deinit();
    try writeFrame(&out.writer, .jpeg, "\xff\xd8jpeg\xff\xd9");
    try writeJson(&out.writer, .confirm, Confirm{ .confirm = "ab" });

    var r: std.Io.Reader = .fixed(out.written());
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    const f = try readFrame(&r, gpa, &buf, max_frame_bytes);
    try std.testing.expectEqual(FrameType.jpeg, f.type);
    try std.testing.expectEqualStrings("\xff\xd8jpeg\xff\xd9", f.payload);

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const c = try readJson(&r, arena.allocator(), Confirm, .confirm);
    try std.testing.expectEqualStrings("ab", c.confirm);
    try std.testing.expectError(error.EndOfStream, readFrame(&r, gpa, &buf, max_frame_bytes));
}

test "views snap to quarter turns" {
    try std.testing.expectEqual(@as(u16, 90), (View{ .rotate = 90 }).normalized().rotate);
    try std.testing.expectEqual(@as(u16, 0), (View{ .rotate = 360 }).normalized().rotate);
    try std.testing.expectEqual(@as(u16, 270), (View{ .rotate = 280 }).normalized().rotate);
    const c = (View{ .rotate = 180, .mirror = true }).control();
    try std.testing.expectEqual(ControlType.view, c.type);
    try std.testing.expectEqual(@as(u16, 180), c.rotate);
    try std.testing.expect(c.mirror and !c.fill);
}

test "qualities stay in range" {
    const q = (Quality{ .height = 1000, .fps = 60, .jpeg = 10 }).normalized();
    try std.testing.expectEqual(@as(u16, 1080), q.height);
    try std.testing.expectEqual(@as(u8, 30), q.fps);
    try std.testing.expectEqual(@as(u8, 30), q.jpeg);
    try std.testing.expectEqual(@as(u16, 480), (Quality{ .height = 0 }).normalized().height);
}

test "a session keeps an exact height within range, else a preset" {
    try std.testing.expectEqual(@as(u16, 360), (Quality{ .height = 360, .fps = 60 }).forSession().height);
    try std.testing.expectEqual(@as(u8, 30), (Quality{ .height = 360, .fps = 60 }).forSession().fps);
    try std.testing.expectEqual(@as(u16, 720), (Quality{ .height = 720 }).forSession().height);
    try std.testing.expectEqual(@as(u16, 480), (Quality{ .height = 100 }).forSession().height);
    try std.testing.expectEqual(@as(u16, 1080), (Quality{ .height = 4000 }).forSession().height);
}

test "the phone's sizes are real camera sizes" {
    try std.testing.expectEqual(@as(u32, 854), Quality.widthOf(480));
    try std.testing.expectEqual(@as(u32, 1280), Quality.widthOf(720));
    try std.testing.expectEqual(@as(u32, 1920), Quality.widthOf(1080));
}

test "oversized frames are refused" {
    const gpa = std.testing.allocator;
    var header: [5]u8 = undefined;
    std.mem.writeInt(u32, header[0..4], max_message_bytes + 10, .big);
    header[4] = @intFromEnum(FrameType.hello);
    var r: std.Io.Reader = .fixed(&header);
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(gpa);
    try std.testing.expectError(error.FrameTooLarge, readFrame(&r, gpa, &buf, max_message_bytes));
}
