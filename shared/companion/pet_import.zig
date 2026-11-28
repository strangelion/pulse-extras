//! Serialized worker-side import transaction. The backend provides a
//! bounded approved helper and durable atomic inventory replacement.
const std = @import("std");
const inventory = @import("pet_inventory.zig");
const fingerprint = @import("pet_fingerprint.zig");

pub const Result = union(enum) { existing: u64, imported: u64 };
pub const Fault = enum { reservation_save, stage, inventory_commit };

pub const Cancel = struct {
    callback: ?*const fn (?*anyopaque) callconv(.c) u32 = null,
    context: ?*anyopaque = null,

    pub fn check(self: Cancel) error{Canceled}!void {
        if (self.callback) |callback| {
            if (callback(self.context) != 0) return error.Canceled;
        }
    }
};

pub const Coordinator = struct {
    index: inventory.Inventory = .{},
    fault: ?Fault = null,
    recovery_id: ?u64 = null,

    // Backend methods: probe(source, source_id) -> digest; save(index);
    // stage(source, source_id, id, digest). A successful stage must mean
    // verified final directory published and helper exit confirmed.
    // No UI calls. No automatic retry after an ambiguous filesystem change.
    pub fn importPackage(self: *Coordinator, backend: anytype, source: []const u8, source_id: []const u8) !Result {
        return self.importPackageControlled(backend, source, source_id, .{});
    }

    pub fn importPackageControlled(self: *Coordinator, backend: anytype, source: []const u8, source_id: []const u8, cancel: Cancel) !Result {
        return self.importPackageWithAllocator(std.heap.page_allocator, backend, source, source_id, cancel);
    }

    fn importPackageWithAllocator(self: *Coordinator, allocator: std.mem.Allocator, backend: anytype, source: []const u8, source_id: []const u8, cancel: Cancel) !Result {
        if (self.fault != null) return error.RecoveryRequired;
        if (!inventory.validSource(source_id)) return error.Invalid;
        try cancel.check();
        const digest = try backend.probe(source, source_id);
        // This is the final cancellation checkpoint before reservation.
        // After it, finish the durable transaction or report recovery.
        try cancel.check();
        if (try self.index.findPair(digest)) |id| return .{ .existing = id };

        // Allocate before reservation, so OOM cannot leave a durable change.
        // Reuse one unpublished inventory for both stages.
        const scratch = try allocator.create(inventory.Inventory);
        defer allocator.destroy(scratch);
        scratch.copyFrom(&self.index);
        const id = try scratch.reserve();
        backend.save(scratch) catch |err| {
            self.fault = .reservation_save;
            self.recovery_id = id;
            return err;
        };
        self.index.copyFrom(scratch);
        backend.stage(source, source_id, id, digest) catch |err| {
            self.index.pending_id = null;
            self.fault = .stage;
            self.recovery_id = id;
            return err;
        };
        scratch.copyFrom(&self.index);
        // Preconditions were checked before invoking the helper; a failure
        // here is still a recovery fault since the directory now exists.
        scratch.publishPair(id, source_id, digest) catch |err| {
            self.index.pending_id = null;
            self.fault = .inventory_commit;
            self.recovery_id = id;
            return err;
        };
        backend.save(scratch) catch |err| {
            self.index.pending_id = null;
            self.fault = .inventory_commit;
            self.recovery_id = id;
            return err;
        };
        self.index.copyFrom(scratch);
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
            try std.testing.expectError(error.InjectedStage, owner.importPackageWithAllocator(std.testing.allocator, &backend, "source", "cat", .{}));
        } else {
            try std.testing.expectError(error.InjectedWrite, owner.importPackageWithAllocator(std.testing.allocator, &backend, "source", "cat", .{}));
        }
        try std.testing.expectEqual(@as(usize, 0), owner.index.count);
        try std.testing.expectEqual(@as(u64, 1), owner.recovery_id.?);
        try std.testing.expectEqual(@as(usize, if (case == 0) 0 else 1), backend.stages);
        try std.testing.expectEqual(@as(u64, if (case == 0) 1 else 2), backend.saved.next_id);
        try std.testing.expectError(error.RecoveryRequired, owner.importPackage(&backend, "source", "cat"));
    }
}

test "cancellation before reservation leaves index and filesystem untouched" {
    const Probe = struct {
        calls: usize = 0,
        cancel_at: usize,
        fn check(ctx: ?*anyopaque) callconv(.c) u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx orelse unreachable));
            self.calls += 1;
            return @intFromBool(self.calls >= self.cancel_at);
        }
    };
    for (1..3) |cancel_at| {
        var owner: Coordinator = .{};
        var backend: Mock = .{};
        var probe: Probe = .{ .cancel_at = cancel_at };
        try std.testing.expectError(error.Canceled, owner.importPackageControlled(&backend, "source", "cat", .{ .callback = Probe.check, .context = &probe }));
        try std.testing.expectEqual(@as(usize, 0), backend.writes);
        try std.testing.expectEqual(@as(usize, 0), backend.stages);
        try std.testing.expectEqual(@as(u64, 1), owner.index.next_id);
        try std.testing.expectEqual(@as(usize, 0), owner.index.count);
        try std.testing.expect(owner.fault == null);
        try std.testing.expectEqual(@as(u64, 1), (try owner.importPackage(&backend, "source", "cat")).imported);
    }
    // Cancellation after the last checkpoint cannot interrupt publication.
    var owner: Coordinator = .{};
    var backend: Mock = .{};
    var probe: Probe = .{ .cancel_at = 3 };
    try std.testing.expectEqual(@as(u64, 1), (try owner.importPackageControlled(&backend, "source", "cat", .{ .callback = Probe.check, .context = &probe })).imported);
    try std.testing.expectEqual(@as(usize, 2), probe.calls);
    try std.testing.expectEqual(@as(usize, 2), backend.writes);
}

test "allocation failure before reservation leaves durable state untouched" {
    var owner: Coordinator = .{};
    var backend: Mock = .{};
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, owner.importPackageWithAllocator(failing.allocator(), &backend, "source", "cat", .{}));
    try std.testing.expectEqual(@as(u64, 1), owner.index.next_id);
    try std.testing.expectEqual(@as(usize, 0), owner.index.count);
    try std.testing.expectEqual(@as(usize, 0), backend.writes);
    try std.testing.expectEqual(@as(usize, 0), backend.stages);
    try std.testing.expect(owner.fault == null);
    try std.testing.expect(owner.index.pending_id == null);
}
