//! Owned decoded-buffer handoff over the shared latest-only task primitive.
//! No window, decoder, private worker, or OS handle is owned here.
//! The stable Context is borrowed until the active future has joined;
//! the Future itself returns a copyable bool, never an owning pointer.
const std = @import("std");
const Group = @import("runtime_group").Group;
const LatestTask = @import("runtime_latest_task").LatestTask;

pub const Kind = enum { outfit, activity };
pub const Selection = struct {
    kind: Kind,
    outfit: u8,
    activity: u8 = 0,
};

pub const DecodeFn = *const fn (*anyopaque, std.mem.Allocator, Selection) ?[]u8;
pub const NotifyFn = *const fn (*anyopaque) void;

/// Decoder returns an allocator-owned, nonempty buffer or null. It must
/// free partial buffers before failure and must not retain the allocation
/// after return. The optional notifier must not wait on the UI thread.
pub const Context = struct {
    allocator: std.mem.Allocator,
    userdata: *anyopaque,
    decode: DecodeFn,
    notify: ?NotifyFn = null,
    mailbox: ?[]u8 = null,

    fn discard(self: *Context) void {
        if (self.mailbox) |bytes| self.allocator.free(bytes);
        self.mailbox = null;
    }
};

const Request = struct {
    context: *Context,
    generation: u64,
    selection: Selection,
};

fn work(request: Request) bool {
    const context = request.context;
    std.debug.assert(context.mailbox == null);
    context.mailbox = context.decode(context.userdata, context.allocator, request.selection);
    const ok = context.mailbox != null;
    // Notification is a wake hint, NOT proof of Future completion.
    // Owner still joins before reading or transferring the mailbox.
    if (context.notify) |notify| notify(context.userdata);
    return ok;
}

const Slot = LatestTask(Request, bool, work);

pub const Completion = union(enum) {
    stale,
    failed: Selection,
    ready: struct {
        selection: Selection,
        bytes: []u8,
    },
};

pub const Decoder = struct {
    context: Context,
    slot: Slot,
    next_generation: u64 = 0,
    desired: ?u64 = null,

    /// Owner must remain at a stable address from first submit until stop.
    /// All control methods are serialized on the owning thread.
    pub fn init(io: std.Io, group: *Group, userdata: *anyopaque, decode: DecodeFn, notify: ?NotifyFn) Decoder {
        return .{
            .context = .{ .allocator = group.allocator(), .userdata = userdata, .decode = decode, .notify = notify },
            .slot = Slot.initWithGroup(io, group),
        };
    }

    pub fn submit(self: *Decoder, selection: Selection) error{ Stopped, ResourceBusy, GenerationExhausted }!void {
        if (self.next_generation == std.math.maxInt(u64)) return error.GenerationExhausted;
        const generation = self.next_generation + 1;
        _ = try self.slot.submit(.{ .context = &self.context, .generation = generation, .selection = selection });
        self.next_generation = generation;
        self.desired = generation;
    }

    pub fn startNext(self: *Decoder) !bool {
        return self.slot.startNext();
    }

    /// Invalidate current intent without blocking on a foreign decoder.
    /// A running task remains charged until actually joined.
    pub fn invalidate(self: *Decoder) void {
        self.desired = null;
        self.slot.clearQueued();
    }

    pub fn busy(self: *const Decoder) bool {
        return self.slot.running != null or self.slot.queued != null;
    }

    /// May block. Call only after a completion wake or at owner-side drain.
    /// On ready, ownership transfers to the caller, who must free bytes
    /// with the same Group allocator after presentation/rejection.
    pub fn join(self: *Decoder) error{NoActiveTask}!Completion {
        const completion = try self.slot.awaitActive();
        if (self.desired != completion.input.generation or self.slot.state != .active) {
            self.context.discard();
            return .stale;
        }
        self.desired = null;
        if (!completion.result) {
            self.context.discard();
            return .{ .failed = completion.input.selection };
        }
        const bytes = self.context.mailbox orelse return .{ .failed = completion.input.selection };
        self.context.mailbox = null;
        return .{ .ready = .{ .selection = completion.input.selection, .bytes = bytes } };
    }

    /// Blocking shutdown. No callback, result or queued context survives.
    /// Cancellation is only a request; foreign WIC work may finish first.
    pub fn stop(self: *Decoder) void {
        self.invalidate();
        self.slot.requestStop();
        if (self.slot.running != null) _ = self.slot.cancelActive() catch unreachable;
        self.context.discard();
        self.slot.finishStop() catch unreachable;
    }
};

fn testDecode(_: *anyopaque, allocator: std.mem.Allocator, selection: Selection) ?[]u8 {
    if (selection.outfit == 255) return null;
    const data = allocator.alloc(u8, 16) catch return null;
    @memset(data, selection.outfit);
    return data;
}

test "latest decode frees stale output and transfers only current result" {
    var group = Group.init(std.testing.allocator, 64, 1, 1);
    var unused: u8 = 0;
    var decoder = Decoder.init(std.testing.io, &group, &unused, testDecode, null);
    defer decoder.stop();
    try decoder.submit(.{ .kind = .outfit, .outfit = 1 });
    try std.testing.expect(try decoder.startNext());
    try decoder.submit(.{ .kind = .outfit, .outfit = 2 });
    try decoder.submit(.{ .kind = .outfit, .outfit = 3 });
    try std.testing.expectEqual(@as(usize, 1), group.diagnostics().queued);
    try std.testing.expectEqual(@as(usize, 1), group.diagnostics().running);
    const stale = try decoder.join();
    try std.testing.expect(stale == .stale);
    try std.testing.expectEqual(@as(usize, 0), group.diagnostics().memory.live_bytes);
    try std.testing.expect(try decoder.startNext());
    const current = try decoder.join();
    switch (current) {
        .ready => |result| {
            defer group.allocator().free(result.bytes);
            try std.testing.expectEqual(@as(u8, 3), result.selection.outfit);
            try std.testing.expectEqual(@as(u8, 3), result.bytes[0]);
            try std.testing.expectError(error.OutstandingAllocations, group.checkDrained());
        },
        else => return error.UnexpectedResult,
    }
    try std.testing.expect(!decoder.busy());
    decoder.stop();
    try group.checkDrained();
}

test "invalidated or stopped decode releases the mailbox after actual join" {
    var group = Group.init(std.testing.allocator, 64, 1, 1);
    var unused: u8 = 0;
    var decoder = Decoder.init(std.testing.io, &group, &unused, testDecode, null);
    defer decoder.stop();
    try decoder.submit(.{ .kind = .activity, .outfit = 1, .activity = 2 });
    try std.testing.expect(try decoder.startNext());
    decoder.invalidate();
    try std.testing.expectEqual(@as(usize, 1), group.diagnostics().running);
    const stale = try decoder.join();
    try std.testing.expect(stale == .stale);
    try group.checkDrained();
    try decoder.submit(.{ .kind = .outfit, .outfit = 2 });
    try std.testing.expect(try decoder.startNext());
    try decoder.submit(.{ .kind = .outfit, .outfit = 3 });
    decoder.stop();
    try group.checkDrained();
    try std.testing.expectError(error.Stopped, decoder.submit(.{ .kind = .outfit, .outfit = 4 }));
}

test "allocation denial and failed decode preserve drain and next request" {
    var group = Group.init(std.testing.allocator, 8, 1, 1);
    var unused: u8 = 0;
    var decoder = Decoder.init(std.testing.io, &group, &unused, testDecode, null);
    defer decoder.stop();
    try decoder.submit(.{ .kind = .outfit, .outfit = 1 });
    try std.testing.expect(try decoder.startNext());
    const failed = try decoder.join();
    try std.testing.expect(failed == .failed);
    try group.checkDrained();
    try std.testing.expectEqual(@as(usize, 1), group.diagnostics().memory.denied);
    try decoder.submit(.{ .kind = .outfit, .outfit = 255 });
    try std.testing.expect(try decoder.startNext());
    const missing = try decoder.join();
    try std.testing.expect(missing == .failed);
    decoder.stop();
    try group.checkDrained();
}
