//! Session-local external resource quotas; not OS-wide resource limits.
const std = @import("std");
const Budget = @import("runtime_budget").Budget;
const Log = @import("runtime_event_log").Log;

pub const Kind = enum(u32) { file = 0, codec = 1, dib = 2, notify = 3, ipc = 4, registry = 5, menu = 6, argv = 7, window = 8, memory_dc = 9, desktop_dc = 10, menu_timer = 11 };
pub const Owner = struct {
    files: Budget = Budget.init(320),
    codecs: Budget = Budget.init(1),
    dib: Budget = Budget.init(2 * 384 * 416 * 4),
    notifications: Budget = Budget.init(1),
    ipc: Budget = Budget.init(4),
    registry: Budget = Budget.init(1),
    menus: Budget = Budget.init(5),
    argv: Budget = Budget.init(1),
    windows: Budget = Budget.init(1),
    memory_dcs: Budget = Budget.init(2),
    desktop_dcs: Budget = Budget.init(1),
    menu_timers: Budget = Budget.init(1),
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
            3 => &self.notifications,
            4 => &self.ipc,
            5 => &self.registry,
            6 => &self.menus,
            7 => &self.argv,
            8 => &self.windows,
            9 => &self.memory_dcs,
            10 => &self.desktop_dcs,
            11 => &self.menu_timers,
            else => null,
        };
    }

    /// Only after all resource users have joined; this is not a join.
    pub fn checkDrained(self: *const Owner) error{OutstandingResources}!void {
        if (self.files.used != 0 or self.codecs.used != 0 or self.dib.used != 0 or self.notifications.used != 0 or self.ipc.used != 0 or self.registry.used != 0 or
            self.menus.used != 0 or self.argv.used != 0 or self.windows.used != 0 or self.memory_dcs.used != 0 or
            self.desktop_dcs.used != 0 or self.menu_timers.used != 0 or self.cleanup_failures != 0) return error.OutstandingResources;
    }
};

pub const Bridge = extern struct {
    context: *Owner,
    reserve: *const fn (*Owner, u32, usize) callconv(.c) c_int,
    release: *const fn (*Owner, u32, usize) callconv(.c) void,
    cleanup_failed: *const fn (*Owner, u32) callconv(.c) void,
    note: *const fn (*Owner, u32) callconv(.c) void,

    pub fn init(owner: *Owner) Bridge {
        return .{ .context = owner, .reserve = reserveResource, .release = releaseResource, .cleanup_failed = cleanupFailed, .note = noteEvent };
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

fn noteEvent(owner: *Owner, code: u32) callconv(.c) void {
    const kind: @import("runtime_event_log").Kind = switch (code) {
        0 => .admitted,
        1 => .backpressure,
        2 => .cancelled,
        3 => .io_failure,
        4 => .timeout,
        else => return,
    };
    owner.enter();
    defer owner.lock.unlock();
    owner.log.add(.{ .kind = kind, .count = 1 });
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

test "notification event has its own bounded reservation and drain gate" {
    var owner: Owner = .{};
    const bridge = Bridge.init(&owner);
    try std.testing.expectEqual(@as(c_int, 1), bridge.reserve(bridge.context, 3, 1));
    try std.testing.expectEqual(@as(c_int, 0), bridge.reserve(bridge.context, 3, 1));
    try std.testing.expectError(error.OutstandingResources, owner.checkDrained());
    bridge.release(bridge.context, 3, 1);
    try owner.checkDrained();
}

test "native IPC registry menu and argument quotas drain independently" {
    var owner: Owner = .{};
    const bridge = Bridge.init(&owner);
    const limits = [_]usize{ 4, 1, 5, 1 };
    for (limits, 4..) |limit, kind| {
        const code: u32 = @intCast(kind);
        try std.testing.expectEqual(@as(c_int, 1), bridge.reserve(bridge.context, code, limit));
        try std.testing.expectEqual(@as(c_int, 0), bridge.reserve(bridge.context, code, 1));
        try std.testing.expectError(error.OutstandingResources, owner.checkDrained());
        bridge.release(bridge.context, code, limit);
    }
    try owner.checkDrained();
}

test "surface object quotas and fixed diagnostic codes" {
    var owner: Owner = .{};
    const bridge = Bridge.init(&owner);
    const limits = [_]usize{ 1, 2, 1, 1 };
    for (limits, 8..) |limit, kind| {
        const code: u32 = @intCast(kind);
        try std.testing.expectEqual(@as(c_int, 1), bridge.reserve(bridge.context, code, limit));
        try std.testing.expectEqual(@as(c_int, 0), bridge.reserve(bridge.context, code, 1));
        try std.testing.expectError(error.OutstandingResources, owner.checkDrained());
        bridge.release(bridge.context, code, limit);
    }
    try owner.checkDrained();
    owner.log.clear();
    bridge.note(bridge.context, 99);
    try std.testing.expectEqual(@as(usize, 0), owner.log.len);
    bridge.note(bridge.context, 0);
    bridge.note(bridge.context, 2);
    bridge.note(bridge.context, 3);
    try std.testing.expectEqual(@as(usize, 3), owner.log.len);
    try std.testing.expectEqual(@as(u64, 1), owner.log.get(2).?.count);
    try std.testing.expect(owner.log.get(2).?.kind == .io_failure);
    for (0..100) |_| bridge.note(bridge.context, 1);
    try std.testing.expectEqual(@as(usize, 64), owner.log.len);
    try std.testing.expectEqual(@as(usize, 39), owner.log.dropped);
}
