//! Public Preview 3 task/dispatch adapters. UI owns task operations; dispatch
//! post/cancel may be any-thread. A cancellation request is not a join.
//! Keep callback userdata stable until confirmed terminal/released or the
//! documented host stop/destroy boundary. No independent threads or timers.

const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");

pub const TaskTable = raw.PulseTasksV1;
pub const Descriptor = raw.PulseTaskDescriptor;
pub const Context = raw.PulseTaskContext;
pub const Snapshot = raw.PulseTaskSnapshot;
pub const TaskState = enum(u32) {
    running = 0,
    cancelling = 1,
    completed = 2,
    partial = 3,
    failed = 4,
    cancelled = 5,

    pub fn terminal(self: TaskState) bool {
        return self != .running and self != .cancelling;
    }
};

pub fn taskTable(host: host_mod.Host) host_mod.Error!TaskTable {
    const table = try host.query(TaskTable, raw.PULSE_TASKS_INTERFACE_NAME, raw.PULSE_TASKS_VERSION_1);
    try validateTaskTable(&table);
    return table;
}

fn validateTaskTable(table: *const TaskTable) host_mod.Error!void {
    if (table.size < @sizeOf(TaskTable) or table.version < raw.PULSE_TASKS_VERSION_1) return error.Abi;
    if (table.create == null or table.cancel == null or table.get == null or table.release == null) return error.Unavailable;
}

const Capture = struct {
    id: u64,
    state: ?TaskState = null,
    invalid: bool = false,

    fn receive(user: ?*anyopaque, snapshot: [*c]const Snapshot) callconv(.c) void {
        const self: *Capture = @ptrCast(@alignCast(user orelse return));
        if (snapshot == null or snapshot.*.size < @sizeOf(Snapshot) or snapshot.*.id != self.id or self.state != null) {
            self.invalid = true;
            return;
        }
        self.state = switch (snapshot.*.state) {
            0 => .running,
            1 => .cancelling,
            2 => .completed,
            3 => .partial,
            4 => .failed,
            5 => .cancelled,
            else => null,
        };
        if (self.state == null) self.invalid = true;
    }
};

/// One retained task. The caller owns the descriptor userdata and must not
/// move or free it while occupied. Invalid successful IDs poison the slot:
/// a broken host response cannot be treated as evidence of safe release.
pub const Task = struct {
    table: TaskTable,
    id: u64 = 0,
    poisoned: bool = false,
    observed: ?TaskState = null,
    cancellation_requested: bool = false,

    pub fn init(table: TaskTable) host_mod.Error!Task {
        try validateTaskTable(&table);
        return .{ .table = table };
    }

    pub fn occupied(self: *const Task) bool {
        return self.id != 0 or self.poisoned;
    }

    pub fn start(self: *Task, descriptor: *const Descriptor) host_mod.Error!void {
        if (self.occupied()) return error.State;
        if (descriptor.size < @sizeOf(Descriptor) or descriptor.work == null) return error.Argument;
        const title = abi.slice(descriptor.title) orelse return error.Argument;
        const kind = abi.slice(descriptor.type) orelse return error.Argument;
        for ([_][]const u8{ title, kind }) |value| {
            if (value.len == 0 or value.len > 128 or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.Argument;
        }
        var id: u64 = 0;
        try host_mod.mapStatus(self.table.create.?(self.table.context, descriptor, &id));
        if (id == 0) {
            self.poisoned = true;
            return error.State;
        }
        self.id = id;
        self.observed = null;
        self.cancellation_requested = false;
    }

    pub fn poll(self: *Task) host_mod.Error!TaskState {
        if (self.id == 0) return error.State;
        var capture: Capture = .{ .id = self.id };
        try host_mod.mapStatus(self.table.get.?(self.table.context, self.id, &Capture.receive, &capture));
        if (capture.invalid) return error.Abi;
        const state = capture.state orelse return error.Abi;
        if (self.observed) |previous| {
            if (previous.terminal() and previous != state) return error.Abi;
        }
        self.observed = state;
        return state;
    }

    /// A successful cancel only signals; retain id and userdata.
    pub fn cancel(self: *Task) host_mod.Error!void {
        if (!self.occupied()) return;
        if (self.id == 0) return error.State;
        if (self.observed) |state| {
            if (state.terminal()) return;
        }
        if (self.cancellation_requested) return;
        try host_mod.mapStatus(self.table.cancel.?(self.table.context, self.id));
        self.cancellation_requested = true;
    }

    /// Require observed terminal state and successful release. STATE alone
    /// is not evidence: the host may have evicted a task or be inconsistent.
    pub fn releaseTerminal(self: *Task) host_mod.Error!void {
        if (self.id == 0 or !(self.observed orelse return error.State).terminal()) return error.State;
        try host_mod.mapStatus(self.table.release.?(self.table.context, self.id));
        self.id = 0;
        self.observed = null;
        self.cancellation_requested = false;
    }
};

pub const Dispatch = struct {
    table: raw.PulseDispatchV1,

    pub fn init(host: host_mod.Host) host_mod.Error!Dispatch {
        const table = try host.query(raw.PulseDispatchV1, raw.PULSE_DISPATCH_INTERFACE, raw.PULSE_DISPATCH_VERSION);
        if (table.post == null or table.cancel == null) return error.Unavailable;
        return .{ .table = table };
    }

    /// Callback can execute before this returns. Userdata must already be
    /// fully initialized and must not depend on the returned token.
    pub fn post(self: *const Dispatch, callback: raw.PulseDispatchCallback, user: ?*anyopaque) host_mod.Error!u64 {
        if (callback == null) return error.Argument;
        var token: u64 = 0;
        try host_mod.mapStatus(self.table.post.?(self.table.context, callback, user, &token));
        if (token == 0) return error.State;
        return token;
    }

    /// Only OK means the callback cannot subsequently begin. Do not map
    /// STATE to success: it may already be running.
    pub fn cancel(self: *const Dispatch, token: u64) host_mod.Error!void {
        if (token == 0) return error.Argument;
        try host_mod.mapStatus(self.table.cancel.?(self.table.context, token));
    }
};

/// A bounded, coalescing wake hint, not a terminal notification. The producer
/// may be a worker or the owner; only the owner may reap, stop and cancel.
/// The callback may execute before post returns. Never wait for it or assume
/// STATE from cancel is evidence of callback drain. Keep this object and user
/// stable until all producers have stopped and checkDrained succeeds.
pub const Wake = struct {
    pub const Callback = *const fn (*anyopaque) void;
    pub const State = enum(u8) { idle, posting, queued, early, delivered, failed, poisoned };

    dispatch: Dispatch,
    callback: Callback,
    user: *anyopaque,
    state: std.atomic.Value(State) = std.atomic.Value(State).init(.idle),
    enabled: std.atomic.Value(bool) = std.atomic.Value(bool).init(true),
    last_status: std.atomic.Value(abi.Status) = std.atomic.Value(abi.Status).init(abi.ok),
    token: u64 = 0,
    delivering: bool = false,

    pub fn init(dispatch: Dispatch, callback: Callback, user: *anyopaque) host_mod.Error!Wake {
        if (dispatch.table.size < @sizeOf(raw.PulseDispatchV1) or dispatch.table.version < raw.PULSE_DISPATCH_VERSION) return error.Abi;
        if (dispatch.table.post == null or dispatch.table.cancel == null) return error.Unavailable;
        return .{ .dispatch = dispatch, .callback = callback, .user = user };
    }

    /// Any thread. At most one outstanding post, with no spin or retry.
    /// A failed post is latched; explicit owner events remain usable.
    pub fn request(self: *Wake) void {
        if (!self.enabled.load(.acquire)) return;
        if (self.state.cmpxchgStrong(.idle, .posting, .acq_rel, .acquire) != null) return;
        if (!self.enabled.load(.acquire)) {
            self.state.store(.idle, .release);
            return;
        }
        var token: u64 = 0;
        const status = self.dispatch.table.post.?(self.dispatch.table.context, &receive, self, &token);
        if (status != abi.ok) {
            self.last_status.store(status, .release);
            self.state.store(.failed, .release);
            return;
        }
        if (token == 0) {
            self.last_status.store(abi.error_state, .release);
            self.state.store(.poisoned, .release);
            return;
        }
        self.token = token;
        // If the callback already ran, it could not depend on the token.
        if (self.state.cmpxchgStrong(.posting, .queued, .acq_rel, .acquire)) |previous| {
            if (previous == .early) self.state.store(.delivered, .release);
        }
    }

    fn receive(user: ?*anyopaque) callconv(.c) void {
        const self: *Wake = @ptrCast(@alignCast(user orelse return));
        if (self.state.cmpxchgStrong(.posting, .early, .acq_rel, .acquire)) |previous| {
            if (previous != .queued) return;
            self.state.store(.delivered, .release);
        }
        self.delivering = true;
        defer self.delivering = false;
        if (self.enabled.load(.acquire)) self.callback(self.user);
    }

    /// Owner only. A delivery that preceded post return is not reusable yet.
    /// Never touch token unless the state was acquired as queued.
    pub fn reap(self: *Wake) void {
        switch (self.state.load(.acquire)) {
            .delivered => _ = self.state.cmpxchgStrong(.delivered, .idle, .acq_rel, .acquire),
            .failed => _ = self.state.cmpxchgStrong(.failed, .idle, .acq_rel, .acquire),
            else => {},
        }
    }

    pub fn lastFailure(self: *const Wake) ?host_mod.Error {
        host_mod.mapStatus(self.last_status.load(.acquire)) catch |err| return err;
        return null;
    }

    pub fn disable(self: *Wake) void {
        self.enabled.store(false, .release);
    }

    /// Owner only, after producers have drained. A pending callback is
    /// cancelled only by a known token. On failure retain the slot.
    pub fn drain(self: *Wake) host_mod.Error!void {
        if (self.enabled.load(.acquire) or self.delivering) return error.State;
        self.reap();
        switch (self.state.load(.acquire)) {
            .idle => {},
            .queued => {
                try self.dispatch.cancel(self.token);
                self.state.store(.idle, .release);
            },
            else => return error.State,
        }
    }

    pub fn checkDrained(self: *const Wake) error{Busy}!void {
        if (self.delivering) return error.Busy;
        switch (self.state.load(.acquire)) {
            .idle, .delivered, .failed => {},
            else => return error.Busy,
        }
    }
};

pub const DispatchCallback = raw.PulseDispatchCallback;

const Mock = struct {
    state: TaskState = .running,
    cancel_calls: usize = 0,
    release_calls: usize = 0,
    invalid_id: bool = false,
    fail_release: bool = false,
    wrong_snapshot: bool = false,

    fn create(user: ?*anyopaque, _: [*c]const Descriptor, out: [*c]u64) callconv(.c) abi.Status {
        const self: *Mock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        out.* = if (self.invalid_id) 0 else 42;
        return abi.ok;
    }

    fn cancel(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *Mock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.cancel_calls += 1;
        self.state = .cancelling;
        return abi.ok;
    }

    fn get(user: ?*anyopaque, id: u64, callback: raw.PulseTaskSnapshotFn, data: ?*anyopaque) callconv(.c) abi.Status {
        const self: *Mock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        var snapshot: Snapshot = std.mem.zeroes(Snapshot);
        snapshot.size = @sizeOf(Snapshot);
        snapshot.id = if (self.wrong_snapshot) id + 1 else id;
        snapshot.state = @backingInt(self.state);
        (callback orelse return abi.error_argument)(data, &snapshot);
        return abi.ok;
    }

    fn release(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *Mock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (self.fail_release) return abi.error_state;
        self.release_calls += 1;
        return abi.ok;
    }

    fn table(self: *Mock) TaskTable {
        return .{
            .size = @sizeOf(TaskTable),
            .version = raw.PULSE_TASKS_VERSION_1,
            .context = self,
            .create = &create,
            .cancel = &cancel,
            .get = &get,
            .release = &release,
        };
    }

    fn work(_: ?*anyopaque, _: [*c]const Context) callconv(.c) raw.PulseTaskState {
        return @backingInt(TaskState.completed);
    }

    fn descriptor() Descriptor {
        return .{ .size = @sizeOf(Descriptor), .title = abi.view("VCS query"), .type = abi.view("vcs"), .work = &work };
    }

    fn postInline(_: ?*anyopaque, callback: raw.PulseDispatchCallback, user: ?*anyopaque, token: [*c]u64) callconv(.c) abi.Status {
        (callback orelse return abi.error_argument)(user);
        token.* = 1;
        return abi.ok;
    }

    fn cancelDispatch(_: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        return abi.error_state;
    }

    fn mark(user: ?*anyopaque) callconv(.c) void {
        const value: *bool = @ptrCast(@alignCast(user orelse return));
        value.* = true;
    }
};

test "task cancellation is not terminal and failed release retains ownership" {
    var mock: Mock = .{};
    var task = try Task.init(mock.table());
    const descriptor = Mock.descriptor();
    try task.start(&descriptor);
    try std.testing.expectEqual(TaskState.running, try task.poll());
    try task.cancel();
    try task.cancel();
    try std.testing.expectEqual(@as(usize, 1), mock.cancel_calls);
    try std.testing.expectEqual(TaskState.cancelling, try task.poll());
    try std.testing.expectError(error.State, task.releaseTerminal());
    try std.testing.expectError(error.State, task.start(&descriptor));
    mock.state = .cancelled;
    try std.testing.expectEqual(TaskState.cancelled, try task.poll());
    mock.fail_release = true;
    try std.testing.expectError(error.State, task.releaseTerminal());
    try std.testing.expect(task.occupied());
    mock.fail_release = false;
    try task.releaseTerminal();
    try std.testing.expect(!task.occupied());
    try std.testing.expectEqual(@as(usize, 1), mock.release_calls);
}

test "invalid successful id and inconsistent snapshots fail closed" {
    var mock: Mock = .{ .invalid_id = true };
    var task = try Task.init(mock.table());
    const descriptor = Mock.descriptor();
    try std.testing.expectError(error.State, task.start(&descriptor));
    try std.testing.expect(task.occupied());
    try std.testing.expectError(error.State, task.start(&descriptor));
    mock.invalid_id = false;
    var second = try Task.init(mock.table());
    try second.start(&descriptor);
    mock.wrong_snapshot = true;
    try std.testing.expectError(error.Abi, second.poll());
    try std.testing.expectError(error.State, second.releaseTerminal());
    mock.wrong_snapshot = false;
    mock.state = .completed;
    _ = try second.poll();
    try second.releaseTerminal();
}

test "dispatch permits callback before post returns and does not swallow STATE" {
    const dispatch: Dispatch = .{ .table = .{ .post = &Mock.postInline, .cancel = &Mock.cancelDispatch } };
    var called = false;
    const token = try dispatch.post(&Mock.mark, &called);
    try std.testing.expect(called);
    try std.testing.expectError(error.State, dispatch.cancel(token));
}

const WakeMock = struct {
    callback: DispatchCallback = null,
    user: ?*anyopaque = null,
    inline_delivery: bool = false,
    reject: bool = false,
    zero_token: bool = false,
    fail_cancel: bool = false,
    posts: usize = 0,
    deliveries: usize = 0,

    fn post(user: ?*anyopaque, callback: DispatchCallback, data: ?*anyopaque, out: [*c]u64) callconv(.c) abi.Status {
        const self: *WakeMock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.posts += 1;
        if (self.reject) return abi.error_state;
        self.callback = callback;
        self.user = data;
        if (self.inline_delivery) self.deliver();
        out.* = if (self.zero_token) 0 else @intCast(self.posts);
        return abi.ok;
    }

    fn cancel(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *WakeMock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (self.fail_cancel or self.callback == null) return abi.error_state;
        self.callback = null;
        self.user = null;
        return abi.ok;
    }

    fn dispatch(self: *WakeMock) Dispatch {
        return .{ .table = .{
            .size = @sizeOf(raw.PulseDispatchV1),
            .version = raw.PULSE_DISPATCH_VERSION,
            .context = self,
            .post = &post,
            .cancel = &cancel,
        } };
    }

    fn deliver(self: *WakeMock) void {
        const callback = self.callback orelse return;
        const data = self.user;
        self.callback = null;
        self.user = null;
        callback(data);
    }

    fn mark(user: *anyopaque) void {
        const self: *WakeMock = @ptrCast(@alignCast(user));
        self.deliveries += 1;
    }
};

test "wake coalesces and tolerates callback before post returns" {
    var mock: WakeMock = .{ .inline_delivery = true };
    var wake = try Wake.init(mock.dispatch(), &WakeMock.mark, &mock);
    wake.request();
    wake.request();
    try std.testing.expectEqual(@as(usize, 1), mock.posts);
    try std.testing.expectEqual(@as(usize, 1), mock.deliveries);
    wake.reap();
    mock.inline_delivery = false;
    wake.request();
    wake.request();
    try std.testing.expectEqual(@as(usize, 2), mock.posts);
    try std.testing.expectError(error.Busy, wake.checkDrained());
    mock.deliver();
    try std.testing.expectEqual(@as(usize, 2), mock.deliveries);
    wake.disable();
    try wake.drain();
    try wake.checkDrained();
}

test "wake retains failed cancel and suppresses late callback during stop" {
    var mock: WakeMock = .{ .fail_cancel = true };
    var wake = try Wake.init(mock.dispatch(), &WakeMock.mark, &mock);
    wake.request();
    wake.disable();
    try std.testing.expectError(error.State, wake.drain());
    try std.testing.expectError(error.Busy, wake.checkDrained());
    wake.request();
    try std.testing.expectEqual(@as(usize, 1), mock.posts);
    mock.deliver();
    try std.testing.expectEqual(@as(usize, 0), mock.deliveries);
    try wake.drain();
    try wake.checkDrained();
}

test "wake reports queue rejection without looping and poisons invalid successful token" {
    var mock: WakeMock = .{ .reject = true };
    var wake = try Wake.init(mock.dispatch(), &WakeMock.mark, &mock);
    wake.request();
    wake.request();
    try std.testing.expectEqual(@as(usize, 1), mock.posts);
    try std.testing.expectEqual(error.State, wake.lastFailure().?);
    wake.reap();
    mock.reject = false;
    mock.zero_token = true;
    wake.request();
    try std.testing.expectEqual(@as(usize, 2), mock.posts);
    wake.disable();
    try std.testing.expectError(error.State, wake.drain());
    try std.testing.expectError(error.Busy, wake.checkDrained());
    mock.deliver();
    try std.testing.expectEqual(@as(usize, 0), mock.deliveries);
}
