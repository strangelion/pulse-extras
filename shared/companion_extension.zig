//! One import root for the settings extension, so catalog and manager types
//! have the same module identity.
const std = @import("std");
const builtin = @import("builtin");
const library = @import("companion/pet_library_read.zig");
const runtime = @import("companion_runtime_owner.zig");
const group = @import("companion_group.zig");
const model = @import("companion/pet_manager.zig");

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
pub const Session = struct {
    phase: std.atomic.Value(u32) = .init(@backingInt(Phase.idle)),
    working_set: std.atomic.Value(usize) = .init(0),
    private_bytes: std.atomic.Value(usize) = .init(0),
    owned: std.atomic.Value(usize) = .init(0),
    ready: std.atomic.Value(usize) = .init(0),
    denied: std.atomic.Value(usize) = .init(0),
    pending_start: std.atomic.Value(bool) = .init(false),

    pub fn set(self: *Session, phase: Phase) void {
        self.phase.store(@backingInt(phase), .release);
    }

    pub fn canStart(self: *const Session) bool {
        return self.phase.load(.acquire) == @backingInt(Phase.running) and
            self.owned.load(.acquire) < session_limit and !self.pending_start.load(.acquire);
    }

    // Called only by the UI producer. A duplicate request is not queued.
    // Worker revalidates native admission before each actual launch.
    pub fn requestStart(self: *Session) bool {
        if (!self.canStart()) return false;
        return !self.pending_start.swap(true, .acq_rel);
    }

    pub fn reset(self: *Session) void {
        self.pending_start.store(false, .release);
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

fn runOwned(owner: *runtime.Owner, session: *Session, root: [:0]const u16, digest: [32]u8, helper: [:0]const u16, helper_digest: *const [32]u8, canceled: *const fn (?*anyopaque) callconv(.c) u32, context: ?*anyopaque) !void {
    if (canceled(context) != 0) return;
    session.set(.starting);
    try owner.open(root, digest, session_limit, session_limit * model.child_commit_ceiling);
    if (canceled(context) != 0) return;
    const started = try owner.group.startBuiltin(helper, helper_digest);
    var failure: ?anyerror = started.failure;
    var rows: [group.max_tick_slots]group.TickResult = undefined;
    var begin = GetTickCount64();
    while (failure == null and canceled(context) == 0) {
        if (session.pending_start.load(.acquire)) {
            session.set(.starting);
            if (canceled(context) == 0) {
                if (owner.group.startBuiltin(helper, helper_digest)) |next| {
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
        const count = try owner.group.tick(&rows);
        for (rows[0..count]) |row| {
            if (row.failure) |err| failure = err;
            if (row.exit_code) |code| {
                if (code != 0) failure = error.ChildExited;
            }
        }
        var items: [session_limit]model.Instance = undefined;
        const owned = try owner.group.snapshot(0, &items);
        var ready: usize = 0;
        var working_set: usize = 0;
        var private_bytes: usize = 0;
        for (items[0..owned]) |item| {
            if (item.state == .running) ready += 1;
            if (item.metrics) |metrics| {
                working_set += metrics.working_set;
                private_bytes += metrics.private_bytes;
            }
        }
        session.owned.store(owned, .release);
        session.ready.store(ready, .release);
        session.working_set.store(working_set, .release);
        session.private_bytes.store(private_bytes, .release);
        if (owned == 0) {
            session.set(.stopping);
            break;
        }
        if (ready == owned) {
            session.set(.running);
        } else if (GetTickCount64() - begin >= 15_000) {
            failure = error.ReadinessTimeout;
        }
        if (failure == null) Sleep(100);
    }
    session.set(.stopping);
    session.pending_start.store(false, .release);
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
    try std.testing.expect(session.requestStart());
    try std.testing.expect(!session.requestStart());
    session.pending_start.store(false, .release);
    session.owned.store(session_limit, .release);
    try std.testing.expect(!session.requestStart());
    session.reset();
    try std.testing.expectEqual(@as(usize, 0), session.owned.load(.acquire));
    try std.testing.expect(!session.requestStart());
}

test "runtime approval requires exactly one SHA-256 hex digest" {
    try std.testing.expectError(error.InvalidRuntimeDigest, parseDigest(""));
    try std.testing.expectError(error.InvalidRuntimeDigest, parseDigest("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
    const digest = try parseDigest("0101010101010101010101010101010101010101010101010101010101010101");
    try std.testing.expectEqual(@as(u8, 1), digest[31]);
}
