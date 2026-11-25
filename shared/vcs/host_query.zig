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
const ui = @import("pulse_ui_model");
const context = @import("pulse_context");
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

/// Actual Preview 3 UI model attachment. This is an owner-thread object
/// with a stable address from open through successful close and task drain.
/// The host synchronously copies the tree and invalidates subscriptions on
/// close. Failed close retains the handle; no new commands are accepted.
/// Tool/repository approval and provider lifetime belong to the caller.
pub const Binding = struct {
    pub const Navigation = context.Navigation(identity.max_path_bytes);

    controller: Controller,
    navigation: Navigation = .{},
    navigation_generation: ?u64 = null,
    model: ?ui.Panel = null,
    language: panel.Language,
    accepting: bool = false,
    poisoned: bool = false,
    last_error: ?host_mod.Error = null,

    pub fn init(table: async_host.TaskTable, language: panel.Language) host_mod.Error!Binding {
        return .{ .controller = try Controller.init(table), .language = language };
    }

    pub fn open(self: *Binding, host: host_mod.Host) host_mod.Error!void {
        const table = try host.query(ui.TableV1, ui.interface_name, ui.version_1);
        try self.openWithTable(table);
    }

    pub fn openWithTable(self: *Binding, table: ui.TableV1) host_mod.Error!void {
        if (self.model != null or self.poisoned or self.controller.stopped) return error.State;
        if (table.size < @sizeOf(ui.TableV1) or table.version < ui.version_1) return error.Abi;
        const create = table.create orelse return error.Unavailable;
        if (table.update == null or table.close == null or table.subscribe_command == null or table.unsubscribe == null) return error.Unavailable;
        self.last_error = null;
        var content: panel.Content = undefined;
        var tree: ui.Tree = undefined;
        const current = self.controller.view();
        content.buildInteractive(self.language, &current, &tree);
        var id: u64 = 0;
        try host_mod.mapStatus(create(table.context, abi.view("VCS"), &tree, &id));
        if (id == 0) {
            // Invalid successful ID: no handle to close. Do not certify drain.
            self.poisoned = true;
            self.last_error = error.State;
            return error.State;
        }
        self.model = .{ .table = table, .id = id };
        for ([_][]const u8{ panel.command_refresh, panel.command_cancel, panel.command_check }) |name| {
            _ = self.model.?.subscribeCommand(name, &onCommand, self) catch |err| {
                self.last_error = err;
                // Close invalidates all subscriptions, including any partial
                // registration. Keep the original panel if cleanup fails.
                self.closeModel() catch |cleanup_err| {
                    self.last_error = cleanup_err;
                    return cleanup_err;
                };
                return err;
            };
        }
        self.accepting = true;
    }

    /// Subscribe only after the panel is live. Callback delivery stores a
    /// bounded directory ticket; no VCS tool or filesystem lookup runs there.
    pub fn openNavigation(self: *Binding, host: host_mod.Host) host_mod.Error!void {
        try self.openNavigationWithTable(try context.Table.init(host.raw()));
    }

    pub fn openNavigationWithTable(self: *Binding, table: context.Table) host_mod.Error!void {
        if (!self.accepting) return error.State;
        self.navigation.open(table) catch |err| {
            self.controller.clear() catch {};
            self.render() catch {};
            self.last_error = err;
            return err;
        };
        try self.invalidateNavigation();
        try self.render();
    }

    /// Invalidate an old selection before any owner-side publication or
    /// command. Retry failed cancellation without certifying a drain.
    fn invalidateNavigation(self: *Binding) host_mod.Error!void {
        if (!self.navigation.accepting) return;
        const latest = if (self.navigation.latest) |*value| value else return;
        if (self.navigation_generation == latest.generation) return;
        try self.controller.clear();
        self.navigation_generation = latest.generation;
    }

    /// The owner can schedule independent repository discovery and approval
    /// for this ticket. A null directory means clear, not a repository root.
    pub fn takeNavigation(self: *Binding) host_mod.Error!?Navigation.Ticket {
        if (!self.accepting) return error.State;
        try self.invalidateNavigation();
        if (!self.navigation.pending) return null;
        try self.render();
        return self.navigation.take();
    }

    /// Only apply a still-current, independently authorized resolution.
    /// A navigation ticket is not itself proof of trust or root identity.
    pub fn selectResolved(self: *Binding, ticket: *const Navigation.Ticket, provider: contract.Provider, workspace: *const identity.Workspace) host_mod.Error!void {
        if (!self.accepting) return error.State;
        try self.invalidateNavigation();
        if (ticket.directory() == null or !self.navigation.isCurrent(ticket)) {
            try self.render();
            return error.State;
        }
        try self.selectAuthorized(provider, workspace);
    }

    /// Only the registered panel and declared vocabulary may invoke actions.
    /// Errors are retained for the owner; do not throw across C ABI.
    fn onCommand(user: ?*anyopaque, id: u64, command: abi.StringView) callconv(.c) void {
        const self: *Binding = @ptrCast(@alignCast(user orelse return));
        if (!self.accepting) return;
        const model = self.model orelse return;
        if (model.id != id) return;
        const name = abi.slice(command) orelse return;
        self.last_error = null;
        self.invalidateNavigation() catch |err| {
            self.last_error = err;
            self.render() catch {};
            return;
        };
        self.controller.command(name) catch |err| {
            self.last_error = err;
        };
        self.render() catch |err| {
            self.last_error = err;
        };
    }

    /// Resolved, independently authorized selection only. Never resolve a
    /// repository or spawn a CLI from this UI-thread method.
    pub fn select(self: *Binding, provider: contract.Provider, workspace: *const identity.Workspace) host_mod.Error!void {
        if (!self.accepting or self.navigation.table != null or self.navigation.accepting) return error.State;
        try self.selectAuthorized(provider, workspace);
    }

    fn selectAuthorized(self: *Binding, provider: contract.Provider, workspace: *const identity.Workspace) host_mod.Error!void {
        self.controller.select(provider, workspace) catch |err| {
            self.last_error = err;
            self.render() catch {};
            return err;
        };
        self.last_error = null;
        try self.render();
    }

    pub fn clear(self: *Binding) host_mod.Error!void {
        if (!self.accepting) return error.State;
        self.controller.clear() catch |err| {
            self.last_error = err;
            self.render() catch {};
            return err;
        };
        self.last_error = null;
        try self.render();
    }

    /// An explicit owner event can advance a task and repaint. No wait or
    /// recursive dispatch. After closing, the owner may still pump to drain.
    pub fn pump(self: *Binding) host_mod.Error!void {
        self.invalidateNavigation() catch |err| {
            self.last_error = err;
            if (self.accepting) self.render() catch {};
            return err;
        };
        self.controller.pump() catch |err| {
            self.last_error = err;
            return err;
        };
        self.last_error = null;
        if (self.accepting) try self.render();
    }

    pub fn render(self: *Binding) host_mod.Error!void {
        if (!self.accepting) return error.State;
        const model = if (self.model) |*value| value else return error.State;
        var content: panel.Content = undefined;
        var tree: ui.Tree = undefined;
        const current = self.controller.view();
        content.buildInteractive(self.language, &current, &tree);
        model.update(&tree) catch |err| {
            self.last_error = err;
            // STATE may mean the user closed the panel. Do not assume that
            // ownership has been released until the close path confirms it.
            if (err == error.State) self.accepting = false;
            return err;
        };
    }

    fn closeModel(self: *Binding) host_mod.Error!void {
        self.accepting = false;
        if (self.poisoned) return error.State;
        if (self.model) |*model| {
            try model.close();
            self.model = null;
        }
    }

    /// Always attempt both cancellation and panel close, even if one fails.
    /// This does not wait for the host worker. Keep self and all provider
    /// userdata alive until checkDrained or the documented host destroy gate.
    pub fn requestStop(self: *Binding) host_mod.Error!void {
        self.accepting = false;
        var failure: ?host_mod.Error = null;
        self.navigation.close() catch |err| {
            failure = err;
        };
        self.controller.requestStop() catch |err| {
            failure = err;
        };
        self.closeModel() catch |err| {
            failure = err;
        };
        self.last_error = failure;
        if (failure) |err| return err;
    }

    pub fn checkDrained(self: *const Binding) error{Busy}!void {
        if (self.model != null or self.poisoned) return error.Busy;
        try self.navigation.checkDrained();
        try self.controller.checkDrained();
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

const MockUi = struct {
    created: usize = 0,
    closed: usize = 0,
    updates: usize = 0,
    subscriptions: usize = 0,
    fail_subscribe_at: usize = 0,
    fail_close: bool = false,
    fail_update: bool = false,
    callback: ui.ClickFn = null,
    callback_user: ?*anyopaque = null,

    fn create(user: ?*anyopaque, _: abi.StringView, tree: [*c]const ui.Tree, out: [*c]u64) callconv(.c) abi.Status {
        const self: *MockUi = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (tree == null or tree.*.root == null or tree.*.command_count != 3) return abi.error_argument;
        self.created += 1;
        out.* = 7;
        return abi.ok;
    }

    fn update(user: ?*anyopaque, id: u64, tree: [*c]const ui.Tree) callconv(.c) abi.Status {
        const self: *MockUi = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (id != 7 or tree == null or tree.*.command_count != 3) return abi.error_argument;
        if (self.fail_update) return abi.error_state;
        self.updates += 1;
        return abi.ok;
    }

    fn subscribe(user: ?*anyopaque, id: u64, command: abi.StringView, callback: ui.ClickFn, data: ?*anyopaque, out: [*c]u64) callconv(.c) abi.Status {
        const self: *MockUi = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (id != 7 or callback == null or data == null or panel.parseCommand(abi.slice(command) orelse return abi.error_argument) == null) return abi.error_argument;
        self.subscriptions += 1;
        if (self.subscriptions == self.fail_subscribe_at) return abi.error_permission;
        self.callback = callback;
        self.callback_user = data;
        out.* = self.subscriptions;
        return abi.ok;
    }

    fn unsubscribe(_: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        return abi.ok;
    }

    fn close(user: ?*anyopaque, id: u64) callconv(.c) abi.Status {
        const self: *MockUi = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (id != 7) return abi.error_argument;
        if (self.fail_close) return abi.error_permission;
        self.closed += 1;
        self.callback = null;
        self.callback_user = null;
        return abi.ok;
    }

    fn table(self: *MockUi) ui.TableV1 {
        return .{
            .size = @sizeOf(ui.TableV1),
            .version = ui.version_1,
            .context = self,
            .create = &create,
            .update = &update,
            .subscribe_command = &subscribe,
            .unsubscribe = &unsubscribe,
            .close = &close,
        };
    }

    fn click(self: *MockUi, id: u64, command: []const u8) void {
        if (self.callback) |callback| callback(self.callback_user, id, abi.view(command));
    }
};

test "binding registers real SDK commands and updates after task completion" {
    var mock: Mock = .{};
    var host_ui: MockUi = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.openWithTable(host_ui.table());
    try std.testing.expectEqual(@as(usize, 3), host_ui.subscriptions);
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try binding.select(mock.provider(), &workspace);
    const updates = host_ui.updates;
    host_ui.click(99, panel.command_cancel);
    try std.testing.expectEqual(updates, host_ui.updates);
    mock.runWork();
    host_ui.click(7, panel.command_check);
    try std.testing.expectEqual(panel.Phase.ready, binding.controller.view().phase);
    try std.testing.expect(host_ui.updates > updates);
    try std.testing.expect(binding.last_error == null);
    host_ui.click(7, panel.command_refresh);
    try std.testing.expectEqual(panel.Phase.refreshing, binding.controller.view().phase);
    try binding.requestStop();
    try std.testing.expect(host_ui.callback == null);
    try std.testing.expectError(error.Busy, binding.checkDrained());
    mock.runWork();
    try binding.pump();
    try binding.checkDrained();
}

test "binding preflights interfaces and retains failed partial rollback" {
    var mock: Mock = .{};
    var host_ui: MockUi = .{ .fail_subscribe_at = 2, .fail_close = true };
    var binding = try Binding.init(mock.table(), .zh);
    var incomplete = host_ui.table();
    incomplete.close = null;
    try std.testing.expectError(error.Unavailable, binding.openWithTable(incomplete));
    try std.testing.expectEqual(@as(usize, 0), host_ui.created);
    try std.testing.expectError(error.Permission, binding.openWithTable(host_ui.table()));
    try std.testing.expect(!binding.accepting);
    try std.testing.expect(binding.model != null);
    host_ui.click(7, panel.command_check);
    try std.testing.expectEqual(@as(usize, 0), host_ui.updates);
    try std.testing.expectError(error.Busy, binding.checkDrained());
    host_ui.fail_close = false;
    try binding.requestStop();
    try binding.checkDrained();
    try std.testing.expectEqual(@as(usize, 1), host_ui.closed);
}

test "model update failure does not free an active host task" {
    var mock: Mock = .{};
    var host_ui: MockUi = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.openWithTable(host_ui.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    host_ui.fail_update = true;
    try std.testing.expectError(error.State, binding.select(mock.provider(), &workspace));
    try std.testing.expect(!binding.accepting);
    try std.testing.expectError(error.Busy, binding.checkDrained());
    try binding.requestStop();
    mock.runWork();
    try binding.pump();
    try binding.checkDrained();
}

test "navigation tickets prevent obsolete selection and result publication" {
    var mock: Mock = .{};
    var host_ui: MockUi = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.openWithTable(host_ui.table());
    // Context adapter callback ownership is tested in pulse_context.
    // Model the mailbox's latest copied tickets here to exercise the gate.
    binding.navigation.accepting = true;
    var first: Binding.Navigation.Ticket = .{ .generation = 1, .len = 3 };
    @memcpy(first.bytes[0..3], "one");
    binding.navigation.latest = first;
    binding.navigation.pending = true;
    const ticket = (try binding.takeNavigation()).?;
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try std.testing.expectError(error.State, binding.select(mock.provider(), &workspace));
    try binding.selectResolved(&ticket, mock.provider(), &workspace);
    mock.runWork();
    var second: Binding.Navigation.Ticket = .{ .generation = 2, .len = 3 };
    @memcpy(second.bytes[0..3], "two");
    binding.navigation.latest = second;
    binding.navigation.pending = true;
    try std.testing.expectError(error.State, binding.selectResolved(&ticket, mock.provider(), &workspace));
    // The mock cancel changes state to cancelling even if work had finished.
    mock.state = .completed;
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.empty, binding.controller.view().phase);
    try std.testing.expect(binding.controller.view().snapshot == null);
    const next = (try binding.takeNavigation()).?;
    try std.testing.expectEqualStrings("two", next.directory().?);
    try binding.requestStop();
    try binding.checkDrained();
}
