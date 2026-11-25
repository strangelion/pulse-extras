//! Allocation-free redacted diagnostic ring. A record contains only a fixed
//! event kind and a numeric count. Callers explicitly export if desired.

const std = @import("std");

pub const Kind = enum { admitted, backpressure, cancelled, timeout, output_limit, allocation_limit, io_failure, cleanup_failure, stopped };

pub const Record = struct {
    kind: Kind,
    count: u64,
};

pub const Log = struct {
    const capacity = 64;
    entries: [capacity]Record = undefined,
    head: usize = 0,
    len: usize = 0,
    dropped: usize = 0,

    pub fn add(self: *Log, record: Record) void {
        if (self.len == capacity) {
            self.entries[self.head] = record;
            self.head = (self.head + 1) % capacity;
            self.dropped +|= 1;
            return;
        }
        self.entries[(self.head + self.len) % capacity] = record;
        self.len += 1;
    }

    pub fn get(self: *const Log, index: usize) ?Record {
        if (index >= self.len) return null;
        return self.entries[(self.head + index) % capacity];
    }

    /// Export only typed records; caller owns destination and file rotation.
    /// No heap allocation. An undersized destination fails without mutating log.
    pub fn encode(self: *const Log, buffer: []u8) error{NoSpaceLeft}![]const u8 {
        var used: usize = 0;
        const header = std.fmt.bufPrint(buffer, "pulse-runtime-log-v1 dropped={d}\n", .{self.dropped}) catch return error.NoSpaceLeft;
        used += header.len;
        for (0..self.len) |index| {
            const record = self.get(index).?;
            const line = std.fmt.bufPrint(buffer[used..], "{s} {d}\n", .{ @tagName(record.kind), record.count }) catch return error.NoSpaceLeft;
            used += line.len;
        }
        return buffer[0..used];
    }

    pub fn clear(self: *Log) void {
        self.head = 0;
        self.len = 0;
        self.dropped = 0;
    }
};

test "diagnostics retain only the newest bounded records" {
    var log: Log = .{};
    for (0..1000) |i| log.add(.{ .kind = .admitted, .count = i });
    try std.testing.expectEqual(@as(usize, 64), log.len);
    try std.testing.expectEqual(@as(usize, 936), log.dropped);
    try std.testing.expectEqual(@as(u64, 936), log.get(0).?.count);
    try std.testing.expectEqual(@as(u64, 999), log.get(63).?.count);
    try std.testing.expect(log.get(64) == null);
    log.clear();
    try std.testing.expect(log.get(0) == null);
}

test "diagnostic export is bounded and does not mutate records on failure" {
    var log: Log = .{};
    log.add(.{ .kind = .timeout, .count = 1 });
    var small: [4]u8 = undefined;
    try std.testing.expectError(error.NoSpaceLeft, log.encode(&small));
    var buffer: [128]u8 = undefined;
    try std.testing.expectEqualStrings("pulse-runtime-log-v1 dropped=0\ntimeout 1\n", try log.encode(&buffer));
    try std.testing.expectEqual(@as(usize, 1), log.len);
}
