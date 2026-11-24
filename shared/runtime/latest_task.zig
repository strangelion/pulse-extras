//! One active future and one replaceable queued input, for latest-only work.
//! No private thread, timer or dynamically growing queue. Caller owns std.Io.
//! Input and Output must be copyable values without owned heap/OS resources.
//! Borrowed context must remain valid through join and queue removal.
//! Only the serialized owner may call these methods.

const std = @import("std");

pub fn LatestTask(comptime Input: type, comptime Output: type, comptime work: fn (Input) Output) type {
    return struct {
        const Self = @This();

        pub const State = enum { active, stopping, stopped };
        pub const Admission = enum { queued, replaced };
        pub const Completion = struct {
            input: Input,
            result: Output,
        };

        const Active = struct {
            input: Input,
            future: std.Io.Future(Output),
        };

        io: std.Io,
        state: State = .active,
        queued: ?Input = null,
        running: ?Active = null,

        pub fn init(io: std.Io) Self {
            return .{ .io = io };
        }

        pub fn submit(self: *Self, input: Input) error{Stopped}!Admission {
            if (self.state != .active) return error.Stopped;
            const admission: Admission = if (self.queued == null) .queued else .replaced;
            self.queued = input;
            return admission;
        }

        /// Failed concurrency admission preserves the queued request.
        /// Never execute work inline as a fallback.
        pub fn startNext(self: *Self) error{ Stopped, Busy, ConcurrencyUnavailable }!bool {
            if (self.state != .active) return error.Stopped;
            if (self.running != null) return error.Busy;
            const input = self.queued orelse return false;
            const future = try self.io.concurrent(work, .{input});
            self.running = .{ .input = input, .future = future };
            self.queued = null;
            return true;
        }

        /// Both join methods can block. No concurrent access to the Future.
        pub fn awaitActive(self: *Self) error{NoActiveTask}!Completion {
            const active = if (self.running) |*value| value else return error.NoActiveTask;
            const result = active.future.await(self.io);
            const input = active.input;
            self.running = null;
            return .{ .input = input, .result = result };
        }

        /// Return actual result even when completion raced cancellation.
        pub fn cancelActive(self: *Self) error{NoActiveTask}!Completion {
            const active = if (self.running) |*value| value else return error.NoActiveTask;
            const result = active.future.cancel(self.io);
            const input = active.input;
            self.running = null;
            return .{ .input = input, .result = result };
        }

        pub fn clearQueued(self: *Self) void {
            self.queued = null;
        }

        pub fn requestStop(self: *Self) void {
            if (self.state == .active) self.state = .stopping;
            self.clearQueued();
        }

        pub fn finishStop(self: *Self) error{ NotStopping, Busy }!void {
            if (self.state == .active) return error.NotStopping;
            if (self.running != null or self.queued != null) return error.Busy;
            self.state = .stopped;
        }

        /// Owner-side blocking shutdown; no detached future survives it.
        pub fn shutdown(self: *Self) void {
            self.requestStop();
            if (self.running != null) _ = self.cancelActive() catch unreachable;
            self.finishStop() catch unreachable;
        }
    };
}

fn echo(input: u32) u32 {
    return input;
}

const TestSlot = LatestTask(u32, u32, echo);

test "latest task keeps one running and one latest queued request" {
    var slot = TestSlot.init(std.testing.io);
    defer slot.shutdown();
    try std.testing.expect(!try slot.startNext());
    try std.testing.expectEqual(TestSlot.Admission.queued, try slot.submit(1));
    try std.testing.expect(try slot.startNext());
    try std.testing.expectEqual(TestSlot.Admission.queued, try slot.submit(2));
    for (3..1001) |index| {
        try std.testing.expectEqual(TestSlot.Admission.replaced, try slot.submit(@intCast(index)));
    }
    try std.testing.expectError(error.Busy, slot.startNext());
    const first = try slot.awaitActive();
    try std.testing.expectEqual(@as(u32, 1), first.result);
    try std.testing.expect(try slot.startNext());
    const latest = try slot.awaitActive();
    try std.testing.expectEqual(@as(u32, 1000), latest.input);
    try std.testing.expectEqual(@as(u32, 1000), latest.result);
    try std.testing.expect(!try slot.startNext());
    try std.testing.expectError(error.NoActiveTask, slot.awaitActive());
}

test "stop drops queued work and requires joining active work" {
    var slot = TestSlot.init(std.testing.io);
    defer slot.shutdown();
    try std.testing.expectError(error.NotStopping, slot.finishStop());
    _ = try slot.submit(1);
    _ = try slot.startNext();
    _ = try slot.submit(2);
    slot.requestStop();
    try std.testing.expect(slot.queued == null);
    try std.testing.expectError(error.Stopped, slot.submit(3));
    try std.testing.expectError(error.Stopped, slot.startNext());
    try std.testing.expectError(error.Busy, slot.finishStop());
    _ = try slot.cancelActive();
    try slot.finishStop();
    try slot.finishStop();
    try std.testing.expectEqual(TestSlot.State.stopped, slot.state);
}
