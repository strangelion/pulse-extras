//! Session-local external resource quotas; not OS-wide resource limits.
const std = @import("std");
const Budget = @import("runtime_budget").Budget;
const Log = @import("runtime_event_log").Log;

pub const Kind = enum(u32) { file = 0, codec = 1, dib = 2 };
pub const Owner = struct {
    files: Budget = Budget.init(320),
    codecs: Budget = Budget.init(1),
    dib: Budget = Budget.init(2 * 384 * 416 * 4),
    log: Log = .{},
    cleanup_failures: usize = 0,
    lock: std.atomic.Mutex = .unlocked,

    fn enter(self: *Owner) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    fn noteFailureLocked(self: *Owner, kind: u32) void {
        self.cleanup_failures +|= 1;
        self.log.add(.{ .kind = .cleanup_failure, .count = kind });
    }

    fn quota(self: *Owner, kind: u32) ?*Budget {
        return switch (kind) {
            0 => &self.files,
            1 => &self.codecs,
            2 => &self.dib,
            else => null,
        };
    }

    /// Only after all resource users have joined; this is not a join.
    pub fn checkDrained(self: *const Owner) error{OutstandingResources}!void {
        if (self.files.used != 0 or self.codecs.used != 0 or self.dib.used != 0 or self.cleanup_failures != 0) return error.OutstandingResources;
    }
};

pub const Bridge = extern struct {
    context: *Owner,
    reserve: *const fn (*Owner, u32, usize) callconv(.c) c_int,
    release: *const fn (*Owner, u32, usize) callconv(.c) void,
    cleanup_failed: *const fn (*Owner, u32) callconv(.c) void,

    pub fn init(owner: *Owner) Bridge {
        return .{ .context = owner, .reserve = reserveResource, .release = releaseResource, .cleanup_failed = cleanupFailed };
    }
};

fn reserveResource(owner: *Owner, kind: u32, amount: usize) callconv(.c) c_int {
    owner.enter();
    defer owner.lock.unlock();
    const q = owner.quota(kind) orelse return 0;
    if (amount == 0) return 0;
    q.reserve(amount) catch {
        owner.log.add(.{ .kind = .backpressure, .count = kind });
        return 0;
    };
    return 1;
}

fn releaseResource(owner: *Owner, kind: u32, amount: usize) callconv(.c) void {
    owner.enter();
    defer owner.lock.unlock();
    const q = owner.quota(kind) orelse {
        owner.noteFailureLocked(kind);
        return;
    };
    if (amount == 0 or amount > q.used) {
        owner.noteFailureLocked(kind);
        return;
    }
    q.release(amount);
}

fn cleanupFailed(owner: *Owner, kind: u32) callconv(.c) void {
    owner.enter();
    defer owner.lock.unlock();
    owner.noteFailureLocked(kind);
}

test "resource quotas reserve release and report bounded denial" {
    var owner: Owner = .{};
    const bridge = Bridge.init(&owner);
    try std.testing.expectEqual(@as(c_int, 1), bridge.reserve(bridge.context, 0, 320));
    try std.testing.expectEqual(@as(c_int, 0), bridge.reserve(bridge.context, 0, 1));
    try std.testing.expectEqual(@as(c_int, 1), bridge.reserve(bridge.context, 1, 1));
    try std.testing.expectEqual(@as(c_int, 0), bridge.reserve(bridge.context, 1, 1));
    try std.testing.expectEqual(@as(c_int, 1), bridge.reserve(bridge.context, 2, 638976));
    try std.testing.expectEqual(@as(c_int, 1), bridge.reserve(bridge.context, 2, 638976));
    try std.testing.expectEqual(@as(c_int, 0), bridge.reserve(bridge.context, 2, 1));
    try std.testing.expectError(error.OutstandingResources, owner.checkDrained());
    bridge.release(bridge.context, 2, 1277952);
    bridge.release(bridge.context, 1, 1);
    bridge.release(bridge.context, 0, 320);
    try owner.checkDrained();
    try std.testing.expectEqual(@as(usize, 3), owner.log.len);
}

test "failed cleanup and invalid release are not silently drained" {
    var owner: Owner = .{};
    const bridge = Bridge.init(&owner);
    bridge.release(bridge.context, 0, 1);
    bridge.cleanup_failed(bridge.context, 2);
    try std.testing.expectEqual(@as(usize, 2), owner.cleanup_failures);
    try std.testing.expectError(error.OutstandingResources, owner.checkDrained());
}
