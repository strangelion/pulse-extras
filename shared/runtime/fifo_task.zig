//! Fixed-capacity FIFO task owner for non-coalescible work. Inputs and outputs
//! are copyable values without independent allocations or handles. Borrowed
//! context outlives the queue and active job. Owner drives all operations.
//! No resident scheduler. Stop drains explicitly or returns canceled inputs.

const std = @import("std");
const Group = @import("runtime_group").Group;

pub fn FifoTask(comptime Input: type, comptime Output: type, comptime work: fn (Input) Output, comptime capacity: usize) type {
    if (capacity == 0 or capacity > 64) @compileError("FIFO capacity must be 1..64");
    return struct {
        const Self = @This();
        pub const Completion = struct {
            input: Input,
            result: Output,
        };
        const Active = struct {
            input: Input,
            future: std.Io.Future(Output),
        };

        io: std.Io,
        group: *Group,
        accepting: bool = true,
        entries: [capacity]Input = undefined,
        head: usize = 0,
        count: usize = 0,
        active: ?Active = null,

        pub fn init(io: std.Io, group: *Group) Self {
            return .{ .io = io, .group = group };
        }

        pub fn submit(self: *Self, input: Input) error{ Stopped, Full, ResourceBusy }!void {
            if (!self.accepting) return error.Stopped;
            if (self.count == capacity) return error.Full;
            try self.group.reserveQueued();
            self.entries[(self.head + self.count) % capacity] = input;
            self.count += 1;
        }

        fn pop(self: *Self) ?Input {
            if (self.count == 0) return null;
            const input = self.entries[self.head];
            self.head = (self.head + 1) % capacity;
            self.count -= 1;
            self.group.releaseQueued();
            return input;
        }

        /// Can continue draining accepted work after admission closes.
        /// A failed launch leaves the head queued, preserving order.
        pub fn startNext(self: *Self) error{ Busy, ResourceBusy, ConcurrencyUnavailable }!bool {
            if (self.active != null) return error.Busy;
            if (self.count == 0) return false;
            try self.group.reserveRunning();
            errdefer self.group.releaseRunning();
            const input = self.entries[self.head];
            const future = try self.io.concurrent(work, .{input});
            _ = self.pop();
            self.active = .{ .input = input, .future = future };
            return true;
        }

        pub fn join(self: *Self, cancel: bool) error{NoActiveTask}!Completion {
            const active = if (self.active) |*value| value else return error.NoActiveTask;
            const result = if (cancel) active.future.cancel(self.io) else active.future.await(self.io);
            const input = active.input;
            self.active = null;
            self.group.releaseRunning();
            return .{ .input = input, .result = result };
        }

        pub fn requestStop(self: *Self) void {
            self.accepting = false;
        }

        /// Explicitly returns each canceled queued input; no silent drop.
        pub fn cancelNext(self: *Self) ?Input {
            return self.pop();
        }

        pub fn checkDrained(self: *Self) error{Busy}!void {
            if (self.active != null or self.count != 0) return error.Busy;
        }
    };
}

fn echo(input: u32) u32 {
    return input;
}

const TestQueue = FifoTask(u32, u32, echo, 2);

test "FIFO preserves order and rejects excess submissions" {
    var group = Group.init(std.testing.allocator, 0, 3, 1);
    var queue = TestQueue.init(std.testing.io, &group);
    defer {
        if (queue.active != null) _ = queue.join(true) catch unreachable;
        while (queue.cancelNext() != null) {}
    }
    try queue.submit(1);
    try queue.submit(2);
    try std.testing.expectError(error.Full, queue.submit(3));
    try std.testing.expect(try queue.startNext());
    try queue.submit(3);
    queue.requestStop();
    try std.testing.expectError(error.Stopped, queue.submit(4));
    try std.testing.expectEqual(@as(u32, 1), (try queue.join(false)).result);
    try std.testing.expect(try queue.startNext());
    try std.testing.expectEqual(@as(u32, 2), (try queue.join(false)).result);
    try std.testing.expectEqual(@as(u32, 3), queue.cancelNext().?);
    try queue.checkDrained();
    try group.checkDrained();
}

test "shared running quota preserves a second queue until capacity is released" {
    var group = Group.init(std.testing.allocator, 0, 2, 1);
    var first = TestQueue.init(std.testing.io, &group);
    var second = TestQueue.init(std.testing.io, &group);
    defer {
        if (first.active != null) _ = first.join(true) catch unreachable;
        if (second.active != null) _ = second.join(true) catch unreachable;
        while (first.cancelNext() != null) {}
        while (second.cancelNext() != null) {}
    }
    try first.submit(1);
    try second.submit(2);
    try std.testing.expect(try first.startNext());
    try std.testing.expectError(error.ResourceBusy, second.startNext());
    _ = try first.join(false);
    try std.testing.expect(try second.startNext());
    try std.testing.expectEqual(@as(u32, 2), (try second.join(false)).result);
    try group.checkDrained();
}
