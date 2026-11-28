//! Persistent managed-asset identity inventory. No external paths, filesystem
//! traversal or image decode. Serialized worker; stable IDs never reused.
const std = @import("std");
const fingerprint = @import("pet_fingerprint.zig");

pub const max_entries = 512;
pub const max_bytes = 16 + max_entries * 170;
pub const Error = error{ Invalid, Full, IdExhausted, UnknownAsset, InvalidRecord, BufferTooSmall, DuplicateContent, NeedsRevalidation };

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
    secondary: ?fingerprint.Secondary = null,

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

    /// Both inventories are caller-owned and distinct. Preserve pending
    /// reservations for staged transactions; decodeScratch clears them.
    pub fn copyFrom(self: *Inventory, source: *const Inventory) void {
        @memcpy(self.entries[0..source.count], source.entries[0..source.count]);
        self.next_id = source.next_id;
        self.pending_id = source.pending_id;
        self.count = source.count;
    }

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

    // Equal primary alone is not proof of identical content. Old records
    // without a secondary must be explicitly revalidated before dedup.
    pub fn findPair(self: *const Inventory, pair: fingerprint.Pair) Error!?u64 {
        var unknown = false;
        for (self.entries[0..self.count]) |entry| {
            if (entry.digest) |primary| {
                if (!std.mem.eql(u8, &primary, &pair.primary)) continue;
                if (entry.secondary) |secondary| {
                    if (std.mem.eql(u8, &secondary, &pair.secondary)) return entry.id;
                } else unknown = true;
            }
        }
        if (unknown) return error.NeedsRevalidation;
        return null;
    }

    pub fn publishPair(self: *Inventory, id: u64, source: []const u8, pair: fingerprint.Pair) Error!void {
        return self.publishInternal(id, source, pair.primary, pair.secondary);
    }

    pub fn publish(self: *Inventory, id: u64, source: []const u8) Error!void {
        return self.publishInternal(id, source, null, null);
    }

    pub fn publishVerified(self: *Inventory, id: u64, source: []const u8, value: fingerprint.Digest) Error!void {
        return self.publishInternal(id, source, value, null);
    }

    fn publishInternal(self: *Inventory, id: u64, source: []const u8, value: ?fingerprint.Digest, secondary: ?fingerprint.Secondary) Error!void {
        if (id == 0 or self.pending_id != id or id != self.next_id - 1) return error.Invalid;
        if (value) |hash| {
            if (secondary) |second| {
                if (try self.findPair(.{ .primary = hash, .secondary = second }) != null) return error.DuplicateContent;
            } else if (self.findDigest(hash) != null) return error.DuplicateContent;
        }
        if (self.count == max_entries) return error.Full;
        if (self.count != 0 and id <= self.entries[self.count - 1].id) return error.Invalid;
        var record = try Record.init(id, source);
        record.digest = value;
        record.secondary = secondary;
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

// PCI3: PCI2 fields with digest kind 0/1/2 (none/primary/pair).
// PCI1 is readable but its missing fingerprints are never assumed verified.
// No mutable metadata or filesystem path in the inventory.
pub fn encode(value: *const Inventory, out: []u8) Error![]const u8 {
    if (value.next_id == 0 or value.count > max_entries) return error.InvalidRecord;
    var needed: usize = 16;
    var last: u64 = 0;
    for (value.entries[0..value.count]) |*entry| {
        if (entry.len > 64 or !validSource(entry.sourceId()) or entry.id <= last or entry.id >= value.next_id) return error.InvalidRecord;
        last = entry.id;
        if (entry.secondary != null and entry.digest == null) return error.InvalidRecord;
        needed += 10 + @as(usize, entry.len) + @as(usize, if (entry.digest != null) 32 else 0) + @as(usize, if (entry.secondary != null) 64 else 0);
    }
    if (out.len < needed) return error.BufferTooSmall;
    @memcpy(out[0..4], "PCI3");
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
        out[pos] = if (entry.secondary != null) 2 else @intFromBool(entry.digest != null);
        pos += 1;
        if (entry.digest) |hash| {
            @memcpy(out[pos .. pos + 32], &hash);
            pos += 32;
        }
        if (entry.secondary) |second| {
            @memcpy(out[pos .. pos + 64], &second);
            pos += 64;
        }
    }
    return out[0..pos];
}

// Decode into a staged value, commit only on exact, valid end of record.
pub fn decode(value: *Inventory, input: []const u8) Error!void {
    var candidate: Inventory = undefined;
    try decodeScratch(&candidate, input);
    value.copyFrom(&candidate);
}

/// Worker-owned, unpublished scratch only. On error its contents may be
/// partial; never call this directly on the authoritative inventory.
pub fn decodeScratch(candidate: *Inventory, input: []const u8) Error!void {
    if (input.len < 16 or input.len > max_bytes) return error.InvalidRecord;
    const legacy = std.mem.eql(u8, input[0..4], "PCI1");
    const dual = std.mem.eql(u8, input[0..4], "PCI3");
    if (!legacy and !dual and !std.mem.eql(u8, input[0..4], "PCI2")) return error.InvalidRecord;
    candidate.next_id = get64(input[4..12]);
    candidate.count = 0;
    candidate.pending_id = null;
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
            if (pos == input.len or input[pos] > @as(u8, if (dual) 2 else 1)) return error.InvalidRecord;
            const kind = input[pos];
            pos += 1;
            if (kind != 0) {
                if (input.len - pos < 32) return error.InvalidRecord;
                const hash: fingerprint.Digest = input[pos..][0..32].*;
                record.digest = hash;
                pos += 32;
                if (kind == 2) {
                    if (input.len - pos < 64) return error.InvalidRecord;
                    const second: fingerprint.Secondary = input[pos..][0..64].*;
                    if ((candidate.findPair(.{ .primary = hash, .secondary = second }) catch return error.InvalidRecord) != null) return error.InvalidRecord;
                    record.secondary = second;
                    pos += 64;
                } else if (candidate.findDigest(hash) != null) return error.InvalidRecord;
            }
        }
        candidate.entries[candidate.count] = record;
        candidate.count += 1;
        last = id;
    }
    if (pos != input.len) return error.InvalidRecord;
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
    try std.testing.expectEqualStrings("PCI3", encoded[0..4]);
    try decode(&value, encoded);
    try std.testing.expectEqual(@as(u64, 2), value.next_id);
}

test "simulated primary collision preserves both assets and rejects equal pairs" {
    var index: Inventory = .{};
    const first: fingerprint.Pair = .{ .primary = @splat(1), .secondary = @splat(2) };
    const second: fingerprint.Pair = .{ .primary = @splat(1), .secondary = @splat(3) };
    const a = try index.reserve();
    try index.publishPair(a, "cat", first);
    const b = try index.reserve();
    try index.publishPair(b, "fox", second);
    try std.testing.expectEqual(a, (try index.findPair(first)).?);
    try std.testing.expectEqual(b, (try index.findPair(second)).?);
    const c = try index.reserve();
    try std.testing.expectError(error.DuplicateContent, index.publishPair(c, "cat", first));
    var buffer: [max_bytes]u8 = undefined;
    const encoded = try encode(&index, &buffer);
    var restored: Inventory = .{};
    try decode(&restored, encoded);
    try std.testing.expectEqual(b, (try restored.findPair(second)).?);
    var old: Inventory = .{};
    const legacy = try old.reserve();
    try old.publishVerified(legacy, "cat", first.primary);
    try std.testing.expectError(error.NeedsRevalidation, old.findPair(first));
}
