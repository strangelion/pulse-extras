//! One import root for the settings extension, so catalog and manager types
//! have the same module identity.
const std = @import("std");
const builtin = @import("builtin");
const library = @import("companion/pet_library_read.zig");
const runtime = @import("companion_runtime_owner.zig");
const group = @import("companion_group.zig");
const model = @import("companion/pet_manager.zig");
const inventory = @import("companion/pet_inventory.zig");
pub const builtin_asset_id = group.Group.builtin_asset_id;

pub const Snapshot = library.Snapshot;
pub const readFilteredDefault = library.readFilteredDefault;

extern "kernel32" fn GetModuleHandleExW(u32, *const anyopaque, *usize) callconv(.winapi) c_int;
extern "kernel32" fn GetModuleFileNameW(usize, [*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

pub fn parseDigest(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidRuntimeDigest;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidRuntimeDigest;
    return digest;
}

fn packageRoot(path: *[1024]u16) ![:0]const u16 {
    var module: usize = 0;
    // FROM_ADDRESS | UNCHANGED_REFCOUNT: locate this exact entry DLL.
    if (GetModuleHandleExW(6, @ptrCast(&checkRuntime), &module) == 0 or module == 0) return error.ModulePathUnavailable;
    const len = GetModuleFileNameW(module, path, path.len);
    if (len == 0 or len >= path.len) return error.ModulePathUnavailable;
    const last = std.mem.lastIndexOfScalar(u16, path[0..len], '\\') orelse return error.ModulePathUnavailable;
    path[last] = 0;
    return path[0..last :0];
}

pub fn checkRuntime(hex: []const u8) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(hex);
    var path: [1024]u16 = undefined;
    const root = try packageRoot(&path);
    // No children in this one-shot check. Keep the owner stable until close.
    const owner = try std.heap.page_allocator.create(runtime.Owner);
    owner.* = .{};
    owner.open(root, digest, 1, 128 * 1024 * 1024) catch |err| {
        owner.close() catch return error.CleanupFailed;
        std.heap.page_allocator.destroy(owner);
        return err;
    };
    owner.close() catch return error.CleanupFailed;
    std.heap.page_allocator.destroy(owner);
}

// Experimental UI admission ceiling, independent of native storage capacity.
pub const session_limit: usize = 8;

// One pending built-in start; all native operations remain worker-owned.
pub const Phase = enum(u32) { idle, starting, running, stopping };
pub const RunningRow = model.Instance;
pub const RunningSnapshot = struct {
    count: usize = 0,
    rows: [session_limit]RunningRow = undefined,
};

pub const Session = struct {
    phase: std.atomic.Value(u32) = .init(@backingInt(Phase.idle)),
    working_set: std.atomic.Value(usize) = .init(0),
    private_bytes: std.atomic.Value(usize) = .init(0),
    owned: std.atomic.Value(usize) = .init(0),
    ready: std.atomic.Value(usize) = .init(0),
    denied: std.atomic.Value(usize) = .init(0),
    pending_start: std.atomic.Value(bool) = .init(false),
    start_asset: std.atomic.Value(u64) = .init(builtin_asset_id),
    pending_stop: std.atomic.Value(u64) = .init(0),
    stopping_id: std.atomic.Value(u64) = .init(0),
    snapshot_lock: std.atomic.Value(bool) = .init(false),
    snapshot: RunningSnapshot = .{},

    pub fn set(self: *Session, phase: Phase) void {
        self.phase.store(@backingInt(phase), .release);
    }

    pub fn canStart(self: *const Session) bool {
        return self.phase.load(.acquire) == @backingInt(Phase.running) and
            self.owned.load(.acquire) < session_limit and !self.pending_start.load(.acquire) and
            self.pending_stop.load(.acquire) == 0 and self.stopping_id.load(.acquire) == 0;
    }

    // Called only by the UI producer. A duplicate request is not queued.
    // Worker revalidates native admission before each actual launch.
    pub fn requestStart(self: *Session) bool {
        return self.requestAsset(builtin_asset_id);
    }

    // Single UI producer, worker reads only after pending_start publishes.
    pub fn requestAsset(self: *Session, asset_id: u64) bool {
        if (asset_id == 0 or !self.canStart()) return false;
        self.start_asset.store(asset_id, .monotonic);
        self.pending_start.store(true, .release);
        return true;
    }

    pub fn requestStop(self: *Session, id: u64) bool {
        if (id == 0 or self.phase.load(.acquire) != @backingInt(Phase.running) or
            self.pending_start.load(.acquire) or self.stopping_id.load(.acquire) != 0) return false;
        return self.pending_stop.cmpxchgStrong(0, id, .acq_rel, .acquire) == null;
    }

    // Neither side waits for the other. Skip a busy publication/read;
    // the next tick retries. All non-atomic row fields are lock-protected.
    pub fn publishRows(self: *Session, rows: []const RunningRow) void {
        if (self.snapshot_lock.swap(true, .acquire)) return;
        defer self.snapshot_lock.store(false, .release);
        self.snapshot.count = @min(rows.len, session_limit);
        @memcpy(self.snapshot.rows[0..self.snapshot.count], rows[0..self.snapshot.count]);
    }

    pub fn copyRows(self: *Session, out: *RunningSnapshot) void {
        if (self.snapshot_lock.swap(true, .acquire)) return;
        defer self.snapshot_lock.store(false, .release);
        out.count = self.snapshot.count;
        @memcpy(out.rows[0..out.count], self.snapshot.rows[0..out.count]);
    }

    pub fn reset(self: *Session) void {
        self.pending_stop.store(0, .release);
        self.stopping_id.store(0, .release);
        self.publishRows(&.{});
        self.pending_start.store(false, .release);
        self.start_asset.store(builtin_asset_id, .release);
        self.owned.store(0, .release);
        self.ready.store(0, .release);
        self.denied.store(0, .release);
        self.working_set.store(0, .release);
        self.private_bytes.store(0, .release);
        self.set(.idle);
    }
};

pub fn runBuiltin(session: *Session, runtime_hex: []const u8, helper_hex: []const u8, canceled: *const fn (?*anyopaque) callconv(.c) u32, context: ?*anyopaque) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(runtime_hex);
    const helper_digest = try parseDigest(helper_hex);
    var path: [1024]u16 = undefined;
    const root = try packageRoot(&path);
    const suffix = std.unicode.wtf8ToWtf16LeStringLiteral("\\pulse-pet-demo.exe");
    if (root.len + suffix.len >= path.len) return error.ModulePathUnavailable;
    // Use separate storage because owner.open still needs the root terminator.
    var helper: [1024]u16 = undefined;
    @memcpy(helper[0..root.len], root);
    @memcpy(helper[root.len..][0..suffix.len], suffix);
    const len = root.len + suffix.len;
    helper[len] = 0;
    const owner = try std.heap.page_allocator.create(runtime.Owner);
    owner.* = .{};
    defer session.reset();
    const outcome = runOwned(owner, session, root, digest, helper[0..len :0], &helper_digest, canceled, context);
    // Cleanup must run for both successful and failed starts. Retain owner
    // memory if native module/handle cleanup itself fails.
    const closed = owner.close();
    if (closed) |_| {
        std.heap.page_allocator.destroy(owner);
    } else |_| {
        owner.abandon() catch return error.CleanupFailed;
        std.heap.page_allocator.destroy(owner);
        return error.UnconfirmedShutdown;
    }
    return outcome;
}

fn launchAsset(owner: *runtime.Owner, helper: [:0]const u16, digest: *const [32]u8, asset_id: u64) !group.Start {
    if (asset_id == builtin_asset_id) return owner.group.startBuiltin(helper, digest);
    var path: [1024]u16 = undefined;
    const root = try library.knownRoot(&path);
    // Only the known-folder resolver chooses the parent, not the UI.
    const suffix = std.unicode.wtf8ToWtf16LeStringLiteral("\\PulseExtras-Companion");
    if (!std.mem.endsWith(u16, root, suffix) or root.len <= suffix.len) return error.InvalidRoot;
    const parent_len = root.len - suffix.len;
    path[parent_len] = 0;
    const approved = try owner.privateRoot(path[0..parent_len :0]);
    const index = try std.heap.page_allocator.create(inventory.Inventory);
    defer std.heap.page_allocator.destroy(index);
    index.* = .{};
    try library.readManagedIndex(approved, index);
    return owner.group.startManagedWide(helper, digest, index, approved, asset_id);
}

fn runOwned(owner: *runtime.Owner, session: *Session, root: [:0]const u16, digest: [32]u8, helper: [:0]const u16, helper_digest: *const [32]u8, canceled: *const fn (?*anyopaque) callconv(.c) u32, context: ?*anyopaque) !void {
    if (canceled(context) != 0) return;
    session.set(.starting);
    try owner.open(root, digest, session_limit, session_limit * model.child_commit_ceiling);
    if (canceled(context) != 0) return;
    const started = try launchAsset(owner, helper, helper_digest, session.start_asset.load(.acquire));
    var failure: ?anyerror = started.failure;
    var rows: [group.max_tick_slots]group.TickResult = undefined;
    var begin = GetTickCount64();
    var stop_since: u64 = 0;
    while (failure == null and canceled(context) == 0) {
        if (session.pending_start.load(.acquire)) {
            session.set(.starting);
            if (canceled(context) == 0) {
                if (launchAsset(owner, helper, helper_digest, session.start_asset.load(.acquire))) |next| {
                    if (next.failure) |err| failure = err;
                    begin = GetTickCount64();
                } else |_| {
                    // Admission or a fully rolled-back launch failure does
                    // not terminate already running pets.
                    _ = session.denied.fetchAdd(1, .monotonic);
                }
            }
            session.pending_start.store(false, .release);
        }
        const requested = session.pending_stop.load(.acquire);
        if (requested != 0 and canceled(context) == 0) {
            // Keep admission closed before clearing the pending command.
            session.stopping_id.store(requested, .release);
            if (owner.group.stop(requested, false)) |_| {
                stop_since = GetTickCount64();
            } else |err| {
                session.stopping_id.store(0, .release);
                if (err == error.UnknownInstance) {
                    _ = session.denied.fetchAdd(1, .monotonic);
                } else {
                    failure = err;
                }
            }
            session.pending_stop.store(0, .release);
        }
        const stopping = session.stopping_id.load(.acquire);
        if (stopping != 0 and GetTickCount64() - stop_since >= 2_000) {
            owner.group.stop(stopping, true) catch |err| {
                if (err != error.UnknownInstance) failure = err;
            };
        }
        const count = try owner.group.tick(&rows);
        for (rows[0..count]) |row| {
            if (row.failure) |err| failure = err;
            if (row.exit_code) |code| {
                if (row.id == stopping) {
                    session.stopping_id.store(0, .release);
                } else if (code != 0) {
                    failure = error.ChildExited;
                }
            }
        }
        if (session.stopping_id.load(.acquire) != 0 and GetTickCount64() - stop_since >= 5_000) failure = error.UnconfirmedShutdown;
        var items: [session_limit]model.Instance = undefined;
        const owned = try owner.group.snapshot(0, &items);
        var ready: usize = 0;
        var starting: usize = 0;
        var working_set: usize = 0;
        var private_bytes: usize = 0;
        for (items[0..owned]) |item| {
            if (item.state == .running) ready += 1;
            if (item.state == .starting) starting += 1;
            if (item.metrics) |metrics| {
                working_set += metrics.working_set;
                private_bytes += metrics.private_bytes;
            }
        }
        session.publishRows(items[0..owned]);
        session.owned.store(owned, .release);
        session.ready.store(ready, .release);
        session.working_set.store(working_set, .release);
        session.private_bytes.store(private_bytes, .release);
        if (owned == 0) {
            session.set(.stopping);
            break;
        }
        if (starting == 0) {
            session.set(.running);
        } else if (GetTickCount64() - begin >= 15_000) {
            failure = error.ReadinessTimeout;
        }
        if (failure == null) Sleep(100);
    }
    session.set(.stopping);
    session.pending_start.store(false, .release);
    session.pending_stop.store(0, .release);
    if (try owner.group.remaining() != 0) {
        session.set(.stopping);
        try owner.group.beginDrain(false);
        const stop = GetTickCount64();
        while (try owner.group.remaining() != 0) {
            const elapsed = GetTickCount64() - stop;
            if (elapsed >= 5_000) break;
            if (elapsed >= 2_000) try owner.group.beginDrain(true);
            const count = try owner.group.tick(&rows);
            for (rows[0..count]) |row| {
                if (row.failure) |err| failure = err;
            }
            if (try owner.group.remaining() != 0) Sleep(50);
        }
        if (try owner.group.remaining() != 0) return error.UnconfirmedShutdown;
    }
    if (failure) |err| return err;
}

test "session admits only one pending start within the pilot limit" {
    var session: Session = .{};
    try std.testing.expect(!session.requestStart());
    session.owned.store(1, .release);
    session.set(.running);
    try std.testing.expect(session.requestAsset(27));
    try std.testing.expectEqual(@as(u64, 27), session.start_asset.load(.acquire));
    try std.testing.expect(!session.requestStart());
    try std.testing.expectEqual(@as(u64, 27), session.start_asset.load(.acquire));
    session.pending_start.store(false, .release);
    session.owned.store(session_limit, .release);
    try std.testing.expect(!session.requestStart());
    session.reset();
    try std.testing.expectEqual(@as(usize, 0), session.owned.load(.acquire));
    try std.testing.expect(!session.requestStart());
}

test "running snapshot copies stable IDs and stop requests are bounded" {
    var session: Session = .{};
    const rows = [_]RunningRow{ .{ .id = 9, .asset_id = 1 }, .{ .id = 11, .asset_id = 1 } };
    session.publishRows(&rows);
    var copy: RunningSnapshot = .{};
    session.copyRows(&copy);
    try std.testing.expectEqual(@as(usize, 2), copy.count);
    try std.testing.expectEqual(@as(u64, 11), copy.rows[1].id);
    session.set(.running);
    try std.testing.expect(!session.requestStop(0));
    try std.testing.expect(session.requestStop(11));
    try std.testing.expect(!session.requestStop(9));
    try std.testing.expect(!session.canStart());
    session.reset();
    session.copyRows(&copy);
    try std.testing.expectEqual(@as(usize, 0), copy.count);
}

test "runtime approval requires exactly one SHA-256 hex digest" {
    try std.testing.expectError(error.InvalidRuntimeDigest, parseDigest(""));
    try std.testing.expectError(error.InvalidRuntimeDigest, parseDigest("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
    const digest = try parseDigest("0101010101010101010101010101010101010101010101010101010101010101");
    try std.testing.expectEqual(@as(u8, 1), digest[31]);
}
