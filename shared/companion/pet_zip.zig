//! Strict Classic ZIP admission plan. This module NEVER creates files and
//! never delegates archive paths to a general-purpose extractor. Later
//! extraction must use only these ranges, check CRC and actual output size.
//! The caller pins the archive against mutation while planning/extracting.
const std = @import("std");
const fingerprint = @import("pet_fingerprint.zig");

pub const max_archive_bytes = 320 * 1024 * 1024;
pub const max_entries = fingerprint.max_files + 3;
pub const max_name = 160;
pub const Error = error{ InvalidArchive, UnsupportedArchive, ResourceLimit, UnsafePath, DuplicatePath, Io };

pub const Entry = struct {
    name: [max_name]u8 = undefined,
    name_len: usize,
    local: u64,
    data: u64,
    end: u64,
    size: u32,
    compressed: u32,
    crc: u32,
    method: u16,
    directory: bool,

    pub fn path(self: *const Entry) []const u8 {
        return self.name[0..self.name_len];
    }
};

pub const Plan = struct {
    entries: [max_entries]Entry = undefined,
    count: usize = 0,
    total: u64 = 0,
    file_count: usize = 0,
};

fn u16le(bytes: []const u8, at: usize) u16 {
    return @as(u16, bytes[at]) | (@as(u16, bytes[at + 1]) << 8);
}

fn u32le(bytes: []const u8, at: usize) u32 {
    return @as(u32, u16le(bytes, at)) | (@as(u32, u16le(bytes, at + 2)) << 16);
}

fn read(source: anytype, offset: u64, out: []u8, limit: u64) Error!void {
    if (offset > limit or out.len > limit - offset) return error.InvalidArchive;
    const n = source.readAt(offset, out) catch return error.Io;
    if (n != out.len) return error.InvalidArchive;
}

const FileSource = struct {
    io: std.Io,
    file: std.Io.File,

    fn readAt(self: FileSource, offset: u64, out: []u8) !usize {
        return self.file.readPositionalAll(self.io, out, offset);
    }
};

pub fn inspectFile(io: std.Io, file: std.Io.File, plan: *Plan) !void {
    const stat = try file.stat(io);
    if (stat.kind != .file) return error.InvalidArchive;
    try inspect(FileSource{ .io = io, .file = file }, stat.size, plan);
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn safeStem(stem: []const u8, max: usize) bool {
    if (stem.len == 0 or stem.len > max) return false;
    for (stem, 0..) |ch, i| {
        if (ch >= 'a' and ch <= 'z' or std.ascii.isDigit(ch)) continue;
        if (i != 0 and (ch == '-' or ch == '_')) continue;
        return false;
    }
    if (eq(stem, "con") or eq(stem, "prn") or eq(stem, "aux") or eq(stem, "nul")) return false;
    if (stem.len == 4 and (eq(stem[0..3], "com") or eq(stem[0..3], "lpt")) and std.ascii.isDigit(stem[3])) return false;
    return true;
}

fn validLeaf(leaf: []const u8, activity: bool) bool {
    if (!std.mem.endsWith(u8, leaf, ".webp")) return false;
    const stem = leaf[0 .. leaf.len - 5];
    if (std.mem.indexOfScalar(u8, stem, '.')) |dot| {
        return activity and safeStem(stem[0..dot], 32) and safeStem(stem[dot + 1 ..], 32);
    }
    return safeStem(stem, 32);
}

const Name = struct { wrapper: []const u8, relative: []const u8, directory: bool };

fn parseName(raw: []const u8) Error!Name {
    if (raw.len == 0 or raw.len > max_name) return error.UnsafePath;
    const dir = raw[raw.len - 1] == '/';
    const name = if (dir) raw[0 .. raw.len - 1] else raw;
    var parts: [3][]const u8 = undefined;
    var count: usize = 0;
    var iter = std.mem.splitScalar(u8, name, '/');
    while (iter.next()) |part| {
        if (part.len == 0 or count == parts.len) return error.UnsafePath;
        parts[count] = part;
        count += 1;
    }
    if (dir) {
        if (count == 1) {
            if (eq(parts[0], "outfits") or eq(parts[0], "activities")) return .{ .wrapper = "", .relative = name, .directory = true };
            if (!safeStem(parts[0], 64)) return error.UnsafePath;
            return .{ .wrapper = parts[0], .relative = "", .directory = true };
        }
        if (count == 2 and safeStem(parts[0], 64) and (eq(parts[1], "outfits") or eq(parts[1], "activities"))) {
            return .{ .wrapper = parts[0], .relative = parts[1], .directory = true };
        }
        return error.UnsafePath;
    }
    const leaf = parts[count - 1];
    if (eq(leaf, "pet.json") or eq(leaf, "spritesheet.webp")) {
        if (count == 1) return .{ .wrapper = "", .relative = leaf, .directory = false };
        if (count == 2 and safeStem(parts[0], 64)) return .{ .wrapper = parts[0], .relative = leaf, .directory = false };
        return error.UnsafePath;
    }
    if (count < 2) return error.UnsafePath;
    const folder = parts[count - 2];
    if ((!eq(folder, "outfits") and !eq(folder, "activities")) or !validLeaf(leaf, eq(folder, "activities"))) return error.UnsafePath;
    if (count == 2) return .{ .wrapper = "", .relative = name, .directory = false };
    if (!safeStem(parts[0], 64)) return error.UnsafePath;
    return .{ .wrapper = parts[0], .relative = name[parts[0].len + 1 ..], .directory = false };
}

fn entryLimit(path: []const u8) u32 {
    if (eq(path, "pet.json")) return 128 * 1024;
    if (std.mem.startsWith(u8, path, "activities/")) return 2 * 1024 * 1024;
    return 16 * 1024 * 1024;
}

fn checkExtra(source: anytype, start: u64, length: u16, limit: u64) Error!void {
    // Reject ZIP64 and name/Unicode overrides; accept only common timestamp
    // and Unix ownership metadata, never apply any of them to output files.
    if (length > 4096) return error.ResourceLimit;
    var pos: u64 = start;
    const end = start + length;
    if (end > limit) return error.InvalidArchive;
    while (pos < end) {
        var header: [4]u8 = undefined;
        try read(source, pos, &header, end);
        const id = u16le(&header, 0);
        const len = u16le(&header, 2);
        if (id != 0x5455 and id != 0x000a and id != 0x7875) return error.UnsupportedArchive;
        pos += 4;
        if (len > end - pos) return error.InvalidArchive;
        pos += len;
    }
}

fn matchLocal(source: anytype, entry: *Entry, raw: []const u8, flags: u16, central: u64) Error!void {
    var local: [30]u8 = undefined;
    try read(source, entry.local, &local, central);
    if (u32le(&local, 0) != 0x04034b50 or u16le(&local, 6) != flags or
        u16le(&local, 8) != entry.method or u16le(&local, 26) != raw.len) return error.InvalidArchive;
    const local_crc = u32le(&local, 14);
    const local_compressed = u32le(&local, 18);
    const local_size = u32le(&local, 22);
    const descriptor = flags & 8 != 0;
    if ((!descriptor or local_crc != 0) and local_crc != entry.crc) return error.InvalidArchive;
    if ((!descriptor or local_compressed != 0) and local_compressed != entry.compressed) return error.InvalidArchive;
    if ((!descriptor or local_size != 0) and local_size != entry.size) return error.InvalidArchive;
    var local_name: [max_name]u8 = undefined;
    const name_offset = entry.local + local.len;
    try read(source, name_offset, local_name[0..raw.len], central);
    if (!eq(raw, local_name[0..raw.len])) return error.InvalidArchive;
    const extra_len = u16le(&local, 28);
    try checkExtra(source, name_offset + raw.len, extra_len, central);
    entry.data = name_offset + raw.len + extra_len;
    if (entry.data > central or entry.compressed > central - entry.data) return error.InvalidArchive;
    entry.end = entry.data + entry.compressed;
    if (descriptor) {
        var words: [12]u8 = undefined;
        try read(source, entry.end, &words, central);
        if (u32le(&words, 0) == 0x08074b50) {
            entry.end += 4;
            try read(source, entry.end, &words, central);
        }
        if (u32le(&words, 0) != entry.crc or u32le(&words, 4) != entry.compressed or u32le(&words, 8) != entry.size) return error.InvalidArchive;
        entry.end += words.len;
    }
}

// Supports ordinary single-disk ZIP32, stored and deflated entries, and
// classic flat/single-wrapper layouts. Strictly reject comments, ZIP64,
// encrypted archives, overlapping ranges and hidden local records. No
// extraction happens unless the entire plan is accepted.
pub fn inspect(source: anytype, length: u64, out: *Plan) Error!void {
    out.count = 0;
    out.total = 0;
    out.file_count = 0;
    errdefer {
        out.count = 0;
        out.total = 0;
        out.file_count = 0;
    }
    if (length > max_archive_bytes) return error.ResourceLimit;
    if (length < 22) return error.InvalidArchive;
    var eocd: [22]u8 = undefined;
    try read(source, length - eocd.len, &eocd, length);
    if (u32le(&eocd, 0) != 0x06054b50 or u16le(&eocd, 20) != 0) return error.InvalidArchive;
    const count = u16le(&eocd, 10);
    if (u16le(&eocd, 4) != 0 or u16le(&eocd, 6) != 0 or u16le(&eocd, 8) != count) return error.UnsupportedArchive;
    if (count < 2 or count > max_entries) return error.ResourceLimit;
    const central: u64 = u32le(&eocd, 16);
    const central_size: u64 = u32le(&eocd, 12);
    const central_end = length - eocd.len;
    if (central > central_end or central_size != central_end - central) return error.InvalidArchive;
    var pos = central;
    var wrapper: [64]u8 = undefined;
    var wrapper_len: ?usize = null;
    var metadata = false;
    var atlas = false;
    var activities: u64 = 0;
    for (0..count) |_| {
        var header: [46]u8 = undefined;
        try read(source, pos, &header, central_end);
        if (u32le(&header, 0) != 0x02014b50 or u16le(&header, 34) != 0) return error.InvalidArchive;
        const flags = u16le(&header, 8);
        const method = u16le(&header, 10);
        if (flags & ~@as(u16, 0x080e) != 0 or (method != 0 and method != 8) or (method == 0 and flags & 6 != 0)) return error.UnsupportedArchive;
        const name_len = u16le(&header, 28);
        const extra_len = u16le(&header, 30);
        const comment_len = u16le(&header, 32);
        if (name_len == 0 or name_len > max_name or comment_len != 0) return error.UnsupportedArchive;
        var raw: [max_name]u8 = undefined;
        try read(source, pos + header.len, raw[0..name_len], central_end);
        try checkExtra(source, pos + header.len + name_len, extra_len, central_end);
        pos += header.len + @as(u64, name_len) + extra_len;
        const parsed = try parseName(raw[0..name_len]);
        if (wrapper_len) |n| {
            if (!eq(wrapper[0..n], parsed.wrapper)) return error.UnsafePath;
        } else {
            wrapper_len = parsed.wrapper.len;
            @memcpy(wrapper[0..parsed.wrapper.len], parsed.wrapper);
        }
        const attrs = u32le(&header, 38);
        const mode = (attrs >> 16) & 0xf000;
        // Reject symlinks, device nodes and Windows reparse attributes.
        if (attrs & 0x400 != 0 or (mode != 0 and mode != (if (parsed.directory) @as(u32, 0x4000) else 0x8000)) or
            (!parsed.directory and attrs & 0x10 != 0)) return error.UnsafePath;
        var entry: Entry = .{
            .name_len = parsed.relative.len,
            .local = u32le(&header, 42),
            .data = 0,
            .end = 0,
            .size = u32le(&header, 24),
            .compressed = u32le(&header, 20),
            .crc = u32le(&header, 16),
            .method = method,
            .directory = parsed.directory,
        };
        @memcpy(entry.name[0..entry.name_len], parsed.relative);
        for (out.entries[0..out.count]) |*prior| {
            if (eq(prior.path(), entry.path())) return error.DuplicatePath;
        }
        if (parsed.directory) {
            if (entry.size != 0 or entry.crc != 0 or method != 0 or entry.compressed != 0) return error.UnsupportedArchive;
        } else {
            if (entry.size == 0 or entry.compressed == 0 or entry.size > entryLimit(entry.path()) or entry.size > fingerprint.max_total_bytes - out.total) return error.ResourceLimit;
            if (method == 0 and entry.size != entry.compressed) return error.InvalidArchive;
            if (std.mem.startsWith(u8, entry.path(), "activities/")) {
                if (entry.size > 16 * 1024 * 1024 - activities) return error.ResourceLimit;
                activities += entry.size;
            }
            out.total += entry.size;
            out.file_count += 1;
            if (out.file_count > fingerprint.max_files) return error.ResourceLimit;
            metadata = metadata or eq(entry.path(), "pet.json");
            atlas = atlas or eq(entry.path(), "spritesheet.webp");
        }
        try matchLocal(source, &entry, raw[0..name_len], flags, central);
        out.entries[out.count] = entry;
        out.count += 1;
    }
    if (pos != central_end or !metadata or !atlas) return error.InvalidArchive;
    // Sort by local offsets, verify exact coverage (no overlapping entries,
    // leading executable data, hidden local entries or trailing junk).
    var j: usize = 1;
    while (j < out.count) : (j += 1) {
        var k = j;
        while (k > 0 and out.entries[k].local < out.entries[k - 1].local) : (k -= 1) {
            std.mem.swap(Entry, &out.entries[k], &out.entries[k - 1]);
        }
    }
    var end: u64 = 0;
    for (out.entries[0..out.count]) |entry| {
        if (entry.local != end or entry.end <= entry.local) return error.InvalidArchive;
        end = entry.end;
    }
    if (end != central) return error.InvalidArchive;
}

const Bytes = struct {
    bytes: []const u8,

    fn readAt(self: Bytes, offset: u64, out: []u8) !usize {
        const start: usize = @intCast(offset);
        @memcpy(out, self.bytes[start .. start + out.len]);
        return out.len;
    }
};

fn put16(out: []u8, pos: usize, value: u16) void {
    out[pos] = @truncate(value);
    out[pos + 1] = @truncate(value >> 8);
}

fn put32(out: []u8, pos: usize, value: u32) void {
    put16(out, pos, @truncate(value));
    put16(out, pos + 2, @truncate(value >> 16));
}

// Tiny independent stored ZIP fixture (CRC is checked at extraction, not
// during admission). Generates ordinary local and central records.
fn fixture(out: []u8, names: []const []const u8) []u8 {
    @memset(out, 0);
    var offsets: [4]u32 = undefined;
    var pos: usize = 0;
    for (names, 0..) |name, n| {
        offsets[n] = @intCast(pos);
        put32(out, pos, 0x04034b50);
        put16(out, pos + 4, 20);
        put32(out, pos + 18, 1);
        put32(out, pos + 22, 1);
        put16(out, pos + 26, @intCast(name.len));
        @memcpy(out[pos + 30 ..][0..name.len], name);
        out[pos + 30 + name.len] = 'x';
        pos += 31 + name.len;
    }
    const central = pos;
    for (names, 0..) |name, n| {
        put32(out, pos, 0x02014b50);
        put16(out, pos + 4, 20);
        put16(out, pos + 6, 20);
        put32(out, pos + 20, 1);
        put32(out, pos + 24, 1);
        put16(out, pos + 28, @intCast(name.len));
        put32(out, pos + 42, offsets[n]);
        @memcpy(out[pos + 46 ..][0..name.len], name);
        pos += 46 + name.len;
    }
    put32(out, pos, 0x06054b50);
    put16(out, pos + 8, @intCast(names.len));
    put16(out, pos + 10, @intCast(names.len));
    put32(out, pos + 12, @intCast(pos - central));
    put32(out, pos + 16, @intCast(central));
    return out[0 .. pos + 22];
}

test "file-backed ZIP plan and wrapper normalization" {
    var buf: [2048]u8 = undefined;
    const bytes = fixture(&buf, &.{ "pet-package/pet.json", "pet-package/spritesheet.webp", "pet-package/activities/dance.night.webp" });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "pet.zip", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
    var plan: Plan = .{};
    try inspectFile(io, file, &plan);
    try std.testing.expectEqual(@as(usize, 3), plan.file_count);
    try std.testing.expectEqualStrings("activities/dance.night.webp", plan.entries[2].path());
    try std.testing.expectEqual(@as(u64, 3), plan.total);
}

test "ZIP admission fails closed for duplicate mixed paths and hostile headers" {
    var buf: [2048]u8 = undefined;
    var plan: Plan = .{};
    var bytes = fixture(&buf, &.{ "pet.json", "spritesheet.webp", "../evil.webp" });
    try std.testing.expectError(error.UnsafePath, inspect(Bytes{ .bytes = bytes }, bytes.len, &plan));
    try std.testing.expectEqual(@as(usize, 0), plan.count);
    bytes = fixture(&buf, &.{ "pet.json", "spritesheet.webp", "pet.json" });
    try std.testing.expectError(error.DuplicatePath, inspect(Bytes{ .bytes = bytes }, bytes.len, &plan));
    bytes = fixture(&buf, &.{ "pet.json", "wrapper/spritesheet.webp" });
    try std.testing.expectError(error.UnsafePath, inspect(Bytes{ .bytes = bytes }, bytes.len, &plan));
    bytes = fixture(&buf, &.{ "pet.json", "spritesheet.webp" });
    const central = u32le(bytes, bytes.len - 6);
    bytes[30] = 'x'; // local name differs from central name
    try std.testing.expectError(error.InvalidArchive, inspect(Bytes{ .bytes = bytes }, bytes.len, &plan));
    bytes = fixture(&buf, &.{ "pet.json", "spritesheet.webp" });
    put32(bytes, central + 38, 0xa0000000); // symlink
    try std.testing.expectError(error.UnsafePath, inspect(Bytes{ .bytes = bytes }, bytes.len, &plan));
    bytes = fixture(&buf, &.{ "pet.json", "spritesheet.webp" });
    put32(bytes, central + 24, 128 * 1024 + 1);
    try std.testing.expectError(error.ResourceLimit, inspect(Bytes{ .bytes = bytes }, bytes.len, &plan));
    bytes = fixture(&buf, &.{ "pet.json", "spritesheet.webp" });
    put16(bytes, central + 8, 1); // encrypted
    try std.testing.expectError(error.UnsupportedArchive, inspect(Bytes{ .bytes = bytes }, bytes.len, &plan));
    try std.testing.expectEqual(@as(usize, 0), plan.count);
    try std.testing.expectError(error.UnsafePath, parseName("outfits/con.webp"));
    try std.testing.expectError(error.UnsafePath, parseName("activities/../bad.webp"));
}
