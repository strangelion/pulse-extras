//! Worker-owned admission and immutable-by-copy snapshot model for the pet
//! manager. No OS handles, filesystem, UI callbacks, allocation or timers.
//! The supervisor adapter must prove creation failure/exit before release.
const std = @import("std");
const Budget = @import("runtime_budget").Budget;

pub const max_instances = 1024; // Current backend storage capacity.
pub const max_configured_instances: usize = std.math.maxInt(i32);
// Must match PET_CHILD_COMMIT_LIMIT in pet_supervisor_win32.h. A reservation
// is a conservative admission ceiling, not measured private bytes.
pub const child_commit_ceiling: usize = 128 * 1024 * 1024;
pub const State = enum { starting, running, stopping };
pub const Metrics = struct {
    private_bytes: usize,
    working_set: usize,
    handles: u32,
    pid: u32 = 0,
    cpu_100ns: u64 = 0,
    sampled_ms: u64 = 0,
    cpu_core_percent: ?f64 = null,
};
pub const Instance = struct {
    id: u64,
    asset_id: u64,
    native_id: ?u64 = null,
    state: State = .starting,
    metrics: ?Metrics = null,
};
pub const Error = error{ Invalid, Capacity, StorageCapacity, BudgetExceeded, IdExhausted, UnknownInstance, InvalidTransition };
pub const Admission = enum { allowed, configured_limit, storage_limit, budget_limit };

pub const Manager = struct {
    budget: Budget,
    limit: usize,
    next_id: u64 = 1,
    slots: [max_instances]?Instance = @splat(null),

    pub fn init(limit: usize, commit_budget: usize) Error!Manager {
        if (limit == 0 or limit > max_configured_instances or commit_budget < child_commit_ceiling)
            return error.Invalid;
        return .{ .budget = Budget.init(commit_budget), .limit = limit };
    }

    pub fn count(self: *const Manager) usize {
        return self.budget.used / child_commit_ceiling;
    }

    pub fn effectiveLimit(self: *const Manager) usize {
        return @min(@min(self.limit, max_instances), self.budget.limit / child_commit_ceiling);
    }

    pub fn admission(self: *const Manager) Admission {
        const used = self.count();
        if (used >= self.limit) return .configured_limit;
        if (used >= max_instances) return .storage_limit;
        if (used >= self.budget.limit / child_commit_ceiling) return .budget_limit;
        return .allowed;
    }

    fn find(self: *Manager, id: u64) Error!*Instance {
        for (self.slots[0..@min(self.limit, max_instances)]) |*slot| {
            if (slot.*) |*item| {
                if (item.id == id) return item;
            }
        }
        return error.UnknownInstance;
    }

    // Called before launching. The stable ID is never reused in this session,
    // even if creation fails. UI row indices and PIDs are not identifiers.
    pub fn reserveStart(self: *Manager, asset_id: u64) Error!u64 {
        if (asset_id == 0) return error.Invalid;
        switch (self.admission()) {
            .allowed => {},
            .configured_limit => return error.Capacity,
            .storage_limit => return error.StorageCapacity,
            .budget_limit => return error.BudgetExceeded,
        }
        if (self.next_id == std.math.maxInt(u64)) return error.IdExhausted;
        for (self.slots[0..@min(self.limit, max_instances)]) |*slot| {
            if (slot.* == null) {
                try self.budget.reserve(child_commit_ceiling);
                const id = self.next_id;
                self.next_id += 1;
                slot.* = .{ .id = id, .asset_id = asset_id };
                return id;
            }
        }
        return error.Capacity;
    }

    // Bind the separately generated native ID once; a failed native start
    // with a retained process still requires a binding and confirmed reap.
    pub fn bindNative(self: *Manager, id: u64, native_id: u64) Error!void {
        const item = try self.find(id);
        if (native_id == 0 or item.native_id != null) return error.InvalidTransition;
        for (self.slots[0..@min(self.limit, max_instances)]) |slot| {
            if (slot) |other| {
                if (other.native_id == native_id) return error.InvalidTransition;
            }
        }
        item.native_id = native_id;
    }

    pub fn nativeId(self: *Manager, id: u64) Error!u64 {
        const item = try self.find(id);
        return item.native_id orelse error.InvalidTransition;
    }

    // Called only after verified creation and readiness. A stop request that
    // raced startup remains stopping; a late readiness must not revive it.
    pub fn markReady(self: *Manager, id: u64) Error!void {
        const item = try self.find(id);
        switch (item.state) {
            .starting => item.state = .running,
            .stopping, .running => {},
        }
    }

    pub fn requestStop(self: *Manager, id: u64) Error!void {
        const item = try self.find(id);
        item.state = .stopping;
    }

    // Unknown is not zero. The worker publishes only actual measurements;
    // a failed sample explicitly clears stale counters.
    pub fn sample(self: *Manager, id: u64, metrics: ?Metrics) Error!void {
        const item = try self.find(id);
        if (item.state == .starting and item.native_id == null) return error.InvalidTransition;
        if (metrics) |raw| {
            var measured = raw;
            measured.cpu_core_percent = null;
            if (item.metrics) |previous| {
                if (raw.sampled_ms > previous.sampled_ms and raw.cpu_100ns >= previous.cpu_100ns and
                    raw.pid != 0 and raw.pid == previous.pid)
                {
                    const elapsed: f64 = @floatFromInt(raw.sampled_ms - previous.sampled_ms);
                    const ticks: f64 = @floatFromInt(raw.cpu_100ns - previous.cpu_100ns);
                    measured.cpu_core_percent = ticks / elapsed / 100.0;
                }
            }
            item.metrics = measured;
        } else {
            item.metrics = null;
        }
    }

    // Caller must have positive evidence that creation never happened OR
    // that the owned process exited. A kill request/timeout is insufficient.
    pub fn confirmGone(self: *Manager, id: u64) Error!void {
        for (self.slots[0..@min(self.limit, max_instances)]) |*slot| {
            if (slot.*) |item| {
                if (item.id == id) {
                    slot.* = null;
                    self.budget.release(child_commit_ceiling);
                    return;
                }
            }
        }
        return error.UnknownInstance;
    }

    // Asset removal is a different operation from stopping an instance.
    // Pending starts and stops both pin the asset until confirmed gone.
    pub fn canRemoveAsset(self: *const Manager, asset_id: u64) bool {
        if (asset_id == 0) return false;
        for (self.slots[0..@min(self.limit, max_instances)]) |slot| {
            if (slot) |item| {
                if (item.asset_id == asset_id) return false;
            }
        }
        return true;
    }

    // Bounded value snapshot; consumers never borrow mutable worker slots.
    pub fn snapshot(self: *const Manager, out: []Instance) usize {
        return self.snapshotPage(0, out);
    }

    // Offset counts occupied entries. Serialize against mutations or page a copied snapshot.
    pub fn snapshotPage(self: *const Manager, offset: usize, out: []Instance) usize {
        var skip = offset;
        var n: usize = 0;
        for (self.slots[0..@min(self.limit, max_instances)]) |slot| {
            if (n == out.len) break;
            if (slot) |item| {
                if (skip != 0) {
                    skip -= 1;
                    continue;
                }
                out[n] = item;
                n += 1;
            }
        }
        return n;
    }
};

test "same asset has independent instances and removal is pinned until confirmed gone" {
    var m = try Manager.init(3, child_commit_ceiling * 2);
    const a = try m.reserveStart(7);
    const b = try m.reserveStart(7);
    try std.testing.expect(a != b);
    try std.testing.expectError(error.BudgetExceeded, m.reserveStart(8));
    try m.markReady(a);
    try m.requestStop(a);
    try std.testing.expect(!m.canRemoveAsset(7));
    try std.testing.expectEqual(@as(usize, 2), m.count());
    try m.confirmGone(a);
    try std.testing.expect(!m.canRemoveAsset(7));
    try m.confirmGone(b);
    try std.testing.expect(m.canRemoveAsset(7));
    try std.testing.expectEqual(@as(usize, 0), m.budget.used);
    const c = try m.reserveStart(8);
    try std.testing.expect(c > b);
    try std.testing.expectError(error.UnknownInstance, m.requestStop(a));
    try m.confirmGone(c);
}

test "late readiness does not resurrect a stopping instance and unknown metrics stay unknown" {
    var m = try Manager.init(1, child_commit_ceiling * 2);
    const id = try m.reserveStart(1);
    try std.testing.expectError(error.Capacity, m.reserveStart(2));
    try std.testing.expectError(error.InvalidTransition, m.sample(id, null));
    try m.requestStop(id);
    try m.markReady(id);
    var rows: [1]Instance = undefined;
    try std.testing.expectEqual(@as(usize, 1), m.snapshot(&rows));
    try std.testing.expectEqual(State.stopping, rows[0].state);
    try std.testing.expect(rows[0].metrics == null);
    try m.sample(id, .{ .private_bytes = 12, .working_set = 34, .handles = 5 });
    _ = m.snapshot(&rows);
    try std.testing.expectEqual(@as(usize, 12), rows[0].metrics.?.private_bytes);
    try m.sample(id, null);
    _ = m.snapshot(&rows);
    try std.testing.expect(rows[0].metrics == null);
    try m.confirmGone(id);
    try std.testing.expectError(error.UnknownInstance, m.confirmGone(id));
    try std.testing.expectEqual(@as(usize, 0), m.snapshot(&rows));
}

test "invalid limits and exhausted IDs do not consume reservations" {
    try std.testing.expectError(error.Invalid, Manager.init(0, child_commit_ceiling));
    try std.testing.expectError(error.Invalid, Manager.init(max_configured_instances + 1, child_commit_ceiling));
    try std.testing.expectError(error.Invalid, Manager.init(1, child_commit_ceiling - 1));
    var m = try Manager.init(1, child_commit_ceiling);
    try std.testing.expectError(error.Invalid, m.reserveStart(0));
    m.next_id = std.math.maxInt(u64);
    try std.testing.expectError(error.IdExhausted, m.reserveStart(1));
    try std.testing.expectEqual(@as(usize, 0), m.budget.used);
}

test "1024 logical slots, last page and full budget recovery" {
    var m = try Manager.init(max_instances, child_commit_ceiling * max_instances);
    for (0..max_instances) |i| {
        const id = try m.reserveStart(1);
        try std.testing.expectEqual(@as(u64, @intCast(i + 1)), id);
    }
    try std.testing.expectEqual(@as(usize, 1024), m.count());
    try std.testing.expectError(error.Capacity, m.reserveStart(1));
    var rows: [32]Instance = undefined;
    try std.testing.expectEqual(@as(usize, 24), m.snapshotPage(1000, &rows));
    try std.testing.expectEqual(@as(u64, 1024), rows[23].id);
    try m.requestStop(1024);
    try std.testing.expectError(error.Capacity, m.reserveStart(1));
    try m.confirmGone(1024);
    const replacement = try m.reserveStart(2);
    try std.testing.expectEqual(@as(u64, 1025), replacement);
    try std.testing.expectError(error.UnknownInstance, m.confirmGone(1024));
    try m.confirmGone(replacement);
    for (1..1024) |id| try m.confirmGone(@intCast(id));
    try std.testing.expectEqual(@as(usize, 0), m.count());
}

test "1024 configured slots do not override actual budget" {
    var m = try Manager.init(max_instances, child_commit_ceiling);
    const id = try m.reserveStart(1);
    try std.testing.expectError(error.BudgetExceeded, m.reserveStart(2));
    try m.confirmGone(id);
}

test "INT_MAX configuration does not allocate INT_MAX slots or bypass quota" {
    var m = try Manager.init(max_configured_instances, child_commit_ceiling * 2);
    try std.testing.expectEqual(@as(usize, 2147483647), m.limit);
    try std.testing.expectEqual(@as(usize, 2), m.effectiveLimit());
    const a = try m.reserveStart(1);
    const b = try m.reserveStart(1);
    try std.testing.expectEqual(Admission.budget_limit, m.admission());
    try std.testing.expectError(error.BudgetExceeded, m.reserveStart(1));
    try m.confirmGone(a);
    try m.confirmGone(b);
    try std.testing.expectEqual(Admission.allowed, m.admission());
}

test "INT_MAX configuration reports actual backend capacity separately" {
    var m = try Manager.init(max_configured_instances, child_commit_ceiling * max_instances);
    for (0..max_instances) |_| _ = try m.reserveStart(1);
    try std.testing.expectEqual(Admission.storage_limit, m.admission());
    try std.testing.expectError(error.StorageCapacity, m.reserveStart(1));
    for (1..max_instances + 1) |id| try m.confirmGone(@intCast(id));
    try std.testing.expectEqual(@as(usize, 0), m.count());
}

test "native binding and CPU samples distinguish missing and measured data" {
    var m = try Manager.init(2, child_commit_ceiling * 2);
    const a = try m.reserveStart(1);
    const b = try m.reserveStart(2);
    try m.bindNative(a, 17);
    try std.testing.expectError(error.InvalidTransition, m.bindNative(b, 17));
    try m.bindNative(b, 18);
    try std.testing.expectEqual(@as(u64, 17), try m.nativeId(a));
    try m.sample(a, .{ .private_bytes = 42, .working_set = 64, .handles = 5, .pid = 123, .cpu_100ns = 100, .sampled_ms = 1000 });
    try std.testing.expect((try m.find(a)).metrics.?.cpu_core_percent == null);
    try m.sample(a, .{ .private_bytes = 42, .working_set = 64, .handles = 5, .pid = 123, .cpu_100ns = 1000100, .sampled_ms = 2000 });
    try std.testing.expectEqual(@as(f64, 10), (try m.find(a)).metrics.?.cpu_core_percent.?);
    try std.testing.expectEqual(State.starting, (try m.find(a)).state);
    try m.sample(a, null);
    try std.testing.expect((try m.find(a)).metrics == null);
    try m.confirmGone(a);
    try m.confirmGone(b);
}
