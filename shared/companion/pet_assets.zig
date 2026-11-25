//! Bounded classic WebP pet metadata and atlas preflight.
//! Upstream: OpenPetsHQ/openpets@2f02bb04d872dec6923a47572343305235c63482.
//! No file I/O, decoder, SVG, Motion package, archive extraction or renderer.
const std = @import("std");

pub const max_metadata_bytes = 128 * 1024;
pub const max_webp_bytes = 16 * 1024 * 1024;
pub const frame_width: u32 = 192;
pub const frame_height: u32 = 208;
pub const columns: u32 = 8;

pub const Layout = enum {
    v1,
    v2,

    pub fn rows(self: Layout) u32 {
        return if (self == .v1) 9 else 11;
    }

    pub fn width(_: Layout) u32 {
        return frame_width * columns;
    }

    pub fn height(self: Layout) u32 {
        return frame_height * self.rows();
    }

    pub fn rgbaBytes(self: Layout) usize {
        return @as(usize, self.width()) * @as(usize, self.height()) * 4;
    }
};

pub const Metadata = struct {
    layout: Layout,
};

fn safePetId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64 or std.mem.eql(u8, id, "builtin")) return false;
    for (id, 0..) |c, i| {
        if ((c >= 'a' and c <= 'z') or std.ascii.isDigit(c)) continue;
        if (i != 0 and (c == '-' or c == '_')) continue;
        return false;
    }
    return true;
}

fn textField(value: std.json.Value, max_bytes: usize) bool {
    if (value != .string) return false;
    const trimmed = std.mem.trim(u8, value.string, " \t\r\n");
    if (trimmed.len == 0 or trimmed.len > max_bytes) return false;
    for (trimmed) |c| {
        if (c < 32 or c == 127) return false;
    }
    return true;
}

/// Owns only the layout; no reference to input or parse allocations escapes.
/// Caller supplies a bounded scratch allocator. Byte limits are deliberately
/// stricter than upstream UTF-16 text limits. Unsupported extensions fail
/// closed instead of silently dropping outfits, activities or motion clips.
pub fn parseMetadata(allocator: std.mem.Allocator, input: []const u8, expected_id: []const u8) error{ InvalidMetadata, UnsupportedFormat, OutOfMemory }!Metadata {
    if (!safePetId(expected_id) or input.len == 0 or input.len > max_metadata_bytes or !std.unicode.utf8ValidateSlice(input)) return error.InvalidMetadata;
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, input, .{}) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidMetadata,
    };
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidMetadata;
    const object = parsed.value.object;
    const id = object.get("id") orelse return error.InvalidMetadata;
    if (id != .string or !std.mem.eql(u8, id.string, expected_id)) return error.InvalidMetadata;
    if (!textField(object.get("displayName") orelse return error.InvalidMetadata, 80 * 4)) return error.InvalidMetadata;
    if (!textField(object.get("description") orelse return error.InvalidMetadata, 500 * 4)) return error.InvalidMetadata;
    const path = object.get("spritesheetPath") orelse return error.UnsupportedFormat;
    if (path != .string or !std.mem.eql(u8, path.string, "spritesheet.webp")) return error.UnsupportedFormat;
    var layout: Layout = .v1;
    if (object.get("spriteVersionNumber")) |version| {
        if (version != .integer or version.integer != 2) return error.UnsupportedFormat;
        layout = .v2;
    }
    var keys = object.iterator();
    while (keys.next()) |entry| {
        const key = entry.key_ptr.*;
        if (std.mem.eql(u8, key, "id") or std.mem.eql(u8, key, "displayName") or
            std.mem.eql(u8, key, "description") or std.mem.eql(u8, key, "spritesheetPath") or
            std.mem.eql(u8, key, "spriteVersionNumber")) continue;
        return error.UnsupportedFormat;
    }
    return .{ .layout = layout };
}

fn le16(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8);
}

fn le24(bytes: []const u8) u32 {
    return le16(bytes) | (@as(u32, bytes[2]) << 16);
}

fn le32(bytes: []const u8) u32 {
    return le24(bytes) | (@as(u32, bytes[3]) << 24);
}

const Size = struct { width: u32, height: u32 };

fn imageSize(tag: []const u8, body: []const u8) error{InvalidAtlas}!Size {
    if (std.mem.eql(u8, tag, "VP8 ")) {
        if (body.len < 10 or body[0] & 1 != 0 or !std.mem.eql(u8, body[3..6], &.{ 0x9d, 0x01, 0x2a })) return error.InvalidAtlas;
        return .{ .width = le16(body[6..8]) & 0x3fff, .height = le16(body[8..10]) & 0x3fff };
    }
    if (body.len < 5 or body[0] != 0x2f or body[4] & 0xe0 != 0) return error.InvalidAtlas;
    const bits = le32(body[1..5]);
    return .{ .width = (bits & 0x3fff) + 1, .height = ((bits >> 14) & 0x3fff) + 1 };
}

fn matches(layout: Layout, size: Size) bool {
    return size.width == layout.width() and size.height == layout.height();
}

/// Reject oversized, animated, mismatched or structurally ambiguous WebP
/// before any decoder runs. Strict subset: simple VP8/VP8L or extended
/// static alpha with optional ALPH preceding VP8. Other chunks (including
/// ICC, EXIF, XMP and animation) are unsupported. This validates the RIFF
/// container and image headers only, never compressed image correctness.
pub fn preflightWebp(layout: Layout, bytes: []const u8) error{ InvalidAtlas, UnsupportedAtlas }!void {
    if (bytes.len < 12 or bytes.len > max_webp_bytes) return error.InvalidAtlas;
    if (!std.mem.eql(u8, bytes[0..4], "RIFF") or !std.mem.eql(u8, bytes[8..12], "WEBP")) return error.InvalidAtlas;
    if (le32(bytes[4..8]) != bytes.len - 8) return error.InvalidAtlas;
    var cursor: usize = 12;
    var extended = false;
    var alpha = false;
    var alpha_chunk = false;
    var image = false;
    while (cursor < bytes.len) {
        if (image or bytes.len - cursor < 8) return error.InvalidAtlas;
        const tag = bytes[cursor..][0..4];
        const size: usize = le32(bytes[cursor + 4 ..][0..4]);
        const start = cursor + 8;
        if (size > bytes.len - start) return error.InvalidAtlas;
        const end = start + size;
        if (size % 2 != 0 and (end == bytes.len or bytes[end] != 0)) return error.InvalidAtlas;
        const body = bytes[start..end];
        if (std.mem.eql(u8, tag, "VP8X")) {
            if (cursor != 12 or body.len != 10) return error.InvalidAtlas;
            if (body[0] & 0xef != 0) return error.UnsupportedAtlas;
            if (body[1] != 0 or body[2] != 0 or body[3] != 0) return error.InvalidAtlas;
            if (!matches(layout, .{ .width = le24(body[4..7]) + 1, .height = le24(body[7..10]) + 1 })) return error.InvalidAtlas;
            extended = true;
            alpha = body[0] & 0x10 != 0;
        } else if (std.mem.eql(u8, tag, "ALPH")) {
            if (!extended or !alpha or alpha_chunk or body.len == 0) return error.InvalidAtlas;
            alpha_chunk = true;
        } else if (std.mem.eql(u8, tag, "VP8 ") or std.mem.eql(u8, tag, "VP8L")) {
            const lossy = std.mem.eql(u8, tag, "VP8 ");
            if (lossy and alpha != alpha_chunk) return error.InvalidAtlas;
            if (!lossy and alpha_chunk) return error.InvalidAtlas;
            if (!matches(layout, try imageSize(tag, body))) return error.InvalidAtlas;
            image = true;
        } else return error.UnsupportedAtlas;
        cursor = end + size % 2;
    }
    if (!image) return error.InvalidAtlas;
}

/// A future decoder must return exactly one tightly packed RGBA8 atlas.
/// Never allocate output based on untrusted decoded dimensions.
pub fn validateDecoded(layout: Layout, width: u32, height: u32, stride: usize, len: usize) error{InvalidAtlas}!void {
    if (width != layout.width() or height != layout.height() or stride != @as(usize, width) * 4 or len != layout.rgbaBytes()) return error.InvalidAtlas;
}

const t = std.testing;
const classic = "{\"id\":\"sample-pet\",\"displayName\":\"Sample\",\"description\":\"Test fixture\",\"spritesheetPath\":\"spritesheet.webp\"}";
const classic_v2 = "{\"id\":\"sample-pet\",\"displayName\":\"Sample\",\"description\":\"Test fixture\",\"spritesheetPath\":\"spritesheet.webp\",\"spriteVersionNumber\":2}";

test "classic metadata resolves exact v1 and v2 dimensions" {
    const one = try parseMetadata(t.allocator, classic, "sample-pet");
    const two = try parseMetadata(t.allocator, classic_v2, "sample-pet");
    try t.expectEqual(Layout.v1, one.layout);
    try t.expectEqual(Layout.v2, two.layout);
    try t.expectEqual(@as(u32, 1536), one.layout.width());
    try t.expectEqual(@as(u32, 1872), one.layout.height());
    try t.expectEqual(@as(u32, 2288), two.layout.height());
    try t.expectEqual(@as(usize, 14057472), two.layout.rgbaBytes());
}

test "metadata rejects mismatches unsupported formats and duplicate keys" {
    try t.expectError(error.InvalidMetadata, parseMetadata(t.allocator, classic, "../sample-pet"));
    try t.expectError(error.InvalidMetadata, parseMetadata(t.allocator, classic, "other"));
    try t.expectError(error.InvalidMetadata, parseMetadata(t.allocator, "{\"id\":\"a\",\"id\":\"a\"}", "a"));
    try t.expectError(error.UnsupportedFormat, parseMetadata(t.allocator, "{\"id\":\"a\",\"displayName\":\"A\",\"description\":\"A\",\"spritesheetPath\":\"spritesheet.svg\"}", "a"));
    try t.expectError(error.UnsupportedFormat, parseMetadata(t.allocator, "{\"id\":\"a\",\"displayName\":\"A\",\"description\":\"A\",\"spritesheetPath\":\"spritesheet.webp\",\"spriteVersionNumber\":null}", "a"));
    try t.expectError(error.UnsupportedFormat, parseMetadata(t.allocator, "{\"id\":\"a\",\"displayName\":\"A\",\"description\":\"A\",\"spritesheetPath\":\"spritesheet.webp\",\"wardrobe\":{}}", "a"));
}

// Synthetic headers, deliberately not decodable compressed images.
const lossy_header = "RIFF\x16\x00\x00\x00WEBPVP8 \x0a\x00\x00\x00\x00\x00\x00\x9d\x01\x2a\x00\x06\x50\x07";
const lossless_header = "RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x2f\xff\xc5\xd3\x01\x00";

test "WebP preflight checks both static header layouts and exact size" {
    try preflightWebp(.v1, lossy_header);
    try preflightWebp(.v1, lossless_header);
    try t.expectError(error.InvalidAtlas, preflightWebp(.v2, lossy_header));
    try t.expectError(error.InvalidAtlas, preflightWebp(.v1, lossy_header[0 .. lossy_header.len - 1]));
    try t.expectError(error.InvalidAtlas, preflightWebp(.v1, lossy_header ++ "x"));
    var bad = lossless_header.*;
    bad[bad.len - 1] = 1;
    try t.expectError(error.InvalidAtlas, preflightWebp(.v1, &bad));
}

test "WebP preflight refuses animated extended containers" {
    const animated = "RIFF\x16\x00\x00\x00WEBPVP8X\x0a\x00\x00\x00\x02\x00\x00\x00\xff\x05\x00\x4f\x07\x00";
    try t.expectError(error.UnsupportedAtlas, preflightWebp(.v1, animated));
}

test "decoded atlas must be tightly packed and exactly bounded" {
    try validateDecoded(.v2, 1536, 2288, 6144, 14057472);
    try t.expectError(error.InvalidAtlas, validateDecoded(.v2, 1536, 2288, 6145, 14057472));
    try t.expectError(error.InvalidAtlas, validateDecoded(.v2, 1536, 2288, 6144, 14057471));
    try t.expectError(error.InvalidAtlas, validateDecoded(.v2, 1536, 1872, 6144, 14057472));
}
