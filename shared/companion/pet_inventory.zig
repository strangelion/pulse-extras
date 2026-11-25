//! Persistent managed-asset identity inventory. No external paths, filesystem
//! traversal or image decode. Serialized worker; stable IDs never reused.
const std = @import("std");
const fingerprint = @import("pet_fingerprint.zig");

pub const max_entries = 512;
pub const max_bytes = 16 + max_entries * 106;
pub const Error = error{ Invalid, Full, IdExhausted, UnknownAsset, InvalidRecord, BufferTooSmall, DuplicateContent };

pub fn validSource(source: []const u8) bool {
    if (source.len == 0 or source.len > 64 or std.mem.eql(u8, source, "builtin")) return false;
    for (source, 0..) |ch, i| {
        if (ch >= 'a' and ch <= 'z' or std.ascii.isDigit(ch)) continue;
        if (i != 0 and (ch == '-' or ch == '_')) continue;
        return false;
    }
    return true;
}

pub const Record = struct {
    id: u64,
    source: [64]u8 = @splat(0),
    len: u8,
    digest: ?fingerprint.Digest = null,

    pub fn init(id: u64, source: []const u8) Error!Record {
        if (id == 0 or !validSource(source)) return error.Invalid;
        var result: Record = .{ .id = id, .len = @intCast(source.len) };
        @memcpy(result.source[0..source.len], source);
        return result;
    }

    pub fn sourceId(self: *const Record) []const u8 {
        return self.source[0..self.len];
    }
};

pub const Inventory = struct {
    next_id: u64 = 1,
    count: usize = 0,
    pending_id: ?u64 = null, // Session only; restart abandons unpublished reservations.
    entries: [max_entries]Record = undefined,

    pub fn get(self: *const Inventory, id: u64) Error!Record {
        for (self.entries[0..self.count]) |entry| {
            if (entry.id == id) return entry;
        }
        return error.UnknownAsset;
    }

    // Reserve and persist this high-water mark BEFORE creating the managed
    // directory. A failed import may leave a gap; no reuse on retry/restart.
    pub fn reserve(self: *Inventory) Error!u64 {
        if (self.count == max_entries) return error.Full;
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        const id = self.next_id;
        self.next_id += 1;
        self.pending_id = id;
        return id;
    }

    // Publish only a just-reserved ID, after staged validation and rename.
    // Older unused IDs cannot be adopted through this operation.
    pub fn findDigest(self: *const Inventory, value: fingerprint.Digest) ?u64 {
        for (self.entries[0..self.count]) |entry| {
            if (entry.digest) |existing| {
                if (std.mem.eql(u8, &existing, &value)) return entry.id;
            }
        }
        return null;
    }

    pub fn publish(self: *Inventory, id: u64, source: []const u8) Error!void {
        return self.publishInternal(id, source, null);
    }

    pub fn publishVerified(self: *Inventory, id: u64, source: []const u8, value: fingerprint.Digest) Error!void {
        return self.publishInternal(id, source, value);
    }

    fn publishInternal(self: *Inventory, id: u64, source: []const u8, value: ?fingerprint.Digest) Error!void {
        if (id == 0 or self.pending_id != id or id != self.next_id - 1) return error.Invalid;
        if (value) |hash| {
            if (self.findDigest(hash) != null) return error.DuplicateContent;
        }
        if (self.count == max_entries) return error.Full;
        if (self.count != 0 and id <= self.entries[self.count - 1].id) return error.Invalid;
        var record = try Record.init(id, source);
        record.digest = value;
        self.entries[self.count] = record;
        self.count += 1;
        self.pending_id = null;
    }

    // Caller must have checked active instance pins. No file deletion here.
    pub fn remove(self: *Inventory, id: u64) Error!void {
        for (self.entries[0..self.count], 0..) |entry, i| {
            if (entry.id != id) continue;
            var j = i;
            while (j + 1 < self.count) : (j += 1) self.entries[j] = self.entries[j + 1];
            self.count -= 1;
            return;
        }
        return error.UnknownAsset;
    }
};

pub fn directory(root: []const u8, id: u64, out: []u8) Error![]const u8 {
    if (root.len < 4 or id == 0 or root[1] != ':' or root[2] != '\\' or
        root[root.len - 1] == '\\' or std.mem.indexOfScalar(u8, root, 0) != null) return error.Invalid;
    return std.fmt.bufPrint(out, "{s}\\pet-{x:0>16}", .{ root, id }) catch error.BufferTooSmall;
}

fn put64(out: []u8, value: u64) void {
    for (0..8) |i| out[i] = @truncate(value >> @as(u6, @intCast(i * 8)));
}

fn get64(input: []const u8) u64 {
    var result: u64 = 0;
    for (0..8) |i| result |= @as(u64, input[i]) << @as(u6, @intCast(i * 8));
    return result;
}

// PCI2: PCI1 fields plus per-record digest presence and optional 32 bytes.
// PCI1 is readable but its missing fingerprints are never assumed verified.
// No mutable metadata or filesystem path in the inventory.
pub fn encode(value: *const Inventory, out: []u8) Error![]const u8 {
    if (value.next_id == 0 or value.count > max_entries) return error.InvalidRecord;
    var needed: usize = 16;
    var last: u64 = 0;
    for (value.entries[0..value.count]) |*entry| {
        if (entry.len > 64 or !validSource(entry.sourceId()) or entry.id <= last or entry.id >= value.next_id) return error.InvalidRecord;
        last = entry.id;
        needed += 10 + @as(usize, entry.len) + @as(usize, if (entry.digest != null) 32 else 0);
    }
    if (out.len < needed) return error.BufferTooSmall;
    @memcpy(out[0..4], "PCI2");
    put64(out[4..12], value.next_id);
    const count: u32 = @intCast(value.count);
    for (0..4) |i| out[12 + i] = @truncate(count >> @as(u5, @intCast(i * 8)));
    var pos: usize = 16;
    for (value.entries[0..value.count]) |*entry| {
        put64(out[pos .. pos + 8], entry.id);
        out[pos + 8] = entry.len;
        pos += 9;
        @memcpy(out[pos .. pos + entry.len], entry.sourceId());
        pos += entry.len;
        out[pos] = @intFromBool(entry.digest != null);
        pos += 1;
        if (entry.digest) |hash| {
            @memcpy(out[pos .. pos + 32], &hash);
            pos += 32;
        }
    }
    return out[0..pos];
}

// Decode into a staged value, commit only on exact, valid end of record.
pub fn decode(value: *Inventory, input: []const u8) Error!void {
    if (input.len < 16 or input.len > max_bytes) return error.InvalidRecord;
    const legacy = std.mem.eql(u8, input[0..4], "PCI1");
    if (!legacy and !std.mem.eql(u8, input[0..4], "PCI2")) return error.InvalidRecord;
    var candidate: Inventory = .{ .next_id = get64(input[4..12]) };
    if (candidate.next_id == 0) return error.InvalidRecord;
    var count: u32 = 0;
    for (0..4) |i| count |= @as(u32, input[12 + i]) << @as(u5, @intCast(i * 8));
    if (count > max_entries) return error.InvalidRecord;
    var pos: usize = 16;
    var last: u64 = 0;
    for (0..count) |_| {
        if (input.len - pos < 9) return error.InvalidRecord;
        const id = get64(input[pos .. pos + 8]);
        const len: usize = input[pos + 8];
        pos += 9;
        if (len > input.len - pos or id <= last or id >= candidate.next_id) return error.InvalidRecord;
        var record = Record.init(id, input[pos .. pos + len]) catch return error.InvalidRecord;
        pos += len;
        if (!legacy) {
            if (pos == input.len or input[pos] > 1) return error.InvalidRecord;
            const present = input[pos] == 1;
            pos += 1;
            if (present) {
                if (input.len - pos < 32) return error.InvalidRecord;
                const hash: fingerprint.Digest = input[pos..][0..32].*;
                if (candidate.findDigest(hash) != null) return error.InvalidRecord;
                record.digest = hash;
                pos += 32;
            }
        }
        candidate.entries[candidate.count] = record;
        candidate.count += 1;
        last = id;
    }
    if (pos != input.len) return error.InvalidRecord;
    value.* = candidate;
}

test "stable IDs survive gaps removal and inventory round trip" {
    var inventory: Inventory = .{};
    const a = try inventory.reserve();
    try inventory.publish(a, "cat");
    _ = try inventory.reserve(); // failed import
    const b = try inventory.reserve();
    try inventory.publish(b, "fox");
    try inventory.remove(a);
    var bytes: [max_bytes]u8 = undefined;
    const encoded = try encode(&inventory, &bytes);
    var restored: Inventory = .{};
    try decode(&restored, encoded);
    try std.testing.expectEqual(@as(u64, 4), restored.next_id);
    const fox = try restored.get(b);
    try std.testing.expectEqualStrings("fox", fox.sourceId());
    try std.testing.expectError(error.UnknownAsset, restored.get(a));
    for (0..encoded.len) |len| {
        try std.testing.expectError(error.InvalidRecord, decode(&restored, encoded[0..len]));
        try std.testing.expectEqual(@as(u64, 4), restored.next_id);
    }
    const next = try restored.reserve();
    try std.testing.expectEqual(@as(u64, 4), next);
    try std.testing.expectError(error.Invalid, restored.publish(next - 1, "cat"));
    try restored.publish(next, "cat");
    var path: [128]u8 = undefined;
    try std.testing.expectEqualStrings("C:\\Pets\\pet-0000000000000004", try directory("C:\\Pets", next, &path));
    try std.testing.expectError(error.Invalid, Record.init(1, "../cat"));
}

test "verified fingerprints persist and duplicate content cannot publish twice" {
    var value: Inventory = .{};
    const a = try value.reserve();
    const hash: fingerprint.Digest = @splat(7);
    try value.publishVerified(a, "cat", hash);
    const b = try value.reserve();
    try std.testing.expectError(error.DuplicateContent, value.publishVerified(b, "cat", hash));
    var bytes: [max_bytes]u8 = undefined;
    const encoded = try encode(&value, &bytes);
    var restored: Inventory = .{};
    try decode(&restored, encoded);
    try std.testing.expectEqual(a, restored.findDigest(hash).?);
    try std.testing.expectError(error.Invalid, restored.publish(b, "cat"));
    try restored.remove(a);
    try std.testing.expectError(error.Invalid, restored.publish(a, "cat"));
    const c = try restored.reserve();
    try restored.publishVerified(c, "cat", hash);
    try std.testing.expect(c > b);
    try std.testing.expectEqual(c, restored.findDigest(hash).?);
}

test "PCI1 records migrate as unknown fingerprints" {
    const old = "PCI1\x02\x00\x00\x00\x00\x00\x00\x00\x01\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x03cat";
    var value: Inventory = .{};
    try decode(&value, old);
    const record = try value.get(1);
    try std.testing.expect(record.digest == null);
    var buffer: [max_bytes]u8 = undefined;
    const encoded = try encode(&value, &buffer);
    try std.testing.expectEqualStrings("PCI2", encoded[0..4]);
    try decode(&value, encoded);
    try std.testing.expectEqual(@as(u64, 2), value.next_id);
}
