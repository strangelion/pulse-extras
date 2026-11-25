//! Read-only recovery classification. A normal top-level entry is not a
//! verified package, and these counts never authorize deletion or adoption.
const std = @import("std");
const inventory = @import("pet_inventory.zig");

pub const max_rows = 4096;
pub const Kind = enum(u32) { unknown, package, pending, preference, inventory, inventory_pending, lock };
pub const Row = extern struct {
    id: u64,
    kind: u32,
    attributes: u32,
};
pub const Report = struct {
    registered: usize = 0,
    missing: usize = 0,
    orphan_packages: usize = 0,
    pending_directories: usize = 0,
    pending_records: usize = 0,
    orphan_preferences: usize = 0,
    invalid: usize = 0,
    unknown: usize = 0,
    unreserved: usize = 0,
};

pub fn classify(index: *const inventory.Inventory, rows: []const Row) !Report {
    if (rows.len > max_rows or index.count > inventory.max_entries) return error.InvalidScan;
    var report: Report = .{};
    var seen: [inventory.max_entries]bool = @splat(false);
    for (rows) |row| {
        if (row.kind > @backingInt(Kind.lock)) return error.InvalidScan;
        const kind: Kind = @fromBackingInt(row.kind);
        const directory = (row.attributes & 0x10) != 0;
        const reparse = (row.attributes & 0x400) != 0;
        if ((kind == .package or kind == .pending or kind == .preference) != (row.id != 0)) return error.InvalidScan;
        if (row.id != 0 and row.id >= index.next_id) report.unreserved += 1;
        if (reparse) {
            report.invalid += 1;
            continue;
        }
        switch (kind) {
            .unknown => report.unknown += 1,
            .package => {
                if (!directory) {
                    report.invalid += 1;
                    continue;
                }
                var found = false;
                for (index.entries[0..index.count], 0..) |entry, n| {
                    if (entry.id != row.id) continue;
                    if (seen[n]) return error.InvalidScan;
                    seen[n] = true;
                    found = true;
                    break;
                }
                if (found) report.registered += 1 else report.orphan_packages += 1;
            },
            .pending => if (directory) {
                report.pending_directories += 1;
            } else {
                report.pending_records += 1;
            },
            .preference => {
                if (directory) {
                    report.invalid += 1;
                    continue;
                }
                _ = index.get(row.id) catch {
                    report.orphan_preferences += 1;
                    continue;
                };
            },
            .inventory_pending => if (directory) {
                report.invalid += 1;
            } else {
                report.pending_records += 1;
            },
            .inventory, .lock => if (directory) {
                report.invalid += 1;
            },
        }
    }
    report.missing = index.count - report.registered;
    return report;
}

test "classify top-level recovery states without modifying inventory" {
    var index: inventory.Inventory = .{};
    try index.publish(try index.reserve(), "cat");
    try index.publish(try index.reserve(), "dog");
    const rows = [_]Row{
        .{ .id = 1, .kind = @backingInt(Kind.package), .attributes = 0x10 },
        .{ .id = 2, .kind = @backingInt(Kind.package), .attributes = 0x410 },
        .{ .id = 3, .kind = @backingInt(Kind.package), .attributes = 0x10 },
        .{ .id = 4, .kind = @backingInt(Kind.pending), .attributes = 0x10 },
        .{ .id = 1, .kind = @backingInt(Kind.pending), .attributes = 0x80 },
        .{ .id = 5, .kind = @backingInt(Kind.preference), .attributes = 0x80 },
        .{ .id = 0, .kind = @backingInt(Kind.unknown), .attributes = 0x80 },
    };
    const result = try classify(&index, &rows);
    try std.testing.expectEqualDeep(Report{
        .registered = 1,
        .missing = 1,
        .orphan_packages = 1,
        .pending_directories = 1,
        .pending_records = 1,
        .orphan_preferences = 1,
        .invalid = 1,
        .unknown = 1,
        .unreserved = 3,
    }, result);
    try std.testing.expectEqual(@as(usize, 2), index.count);
    try std.testing.expectEqual(@as(u64, 3), index.next_id);
    try std.testing.expectError(error.InvalidScan, classify(&index, &.{ rows[0], rows[0] }));
}
