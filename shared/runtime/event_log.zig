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
