//! Native worker adapter. Stable address, one serialized owner. No UI calls.
//! A live process is not a ready desktop pet; wait for first-frame acknowledgment.
const std = @import("std");
const model = @import("companion/pet_manager.zig");
const catalog = @import("companion/pet_catalog.zig");
const inventory = @import("companion/pet_inventory.zig");
const fingerprint = @import("companion/pet_fingerprint.zig");
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
    ready_event: Handle,
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
extern "c" fn pet_group_start_approved(*Native, [*:0]const u16, *const [32]u8, *const Options, ?[*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, *u64) c_int;
extern "c" fn pet_group_request_stop(*Native, u64) c_int;
extern "c" fn pet_group_force_stop(*Native, u64) c_int;
extern "c" fn pet_group_reap(*Native, u64, *u32) c_int;
extern "c" fn pet_group_ready(*Native, u64, *c_int) c_int;
extern "c" fn pet_group_publish(*Native, u64, u32) c_int;
extern "c" fn pet_group_sample(*Native, u64, *RawMetrics) c_int;
extern "c" fn pet_group_close(*Native) c_int;
extern "c" fn pet_group_abandon(*Native) c_int;

// The native module owns the implementation, not the caller's storage.
// All calls are serialized by the same worker; no CRT allocation crosses
// this boundary. Keep the module loaded until every group is closed.
pub const NativeApi = extern struct {
    version: u32,
    size: u32,
    storage_size: ?*const fn () callconv(.c) usize,
    open: ?*const fn (*Native, u32, usize) callconv(.c) c_int,
    start: ?*const fn (*Native, [*:0]const u16, *const [32]u8, *const Options, ?[*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, *u64) callconv(.c) c_int,
    request_stop: ?*const fn (*Native, u64) callconv(.c) c_int,
    force_stop: ?*const fn (*Native, u64) callconv(.c) c_int,
    reap: ?*const fn (*Native, u64, *u32) callconv(.c) c_int,
    ready: ?*const fn (*Native, u64, *c_int) callconv(.c) c_int,
    publish: ?*const fn (*Native, u64, u32) callconv(.c) c_int,
    sample: ?*const fn (*Native, u64, *RawMetrics) callconv(.c) c_int,
    close: ?*const fn (*Native) callconv(.c) c_int,
    abandon: ?*const fn (*Native) callconv(.c) c_int,

    pub fn valid(self: *const NativeApi) bool {
        return self.version == 2 and self.size == @sizeOf(NativeApi) and
            self.storage_size != null and self.open != null and self.start != null and
            self.request_stop != null and self.force_stop != null and self.reap != null and
            self.ready != null and self.publish != null and self.sample != null and self.close != null and self.abandon != null;
    }
};

const linked_api: NativeApi = .{
    .version = 2,
    .size = @sizeOf(NativeApi),
    .storage_size = pet_group_storage_size,
    .open = pet_group_open,
    .start = pet_group_start_approved,
    .request_stop = pet_group_request_stop,
    .force_stop = pet_group_force_stop,
    .reap = pet_group_reap,
    .ready = pet_group_ready,
    .publish = pet_group_publish,
    .sample = pet_group_sample,
    .close = pet_group_close,
    .abandon = pet_group_abandon,
};

pub const NativeError = error{ Invalid, Busy, OsError, ContainmentFailed, Timeout, CountLimit, StorageLimit, BudgetLimit, SystemMemory, UnapprovedExecutable };
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
        10 => error.UnapprovedExecutable,
        else => error.OsError,
    };
}
pub const Start = struct {
    id: u64,
    // A non-null failure means native creation was ambiguous and the ID
    // remains owned. Stop/reap it; do not discard the reservation.
    failure: ?NativeError = null,
};
const Package = struct { directory: [*:0]const u16, source_id: [*:0]const u16, expected_sha: ?[*:0]const u16 = null };

pub const TickResult = struct {
    id: u64,
    exit_code: ?u32 = null,
    failure: ?anyerror = null,
};
pub const max_tick_slots = 32;
pub const Drain = enum { normal, cooperative, force };

pub const Group = struct {
    native: Native = undefined,
    manager: ?model.Manager = null,
    api: NativeApi = undefined,
    cursor: usize = 0,
    drain: Drain = .normal,

    pub fn open(self: *Group, limit: usize, budget: usize) !void {
        return self.openWithApi(linked_api, limit, budget);
    }

    pub fn openWithApi(self: *Group, api: NativeApi, limit: usize, budget: usize) !void {
        if (self.manager != null) return error.Busy;
        if (!api.valid() or @sizeOf(usize) != 8 or api.storage_size.?() != @sizeOf(Native)) return error.Invalid;
        const manager = try model.Manager.init(limit, budget);
        try check(api.open.?(&self.native, @intCast(limit), budget));
        self.api = api;
        self.manager = manager;
        self.cursor = 0;
        self.drain = .normal;
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

    // The worker resolves the local asset ID to the catalog entry and its
    // independently validated private directory; the child revalidates the
    // package. Never use an arbitrary UI path or a user-supplied executable.
    pub fn startPackage(self: *Group, io: std.Io, approval: trust.Approval, entry: *const catalog.Entry, directory: []const u8, scale: u32, reduced: bool, topmost: bool) !Start {
        return self.startPackageInternal(io, approval, entry, directory, scale, reduced, topmost, null);
    }

    fn startPackageInternal(self: *Group, io: std.Io, approval: trust.Approval, entry: *const catalog.Entry, directory: []const u8, scale: u32, reduced: bool, topmost: bool, expected_sha: ?[*:0]const u16) !Start {
        if (!trust.localAbsolute(directory) or std.mem.indexOfScalar(u8, directory, 0) != null) return error.Invalid;
        var dir: [1024]u16 = undefined;
        const dir_len = try std.unicode.utf8ToUtf16Le(dir[0 .. dir.len - 1], directory);
        dir[dir_len] = 0;
        var source: [65]u16 = undefined;
        const source_len = try std.unicode.utf8ToUtf16Le(source[0 .. source.len - 1], entry.sourceId());
        source[source_len] = 0;
        return self.startSelected(io, approval, entry.id, .{
            .scale = scale,
            .reduced = @intFromBool(reduced),
            .topmost = @intFromBool(topmost),
        }, .{ .directory = dir[0..dir_len :0], .source_id = source[0..source_len :0], .expected_sha = expected_sha });
    }

    // Resolve only an inventory-owned ID to a deterministic private path.
    // The root must be approved by the owning worker, never supplied by UI.
    pub fn startManaged(self: *Group, io: std.Io, approval: trust.Approval, entry: *const catalog.Entry, index: *const inventory.Inventory, asset_root: []const u8, scale: u32, reduced: bool, topmost: bool) !Start {
        const record = try index.get(entry.id);
        if (!std.mem.eql(u8, record.sourceId(), entry.sourceId())) return error.Invalid;
        var path: [4096]u8 = undefined;
        const dir = try inventory.directory(asset_root, entry.id, &path);
        const digest = record.digest orelse return error.UnverifiedAsset;
        const secondary = record.secondary orelse return error.UnverifiedAsset;
        const hex = fingerprint.pairHex(.{ .primary = digest, .secondary = secondary });
        var expected: [194]u16 = @splat(0);
        for (hex, 0..) |ch, i| expected[i] = ch;
        return self.startPackageInternal(io, approval, entry, dir, scale, reduced, topmost, expected[0..193 :0]);
    }

    fn startInternal(self: *Group, io: std.Io, approval: trust.Approval, asset_id: u64, options: Options) !Start {
        return self.startSelected(io, approval, asset_id, options, null);
    }

    fn startSelected(self: *Group, io: std.Io, approval: trust.Approval, asset_id: u64, options: Options, package: ?Package) !Start {
        const manager = try self.active();
        if (self.drain != .normal) return error.Draining;
        if (options.scale < 50 or options.scale > 200) return error.Invalid;
        // Hash the native pinned file instead of reopening by pathname here.
        _ = io;
        if (!trust.localAbsolute(approval.path) or std.mem.indexOfScalar(u8, approval.path, 0) != null or
            !std.ascii.endsWithIgnoreCase(approval.path, ".exe")) return error.UnapprovedExecutable;
        var path: [1024]u16 = undefined;
        const len = try std.unicode.utf8ToUtf16Le(path[0 .. path.len - 1], approval.path);
        path[len] = 0;
        return self.startNative(manager, path[0..len :0], &approval.digest, asset_id, options, package);
    }

    pub const builtin_asset_id = std.math.maxInt(u64);

    // Wide fixed-path adapter for the host-owned private lease. Resolve an
    // inventory ID anew; the child validates the exact dual fingerprint.
    pub fn startManagedWide(self: *Group, helper: [:0]const u16, helper_digest: *const [32]u8, index: *const inventory.Inventory, root: [:0]const u16, asset_id: u64) !Start {
        const manager = try self.active();
        if (self.drain != .normal) return error.Draining;
        const record = try index.get(asset_id);
        const digest = record.digest orelse return error.UnverifiedAsset;
        const secondary = record.secondary orelse return error.UnverifiedAsset;
        const hex = fingerprint.pairHex(.{ .primary = digest, .secondary = secondary });
        var expected: [194]u16 = @splat(0);
        for (hex, 0..) |ch, i| expected[i] = ch;
        var leaf_buf: [32]u8 = undefined;
        const leaf = try std.fmt.bufPrint(&leaf_buf, "\\pet-{x:0>16}", .{asset_id});
        var dir: [1024]u16 = undefined;
        if (root.len + leaf.len >= dir.len) return error.Invalid;
        @memcpy(dir[0..root.len], root);
        for (leaf, 0..) |ch, i| dir[root.len + i] = ch;
        const len = root.len + leaf.len;
        dir[len] = 0;
        var source: [65]u16 = @splat(0);
        for (record.sourceId(), 0..) |ch, i| source[i] = ch;
        return self.startNative(manager, helper, helper_digest, asset_id, .{}, .{ .directory = dir[0..len :0], .source_id = source[0..record.len :0], .expected_sha = expected[0..193 :0] });
    }

    // Built-in development pet only; no asset ID or arbitrary command from UI.
    pub fn startBuiltin(self: *Group, path: [:0]const u16, digest: *const [32]u8) !Start {
        const manager = try self.active();
        if (self.drain != .normal) return error.Draining;
        return self.startNative(manager, path, digest, builtin_asset_id, .{}, null);
    }

    fn startNative(self: *Group, manager: *model.Manager, path: [:0]const u16, digest: *const [32]u8, asset_id: u64, options: Options, package: ?Package) !Start {
        const id = try manager.reserveStart(asset_id);
        var native_id: u64 = 0;
        const code = self.api.start.?(&self.native, path.ptr, digest, &options, if (package) |selected| selected.directory else null, if (package) |selected| selected.source_id else null, if (package) |selected| selected.expected_sha else null, &native_id);
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
        try check(if (force) self.api.force_stop.?(&self.native, native_id) else self.api.request_stop.?(&self.native, native_id));
    }

    // Returns null while the process is still alive. No early release.
    pub fn reap(self: *Group, id: u64) !?u32 {
        const manager = try self.active();
        const native_id = try manager.nativeId(id);
        var code: u32 = 0;
        check(self.api.reap.?(&self.native, native_id, &code)) catch |err| {
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
        check(self.api.sample.?(&self.native, native_id, &raw)) catch |err| {
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

    pub fn publish(self: *Group, id: u64, reaction: u32) !void {
        const native_id = try (try self.active()).nativeId(id);
        try check(self.api.publish.?(&self.native, native_id, reaction));
    }

    pub fn pollReady(self: *Group, id: u64) !bool {
        const manager = try self.active();
        const native_id = try manager.nativeId(id);
        var ready: c_int = 0;
        try check(self.api.ready.?(&self.native, native_id, &ready));
        if (ready != 0) try manager.markReady(id);
        return ready != 0;
    }

    // Worker tick for one owned instance. Exit is checked before sampling.
    // A sample racing an exit gets one more reap check; other errors stay
    // visible and do not release ownership or claim readiness.
    pub fn refresh(self: *Group, id: u64) !?u32 {
        if (try self.reap(id)) |code| return code;
        _ = self.pollReady(id) catch |err| {
            if (err == error.Busy) return self.reap(id);
            return err;
        };
        self.sample(id) catch |err| {
            if (err == error.Busy) return self.reap(id);
            return err;
        };
        return null;
    }

    // Admission closes immediately, not after a full sweep. The owner
    // chooses whether and when to escalate; never force unrelated jobs.
    pub fn beginDrain(self: *Group, force: bool) !void {
        _ = try self.active();
        if (force) {
            self.drain = .force;
        } else if (self.drain == .normal) {
            self.drain = .cooperative;
        }
    }

    pub fn remaining(self: *Group) !usize {
        return (try self.active()).count();
    }

    // A single serialized, nonblocking owner tick. Scan at most 32 physical
    // slots, rather than paging occupied rows (which shift on confirmed
    // reap). No allocation and no sleep. Each returned record is a copied
    // per-instance outcome; one failure cannot starve other children.
    // Callers must retain/report failures and keep pumping until remaining
    // reaches zero. A zero-result tick can simply have scanned empty slots.
    pub fn tick(self: *Group, out: []TickResult) !usize {
        const manager = try self.active();
        const capacity = @min(manager.limit, model.max_instances);
        const budget = @min(@min(out.len, max_tick_slots), capacity);
        if (budget == 0) return error.Invalid;
        var n: usize = 0;
        for (0..budget) |_| {
            const slot = self.cursor;
            self.cursor = (slot + 1) % capacity;
            const item = manager.slots[slot] orelse continue;
            var result: TickResult = .{ .id = item.id };
            if (self.drain == .normal) {
                result.exit_code = self.refresh(item.id) catch |err| blk: {
                    result.failure = err;
                    break :blk null;
                };
            } else {
                // Check exit before requesting stop. In drain mode don't
                // sample CPU or attempt a readiness transition.
                result.exit_code = self.reap(item.id) catch |err| blk: {
                    result.failure = err;
                    break :blk null;
                };
                if (result.failure == null and result.exit_code == null) {
                    self.stop(item.id, self.drain == .force) catch |err| {
                        result.failure = err;
                    };
                }
            }
            out[n] = result;
            n += 1;
        }
        return n;
    }

    pub fn snapshot(self: *Group, offset: usize, out: []model.Instance) !usize {
        return (try self.active()).snapshotPage(offset, out);
    }

    // Terminal emergency only: never claim a confirmed reap or reuse the budget.
    pub fn abandon(self: *Group) !void {
        _ = try self.active();
        try check(self.api.abandon.?(&self.native));
        self.manager = null;
        self.cursor = 0;
        self.drain = .normal;
    }

    pub fn close(self: *Group) !void {
        const manager = try self.active();
        if (manager.count() != 0) return error.Busy;
        try check(self.api.close.?(&self.native));
        self.manager = null;
        self.cursor = 0;
        self.drain = .normal;
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
    try std.testing.expectEqual(@as(usize, 0), try group.remaining());
    for (&ids) |*id| {
        const started = try group.startInternal(io, approval, 1, .{ .smoke = 1 });
        id.* = started.id;
        try std.testing.expect(started.failure == null);
        try group.publish(id.*, 5); // Required testing reaction for hidden smoke.
    }
    try std.testing.expect(ids[0] != ids[1]);
    try std.testing.expectError(error.BudgetExceeded, group.startInternal(io, approval, 1, .{ .smoke = 1 }));
    var rows: [2]model.Instance = undefined;
    try std.testing.expectEqual(@as(usize, 2), try group.snapshot(0, &rows));
    try std.testing.expectEqual(model.State.starting, rows[0].state);
    try std.testing.expectError(error.Busy, group.close());
    var empty: [0]TickResult = .{};
    try std.testing.expectError(error.Invalid, group.tick(&empty));
    var tick_results: [max_tick_slots]TickResult = undefined;
    // Each active ID is observed even with many empty physical slots.
    const observed = try group.tick(&tick_results);
    try std.testing.expectEqual(@as(usize, 2), observed);
    for (tick_results[0..observed], 0..) |result, i| {
        try std.testing.expectEqual(ids[i], result.id);
        try std.testing.expect(result.failure == null);
        if (result.exit_code) |code| {
            try std.testing.expectEqual(@as(u32, 0), code);
            ids[i] = 0;
        }
    }
    // Smoke can exit quickly; assert acknowledgment on a separate native
    // fixture below rather than relying on a scheduler-sensitive poll here.
    for (&ids) |*id| {
        if (id.* == 0) continue;
        try std.testing.expectEqual(@as(u32, 0), try waitReap(&group, id.*));
        id.* = 0;
    }
    try std.testing.expectEqual(@as(usize, 0), try group.snapshot(0, &rows));
    const last = try group.startInternal(io, approval, 1, .{ .smoke = 1 });
    ids[0] = last.id;
    try std.testing.expect(last.failure == null);
    try group.publish(last.id, 5);
    try group.beginDrain(false);
    try std.testing.expectError(error.Draining, group.startInternal(io, approval, 1, .{ .smoke = 1 }));
    try std.testing.expectError(error.Busy, group.close());
    // Walk the physical ring without losing a child when occupied rows shift.
    for (0..200) |_| {
        const n = try group.tick(&tick_results);
        for (tick_results[0..n]) |result| {
            try std.testing.expectEqual(last.id, result.id);
            try std.testing.expect(result.failure == null);
            if (result.exit_code != null) ids[0] = 0;
        }
        if (try group.remaining() == 0) break;
        pet_host_fixture_sleep(25);
    }
    try std.testing.expectEqual(@as(usize, 0), try group.remaining());
    try std.testing.expectEqual(@as(u64, 0), ids[0]);
    try group.close();
    try group.open(2, model.child_commit_ceiling * 2);
    try std.testing.expectEqual(Drain.normal, group.drain);
    try group.beginDrain(true);
    try group.beginDrain(false);
    try std.testing.expectEqual(Drain.force, group.drain);
}
