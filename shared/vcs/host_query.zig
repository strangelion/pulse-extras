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
        const self: *Query = @ptrCast(@alignCast(user orelse return @backingInt(async_host.TaskState.failed)));
        if (context == null) return @backingInt(async_host.TaskState.failed);
        const cancelled = context.*.cancelled orelse return @backingInt(async_host.TaskState.failed);
        if (cancelled(context.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
        self.result = self.provider.summarize(&self.workspace);
        self.published.store(true, .release);
        if (self.result) |_| {
            return @backingInt(if (cancelled(context.*.context) != 0) async_host.TaskState.cancelled else async_host.TaskState.completed);
        } else |err| {
            return @backingInt(if (err == error.Cancelled) async_host.TaskState.cancelled else async_host.TaskState.failed);
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

/// UI-thread coordinator. No waits, no background polling, no nested worker.
/// Provider contexts stay alive until checkDrained succeeds; even a dropped
/// selection may still be executing. The caller owns approval and resolution.
const Selection = struct {
    provider: contract.Provider,
    workspace: identity.Workspace,

    fn same(a: *const Selection, b: *const Selection) bool {
        return a.provider.ctx == b.provider.ctx and a.provider.vtable.summarize == b.provider.vtable.summarize and
            a.workspace.kind == b.workspace.kind and a.workspace.root.eql(b.workspace.root.slice()) and
            a.workspace.repository_root.eql(b.workspace.repository_root.slice());
    }
};

pub const Controller = struct {
    query: Query,
    selection: ?Selection = null,
    queued: ?Selection = null,
    current: panel.View = .{ .phase = .empty },
    stopped: bool = false,

    pub fn init(table: async_host.TaskTable) host_mod.Error!Controller {
        return .{ .query = try Query.init(table) };
    }

    pub fn select(self: *Controller, provider: contract.Provider, workspace: *const identity.Workspace) host_mod.Error!void {
        if (self.stopped) return error.State;
        if (provider.kind != workspace.kind or !provider.supports(.status)) {
            try self.clear();
            return error.Argument;
        }
        const next: Selection = .{ .provider = provider, .workspace = workspace.* };
        const retain = if (self.selection) |previous| previous.same(&next) else false;
        const previous_data = if (retain) self.current.snapshot else null;
        self.selection = next;
        self.queued = next;
        self.current = .{ .phase = .queued, .workspace = workspace.*, .snapshot = previous_data, .stale = previous_data != null };
        if (self.query.task.occupied()) {
            // Mark obsolete before cancellation; a failure still suppresses
            // publication. Preserve the latest queued selection for retry.
            try self.query.cancel();
        } else {
            try self.startQueued();
        }
    }

    fn startQueued(self: *Controller) host_mod.Error!void {
        if (self.stopped or self.query.task.occupied()) return;
        const next = self.queued orelse return;
        self.query.start(next.provider, &next.workspace) catch |err| {
            self.current.phase = .failed;
            self.current.failure = switch (err) {
                error.Permission => error.Permission,
                error.Unavailable => error.Unsupported,
                else => error.Io,
            };
            // No fallback or spin retry. A future explicit owner event may
            // retry admission if the underlying slot is actually free.
            return err;
        };
        self.queued = null;
        self.current.phase = .refreshing;
        self.current.failure = null;
    }

    pub fn refresh(self: *Controller) host_mod.Error!void {
        const selected = self.selection orelse return error.State;
        try self.select(selected.provider, &selected.workspace);
    }

    pub fn clear(self: *Controller) host_mod.Error!void {
        if (self.stopped) return error.State;
        self.selection = null;
        self.queued = null;
        self.current = .{ .phase = .empty };
        try self.query.cancel();
    }

    pub fn cancel(self: *Controller) host_mod.Error!void {
        if (self.stopped) return error.State;
        self.queued = null;
        self.current.phase = if (self.selection == null) .empty else .cancelled;
        self.current.stale = self.current.snapshot != null;
        self.current.failure = null;
        try self.query.cancel();
    }

    /// Call on owner events, not a blocking loop. Only one poll and at most
    /// one admission per invocation. Preserve previous data as stale on error.
    pub fn pump(self: *Controller) host_mod.Error!void {
        const obsolete = self.query.discard or self.stopped;
        if (try self.query.poll()) |terminal| {
            if (!obsolete and self.queued == null and self.selection != null) {
                const previous_data = self.current.snapshot;
                self.current = terminal;
                if (terminal.phase != .ready and previous_data != null) {
                    self.current.snapshot = previous_data;
                    self.current.stale = true;
                }
            }
        }
        try self.startQueued();
    }

    pub fn requestStop(self: *Controller) host_mod.Error!void {
        self.stopped = true;
        self.selection = null;
        self.queued = null;
        self.current = .{ .phase = .stopped };
        try self.query.requestStop();
    }

    pub fn checkDrained(self: *const Controller) error{Busy}!void {
        if (self.queued != null) return error.Busy;
        try self.query.checkDrained();
    }

    pub fn view(self: *const Controller) panel.View {
        return self.current;
    }

    /// Fixed command vocabulary only. Reject unknown or inappropriate events.
    pub fn command(self: *Controller, name: []const u8) host_mod.Error!void {
        switch (panel.parseCommand(name) orelse return error.Argument) {
            .refresh => {
                if (self.current.phase == .queued or self.current.phase == .refreshing or self.stopped) return error.State;
                try self.refresh();
            },
            .cancel => {
                if (self.current.phase != .queued and self.current.phase != .refreshing) return error.State;
                try self.cancel();
            },
            .check => try self.pump(),
        }
    }
};

const Mock = struct {
    descriptor: async_host.Descriptor = undefined,
    state: async_host.TaskState = .running,
    cancel_flag: bool = false,
    fail_release: bool = false,
    fail_create: bool = false,
    fail_cancel: bool = false,
    fail_query: bool = false,
    calls: usize = 0,
    wrong_workspace: bool = false,

    fn create(user: ?*anyopaque, descriptor: [*c]const async_host.Descriptor, id: [*c]u64) callconv(.c) abi.Status {
        const self: *Mock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (self.fail_create) return abi.error_state;
        self.descriptor = descriptor.*;
        self.state = .running;
        self.cancel_flag = false;
        id.* = 1;
        return abi.ok;
    }

    fn cancel(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *Mock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (self.fail_cancel) return abi.error_permission;
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
        snapshot.state = @backingInt(self.state);
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
        self.state = @fromBackingInt(@intCast(self.descriptor.work.?(self.descriptor.user, &context)));
    }

    fn detectImpl(_: *anyopaque, _: []const u8, _: *detect.Result) void {}

    fn summarize(user: *anyopaque, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        const self: *Mock = @ptrCast(@alignCast(user));
        self.calls += 1;
        if (self.fail_query) return error.Parse;
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

test "host controller coalesces navigation and never publishes an obsolete result" {
    var mock: Mock = .{};
    var controller = try Controller.init(mock.table());
    const a = try identity.Workspace.init(.git, "a", "a");
    const b = try identity.Workspace.init(.git, "b", "b");
    const c = try identity.Workspace.init(.git, "c", "c");
    try controller.select(mock.provider(), &a);
    mock.runWork();
    try controller.select(mock.provider(), &b);
    try controller.select(mock.provider(), &c);
    mock.state = .completed;
    try controller.pump();
    try std.testing.expectEqual(panel.Phase.refreshing, controller.view().phase);
    try std.testing.expect(controller.view().workspace.?.root.eql("c"));
    try std.testing.expect(controller.view().snapshot == null);
    mock.runWork();
    try controller.command(panel.command_check);
    try std.testing.expectEqual(panel.Phase.ready, controller.view().phase);
    try std.testing.expect(controller.view().snapshot.?.workspace.?.root.eql("c"));
    try std.testing.expectEqual(@as(usize, 2), mock.calls);
    try controller.checkDrained();
}

test "host controller keeps stale data on refresh failure and retries admission explicitly" {
    var mock: Mock = .{};
    var controller = try Controller.init(mock.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try controller.select(mock.provider(), &workspace);
    mock.runWork();
    try controller.pump();
    try std.testing.expectEqual(panel.Phase.ready, controller.view().phase);
    mock.fail_create = true;
    try std.testing.expectError(error.State, controller.command(panel.command_refresh));
    try std.testing.expectEqual(panel.Phase.failed, controller.view().phase);
    try std.testing.expect(controller.view().stale);
    mock.fail_create = false;
    try controller.command(panel.command_check);
    try std.testing.expectEqual(panel.Phase.refreshing, controller.view().phase);
    mock.fail_query = true;
    mock.runWork();
    try controller.pump();
    const result = controller.view();
    try std.testing.expectEqual(panel.Phase.failed, result.phase);
    try std.testing.expect(result.stale);
    try std.testing.expectEqual(error.Parse, result.failure.?);
    try std.testing.expectEqual(@as(u32, 4), result.snapshot.?.changes.modified);
    try controller.checkDrained();
    try std.testing.expectError(error.Argument, controller.command("arbitrary"));
}

test "failed cancellation keeps ownership and stop suppresses every result" {
    var mock: Mock = .{};
    var controller = try Controller.init(mock.table());
    const a = try identity.Workspace.init(.git, "a", "a");
    const b = try identity.Workspace.init(.git, "b", "b");
    try controller.select(mock.provider(), &a);
    mock.fail_cancel = true;
    try std.testing.expectError(error.Permission, controller.select(mock.provider(), &b));
    try std.testing.expectError(error.Busy, controller.checkDrained());
    try std.testing.expectEqual(panel.Phase.queued, controller.view().phase);
    try std.testing.expectError(error.Permission, controller.requestStop());
    mock.runWork();
    mock.fail_release = true;
    try std.testing.expectError(error.State, controller.pump());
    try std.testing.expectError(error.Busy, controller.checkDrained());
    mock.fail_release = false;
    try controller.pump();
    try controller.checkDrained();
    try std.testing.expectEqual(panel.Phase.stopped, controller.view().phase);
    try std.testing.expect(controller.view().snapshot == null);
    try std.testing.expectError(error.State, controller.select(mock.provider(), &a));
}

test "interactive model declares only fixed owner commands and maps them" {
    var mock: Mock = .{};
    var controller = try Controller.init(mock.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try controller.select(mock.provider(), &workspace);
    var content: panel.Content = undefined;
    var tree: @import("pulse_ui_model").Tree = undefined;
    const busy = controller.view();
    content.buildInteractive(.en, &busy, &tree);
    try std.testing.expectEqual(@as(u32, 3), tree.command_count);
    try std.testing.expectEqualStrings("Cancel", content.textFor("vcs.action.cancel").?);
    try controller.command(panel.command_cancel);
    mock.runWork();
    try controller.command(panel.command_check);
    try std.testing.expectEqual(panel.Phase.cancelled, controller.view().phase);
    try controller.checkDrained();
}
