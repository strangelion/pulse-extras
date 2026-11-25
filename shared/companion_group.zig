//! Native worker adapter. Stable address, one serialized owner. No UI calls.
//! A live process is not a ready desktop pet; readiness remains unacknowledged.
const std = @import("std");
const model = @import("companion/pet_manager.zig");
const trust = @import("process/trust.zig");
const Handle = ?*anyopaque;
const Owner = extern struct {
    job: Handle,
    process: Handle,
    stop: Handle,
    state_mapping: Handle,
    state_event: Handle,
    state_slot: Handle,
    generation: u32,
    reaction: u32,
};
const Slot = extern struct {
    id: u64,
    child: Owner,
    stopping: c_int,
};
const Native = extern struct {
    limit: u32,
    count: u32,
    next_id: u64,
    commit_budget: usize,
    slots: [model.max_instances]Slot,
};
const Options = extern struct {
    smoke: c_int = 0,
    remember: c_int = 0,
    reduced: c_int = 0,
    topmost: c_int = 0,
    scale: u32 = 100,
};
const RawMetrics = extern struct {
    private_bytes: u64,
    working_set: u64,
    cpu_100ns: u64,
    sampled_ms: u64,
    handles: u32,
    pid: u32,
};
extern "c" fn pet_group_storage_size() usize;
extern "c" fn pet_group_open(*Native, u32, usize) c_int;
extern "c" fn pet_group_start(*Native, [*:0]const u16, *const Options, *u64) c_int;
extern "c" fn pet_group_request_stop(*Native, u64) c_int;
extern "c" fn pet_group_force_stop(*Native, u64) c_int;
extern "c" fn pet_group_reap(*Native, u64, *u32) c_int;
extern "c" fn pet_group_sample(*Native, u64, *RawMetrics) c_int;
extern "c" fn pet_group_close(*Native) c_int;

pub const NativeError = error{ Invalid, Busy, OsError, ContainmentFailed, Timeout, CountLimit, StorageLimit, BudgetLimit, SystemMemory };
fn check(code: c_int) NativeError!void {
    return switch (code) {
        0 => {},
        1 => error.Invalid,
        2 => error.Busy,
        3 => error.OsError,
        4 => error.ContainmentFailed,
        5 => error.Timeout,
        6 => error.CountLimit,
        7 => error.StorageLimit,
        8 => error.BudgetLimit,
        9 => error.SystemMemory,
        else => error.OsError,
    };
}
pub const Start = struct {
    id: u64,
    // A non-null failure means native creation was ambiguous and the ID
    // remains owned. Stop/reap it; do not discard the reservation.
    failure: ?NativeError = null,
};
pub const Group = struct {
    native: Native = undefined,
    manager: ?model.Manager = null,

    pub fn open(self: *Group, limit: usize, budget: usize) !void {
        if (self.manager != null) return error.Busy;
        if (@sizeOf(usize) != 8 or pet_group_storage_size() != @sizeOf(Native)) return error.Invalid;
        const manager = try model.Manager.init(limit, budget);
        try check(pet_group_open(&self.native, @intCast(limit), budget));
        self.manager = manager;
    }

    fn active(self: *Group) NativeError!*model.Manager {
        return if (self.manager) |*manager| manager else error.Invalid;
    }

    // Approval and pinned root ACL remain caller responsibilities. No
    // automatic retry, shared registry writes or arbitrary argument injection.
    pub fn start(self: *Group, io: std.Io, approval: trust.Approval, asset_id: u64, scale: u32, reduced: bool, topmost: bool) !Start {
        return self.startInternal(io, approval, asset_id, .{
            .scale = scale,
            .reduced = @intFromBool(reduced),
            .topmost = @intFromBool(topmost),
        });
    }

    fn startInternal(self: *Group, io: std.Io, approval: trust.Approval, asset_id: u64, options: Options) !Start {
        const manager = try self.active();
        if (options.scale < 50 or options.scale > 200) return error.Invalid;
        try approval.verify(io, approval.path);
        var path: [1024]u16 = undefined;
        const len = try std.unicode.utf8ToUtf16Le(path[0 .. path.len - 1], approval.path);
        path[len] = 0;
        const id = try manager.reserveStart(asset_id);
        var native_id: u64 = 0;
        const code = pet_group_start(&self.native, path[0..len :0], &options, &native_id);
        if (native_id == 0) {
            // Native contract: zero ID on failure proves no retained child.
            try manager.confirmGone(id);
            try check(code);
            return error.OsError;
        }
        // Both generated IDs are unique within their own session.
        manager.bindNative(id, native_id) catch unreachable;
        check(code) catch |err| {
            manager.requestStop(id) catch unreachable;
            return .{ .id = id, .failure = err };
        };
        return .{ .id = id };
    }

    pub fn stop(self: *Group, id: u64, force: bool) !void {
        const manager = try self.active();
        const native_id = try manager.nativeId(id);
        try manager.requestStop(id);
        try check(if (force) pet_group_force_stop(&self.native, native_id) else pet_group_request_stop(&self.native, native_id));
    }

    // Returns null while the process is still alive. No early release.
    pub fn reap(self: *Group, id: u64) !?u32 {
        const manager = try self.active();
        const native_id = try manager.nativeId(id);
        var code: u32 = 0;
        check(pet_group_reap(&self.native, native_id, &code)) catch |err| {
            if (err == error.Busy) return null;
            return err;
        };
        try manager.confirmGone(id);
        return code;
    }

    pub fn sample(self: *Group, id: u64) !void {
        const manager = try self.active();
        const native_id = try manager.nativeId(id);
        var raw: RawMetrics = undefined;
        check(pet_group_sample(&self.native, native_id, &raw)) catch |err| {
            try manager.sample(id, null);
            return err;
        };
        try manager.sample(id, .{
            .private_bytes = @intCast(raw.private_bytes),
            .working_set = @intCast(raw.working_set),
            .handles = raw.handles,
            .pid = raw.pid,
            .cpu_100ns = raw.cpu_100ns,
            .sampled_ms = raw.sampled_ms,
        });
    }

    // Worker tick for one owned instance. Exit is checked before sampling.
    // A sample racing an exit gets one more reap check; other errors stay
    // visible and do not release ownership or claim readiness.
    pub fn refresh(self: *Group, id: u64) !?u32 {
        if (try self.reap(id)) |code| return code;
        self.sample(id) catch |err| {
            if (err == error.Busy) return self.reap(id);
            return err;
        };
        return null;
    }

    pub fn snapshot(self: *Group, offset: usize, out: []model.Instance) !usize {
        return (try self.active()).snapshotPage(offset, out);
    }

    pub fn close(self: *Group) !void {
        const manager = try self.active();
        if (manager.count() != 0) return error.Busy;
        try check(pet_group_close(&self.native));
        self.manager = null;
    }
};

extern "c" fn pet_host_fixture_path([*]u8, u32) u32;
extern "c" fn pet_host_fixture_sleep(u32) void;

fn waitReap(group: *Group, id: u64) !u32 {
    for (0..200) |_| {
        if (try group.reap(id)) |code| return code;
        pet_host_fixture_sleep(25);
    }
    return error.Timeout;
}

test "group adapter binds two approved demo children and recovers reservations" {
    const io = std.testing.io;
    var path: [4096]u8 = undefined;
    const len = pet_host_fixture_path(&path, path.len);
    try std.testing.expect(len > 0 and len < path.len);
    const name = path[0..len];
    const file = try std.Io.Dir.openFileAbsolute(io, name, .{ .follow_symlinks = false });
    const digest = blk: {
        defer file.close(io);
        break :blk try trust.digestFile(io, file);
    };
    const approval: trust.Approval = .{ .path = name, .digest = digest };
    var group: Group = .{};
    try group.open(model.max_configured_instances, model.child_commit_ceiling * 2);
    var ids: [2]u64 = @splat(0);
    defer {
        for (ids) |id| {
            if (id == 0) continue;
            group.stop(id, true) catch {};
            _ = waitReap(&group, id) catch {};
        }
        group.close() catch {};
    }
    var wrong = approval;
    wrong.digest[0] ^= 1;
    try std.testing.expectError(error.UnapprovedExecutable, group.startInternal(io, wrong, 1, .{ .smoke = 1 }));
    for (&ids) |*id| {
        const started = try group.startInternal(io, approval, 1, .{ .smoke = 1 });
        id.* = started.id;
        try std.testing.expect(started.failure == null);
    }
    try std.testing.expect(ids[0] != ids[1]);
    try std.testing.expectError(error.BudgetExceeded, group.startInternal(io, approval, 1, .{ .smoke = 1 }));
    var rows: [2]model.Instance = undefined;
    try std.testing.expectEqual(@as(usize, 2), try group.snapshot(0, &rows));
    try std.testing.expectEqual(model.State.starting, rows[0].state);
    try std.testing.expectError(error.Busy, group.close());
    for (&ids) |*id| {
        try std.testing.expectEqual(@as(u32, 0), try waitReap(&group, id.*));
        id.* = 0;
    }
    try std.testing.expectEqual(@as(usize, 0), try group.snapshot(0, &rows));
}
