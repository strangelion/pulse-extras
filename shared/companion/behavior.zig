//! Pure bounded companion event scheduler; no threads, timers, UI or IPC.
//! One worker owns this state. Host events carry non-reused task IDs, and
//! all time arguments use the same monotonic clock. A separate lease gate
//! must authorize every emitted reaction before any actual network write.
const std = @import("std");
const wire = @import("openpets_protocol.zig");

pub const max_tasks = 32;
pub const task_timeout_ms: u64 = 60000;
pub const terminal_hold_ms: u64 = 1800;
pub const min_send_interval_ms: u64 = 250;

pub const Activity = enum { thinking, working, editing, running, testing, waiting };
pub const Outcome = enum { success, failure, canceled };
pub const Event = union(enum) {
    begin: struct { id: u64, activity: Activity },
    update: struct { id: u64, activity: Activity },
    finish: struct { id: u64, outcome: Outcome },
};

pub const EventError = error{ ClockRegression, InvalidTask, DuplicateTask, UnknownTask, Capacity };
pub const Send = struct { ticket: u64, reaction: wire.Reaction };
pub const Delivery = enum { shown, not_shown, failed };

const Task = struct {
    id: u64 = 0,
    activity: Activity = .working,
    expires: u64 = 0,
};

const Terminal = struct {
    reaction: wire.Reaction,
    expires: u64,
};

fn reactionFor(activity: Activity) wire.Reaction {
    return switch (activity) {
        .thinking => .thinking,
        .working => .working,
        .editing => .editing,
        .running => .running,
        .testing => .testing,
        .waiting => .waiting,
    };
}

fn priority(activity: Activity) u8 {
    return switch (activity) {
        .testing => 6,
        .running => 5,
        .editing => 4,
        .working => 3,
        .thinking => 2,
        .waiting => 1,
    };
}

pub const Scheduler = struct {
    tasks: [max_tasks]Task = @splat(.{}),
    terminal: ?Terminal = null,
    last_time: u64 = 0,
    next_send: u64 = 0,
    next_ticket: u64 = 1,
    available: bool = false,
    attempted: ?wire.Reaction = null,
    in_flight: ?Send = null,

    fn advance(self: *Scheduler, now: u64) EventError!void {
        if (now < self.last_time) return error.ClockRegression;
        self.last_time = now;
        for (&self.tasks) |*task| {
            if (task.id != 0 and now >= task.expires) task.* = .{};
        }
        if (self.terminal) |terminal| {
            if (now >= terminal.expires) self.terminal = null;
        }
    }

    fn find(self: *Scheduler, id: u64) ?*Task {
        for (&self.tasks) |*task| {
            if (task.id == id) return task;
        }
        return null;
    }

    /// Event producers must allocate non-reused IDs and refresh long-running
    /// tasks within the timeout. Unknown/stale updates never create tasks.
    /// Capacity pressure rejects new tasks; it never evicts existing ones.
    pub fn observe(self: *Scheduler, now: u64, event: Event) EventError!void {
        try self.advance(now);
        switch (event) {
            .begin => |data| {
                if (data.id == 0) return error.InvalidTask;
                if (self.find(data.id) != null) return error.DuplicateTask;
                const slot = self.find(0) orelse return error.Capacity;
                slot.* = .{ .id = data.id, .activity = data.activity, .expires = now +| task_timeout_ms };
            },
            .update => |data| {
                if (data.id == 0) return error.InvalidTask;
                const slot = self.find(data.id) orelse return error.UnknownTask;
                slot.activity = data.activity;
                slot.expires = now +| task_timeout_ms;
            },
            .finish => |data| {
                if (data.id == 0) return error.InvalidTask;
                const slot = self.find(data.id) orelse return error.UnknownTask;
                slot.* = .{};
                if (!self.available or data.outcome == .canceled) return;
                const reaction: wire.Reaction = if (data.outcome == .failure) .@"error" else .success;
                // A success cannot obscure an unexpired failure.
                if (self.terminal) |old| {
                    if (old.reaction == .@"error" and reaction == .success) return;
                }
                self.terminal = .{ .reaction = reaction, .expires = now +| terminal_hold_ms };
            },
        }
    }

    fn desired(self: *const Scheduler) wire.Reaction {
        if (self.terminal) |terminal| {
            if (terminal.reaction == .@"error") return terminal.reaction;
        }
        var best: ?Activity = null;
        for (self.tasks) |task| {
            if (task.id == 0) continue;
            if (best == null or priority(task.activity) > priority(best.?)) best = task.activity;
        }
        if (best) |activity| return reactionFor(activity);
        if (self.terminal) |terminal| return terminal.reaction;
        return .idle;
    }

    /// Availability is a signal from the separately authenticated lease
    /// owner. On disconnect, discard terminal animations and pending
    /// delivery tickets; retain bounded current tasks for later resync.
    /// A stale completion must never acknowledge a new connection.
    pub fn setAvailable(self: *Scheduler, now: u64, enabled: bool) EventError!void {
        try self.advance(now);
        if (enabled == self.available) return;
        self.available = enabled;
        self.attempted = null;
        self.in_flight = null;
        if (!enabled) self.terminal = null;
    }

    /// Emit at most one outstanding command. Identical desired states are
    /// coalesced, including a peer response with shown=false. No auto retry.
    /// The caller must recheck the lease and report completion or failure.
    pub fn poll(self: *Scheduler, now: u64) EventError!?Send {
        try self.advance(now);
        if (!self.available or self.in_flight != null or now < self.next_send) return null;
        const value = self.desired();
        if (self.attempted == value or self.next_ticket == std.math.maxInt(u64)) return null;
        const command: Send = .{ .ticket = self.next_ticket, .reaction = value };
        self.next_ticket += 1;
        self.next_send = now +| min_send_interval_ms;
        self.in_flight = command;
        return command;
    }

    /// A failed or ambiguous transport result shuts off emission until
    /// the lease owner explicitly signals availability again.
    pub fn complete(self: *Scheduler, now: u64, ticket: u64, delivery: Delivery) EventError!bool {
        try self.advance(now);
        const command = self.in_flight orelse return false;
        if (command.ticket != ticket) return false;
        self.in_flight = null;
        if (delivery == .failed) {
            try self.setAvailable(now, false);
        } else {
            self.attempted = command.reaction;
        }
        return true;
    }

    /// Earliest useful wake-up. No periodic polling when idle or offline.
    /// Host must also wake on input, availability changes or I/O completion.
    /// This scheduler neither creates timers nor waits.
    pub fn nextWake(self: *Scheduler, now: u64) EventError!?u64 {
        try self.advance(now);
        if (!self.available) return null;
        var deadline: ?u64 = null;
        for (self.tasks) |task| {
            if (task.id != 0) deadline = earliest(deadline, task.expires);
        }
        if (self.terminal) |terminal| deadline = earliest(deadline, terminal.expires);
        if (self.in_flight == null and self.attempted != self.desired() and self.next_ticket != std.math.maxInt(u64)) {
            deadline = earliest(deadline, @max(now, self.next_send));
        }
        return deadline;
    }

    /// Disable emission and forget all local activity. Preserve ticket
    /// monotonicity so delayed results from before reset cannot collide.
    pub fn reset(self: *Scheduler, now: u64) EventError!void {
        try self.advance(now);
        self.tasks = @splat(.{});
        self.terminal = null;
        self.available = false;
        self.attempted = null;
        self.in_flight = null;
    }
};

fn earliest(previous: ?u64, value: u64) u64 {
    return if (previous) |old| @min(old, value) else value;
}

const t = std.testing;

fn delivered(scheduler: *Scheduler, now: u64, expected: wire.Reaction) !void {
    const command = (try scheduler.poll(now)) orelse return error.TestExpectedCommand;
    try t.expectEqual(expected, command.reaction);
    try t.expect(try scheduler.complete(now, command.ticket, .shown));
}

test "scheduler coalesces identical states and throttles burst updates" {
    var scheduler: Scheduler = .{};
    try scheduler.setAvailable(0, true);
    try delivered(&scheduler, 0, .idle);
    try t.expectEqual(@as(?u64, null), try scheduler.nextWake(0));
    try scheduler.observe(1, .{ .begin = .{ .id = 1, .activity = .thinking } });
    try scheduler.observe(2, .{ .update = .{ .id = 1, .activity = .working } });
    try scheduler.observe(3, .{ .update = .{ .id = 1, .activity = .editing } });
    try t.expect((try scheduler.poll(249)) == null);
    try t.expectEqual(@as(?u64, 250), try scheduler.nextWake(249));
    try delivered(&scheduler, 250, .editing);
    try scheduler.observe(251, .{ .update = .{ .id = 1, .activity = .editing } });
    try t.expect((try scheduler.poll(500)) == null);
}

test "scheduler ranks concurrent activity and terminal failures" {
    var scheduler: Scheduler = .{};
    try scheduler.setAvailable(0, true);
    try scheduler.observe(0, .{ .begin = .{ .id = 1, .activity = .testing } });
    try scheduler.observe(0, .{ .begin = .{ .id = 2, .activity = .editing } });
    try delivered(&scheduler, 0, .testing);
    try scheduler.observe(250, .{ .finish = .{ .id = 1, .outcome = .failure } });
    try delivered(&scheduler, 250, .@"error");
    try scheduler.observe(500, .{ .finish = .{ .id = 2, .outcome = .success } });
    try t.expect((try scheduler.poll(500)) == null);
    try delivered(&scheduler, 2050, .idle);
    try t.expectEqual(@as(?u64, null), try scheduler.nextWake(2050));
}

test "scheduler expires abandoned tasks and never revives unknown updates" {
    var scheduler: Scheduler = .{};
    try scheduler.setAvailable(0, true);
    try scheduler.observe(0, .{ .begin = .{ .id = 3, .activity = .running } });
    try delivered(&scheduler, 0, .running);
    try t.expectEqual(@as(?u64, task_timeout_ms), try scheduler.nextWake(1));
    try delivered(&scheduler, task_timeout_ms, .idle);
    try t.expectError(error.UnknownTask, scheduler.observe(task_timeout_ms, .{ .update = .{ .id = 3, .activity = .testing } }));
    try t.expectError(error.ClockRegression, scheduler.poll(1));
}

test "scheduler bounds tasks and preserves existing work at capacity" {
    var scheduler: Scheduler = .{};
    for (0..max_tasks) |i| {
        try scheduler.observe(0, .{ .begin = .{ .id = @as(u64, @intCast(i)) + 1, .activity = .working } });
    }
    try t.expectError(error.Capacity, scheduler.observe(1, .{ .begin = .{ .id = 99, .activity = .testing } }));
    try t.expectError(error.DuplicateTask, scheduler.observe(1, .{ .begin = .{ .id = 1, .activity = .testing } }));
    try t.expectError(error.InvalidTask, scheduler.observe(1, .{ .begin = .{ .id = 0, .activity = .testing } }));
    try scheduler.observe(2, .{ .finish = .{ .id = 1, .outcome = .canceled } });
    try scheduler.observe(2, .{ .begin = .{ .id = 99, .activity = .testing } });
    try scheduler.setAvailable(2, true);
    try delivered(&scheduler, 2, .testing);
}

test "scheduler rejects stale completions and stops on failed delivery" {
    var scheduler: Scheduler = .{};
    try scheduler.setAvailable(0, true);
    const first = (try scheduler.poll(0)).?;
    try scheduler.setAvailable(1, false);
    try t.expectEqual(@as(?u64, null), try scheduler.nextWake(1));
    try scheduler.setAvailable(2, true);
    const second = (try scheduler.poll(250)).?;
    try t.expect(first.ticket != second.ticket);
    try t.expect(!try scheduler.complete(251, first.ticket, .shown));
    try t.expect((try scheduler.poll(251)) == null);
    try t.expect(try scheduler.complete(252, second.ticket, .failed));
    try t.expect((try scheduler.poll(1000)) == null);
    try scheduler.setAvailable(1000, true);
    const third = (try scheduler.poll(1000)).?;
    try t.expect(try scheduler.complete(1001, third.ticket, .not_shown));
    try t.expect((try scheduler.poll(2000)) == null);
    try scheduler.reset(2000);
    try scheduler.setAvailable(2000, true);
    const fourth = (try scheduler.poll(2000)).?;
    try t.expect(fourth.ticket > third.ticket);
    try t.expect(!try scheduler.complete(2001, third.ticket, .shown));
}

test "scheduler success is transient and offline completion does not replay" {
    var scheduler: Scheduler = .{};
    try scheduler.setAvailable(0, true);
    try scheduler.observe(0, .{ .begin = .{ .id = 1, .activity = .working } });
    try delivered(&scheduler, 0, .working);
    try scheduler.observe(250, .{ .finish = .{ .id = 1, .outcome = .success } });
    try delivered(&scheduler, 250, .success);
    try delivered(&scheduler, 2050, .idle);
    try scheduler.setAvailable(2051, false);
    try scheduler.observe(2052, .{ .begin = .{ .id = 2, .activity = .testing } });
    try scheduler.observe(2053, .{ .finish = .{ .id = 2, .outcome = .failure } });
    try scheduler.setAvailable(2300, true);
    try delivered(&scheduler, 2300, .idle);
}
