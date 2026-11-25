//! Strict Classic ZIP admission and bounded extraction. No general-purpose
//! archive path extraction. Caller pins the archive and supplies an empty,
//! exclusively owned private staging directory; never a user source folder.
const std = @import("std");
const fingerprint = @import("pet_fingerprint.zig");

pub const max_archive_bytes = 320 * 1024 * 1024;
pub const max_entries = fingerprint.max_files + 3;
pub const max_name = 160;
pub const Error = error{ InvalidArchive, UnsupportedArchive, ResourceLimit, UnsafePath, DuplicatePath, Io, CorruptPayload };

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
            if (entry.size != 0 or entry.crc != 0 or (method == 0 and entry.compressed != 0) or (method == 8 and entry.compressed == 0)) return error.UnsupportedArchive;
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

// A positional reader that exposes exactly one compressed range to std's
// raw Deflate implementation. Buffered lookahead never sees the next entry.
const RangeReader = struct {
    source: FileSource,
    next: u64,
    end: u64,
    reader: std.Io.Reader,

    fn init(source: FileSource, start: u64, end: u64, buffer: []u8) RangeReader {
        return .{
            .source = source,
            .next = start,
            .end = end,
            .reader = .{ .vtable = &.{ .stream = stream }, .buffer = buffer, .seek = 0, .end = 0 },
        };
    }

    fn stream(reader: *std.Io.Reader, writer: *std.Io.Writer, limit: std.Io.Limit) std.Io.Reader.StreamError!usize {
        const self: *RangeReader = @alignCast(@fieldParentPtr("reader", reader));
        if (self.next == self.end) return error.EndOfStream;
        var chunk: [16 * 1024]u8 = undefined;
        const n: usize = @intCast(@min(self.end - self.next, limit.minInt(chunk.len)));
        if (n == 0) return 0;
        const got = self.source.readAt(self.next, chunk[0..n]) catch return error.ReadFailed;
        if (got != n) return error.ReadFailed;
        try writer.writeAll(chunk[0..n]);
        self.next += n;
        return n;
    }

    fn consumed(self: *const RangeReader) bool {
        return self.next == self.end and self.reader.bufferedLen() == 0;
    }
};

fn copyPayload(io: std.Io, reader: *std.Io.Reader, output: ?std.Io.File, entry: *const Entry) !void {
    var crc = std.hash.Crc32.init();
    var total: u32 = 0;
    var chunk: [16 * 1024]u8 = undefined;
    while (total < entry.size) {
        const want: usize = @min(chunk.len, entry.size - total);
        const n = try reader.readSliceShort(chunk[0..want]);
        if (n == 0) return error.CorruptPayload;
        crc.update(chunk[0..n]);
        if (output) |file| try file.writeStreamingAll(io, chunk[0..n]);
        total += @intCast(n);
    }
    // A valid stream must end here. Never write the byte used for this
    // extra-output check, even if the declared size is malicious.
    if (try reader.readSliceShort(chunk[0..1]) != 0 or crc.final() != entry.crc) return error.CorruptPayload;
}

fn extractEntry(source: FileSource, entry: *const Entry, output: ?std.Io.File) !void {
    var input_buffer: [16 * 1024]u8 = undefined;
    var input = RangeReader.init(source, entry.data, entry.data + entry.compressed, &input_buffer);
    switch (entry.method) {
        0 => try copyPayload(source.io, &input.reader, output, entry),
        8 => {
            var window: [std.compress.flate.max_window_len]u8 = undefined;
            var decoder = std.compress.flate.Decompress.init(&input.reader, .raw, &window);
            try copyPayload(source.io, &decoder.reader, output, entry);
        },
        else => return error.UnsupportedArchive,
    }
    // Deflate may finish before exhausting its range. Reject hidden suffixes.
    if (!input.consumed()) return error.CorruptPayload;
}

/// Extract to a newly created child of an approved private scratch root.
/// The caller owns the root and serializes access. Never reuse "unpacked".
/// On any failure, leave only this fresh unpublished subtree for explicit
/// recovery. Do not recursively delete unknown/preexisting files. Output
/// must still pass the existing package validator before import.
pub fn extractFile(io: std.Io, archive: std.Io.File, scratch: std.Io.Dir) !void {
    var plan: Plan = .{};
    try inspectFile(io, archive, &plan);
    try scratch.createDir(io, "unpacked", .default_dir);
    const root = try scratch.openDir(io, "unpacked", .{ .follow_symlinks = false });
    defer root.close(io);
    const source: FileSource = .{ .io = io, .file = archive };
    var outfits = false;
    var activities = false;
    for (plan.entries[0..plan.count]) |*entry| {
        if (entry.directory) {
            try extractEntry(source, entry, null);
            continue;
        }
        const path = entry.path();
        var parent = root;
        var leaf = path;
        var opened = false;
        defer if (opened) parent.close(io);
        if (std.mem.indexOfScalar(u8, path, '/')) |slash| {
            const folder = path[0..slash];
            const created = if (eq(folder, "outfits")) &outfits else &activities;
            if (!created.*) {
                try root.createDir(io, folder, .default_dir);
                created.* = true;
            }
            parent = try root.openDir(io, folder, .{ .follow_symlinks = false });
            opened = true;
            leaf = path[slash + 1 ..];
        }
        const file = try parent.createFile(io, leaf, .{ .exclusive = true });
        defer file.close(io);
        try extractEntry(source, entry, file);
    }
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

// Tiny independent stored ZIP fixture, with CRC of the literal byte x.
fn fixture(out: []u8, names: []const []const u8) []u8 {
    @memset(out, 0);
    var offsets: [4]u32 = undefined;
    var pos: usize = 0;
    for (names, 0..) |name, n| {
        offsets[n] = @intCast(pos);
        put32(out, pos, 0x04034b50);
        put16(out, pos + 4, 20);
        put32(out, pos + 14, 0x8cdc1683);
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
        put32(out, pos + 16, 0x8cdc1683);
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

test "stored extraction creates only exclusive staged paths" {
    var bytes: [2048]u8 = undefined;
    const zip = fixture(&bytes, &.{ "wrapper/pet.json", "wrapper/spritesheet.webp", "wrapper/outfits/night.webp" });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const archive = try tmp.dir.createFile(io, "pet.zip", .{ .read = true });
    defer archive.close(io);
    try archive.writeStreamingAll(io, zip);
    try extractFile(io, archive, tmp.dir);
    try std.testing.expectError(error.PathAlreadyExists, extractFile(io, archive, tmp.dir));
    const output = try tmp.dir.openFile(io, "unpacked/outfits/night.webp", .{ .follow_symlinks = false });
    defer output.close(io);
    var byte: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 1), try output.readPositionalAll(io, &byte, 0));
    try std.testing.expectEqual(@as(u8, 'x'), byte[0]);
}

test "raw deflate exact length CRC and compressed boundary" {
    // Python zlib raw DEFLATE of abc (independent of Zig).
    const raw = [_]u8{ 0x4b, 0x4c, 0x4a, 0x06, 0x00, 0xff };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const archive = try tmp.dir.createFile(io, "raw", .{ .read = true });
    defer archive.close(io);
    try archive.writeStreamingAll(io, &raw);
    const source: FileSource = .{ .io = io, .file = archive };
    var entry: Entry = .{ .name_len = 0, .local = 0, .data = 0, .end = 5, .size = 3, .compressed = 5, .crc = 0x352441c2, .method = 8, .directory = false };
    const output = try tmp.dir.createFile(io, "out", .{ .read = true, .exclusive = true });
    defer output.close(io);
    try extractEntry(source, &entry, output);
    var result: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 3), try output.readPositionalAll(io, &result, 0));
    try std.testing.expectEqualStrings("abc", result[0..3]);
    entry.compressed = 6;
    try std.testing.expectError(error.CorruptPayload, extractEntry(source, &entry, null));
    entry.compressed = 5;
    entry.size = 2;
    try std.testing.expectError(error.CorruptPayload, extractEntry(source, &entry, null));
    entry.size = 4;
    try std.testing.expectError(error.CorruptPayload, extractEntry(source, &entry, null));
    entry.size = 3;
    entry.crc = 0;
    try std.testing.expectError(error.CorruptPayload, extractEntry(source, &entry, null));
    entry.compressed = 2;
    try std.testing.expectError(error.ReadFailed, extractEntry(source, &entry, null));
}
