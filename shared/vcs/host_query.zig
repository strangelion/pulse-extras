//! Host-owned worker bridge for one approved VCS query, no nested future.
//! All SDK task calls are UI-owner only. Worker reads immutable input and
//! publishes a copy-owned result using release/acquire ordering. The input
//! provider, Runner, I/O and this slot must remain stable through release.
//! Caller must establish repository/tool trust before start. Cancellation
//! discards results; the provider is still bounded by its own command
//! deadlines. Do not interpret a cancel request as a completed process join.
//! No automatic polling, dispatch or DLL unload is implied by this bridge.

const std = @import("std");
const abi = @import("pulse_abi");
const async_host = @import("pulse_async_host");
const host_mod = @import("pulse_host");
const identity = @import("vcs_identity");
const contract = @import("vcs_provider");
const panel = @import("vcs_panel");
const capabilities = @import("vcs_capabilities");
const detect = @import("vcs_detect");

pub const Query = struct {
    task: async_host.Task,
    provider: contract.Provider = undefined,
    workspace: identity.Workspace = undefined,
    result: contract.Error!contract.Snapshot = error.Cancelled,
    published: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    discard: bool = false,
    stopped: bool = false,

    pub fn init(table: async_host.TaskTable) host_mod.Error!Query {
        return .{ .task = try async_host.Task.init(table) };
    }

    /// The host may start work before create returns. Set all worker input
    /// before admission and never mutate it until terminal/release succeeds.
    pub fn start(self: *Query, provider: contract.Provider, workspace: *const identity.Workspace) host_mod.Error!void {
        if (self.stopped or self.task.occupied()) return error.State;
        if (provider.kind != workspace.kind or !provider.supports(.status)) return error.Argument;
        self.provider = provider;
        self.workspace = workspace.*;
        self.result = error.Cancelled;
        self.published.store(false, .monotonic);
        self.discard = false;
        const descriptor: async_host.Descriptor = .{
            .size = @sizeOf(async_host.Descriptor),
            .title = abi.view("VCS status"),
            .type = abi.view("vcs.status"),
            .work = &work,
            .user = self,
        };
        try self.task.start(&descriptor);
    }

    fn work(user: ?*anyopaque, context: [*c]const async_host.Context) callconv(.c) u32 {
        const self: *Query = @ptrCast(@alignCast(user orelse return @intFromEnum(async_host.TaskState.failed)));
        if (context == null) return @intFromEnum(async_host.TaskState.failed);
        const cancelled = context.*.cancelled orelse return @intFromEnum(async_host.TaskState.failed);
        if (cancelled(context.*.context) != 0) return @intFromEnum(async_host.TaskState.cancelled);
        self.result = self.provider.summarize(&self.workspace);
        self.published.store(true, .release);
        if (self.result) |_| {
            return @intFromEnum(if (cancelled(context.*.context) != 0) async_host.TaskState.cancelled else async_host.TaskState.completed);
        } else |err| {
            return @intFromEnum(if (err == error.Cancelled) async_host.TaskState.cancelled else async_host.TaskState.failed);
        }
    }

    /// Owner poll, only on a UI event or supported scheduler. Does not block
    /// awaiting the worker and never reads its result before terminal state.
    /// Returns a copy of the terminal view only after successful release.
    pub fn poll(self: *Query) host_mod.Error!?panel.View {
        if (!self.task.occupied()) return null;
        const state = try self.task.poll();
        if (!state.terminal()) return null;
        var view: panel.View = .{ .phase = .failed, .workspace = self.workspace, .failure = error.Io };
        if (self.stopped or self.discard or state == .cancelled) {
            view.phase = if (self.stopped) .stopped else .cancelled;
            view.failure = null;
        } else if (self.published.load(.acquire)) {
            if (self.result) |snapshot| {
                if (state == .completed) {
                    if (snapshot.workspace) |actual| {
                        if (actual.kind == self.workspace.kind and actual.root.eql(self.workspace.root.slice()) and actual.repository_root.eql(self.workspace.repository_root.slice())) {
                            view.phase = .ready;
                            view.snapshot = snapshot;
                            view.failure = null;
                        } else view.failure = error.Parse;
                    } else view.failure = error.Parse;
                }
            } else |err| view.failure = err;
        }
        try self.task.releaseTerminal();
        return view;
    }

    /// Invalidate publication before asking host to cancel. Retain slot
    /// even if cancellation or terminal release fails.
    pub fn cancel(self: *Query) host_mod.Error!void {
        self.discard = true;
        try self.task.cancel();
    }

    pub fn requestStop(self: *Query) host_mod.Error!void {
        self.stopped = true;
        try self.cancel();
    }

    pub fn checkDrained(self: *const Query) error{Busy}!void {
        if (self.task.occupied()) return error.Busy;
    }
};

const Mock = struct {
    descriptor: async_host.Descriptor = undefined,
    state: async_host.TaskState = .running,
    cancel_flag: bool = false,
    fail_release: bool = false,
    calls: usize = 0,
    wrong_workspace: bool = false,

    fn create(user: ?*anyopaque, descriptor: [*c]const async_host.Descriptor, id: [*c]u64) callconv(.c) abi.Status {
        const self: *Mock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.descriptor = descriptor.*;
        self.state = .running;
        self.cancel_flag = false;
        id.* = 1;
        return abi.ok;
    }

    fn cancel(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *Mock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.cancel_flag = true;
        self.state = .cancelling;
        return abi.ok;
    }

    fn cancelled(user: ?*anyopaque) callconv(.c) u32 {
        const self: *Mock = @ptrCast(@alignCast(user orelse return 1));
        return @intFromBool(self.cancel_flag);
    }

    fn get(user: ?*anyopaque, id: u64, callback: ?*const fn (?*anyopaque, [*c]const async_host.Snapshot) callconv(.c) void, data: ?*anyopaque) callconv(.c) abi.Status {
        const self: *Mock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        var snapshot: async_host.Snapshot = std.mem.zeroes(async_host.Snapshot);
        snapshot.size = @sizeOf(async_host.Snapshot);
        snapshot.id = id;
        snapshot.state = @intFromEnum(self.state);
        (callback orelse return abi.error_argument)(data, &snapshot);
        return abi.ok;
    }

    fn release(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *Mock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        return if (self.fail_release) abi.error_state else abi.ok;
    }

    fn table(self: *Mock) async_host.TaskTable {
        return .{
            .size = @sizeOf(async_host.TaskTable),
            .version = 1,
            .context = self,
            .create = &create,
            .cancel = &cancel,
            .get = &get,
            .release = &release,
        };
    }

    fn runWork(self: *Mock) void {
        const context: async_host.Context = .{ .id = 1, .context = self, .cancelled = &cancelled };
        self.state = @enumFromInt(self.descriptor.work.?(self.descriptor.user, &context));
    }

    fn detectImpl(_: *anyopaque, _: []const u8, _: *detect.Result) void {}

    fn summarize(user: *anyopaque, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        const self: *Mock = @ptrCast(@alignCast(user));
        self.calls += 1;
        var actual = workspace.*;
        if (self.wrong_workspace) actual.root = identity.Path.init("different") catch unreachable;
        return .{ .availability = .ready, .workspace = actual, .changes = .{ .modified = 4 }, .counts = .{ .modified = .ready } };
    }

    fn provider(self: *Mock) contract.Provider {
        var set: capabilities.Set = .empty;
        set.insert(.status);
        return .{
            .kind = .git,
            .display_name = "fixture",
            .capabilities = set,
            .ctx = self,
            .vtable = .{ .detect = detectImpl, .summarize = summarize },
        };
    }
};

test "host task publishes copied result only after terminal release" {
    var mock: Mock = .{};
    var query = try Query.init(mock.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try query.start(mock.provider(), &workspace);
    try std.testing.expect((try query.poll()) == null);
    try std.testing.expectError(error.Busy, query.checkDrained());
    mock.runWork();
    mock.fail_release = true;
    try std.testing.expectError(error.State, query.poll());
    try std.testing.expectError(error.Busy, query.checkDrained());
    mock.fail_release = false;
    const view = (try query.poll()).?;
    try std.testing.expectEqual(panel.Phase.ready, view.phase);
    try std.testing.expectEqual(@as(u32, 4), view.snapshot.?.changes.modified);
    try query.checkDrained();
}

test "queued cancellation does not execute provider and raced result is discarded" {
    var mock: Mock = .{};
    var query = try Query.init(mock.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try query.start(mock.provider(), &workspace);
    try query.cancel();
    try std.testing.expectError(error.Busy, query.checkDrained());
    mock.runWork();
    try std.testing.expectEqual(panel.Phase.cancelled, (try query.poll()).?.phase);
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
    try query.start(mock.provider(), &workspace);
    mock.runWork();
    try query.requestStop();
    mock.state = .completed;
    const view = (try query.poll()).?;
    try std.testing.expectEqual(panel.Phase.stopped, view.phase);
    try std.testing.expect(view.snapshot == null);
    try query.checkDrained();
    try std.testing.expectError(error.State, query.start(mock.provider(), &workspace));
}

test "host task rejects mismatched repository identity" {
    var mock: Mock = .{ .wrong_workspace = true };
    var query = try Query.init(mock.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try query.start(mock.provider(), &workspace);
    mock.runWork();
    const view = (try query.poll()).?;
    try std.testing.expectEqual(panel.Phase.failed, view.phase);
    try std.testing.expectEqual(error.Parse, view.failure.?);
    try std.testing.expect(view.snapshot == null);
    try query.checkDrained();
}
