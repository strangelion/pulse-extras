//! Fixed-size, numeric-only session history, written through the private
//! root lease. Old rows expire on the next append, not a background task.
//! The checksum detects accidental corruption; it is not authentication.
const std = @import("std");
const retention = @import("runtime_retention");

pub const capacity = 16;
pub const max_age: u64 = 30 * 24 * 60 * 60;
const row_bytes = 72;
pub const max_bytes = 8 + capacity * row_bytes + 32;

pub const Record = struct {
    stamp: u64 = 0,
    elapsed_ms: u64 = 0,
    attempted: u64 = 0,
    launched: u64 = 0,
    exits: u64 = 0,
    abnormal: u64 = 0,
    denied: u64 = 0,
    last_exit: u64 = 0,
    failed: u64 = 0,

    fn validate(self: Record) !void {
        if (self.stamp == 0 or self.launched > self.attempted or self.abnormal > self.exits or self.last_exit > 0xffffffff or self.failed > 1) return error.InvalidHistory;
    }

    fn values(self: Record) [9]u64 {
        return .{ self.stamp, self.elapsed_ms, self.attempted, self.launched, self.exits, self.abnormal, self.denied, self.last_exit, self.failed };
    }
};

pub const History = struct {
    records: [capacity]Record = @splat(.{}),
    count: usize = 0,

    pub fn append(self: *History, record: Record) !void {
        try record.validate();
        retention.append(Record, &self.records, &self.count, record, max_age) catch return error.InvalidHistory;
    }

    pub fn encode(self: *const History, buffer: []u8) ![]const u8 {
        if (self.count > capacity) return error.InvalidHistory;
        const payload = 8 + self.count * row_bytes;
        if (buffer.len < payload + 32) return error.NoSpaceLeft;
        @memcpy(buffer[0..4], "PDH1");
        std.mem.writeInt(u32, buffer[4..8], @intCast(self.count), .little);
        var pos: usize = 8;
        for (self.records[0..self.count]) |record| {
            try record.validate();
            for (record.values()) |value| {
                std.mem.writeInt(u64, buffer[pos..][0..8], value, .little);
                pos += 8;
            }
        }
        std.crypto.hash.sha2.Sha256.hash(buffer[0..payload], buffer[payload..][0..32], .{});
        return buffer[0 .. payload + 32];
    }

    pub fn decode(bytes: []const u8) !History {
        if (bytes.len < 40 or bytes.len > max_bytes or !std.mem.eql(u8, bytes[0..4], "PDH1")) return error.InvalidHistory;
        const count: usize = std.mem.readInt(u32, bytes[4..8], .little);
        if (count > capacity) return error.InvalidHistory;
        const payload = 8 + count * row_bytes;
        if (bytes.len != payload + 32) return error.InvalidHistory;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(bytes[0..payload], &digest, .{});
        if (!std.mem.eql(u8, &digest, bytes[payload..])) return error.InvalidHistory;
        var result: History = .{ .count = count };
        var pos: usize = 8;
        for (result.records[0..count]) |*record| {
            var values: [9]u64 = undefined;
            for (&values) |*value| {
                value.* = std.mem.readInt(u64, bytes[pos..][0..8], .little);
                pos += 8;
            }
            record.* = .{
                .stamp = values[0],
                .elapsed_ms = values[1],
                .attempted = values[2],
                .launched = values[3],
                .exits = values[4],
                .abnormal = values[5],
                .denied = values[6],
                .last_exit = values[7],
                .failed = values[8],
            };
            try record.validate();
        }
        return result;
    }

    pub fn format(self: *const History, output: []u8) !usize {
        if (self.count > capacity) return error.InvalidHistory;
        var len: usize = 0;
        const header = try std.fmt.bufPrint(output, "\nretained_sessions: {d}\nUTC_seconds elapsed_ms planned_attempted planned_launched exits abnormal denied last_exit failed\n", .{self.count});
        len += header.len;
        for (self.records[0..self.count]) |record| {
            const line = try std.fmt.bufPrint(output[len..], "{d} {d} {d} {d} {d} {d} {d} {d} {d}\n", .{
                record.stamp, record.elapsed_ms, record.attempted, record.launched, record.exits, record.abnormal, record.denied, record.last_exit, record.failed,
            });
            len += line.len;
        }
        return len;
    }
};

test "bounded history rotates, expires and refuses corrupt records" {
    var log: History = .{};
    for (1..21) |n| try log.append(.{ .stamp = n, .exits = n });
    try std.testing.expectEqual(@as(usize, 16), log.count);
    try std.testing.expectEqual(@as(u64, 5), log.records[0].stamp);
    var bytes: [max_bytes]u8 = undefined;
    const encoded = try log.encode(&bytes);
    const decoded = try History.decode(encoded);
    try std.testing.expectEqual(log.count, decoded.count);
    for (log.records[0..log.count], 0..) |record, n| try std.testing.expectEqualDeep(record, decoded.records[n]);
    for (0..encoded.len) |n| try std.testing.expectError(error.InvalidHistory, History.decode(encoded[0..n]));
    bytes[8] ^= 1;
    try std.testing.expectError(error.InvalidHistory, History.decode(encoded));
    try log.append(.{ .stamp = max_age + 21 });
    try std.testing.expectEqual(@as(usize, 1), log.count);
    try log.append(.{ .stamp = 1 });
    try std.testing.expectEqual(@as(usize, 2), log.count);
    try std.testing.expectError(error.InvalidHistory, log.append(.{ .stamp = 1, .abnormal = 2, .exits = 1 }));
    var report: [4096]u8 = undefined;
    try std.testing.expect((try log.format(&report)) > 0);
}
