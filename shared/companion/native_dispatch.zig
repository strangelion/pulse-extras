//! Worker-owned scheduler-to-native-channel seam. No actual host hooks.
//! Local admission is not a rendered acknowledgment; never claim .shown.
const std = @import("std");
const behavior = @import("behavior.zig");
const wire = @import("openpets_protocol.zig");

pub fn code(value: wire.Reaction) u32 {
    return switch (value) {
        .idle => 0,
        .thinking => 1,
        .working => 2,
        .editing => 3,
        .running => 4,
        .testing => 5,
        .waiting => 6,
        .waving => 7,
        .success => 8,
        .@"error" => 9,
        .celebrating => 10,
    };
}

pub const Publisher = struct {
    context: *anyopaque,
    // False means failed or ambiguous: owner must close channel, no retry.
    publish: *const fn (*anyopaque, u32) bool,
};

pub const Result = enum { idle, admitted, disconnected };

pub const Controller = struct {
    scheduler: behavior.Scheduler = .{},

    pub fn observe(self: *Controller, now: u64, event: behavior.Event) behavior.EventError!void {
        try self.scheduler.observe(now, event);
    }

    pub fn setAvailable(self: *Controller, now: u64, available: bool) behavior.EventError!void {
        try self.scheduler.setAvailable(now, available);
    }

    pub fn pump(self: *Controller, now: u64, publisher: Publisher) behavior.EventError!Result {
        const send = (try self.scheduler.poll(now)) orelse return .idle;
        const ok = publisher.publish(publisher.context, code(send.reaction));
        // not_shown records delivery admission without claiming actual paint.
        _ = try self.scheduler.complete(now, send.ticket, if (ok) .not_shown else .failed);
        return if (ok) .admitted else .disconnected;
    }

    pub fn nextWake(self: *Controller, now: u64) behavior.EventError!?u64 {
        return self.scheduler.nextWake(now);
    }

    pub fn reset(self: *Controller, now: u64) behavior.EventError!void {
        try self.scheduler.reset(now);
    }
};

const Mock = struct {
    calls: usize = 0,
    last: u32 = 99,
    fail: bool = false,

    fn send(context: *anyopaque, value: u32) bool {
        const self: *Mock = @ptrCast(@alignCast(context));
        self.calls += 1;
        self.last = value;
        return !self.fail;
    }

    fn publisher(self: *Mock) Publisher {
        return .{ .context = self, .publish = send };
    }
};

test "native admission coalesces activity and returns to idle" {
    var c: Controller = .{};
    var mock: Mock = .{};
    try c.setAvailable(0, true);
    try std.testing.expectEqual(Result.admitted, try c.pump(0, mock.publisher()));
    try c.observe(1, .{ .begin = .{ .id = 1, .activity = .thinking } });
    try c.observe(2, .{ .update = .{ .id = 1, .activity = .testing } });
    try std.testing.expectEqual(Result.idle, try c.pump(249, mock.publisher()));
    try std.testing.expectEqual(Result.admitted, try c.pump(250, mock.publisher()));
    try std.testing.expectEqual(@as(u32, 5), mock.last);
    try c.observe(251, .{ .finish = .{ .id = 1, .outcome = .success } });
    try std.testing.expectEqual(Result.admitted, try c.pump(500, mock.publisher()));
    try std.testing.expectEqual(@as(u32, 8), mock.last);
    try std.testing.expectEqual(Result.admitted, try c.pump(2051, mock.publisher()));
    try std.testing.expectEqual(@as(u32, 0), mock.last);
    try std.testing.expectEqual(@as(usize, 4), mock.calls);
    try std.testing.expectEqual(@as(?u64, null), try c.nextWake(2051));
}

test "ambiguous native publish disables dispatch without automatic retry" {
    var c: Controller = .{};
    var mock: Mock = .{ .fail = true };
    try c.setAvailable(0, true);
    try std.testing.expectEqual(Result.disconnected, try c.pump(0, mock.publisher()));
    try std.testing.expectEqual(Result.idle, try c.pump(1000, mock.publisher()));
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try std.testing.expectEqual(@as(?u64, null), try c.nextWake(1000));
    try c.reset(1000);
    mock.fail = false;
    try c.setAvailable(1001, true);
    try std.testing.expectEqual(Result.admitted, try c.pump(1001, mock.publisher()));
}
