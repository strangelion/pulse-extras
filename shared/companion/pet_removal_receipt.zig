//! Immutable removal receipt codec. A valid checksum is not authentication.
//! No path, deletion authority, or automatic adoption is represented here.
const std = @import("std");
const inventory = @import("pet_inventory.zig");
const Sha256 = std.crypto.hash.sha2.Sha256;
const fingerprint = @import("pet_fingerprint.zig");

pub const encoded_size = 221;
const payload_size = 189;
pub const Receipt = struct {
    record: inventory.Record,
    volume: u32,
    file_index: u64,

    pub fn verifyPair(self: Receipt, actual: fingerprint.Pair) !void {
        const primary = self.record.digest orelse return error.InvalidReceipt;
        const secondary = self.record.secondary orelse return error.InvalidReceipt;
        if (!std.mem.eql(u8, &primary, &actual.primary) or !std.mem.eql(u8, &secondary, &actual.secondary)) return error.ContentChanged;
    }

    pub fn encode(self: Receipt, out: *[encoded_size]u8) !void {
        if (self.record.id == 0 or self.record.len == 0 or self.record.len > self.record.source.len or self.file_index == 0) return error.InvalidReceipt;
        if (!inventory.validSource(self.record.sourceId())) return error.InvalidReceipt;
        const primary = self.record.digest orelse return error.InvalidReceipt;
        const secondary = self.record.secondary orelse return error.InvalidReceipt;
        out.* = @splat(0);
        @memcpy(out[0..4], "PRC1");
        put64(out[4..12], self.record.id);
        out[12] = self.record.len;
        @memcpy(out[13..][0..self.record.len], self.record.sourceId());
        @memcpy(out[77..109], &primary);
        @memcpy(out[109..173], &secondary);
        put64(out[173..181], self.volume);
        put64(out[181..189], self.file_index);
        Sha256.hash(out[0..payload_size], out[payload_size..encoded_size], .{});
    }

    pub fn decode(bytes: []const u8, expected_id: u64) !Receipt {
        if (bytes.len != encoded_size or !std.mem.eql(u8, bytes[0..4], "PRC1")) return error.InvalidReceipt;
        var hash: [32]u8 = undefined;
        Sha256.hash(bytes[0..payload_size], &hash, .{});
        if (!std.mem.eql(u8, &hash, bytes[payload_size..])) return error.InvalidReceipt;
        const id = get64(bytes[4..12]);
        const len: usize = bytes[12];
        const volume = get64(bytes[173..181]);
        const file_index = get64(bytes[181..189]);
        if (id == 0 or id != expected_id or len == 0 or len > 64 or volume > std.math.maxInt(u32) or file_index == 0) return error.InvalidReceipt;
        for (bytes[13 + len .. 77]) |ch| {
            if (ch != 0) return error.InvalidReceipt;
        }
        var record = inventory.Record.init(id, bytes[13..][0..len]) catch return error.InvalidReceipt;
        record.digest = bytes[77..109].*;
        record.secondary = bytes[109..173].*;
        return .{ .record = record, .volume = @intCast(volume), .file_index = file_index };
    }
};

fn put64(out: []u8, value: u64) void {
    for (0..8) |i| out[i] = @truncate(value >> @as(u6, @intCast(i * 8)));
}

fn get64(bytes: []const u8) u64 {
    var result: u64 = 0;
    for (0..8) |i| result |= @as(u64, bytes[i]) << @as(u6, @intCast(i * 8));
    return result;
}

test "receipt binds stable ID paired fingerprints and directory identity" {
    var record = try inventory.Record.init(17, "cat");
    record.digest = @splat(3);
    record.secondary = @splat(9);
    const receipt: Receipt = .{ .record = record, .volume = 42, .file_index = 1234 };
    var bytes: [encoded_size]u8 = undefined;
    try receipt.encode(&bytes);
    try std.testing.expectEqualDeep(receipt, try Receipt.decode(&bytes, 17));
    try std.testing.expectError(error.InvalidReceipt, Receipt.decode(&bytes, 18));
    try std.testing.expectError(error.InvalidReceipt, Receipt.decode(bytes[0 .. bytes.len - 1], 17));
    bytes[77] ^= 1;
    try std.testing.expectError(error.InvalidReceipt, Receipt.decode(&bytes, 17));
    var legacy = receipt;
    legacy.record.secondary = null;
    try std.testing.expectError(error.InvalidReceipt, legacy.encode(&bytes));
}

test "cleanup preflight requires both independent content digests" {
    var record = try inventory.Record.init(9, "cat");
    record.digest = @splat(3);
    record.secondary = @splat(7);
    var value: Receipt = .{ .record = record, .volume = 1, .file_index = 2 };
    const pair: fingerprint.Pair = .{ .primary = @splat(3), .secondary = @splat(7) };
    try value.verifyPair(pair);
    try std.testing.expectError(error.ContentChanged, value.verifyPair(.{ .primary = @splat(4), .secondary = pair.secondary }));
    try std.testing.expectError(error.ContentChanged, value.verifyPair(.{ .primary = pair.primary, .secondary = @splat(8) }));
    value.record.secondary = null;
    try std.testing.expectError(error.InvalidReceipt, value.verifyPair(pair));
}
