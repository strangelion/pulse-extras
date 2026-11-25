//! Versioned SHA-256 identity of a validated Classic package inventory.
//! Paths and file handles must come from the validated/staged copy, not
//! unchecked archive entries. No path traversal or file opening here.
const std = @import("std");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Digest = [32]u8;
pub const Secondary = [64]u8;
pub const Pair = extern struct {
    primary: Digest,
    secondary: Secondary,
};
pub const max_files = 290; // metadata + atlas + 16 outfits + 16*17 activities
pub const max_file_bytes = 16 * 1024 * 1024;
pub const max_total_bytes = 320 * 1024 * 1024;
pub const Error = error{ InvalidInventory, DuplicatePath, ResourceLimit, ChangedFile };

pub const FileDigest = struct {
    path: []const u8,
    size: u64,
    digest: Digest,
    secondary: Secondary = @splat(0),
};

fn validPath(path: []const u8) bool {
    if (std.mem.eql(u8, path, "pet.json") or std.mem.eql(u8, path, "spritesheet.webp")) return true;
    const prefix: usize = if (std.mem.startsWith(u8, path, "outfits/")) 8 else if (std.mem.startsWith(u8, path, "activities/")) 11 else return false;
    const leaf = path[prefix..];
    if (leaf.len <= 5 or leaf.len > 79 or !std.mem.endsWith(u8, leaf, ".webp")) return false;
    for (leaf[0 .. leaf.len - 5]) |ch| {
        if (!(ch >= 'a' and ch <= 'z' or std.ascii.isDigit(ch) or ch == '-' or ch == '_' or ch == '.')) return false;
    }
    return leaf[0] != '.' and std.mem.indexOf(u8, leaf, "..") == null;
}

fn updateInt(hash: anytype, value: u64) void {
    var bytes: [8]u8 = undefined;
    for (0..8) |i| bytes[i] = @truncate(value >> @as(u6, @intCast(i * 8)));
    hash.update(&bytes);
}

// File SHA-256 is streamed in a fixed 16 KiB buffer. The caller pins the
// file against modification; size checks alone cannot detect all races.
pub fn digestFile(io: std.Io, file: std.Io.File, path: []const u8) !FileDigest {
    if (!validPath(path)) return error.InvalidInventory;
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size == 0 or stat.size > max_file_bytes) return error.ResourceLimit;
    var hash = Sha256.init(.{});
    var secondary = std.crypto.hash.sha2.Sha512.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const want: usize = @intCast(@min(stat.size - offset, buffer.len));
        const n = try file.readPositionalAll(io, buffer[0..want], offset);
        if (n != want) return error.ChangedFile;
        hash.update(buffer[0..n]);
        secondary.update(buffer[0..n]);
        offset += n;
    }
    if ((try file.stat(io)).size != stat.size) return error.ChangedFile;
    return .{ .path = path, .size = stat.size, .digest = hash.finalResult(), .secondary = secondary.finalResult() };
}

pub fn digest(files: []const FileDigest) Error!Digest {
    return (try digestPair(files)).primary;
}

pub fn digestPair(files: []const FileDigest) Error!Pair {
    if (files.len < 2 or files.len > max_files) return error.InvalidInventory;
    var order: [max_files]usize = undefined;
    var total: u64 = 0;
    var metadata = false;
    var atlas = false;
    for (files, 0..) |file, i| {
        if (!validPath(file.path)) return error.InvalidInventory;
        if (file.size == 0 or file.size > max_file_bytes or file.size > max_total_bytes - total) return error.ResourceLimit;
        total += file.size;
        metadata = metadata or std.mem.eql(u8, file.path, "pet.json");
        atlas = atlas or std.mem.eql(u8, file.path, "spritesheet.webp");
        var j = i;
        while (j > 0 and std.mem.order(u8, file.path, files[order[j - 1]].path) == .lt) : (j -= 1) {
            order[j] = order[j - 1];
        }
        order[j] = i;
    }
    if (!metadata or !atlas) return error.InvalidInventory;
    var hash = Sha256.init(.{});
    hash.update("pulse-classic-package-sha256-v1\x00");
    updateInt(&hash, files.len);
    var secondary = std.crypto.hash.sha2.Sha512.init(.{});
    secondary.update("pulse-classic-package-sha512-v1\x00");
    updateInt(&secondary, files.len);
    var previous: ?[]const u8 = null;
    for (order[0..files.len]) |i| {
        const file = files[i];
        if (previous) |p| {
            if (std.mem.eql(u8, p, file.path)) return error.DuplicatePath;
        }
        previous = file.path;
        updateInt(&hash, file.path.len);
        hash.update(file.path);
        updateInt(&hash, file.size);
        hash.update(&file.digest);
        updateInt(&secondary, file.path.len);
        secondary.update(file.path);
        updateInt(&secondary, file.size);
        secondary.update(&file.secondary);
    }
    return .{ .primary = hash.finalResult(), .secondary = secondary.finalResult() };
}

pub fn hex(value: Digest) [64]u8 {
    return hexBytes(32, value);
}

pub fn hexBytes(comptime len: usize, value: [len]u8) [len * 2]u8 {
    const alphabet = "0123456789abcdef";
    var out: [len * 2]u8 = undefined;
    for (value, 0..) |byte, i| {
        out[2 * i] = alphabet[byte >> 4];
        out[2 * i + 1] = alphabet[byte & 15];
    }
    return out;
}

test "canonical package digest is order independent and content sensitive" {
    var files = [_]FileDigest{
        .{ .path = "pet.json", .size = 10, .digest = @splat(1) },
        .{ .path = "spritesheet.webp", .size = 20, .digest = @splat(2) },
        .{ .path = "outfits/night.webp", .size = 30, .digest = @splat(3) },
    };
    const original = try digest(&files);
    const reversed = [_]FileDigest{ files[2], files[0], files[1] };
    try std.testing.expectEqualSlices(u8, &original, &(try digest(&reversed)));
    files[2].digest[0] = 4;
    try std.testing.expect(!std.mem.eql(u8, &original, &(try digest(&files))));
    files[2].path = "activities/night.webp";
    const relocated = try digest(&files);
    files[2].path = "outfits/night.webp";
    try std.testing.expect(!std.mem.eql(u8, &relocated, &(try digest(&files))));
    files[2].path = "spritesheet.webp";
    try std.testing.expectError(error.DuplicatePath, digest(&files));
    files[2].path = "outfits/../evil.webp";
    try std.testing.expectError(error.InvalidInventory, digest(&files));
    const sample: Digest = @splat(0xab);
    const text = hex(sample);
    try std.testing.expectEqualStrings("abababababababababababababababababababababababababababababababab", &text);
}

test "file digest streams actual bytes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "pet.json", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "abc");
    const result = try digestFile(io, file, "pet.json");
    try std.testing.expectEqual(@as(u64, 3), result.size);
    const text = hex(result.digest);
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &text);
}

pub fn pairHex(value: Pair) [193]u8 {
    var out: [193]u8 = undefined;
    @memcpy(out[0..64], &hex(value.primary));
    out[64] = ':';
    @memcpy(out[65..193], &hexBytes(64, value.secondary));
    return out;
}

test "secondary is independent of primary and preserves primary v1" {
    var files = [_]FileDigest{
        .{ .path = "pet.json", .size = 1, .digest = @splat(1), .secondary = @splat(2) },
        .{ .path = "spritesheet.webp", .size = 1, .digest = @splat(3), .secondary = @splat(4) },
    };
    const before = try digestPair(&files);
    files[1].secondary[0] ^= 1;
    const after = try digestPair(&files);
    try std.testing.expectEqualSlices(u8, &before.primary, &after.primary);
    try std.testing.expect(!std.mem.eql(u8, &before.secondary, &after.secondary));
}
