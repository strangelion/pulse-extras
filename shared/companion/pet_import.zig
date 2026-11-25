//! Serialized worker-side import transaction. The backend provides a
//! bounded approved helper and durable atomic inventory replacement.
const std = @import("std");
const inventory = @import("pet_inventory.zig");
const fingerprint = @import("pet_fingerprint.zig");

pub const Result = union(enum) { existing: u64, imported: u64 };
pub const Fault = enum { reservation_save, stage, inventory_commit };

pub const Coordinator = struct {
    index: inventory.Inventory = .{},
    fault: ?Fault = null,
    recovery_id: ?u64 = null,

    // Backend methods: probe(source, source_id) -> digest; save(index);
    // stage(source, source_id, id, digest). A successful stage must mean
    // verified final directory published and helper exit confirmed.
    // No UI calls. No automatic retry after an ambiguous filesystem change.
    pub fn importPackage(self: *Coordinator, backend: anytype, source: []const u8, source_id: []const u8) !Result {
        if (self.fault != null) return error.RecoveryRequired;
        if (!inventory.validSource(source_id)) return error.Invalid;
        const digest = try backend.probe(source, source_id);
        if (try self.index.findPair(digest)) |id| return .{ .existing = id };

        var reserved = self.index;
        const id = try reserved.reserve();
        backend.save(&reserved) catch |err| {
            self.fault = .reservation_save;
            self.recovery_id = id;
            return err;
        };
        self.index = reserved;
        backend.stage(source, source_id, id, digest) catch |err| {
            self.index.pending_id = null;
            self.fault = .stage;
            self.recovery_id = id;
            return err;
        };
        var published = self.index;
        // Preconditions were checked before invoking the helper; a failure
        // here is still a recovery fault since the directory now exists.
        published.publishPair(id, source_id, digest) catch |err| {
            self.index.pending_id = null;
            self.fault = .inventory_commit;
            self.recovery_id = id;
            return err;
        };
        backend.save(&published) catch |err| {
            self.index.pending_id = null;
            self.fault = .inventory_commit;
            self.recovery_id = id;
            return err;
        };
        self.index = published;
        return .{ .imported = id };
    }
};

const Mock = struct {
    writes: usize = 0,
    stages: usize = 0,
    fail_save: usize = 0,
    fail_stage: bool = false,
    saved: inventory.Inventory = .{},

    fn probe(_: *Mock, _: []const u8, _: []const u8) !fingerprint.Pair {
        return .{ .primary = @splat(7), .secondary = @splat(8) };
    }

    fn save(self: *Mock, value: *const inventory.Inventory) !void {
        self.writes += 1;
        if (self.writes == self.fail_save) return error.InjectedWrite;
        self.saved = value.*;
        self.saved.pending_id = null;
    }

    fn stage(self: *Mock, _: []const u8, _: []const u8, id: u64, _: fingerprint.Pair) !void {
        self.stages += 1;
        if (self.saved.next_id != id + 1 or self.saved.count != 0) return error.NotReserved;
        if (self.fail_stage) return error.InjectedStage;
    }
};

test "reserve persist stage commit, then deduplicate without writes" {
    var owner: Coordinator = .{};
    var backend: Mock = .{};
    const result = try owner.importPackage(&backend, "source", "cat");
    try std.testing.expectEqual(@as(u64, 1), result.imported);
    try std.testing.expectEqual(@as(usize, 2), backend.writes);
    try std.testing.expectEqual(@as(usize, 1), backend.saved.count);
    try std.testing.expectEqual(@as(u64, 1), (try owner.importPackage(&backend, "other", "cat")).existing);
    try std.testing.expectEqual(@as(usize, 2), backend.writes);
    try std.testing.expectEqual(@as(usize, 1), backend.stages);
}

test "failure boundaries stop writes and never expose partial imports" {
    for (0..3) |case| {
        var owner: Coordinator = .{};
        var backend: Mock = .{ .fail_save = if (case == 0) 1 else if (case == 2) 2 else 0, .fail_stage = case == 1 };
        if (case == 1) {
            try std.testing.expectError(error.InjectedStage, owner.importPackage(&backend, "source", "cat"));
        } else {
            try std.testing.expectError(error.InjectedWrite, owner.importPackage(&backend, "source", "cat"));
        }
        try std.testing.expectEqual(@as(usize, 0), owner.index.count);
        try std.testing.expectEqual(@as(u64, 1), owner.recovery_id.?);
        try std.testing.expectEqual(@as(usize, if (case == 0) 0 else 1), backend.stages);
        try std.testing.expectEqual(@as(u64, if (case == 0) 1 else 2), backend.saved.next_id);
        try std.testing.expectError(error.RecoveryRequired, owner.importPackage(&backend, "source", "cat"));
    }
}
