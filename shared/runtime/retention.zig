//! In-memory retention policy for caller-owned, already validated records.
//! No filesystem access, timers, allocation or global state. Records are
//! retained in insertion order; a backwards wall-clock jump never expires
//! records from the future. The caller owns persistence and locking.
const std = @import("std");

/// T must expose a u64 stamp in seconds. Validate product-specific fields
/// before calling. On invalid capacity/count/stamp leave storage unchanged.
pub fn append(comptime T: type, records: []T, count: *usize, record: T, max_age: u64) error{InvalidRetention}!void {
    if (records.len == 0 or count.* > records.len or record.stamp == 0) return error.InvalidRetention;
    for (records[0..count.*]) |previous| {
        if (previous.stamp == 0) return error.InvalidRetention;
    }
    var kept: usize = 0;
    for (records[0..count.*]) |previous| {
        if (record.stamp >= previous.stamp and record.stamp - previous.stamp > max_age) continue;
        records[kept] = previous;
        kept += 1;
    }
    if (kept == records.len) {
        std.mem.copyForwards(T, records[0 .. kept - 1], records[1..kept]);
        kept -= 1;
    }
    records[kept] = record;
    count.* = kept + 1;
}

test "retention expires strictly older entries, rotates and preserves future records" {
    const Entry = struct { stamp: u64, value: u32 = 0 };
    var records: [3]Entry = undefined;
    var count: usize = 0;
    try append(Entry, &records, &count, .{ .stamp = 1 }, 10);
    try append(Entry, &records, &count, .{ .stamp = 11 }, 10);
    try std.testing.expectEqual(@as(usize, 2), count);
    try append(Entry, &records, &count, .{ .stamp = 12 }, 10);
    try std.testing.expectEqual(@as(usize, 2), count);
    try std.testing.expectEqual(@as(u64, 11), records[0].stamp);
    try append(Entry, &records, &count, .{ .stamp = 2, .value = 9 }, 10);
    try append(Entry, &records, &count, .{ .stamp = 3 }, 10);
    try std.testing.expectEqual(@as(usize, 3), count);
    try std.testing.expectEqual(@as(u64, 12), records[0].stamp);
    try std.testing.expectEqual(@as(u32, 9), records[1].value);
}

test "invalid retention inputs do not mutate and a one-entry store rotates" {
    const Entry = struct { stamp: u64 };
    var records = [_]Entry{.{ .stamp = 10 }};
    var count: usize = 1;
    try std.testing.expectError(error.InvalidRetention, append(Entry, &records, &count, .{ .stamp = 0 }, 10));
    try std.testing.expectEqual(@as(u64, 10), records[0].stamp);
    count = 2;
    try std.testing.expectError(error.InvalidRetention, append(Entry, &records, &count, .{ .stamp = 11 }, 10));
    count = 1;
    try append(Entry, &records, &count, .{ .stamp = 11 }, 10);
    try std.testing.expectEqual(@as(u64, 11), records[0].stamp);
    try std.testing.expectEqual(@as(usize, 1), count);
    var empty: [0]Entry = .{};
    count = 0;
    try std.testing.expectError(error.InvalidRetention, append(Entry, &empty, &count, .{ .stamp = 1 }, 10));
}
