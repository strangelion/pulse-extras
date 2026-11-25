//! Read-only recovery classification. A normal top-level entry is not a
//! verified package, and these counts never authorize deletion or adoption.
const std = @import("std");
const inventory = @import("pet_inventory.zig");
const receipt = @import("pet_removal_receipt.zig");

pub const max_rows = 4096;
pub const Kind = enum(u32) { unknown, package, pending, preference, inventory, inventory_pending, lock, quarantine, receipt, receipt_pending, cleanup, cleanup_pending, market_root };
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
    quarantined_registered: usize = 0,
    quarantined_removed: usize = 0,
    quarantine_registered_bytes: u64 = 0,
    quarantine_removed_bytes: u64 = 0,
    quarantine_unmeasured: usize = 0,
    receipts: usize = 0,
    receipt_pending: usize = 0,
    cleanup_markers: usize = 0,
    cleanup_pending: usize = 0,
};

pub fn classify(index: *const inventory.Inventory, rows: []const Row) !Report {
    if (rows.len > max_rows or index.count > inventory.max_entries) return error.InvalidScan;
    var report: Report = .{};
    var seen: [inventory.max_entries]bool = @splat(false);
    for (rows) |row| {
        if (row.kind > @backingInt(Kind.market_root)) return error.InvalidScan;
        const kind: Kind = @fromBackingInt(row.kind);
        const directory = (row.attributes & 0x10) != 0;
        const reparse = (row.attributes & 0x400) != 0;
        if ((kind == .package or kind == .pending or kind == .preference or kind == .quarantine or kind == .receipt or kind == .receipt_pending or kind == .cleanup or kind == .cleanup_pending) != (row.id != 0)) return error.InvalidScan;
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
            .quarantine => {
                if (!directory) {
                    report.invalid += 1;
                    continue;
                }
                if (index.get(row.id)) |_| {
                    report.quarantined_registered += 1;
                } else |_| {
                    report.quarantined_removed += 1;
                }
            },
            .receipt => if (directory) {
                report.invalid += 1;
            } else {
                report.receipts += 1;
            },
            .receipt_pending => if (directory) {
                report.invalid += 1;
            } else {
                report.receipt_pending += 1;
            },
            .cleanup => if (directory) {
                report.invalid += 1;
            } else {
                report.cleanup_markers += 1;
            },
            .cleanup_pending => if (directory) {
                report.invalid += 1;
            } else {
                report.cleanup_pending += 1;
            },
            .inventory_pending => if (directory) {
                report.invalid += 1;
            } else {
                report.pending_records += 1;
            },
            .market_root => if (!directory) {
                report.invalid += 1;
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

pub const RemovalState = enum { normal, quarantined };

// Inspect the exact fixed ID and reject ambiguous/interrupted states rather
// than inferring authorization from aggregate scan counts.
pub fn removalState(rows: []const Row, id: u64) !RemovalState {
    if (id == 0 or rows.len > max_rows) return error.InvalidScan;
    var normal: bool = false;
    var quarantined: bool = false;
    var has_receipt: bool = false;
    for (rows) |row| {
        if (row.kind > @backingInt(Kind.market_root)) return error.InvalidScan;
        const kind: Kind = @fromBackingInt(row.kind);
        if (kind == .inventory_pending) return error.RecoveryRequired;
        if (row.id != id) continue;
        if ((row.attributes & 0x400) != 0 or kind == .pending or kind == .receipt_pending or kind == .cleanup or kind == .cleanup_pending) return error.RecoveryRequired;
        const directory = (row.attributes & 0x10) != 0;
        switch (kind) {
            .package => {
                if (!directory or normal) return error.RecoveryRequired;
                normal = true;
            },
            .quarantine => {
                if (!directory or quarantined) return error.RecoveryRequired;
                quarantined = true;
            },
            .preference => if (directory) return error.RecoveryRequired,
            .receipt => {
                if (directory or has_receipt) return error.RecoveryRequired;
                has_receipt = true;
            },
            else => return error.InvalidScan,
        }
    }
    if (normal == quarantined or (normal and has_receipt)) return error.RecoveryRequired;
    return if (normal) .normal else .quarantined;
}

test "removal preflight rejects conflicts pending records and reparse directories" {
    const normal: Row = .{ .id = 1, .kind = @backingInt(Kind.package), .attributes = 0x10 };
    const quarantine: Row = .{ .id = 1, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 };
    const pending: Row = .{ .id = 1, .kind = @backingInt(Kind.pending), .attributes = 0x80 };
    const pending_index: Row = .{ .id = 0, .kind = @backingInt(Kind.inventory_pending), .attributes = 0x80 };
    const link: Row = .{ .id = 1, .kind = @backingInt(Kind.package), .attributes = 0x410 };
    try std.testing.expectEqual(RemovalState.normal, try removalState(&.{normal}, 1));
    try std.testing.expectEqual(RemovalState.quarantined, try removalState(&.{quarantine}, 1));
    try std.testing.expectError(error.RecoveryRequired, removalState(&.{ normal, quarantine }, 1));
    try std.testing.expectError(error.RecoveryRequired, removalState(&.{ normal, pending }, 1));
    try std.testing.expectError(error.RecoveryRequired, removalState(&.{ normal, pending_index }, 1));
    try std.testing.expectError(error.RecoveryRequired, removalState(&.{link}, 1));
    try std.testing.expectError(error.RecoveryRequired, removalState(&.{}, 1));
    try std.testing.expectError(error.RecoveryRequired, removalState(&.{ normal, normal }, 1));
}

test "quarantine distinguishes interrupted removal from unregistered retained copies" {
    var index: inventory.Inventory = .{};
    try index.publish(try index.reserve(), "cat");
    try index.publish(try index.reserve(), "dog");
    try index.remove(2);
    const report = try classify(&index, &.{
        .{ .id = 1, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 },
        .{ .id = 2, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 },
    });
    try std.testing.expectEqual(@as(usize, 1), report.missing);
    try std.testing.expectEqual(@as(usize, 1), report.quarantined_registered);
    try std.testing.expectEqual(@as(usize, 1), report.quarantined_removed);
    try std.testing.expectEqual(@as(usize, 0), report.orphan_packages);
}

pub const RegisteredState = enum { normal, interrupted_removal, missing, blocked };
pub const RegisteredDetail = struct {
    id: u64,
    state: RegisteredState,
};

pub const max_quarantine_details = 64;
pub const QuarantineState = enum { interrupted_removal, unregistered_retained, blocked };
pub const ReceiptState = enum { absent, matched_identity, invalid, unavailable, cleanup_started };
pub const QuarantineDetail = struct {
    id: u64,
    state: QuarantineState,
    logical_bytes: ?u64 = null,
    receipt_state: ReceiptState = .absent,
    cleanup_receipt: ?receipt.Receipt = null,
};

pub const Snapshot = struct {
    summary: Report = .{},
    count: usize = 0,
    details: [inventory.max_entries]RegisteredDetail = undefined,
    quarantine_total: usize = 0,
    quarantine_count: usize = 0,
    quarantine: [max_quarantine_details]QuarantineDetail = undefined,

    // Keep the lowest IDs in stable order, independent of native enumeration.
    // Report the full entry count separately so a bounded list is explicit.
    fn addQuarantine(self: *Snapshot, detail: QuarantineDetail) void {
        self.quarantine_total += 1;
        var pos: usize = 0;
        while (pos < self.quarantine_count and self.quarantine[pos].id < detail.id) : (pos += 1) {}
        if (pos < self.quarantine_count and self.quarantine[pos].id == detail.id) {
            self.quarantine[pos].state = .blocked;
            return;
        }
        if (pos == self.quarantine.len) return;
        self.quarantine_count = @min(self.quarantine_count + 1, self.quarantine.len);
        var i = self.quarantine_count - 1;
        while (i > pos) : (i -= 1) self.quarantine[i] = self.quarantine[i - 1];
        self.quarantine[pos] = detail;
    }

    pub fn stateFor(self: *const Snapshot, id: u64) ?RegisteredState {
        for (self.details[0..self.count]) |detail| {
            if (detail.id == id) return detail.state;
        }
        return null;
    }
};

// Keep registered IDs and a separately bounded quarantine list. Neither
// diagnostic snapshot proves contents, provenance or authority to mutate.
pub fn hasCleanup(rows: []const Row, id: u64) bool {
    for (rows) |row| {
        if (row.id == id and (row.kind == @backingInt(Kind.cleanup) or row.kind == @backingInt(Kind.cleanup_pending))) return true;
    }
    return false;
}

pub fn hasReceipt(rows: []const Row, id: u64) bool {
    for (rows) |row| {
        if (row.id == id and (row.kind == @backingInt(Kind.receipt) or row.kind == @backingInt(Kind.receipt_pending))) return true;
    }
    return false;
}

pub fn inspect(index: *const inventory.Inventory, rows: []const Row) !Snapshot {
    var result: Snapshot = .{ .summary = try classify(index, rows) };
    var global_pending = false;
    for (rows) |row| {
        if (row.kind == @backingInt(Kind.inventory_pending)) global_pending = true;
    }
    for (index.entries[0..index.count]) |record| {
        var has_target = false;
        for (rows) |row| {
            if (row.id == record.id and (row.kind == @backingInt(Kind.package) or row.kind == @backingInt(Kind.quarantine) or row.kind == @backingInt(Kind.pending))) has_target = true;
        }
        const state: RegisteredState = if (record.digest == null or record.secondary == null or global_pending or hasReceipt(rows, record.id) or hasCleanup(rows, record.id))
            .blocked
        else if (removalState(rows, record.id)) |status|
            switch (status) {
                .normal => .normal,
                .quarantined => .interrupted_removal,
            }
        else |_| if (has_target) .blocked else .missing;
        result.details[result.count] = .{ .id = record.id, .state = state };
        result.count += 1;
    }
    for (rows) |row| {
        if (row.kind != @backingInt(Kind.quarantine)) continue;
        var state: QuarantineState = .blocked;
        if (row.id < index.next_id and (row.attributes & 0x410) == 0x10) {
            if (result.stateFor(row.id)) |registered| {
                if (registered == .interrupted_removal) state = .interrupted_removal;
            } else if ((removalState(rows, row.id) catch .normal) == .quarantined) {
                state = .unregistered_retained;
            }
        }
        result.addQuarantine(.{ .id = row.id, .state = state });
    }
    return result;
}

test "registered recovery details distinguish interrupted missing blocked and normal IDs" {
    var index: inventory.Inventory = .{};
    for (0..5) |n| {
        const byte: u8 = @intCast(n + 1);
        try index.publishPair(try index.reserve(), "cat", .{ .primary = @splat(byte), .secondary = @splat(byte) });
    }
    try index.publish(try index.reserve(), "legacy");
    const rows = [_]Row{
        .{ .id = 1, .kind = @backingInt(Kind.package), .attributes = 0x10 },
        .{ .id = 2, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 },
        .{ .id = 4, .kind = @backingInt(Kind.package), .attributes = 0x410 },
        .{ .id = 5, .kind = @backingInt(Kind.package), .attributes = 0x10 },
        .{ .id = 5, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 },
        .{ .id = 6, .kind = @backingInt(Kind.package), .attributes = 0x10 },
        .{ .id = 7, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 },
    };
    const snapshot = try inspect(&index, &rows);
    try std.testing.expectEqual(@as(usize, 6), snapshot.count);
    try std.testing.expectEqual(RegisteredState.normal, snapshot.stateFor(1).?);
    try std.testing.expectEqual(RegisteredState.interrupted_removal, snapshot.stateFor(2).?);
    try std.testing.expectEqual(RegisteredState.missing, snapshot.stateFor(3).?);
    try std.testing.expectEqual(RegisteredState.blocked, snapshot.stateFor(4).?);
    try std.testing.expectEqual(RegisteredState.blocked, snapshot.stateFor(5).?);
    try std.testing.expectEqual(RegisteredState.blocked, snapshot.stateFor(6).?);
    try std.testing.expect(snapshot.stateFor(7) == null);
    try std.testing.expectEqual(@as(usize, 1), snapshot.summary.quarantined_removed);
    const pending = try inspect(&index, &.{ .{ .id = 1, .kind = @backingInt(Kind.package), .attributes = 0x10 }, .{ .id = 0, .kind = @backingInt(Kind.inventory_pending), .attributes = 0x80 } });
    try std.testing.expectEqual(RegisteredState.blocked, pending.stateFor(1).?);
}

test "quarantine details separate registered unregistered and unsafe entries" {
    var index: inventory.Inventory = .{};
    try index.publishPair(try index.reserve(), "cat", .{ .primary = @splat(1), .secondary = @splat(2) });
    try index.publish(try index.reserve(), "removed");
    try index.remove(2);
    const snapshot = try inspect(&index, &.{
        .{ .id = 3, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 },
        .{ .id = 2, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 },
        .{ .id = 1, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 },
        .{ .id = 4, .kind = @backingInt(Kind.quarantine), .attributes = 0x410 },
    });
    try std.testing.expectEqual(@as(usize, 4), snapshot.quarantine_count);
    try std.testing.expectEqual(@as(u64, 1), snapshot.quarantine[0].id);
    try std.testing.expectEqual(QuarantineState.interrupted_removal, snapshot.quarantine[0].state);
    try std.testing.expectEqual(QuarantineState.unregistered_retained, snapshot.quarantine[1].state);
    try std.testing.expectEqual(QuarantineState.blocked, snapshot.quarantine[2].state);
    try std.testing.expectEqual(QuarantineState.blocked, snapshot.quarantine[3].state);
    try std.testing.expect(snapshot.quarantine[1].logical_bytes == null);
}

test "quarantine detail cap retains smallest IDs and reports omitted entries" {
    var snapshot: Snapshot = .{};
    for (0..max_quarantine_details + 5) |n| {
        snapshot.addQuarantine(.{ .id = max_quarantine_details + 5 - n, .state = .blocked });
    }
    try std.testing.expectEqual(@as(usize, max_quarantine_details + 5), snapshot.quarantine_total);
    try std.testing.expectEqual(@as(usize, max_quarantine_details), snapshot.quarantine_count);
    for (snapshot.quarantine[0..snapshot.quarantine_count], 1..) |detail, id| {
        try std.testing.expectEqual(@as(u64, id), detail.id);
    }
}

test "receipt names block registered recovery and pending receipt blocks removal" {
    var index: inventory.Inventory = .{};
    try index.publishPair(try index.reserve(), "cat", .{ .primary = @splat(1), .secondary = @splat(2) });
    const quarantine: Row = .{ .id = 1, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 };
    const receipt_row: Row = .{ .id = 1, .kind = @backingInt(Kind.receipt), .attributes = 0x80 };
    const pending: Row = .{ .id = 1, .kind = @backingInt(Kind.receipt_pending), .attributes = 0x80 };
    const snapshot = try inspect(&index, &.{ quarantine, receipt_row });
    try std.testing.expectEqual(RegisteredState.blocked, snapshot.stateFor(1).?);
    try std.testing.expectEqual(QuarantineState.blocked, snapshot.quarantine[0].state);
    try std.testing.expectEqual(@as(usize, 1), snapshot.summary.receipts);
    try std.testing.expectError(error.RecoveryRequired, removalState(&.{ quarantine, pending }, 1));
    try std.testing.expectError(error.RecoveryRequired, removalState(&.{ quarantine, receipt_row, receipt_row }, 1));
    try index.remove(1);
    const removed = try inspect(&index, &.{ quarantine, receipt_row });
    try std.testing.expectEqual(QuarantineState.unregistered_retained, removed.quarantine[0].state);
}

test "cleanup intent blocks all subsequent namespace operations" {
    var index: inventory.Inventory = .{};
    try index.publishPair(try index.reserve(), "cat", .{ .primary = @splat(1), .secondary = @splat(2) });
    try index.remove(1);
    const dir: Row = .{ .id = 1, .kind = @backingInt(Kind.quarantine), .attributes = 0x10 };
    const marker: Row = .{ .id = 1, .kind = @backingInt(Kind.cleanup), .attributes = 0x80 };
    const pending: Row = .{ .id = 1, .kind = @backingInt(Kind.cleanup_pending), .attributes = 0x80 };
    try std.testing.expectError(error.RecoveryRequired, removalState(&.{ dir, marker }, 1));
    try std.testing.expectError(error.RecoveryRequired, removalState(&.{ dir, pending }, 1));
    const snapshot = try inspect(&index, &.{ dir, marker });
    try std.testing.expectEqual(@as(usize, 1), snapshot.summary.cleanup_markers);
    try std.testing.expectEqual(QuarantineState.blocked, snapshot.quarantine[0].state);
}
