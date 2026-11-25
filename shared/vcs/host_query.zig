//! Host-owned worker bridge for one approved VCS query, no nested future.
//! All SDK task calls are UI-owner only. Worker reads immutable input and
//! publishes a copy-owned result using release/acquire ordering. The input
//! provider, Runner, I/O and this slot must remain stable through release.
//! Caller must establish repository/tool trust before start. Cancellation
//! discards results; the provider is still bounded by its own command
//! deadlines. Do not interpret a cancel request as a completed process join.
//! Optional dispatch hints may advance an owner pump; they do not prove terminal
//! task state. No automatic polling or DLL unload is implied by this bridge.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("pulse_abi");
const async_host = @import("pulse_async_host");
const host_mod = @import("pulse_host");
const identity = @import("vcs_identity");
const contract = @import("vcs_provider");
const panel = @import("vcs_panel");
const ui = @import("pulse_ui_model");
const context_mod = @import("pulse_context");
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
    wake: ?*async_host.Wake = null,
    admitting: bool = false,

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
        self.admitting = true;
        defer self.admitting = false;
        try self.task.start(&descriptor);
    }

    fn work(user: ?*anyopaque, context: [*c]const async_host.Context) callconv(.c) u32 {
        const self: *Query = @ptrCast(@alignCast(user orelse return @backingInt(async_host.TaskState.failed)));
        defer if (self.wake) |wake| wake.request();
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

/// The resolver runs on a host worker, not in a context/UI callback.
/// The caller supplies independent repository/tool approval and stable
/// provider contexts. A marker is not approval and no PATH fallback is allowed.
pub const Resolved = struct {
    provider: contract.Provider,
    workspace: identity.Workspace,
};

pub const Resolver = struct {
    ctx: *anyopaque,
    resolve: *const fn (*anyopaque, *const identity.Path) contract.Error!?Resolved,
};

/// Marker discovery is deliberately separate from selection and authorization.
/// The policy must authorize the actual installation, repository configuration
/// and metadata paths before it runs any provider resolution command.
/// No candidate is silently preferred over another (including Git + JJ).
pub const Discovery = struct {
    probe: detect.Probe,
    policy_ctx: *anyopaque,
    authorizeAndResolve: *const fn (*anyopaque, *const identity.Path, *const detect.Result) contract.Error!?Resolved,

    pub fn resolver(self: *Discovery) Resolver {
        return .{ .ctx = self, .resolve = &resolve };
    }

    fn resolve(user: *anyopaque, directory: *const identity.Path) contract.Error!?Resolved {
        const self: *Discovery = @ptrCast(@alignCast(user));
        const path = directory.slice();
        // Lexical local-path gate only. Probe/policy must independently
        // reject junctions, reparse points, untrusted config and remote I/O.
        if (!localDirectory(path)) return error.Permission;
        const candidates = detect.detect(path, self.probe);
        if (candidates.len == 0) return null;
        const selected = (try self.authorizeAndResolve(self.policy_ctx, directory, &candidates)) orelse return null;
        if (selected.provider.kind != selected.workspace.kind or !selected.provider.supports(.status)) return error.Unsupported;
        const candidate = candidates.find(selected.workspace.kind) orelse return error.Permission;
        if (selected.workspace.root.len == 0 or selected.workspace.root.len > identity.max_path_bytes or selected.workspace.repository_root.len == 0 or selected.workspace.repository_root.len > identity.max_path_bytes) return error.Parse;
        if (!candidate.root.eql(selected.workspace.root.slice())) return error.Permission;
        return selected;
    }

    fn localDirectory(path: []const u8) bool {
        if (builtin.os.tag == .windows) {
            if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or (path[2] != '\\' and path[2] != '/')) return false;
            if (std.mem.indexOfScalar(u8, path[2..], ':') != null) return false;
        } else if (path.len == 0 or path[0] != '/') return false;
        var parts = std.mem.tokenizeAny(u8, path, if (builtin.os.tag == .windows) "/\\" else "/");
        while (parts.next()) |part| {
            if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
        }
        return true;
    }
};

/// Exactly one host-owned resolver task. All task API operations are owner
/// only; the worker writes the result once and publishes it with release.
/// Terminal observation and successful release precede any selection handoff.
pub const Resolution = struct {
    pub const Ticket = context_mod.Navigation(identity.max_path_bytes).Ticket;
    pub const Result = struct {
        ticket: Ticket,
        selection: contract.Error!?Resolved,
    };

    task: async_host.Task,
    resolver: Resolver = undefined,
    ticket: Ticket = undefined,
    directory: identity.Path = undefined,
    result: contract.Error!?Resolved = error.Cancelled,
    published: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    discard: bool = false,
    stopped: bool = false,
    wake: ?*async_host.Wake = null,
    admitting: bool = false,

    pub fn init(table: async_host.TaskTable) host_mod.Error!Resolution {
        return .{ .task = try async_host.Task.init(table) };
    }

    pub fn start(self: *Resolution, resolver: Resolver, ticket: *const Ticket) host_mod.Error!void {
        if (self.stopped or self.task.occupied()) return error.State;
        const directory = ticket.directory() orelse return error.Argument;
        self.directory = identity.Path.init(directory) catch return error.Argument;
        self.ticket = ticket.*;
        self.resolver = resolver;
        self.result = error.Cancelled;
        self.published.store(false, .monotonic);
        self.discard = false;
        const descriptor: async_host.Descriptor = .{
            .size = @sizeOf(async_host.Descriptor),
            .title = abi.view("VCS repository discovery"),
            .type = abi.view("vcs.resolve"),
            .work = &work,
            .user = self,
        };
        self.admitting = true;
        defer self.admitting = false;
        try self.task.start(&descriptor);
    }

    fn work(user: ?*anyopaque, ctx: [*c]const async_host.Context) callconv(.c) u32 {
        const self: *Resolution = @ptrCast(@alignCast(user orelse return @backingInt(async_host.TaskState.failed)));
        defer if (self.wake) |wake| wake.request();
        if (ctx == null) return @backingInt(async_host.TaskState.failed);
        const cancelled = ctx.*.cancelled orelse return @backingInt(async_host.TaskState.failed);
        if (cancelled(ctx.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
        self.result = self.resolver.resolve(self.resolver.ctx, &self.directory);
        self.published.store(true, .release);
        if (cancelled(ctx.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
        if (self.result) |_| {
            return @backingInt(async_host.TaskState.completed);
        } else |err| {
            return @backingInt(if (err == error.Cancelled) async_host.TaskState.cancelled else async_host.TaskState.failed);
        }
    }

    pub fn poll(self: *Resolution) host_mod.Error!?Result {
        if (!self.task.occupied()) return null;
        const state = try self.task.poll();
        if (!state.terminal()) return null;
        var selection: contract.Error!?Resolved = error.Io;
        if (self.discard or self.stopped or state == .cancelled) {
            selection = error.Cancelled;
        } else if (self.published.load(.acquire)) {
            if (self.result) |value| {
                if (state == .completed) selection = value;
            } else |err| selection = err;
        }
        try self.task.releaseTerminal();
        return .{ .ticket = self.ticket, .selection = selection };
    }

    pub fn cancel(self: *Resolution) host_mod.Error!void {
        self.discard = true;
        try self.task.cancel();
    }

    pub fn requestStop(self: *Resolution) host_mod.Error!void {
        self.stopped = true;
        try self.cancel();
    }

    pub fn checkDrained(self: *const Resolution) error{Busy}!void {
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
    pub const Navigation = context_mod.Navigation(identity.max_path_bytes);

    controller: Controller,
    resolution: Resolution,
    resolver: ?Resolver = null,
    wake: ?async_host.Wake = null,
    pumping: bool = false,
    navigation: Navigation = .{},
    navigation_generation: ?u64 = null,
    model: ?ui.Panel = null,
    language: panel.Language,
    approval_locked: bool = false,
    accepting: bool = false,
    poisoned: bool = false,
    last_error: ?host_mod.Error = null,

    pub fn init(table: async_host.TaskTable, language: panel.Language) host_mod.Error!Binding {
        return .{ .controller = try Controller.init(table), .resolution = try Resolution.init(table), .language = language };
    }

    /// Permanent lock for a lifecycle-only attachment. No resolver or
    /// provider can be configured through this Binding after locking.
    pub fn lockExecution(self: *Binding) host_mod.Error!void {
        if (self.model != null or self.resolver != null or self.controller.selection != null or self.controller.query.task.occupied() or self.resolution.task.occupied() or self.navigation.table != null or self.controller.stopped) return error.State;
        self.approval_locked = true;
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
        var current = self.controller.view();
        current.approval_required = self.approval_locked;
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

    /// Configure once at the final stable address, before panel/navigation
    /// registration or any task. Workers may only request a wake; all state
    /// transitions and SDK task/model calls still belong to the owner.
    pub fn configureDispatch(self: *Binding, dispatch: async_host.Dispatch) host_mod.Error!void {
        if (self.wake != null or self.model != null or self.controller.stopped or self.navigation.table != null or self.controller.query.task.occupied() or self.resolution.task.occupied()) return error.State;
        self.wake = try async_host.Wake.init(dispatch, &onWake, self);
        if (self.wake) |*wake| {
            self.controller.query.wake = wake;
            self.resolution.wake = wake;
            self.navigation.notify = &onNavigation;
            self.navigation.notify_user = wake;
        }
    }

    fn onNavigation(user: *anyopaque) void {
        const wake: *async_host.Wake = @ptrCast(@alignCast(user));
        wake.request();
    }

    fn onWake(user: *anyopaque) void {
        const self: *Binding = @ptrCast(@alignCast(user));
        // Inline delivery during admission or borrowed context callback may
        // precede the task ID or invalidate the host's callback contract.
        if (!self.accepting or self.pumping or self.navigation.notifying or self.controller.query.admitting or self.resolution.admitting) return;
        self.pump() catch |err| {
            self.last_error = err;
        };
    }

    /// A latched dispatch failure is independent of provider/query outcome.
    pub fn notificationFailure(self: *const Binding) ?host_mod.Error {
        if (self.wake) |*wake| return wake.lastFailure();
        return null;
    }

    fn drainWake(self: *Binding) host_mod.Error!void {
        if (self.controller.query.task.occupied() or self.resolution.task.occupied() or self.navigation.table != null) return;
        if (self.wake) |*wake| try wake.drain();
    }

    /// Opt in before subscribing. The resolver and all policy/provider
    /// contexts must remain alive until successful stop/drain. Without one,
    /// manual takeNavigation/selectResolved retains its existing semantics.
    pub fn configureResolver(self: *Binding, resolver: Resolver) host_mod.Error!void {
        if (self.approval_locked) return error.Permission;
        if (self.controller.stopped or self.resolver != null or self.navigation.table != null or self.controller.selection != null or self.controller.query.task.occupied()) return error.State;
        self.resolver = resolver;
    }

    /// Subscribe only after the panel is live. Callback delivery stores a
    /// bounded directory ticket; no VCS tool or filesystem lookup runs there.
    pub fn openNavigation(self: *Binding, host: host_mod.Host) host_mod.Error!void {
        try self.openNavigationWithTable(try context_mod.Table.init(host.raw()));
    }

    pub fn openNavigationWithTable(self: *Binding, table: context_mod.Table) host_mod.Error!void {
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
        var failure: ?host_mod.Error = null;
        self.resolution.cancel() catch |err| {
            failure = err;
        };
        self.controller.clear() catch |err| {
            failure = err;
        };
        if (failure) |err| return err;
        self.navigation_generation = latest.generation;
        if (self.resolver != null and self.navigation.pending and latest.directory() != null) self.controller.current = .{ .phase = .queued };
    }

    /// The owner can schedule independent repository discovery and approval
    /// for this ticket. A null directory means clear, not a repository root.
    pub fn takeNavigation(self: *Binding) host_mod.Error!?Navigation.Ticket {
        if (!self.accepting or self.resolver != null) return error.State;
        try self.invalidateNavigation();
        if (!self.navigation.pending) return null;
        try self.render();
        return self.navigation.take();
    }

    /// Only apply a still-current, independently authorized resolution.
    /// A navigation ticket is not itself proof of trust or root identity.
    pub fn selectResolved(self: *Binding, ticket: *const Navigation.Ticket, provider: contract.Provider, workspace: *const identity.Workspace) host_mod.Error!void {
        if (self.approval_locked) return error.Permission;
        if (!self.accepting or self.resolver != null) return error.State;
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
        if (self.approval_locked and !std.mem.eql(u8, name, panel.command_check)) {
            self.last_error = error.Permission;
            return;
        }
        self.invalidateNavigation() catch |err| {
            self.last_error = err;
            self.render() catch {};
            return;
        };
        if (self.resolver != null) {
            const command_kind = panel.parseCommand(name) orelse {
                self.last_error = error.Argument;
                return;
            };
            if (command_kind == .check) {
                self.pump() catch |err| {
                    self.last_error = err;
                };
                return;
            }
            if (command_kind == .refresh) {
                self.retryResolution() catch |err| {
                    self.last_error = err;
                };
                self.render() catch |err| {
                    self.last_error = err;
                };
                return;
            }
            if (command_kind == .cancel and (self.resolution.task.occupied() or self.navigation.pending)) {
                self.cancelResolution() catch |err| {
                    self.last_error = err;
                };
                self.render() catch |err| {
                    self.last_error = err;
                };
                return;
            }
        }
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
        if (self.approval_locked) return error.Permission;
        if (!self.accepting or self.resolver != null or self.navigation.table != null or self.navigation.accepting) return error.State;
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
        if (self.resolver != null) {
            self.navigation.pending = false;
            self.resolution.cancel() catch |err| {
                self.controller.clear() catch {};
                self.last_error = err;
                self.render() catch {};
                return err;
            };
        }
        self.controller.clear() catch |err| {
            self.last_error = err;
            self.render() catch {};
            return err;
        };
        self.last_error = null;
        try self.render();
    }

    /// A refresh is an explicit fresh policy decision, not permission cached
    /// indefinitely from a prior navigation. Retain old task ownership.
    fn retryResolution(self: *Binding) host_mod.Error!void {
        if (!self.accepting or !self.navigation.accepting or self.controller.stopped) return error.State;
        if (self.controller.current.phase == .queued or self.controller.current.phase == .refreshing) return error.State;
        const latest = self.navigation.latest orelse return error.State;
        if (latest.directory() == null) return error.State;
        self.navigation.pending = true;
        var failure: ?host_mod.Error = null;
        self.resolution.cancel() catch |err| {
            failure = err;
        };
        self.controller.clear() catch |err| {
            failure = err;
        };
        self.controller.current = .{ .phase = .queued };
        if (failure) |err| return err;
        try self.pump();
    }

    fn cancelResolution(self: *Binding) host_mod.Error!void {
        self.navigation.pending = false;
        self.controller.current = .{ .phase = .cancelled };
        var failure: ?host_mod.Error = null;
        self.resolution.cancel() catch |err| {
            failure = err;
        };
        self.controller.cancel() catch |err| {
            failure = err;
        };
        self.controller.current.phase = .cancelled;
        if (failure) |err| return err;
    }

    /// One resolver or summary at a time, including release failure.
    /// Never consume a pending ticket until host admission succeeds.
    fn pumpResolution(self: *Binding) host_mod.Error!void {
        const resolver = self.resolver orelse return;
        const discarded = self.resolution.discard;
        if (try self.resolution.poll()) |finished| {
            if (self.accepting and !discarded and self.navigation.isCurrent(&finished.ticket)) {
                if (finished.selection) |selection| {
                    if (selection) |selected| {
                        try self.controller.select(selected.provider, &selected.workspace);
                    } else self.controller.current = .{ .phase = .empty };
                } else |err| {
                    self.controller.current = .{ .phase = if (err == error.Cancelled) .cancelled else .failed, .failure = if (err == error.Cancelled) null else err };
                }
            }
        }
        if (!self.accepting or self.controller.stopped or self.resolution.task.occupied() or self.controller.query.task.occupied() or !self.navigation.pending) return;
        const ticket = self.navigation.latest orelse return;
        if (ticket.directory() == null) {
            _ = self.navigation.take();
            return;
        }
        self.controller.current = .{ .phase = .queued };
        self.resolution.start(resolver, &ticket) catch |err| {
            self.controller.current = .{ .phase = .failed, .failure = if (err == error.Permission) error.Permission else error.Io };
            return err;
        };
        _ = self.navigation.take();
        self.controller.current = .{ .phase = .refreshing };
    }

    /// An explicit owner event can advance a task and repaint. No wait or
    /// recursive dispatch. After closing, the owner may still pump to drain.
    pub fn pump(self: *Binding) host_mod.Error!void {
        if (self.pumping) return error.State;
        self.pumping = true;
        defer self.pumping = false;
        if (self.wake) |*wake| wake.reap();
        self.invalidateNavigation() catch |err| {
            self.last_error = err;
            if (self.accepting) self.render() catch {};
            return err;
        };
        self.controller.pump() catch |err| {
            self.last_error = err;
            return err;
        };
        self.pumpResolution() catch |err| {
            self.last_error = err;
            if (self.accepting) self.render() catch {};
            return err;
        };
        self.last_error = null;
        if (self.accepting) {
            try self.render();
        } else if (self.controller.stopped) {
            try self.drainWake();
        }
    }

    pub fn render(self: *Binding) host_mod.Error!void {
        if (!self.accepting) return error.State;
        // Even an explicit repaint must not expose a superseded workspace.
        // Clear the view before cancel; paint that cleared state on failure.
        var navigation_error: ?host_mod.Error = null;
        self.invalidateNavigation() catch |err| {
            navigation_error = err;
        };
        const model = if (self.model) |*value| value else return error.State;
        var content: panel.Content = undefined;
        var tree: ui.Tree = undefined;
        var current = self.controller.view();
        current.approval_required = self.approval_locked;
        if (self.resolver != null and self.navigation.accepting) {
            if (self.navigation.latest) |*latest| current.discovery_available = latest.directory() != null;
        }
        content.buildInteractive(self.language, &current, &tree);
        model.update(&tree) catch |err| {
            self.last_error = err;
            // STATE may mean the user closed the panel. Do not assume that
            // ownership has been released until the close path confirms it.
            if (err == error.State) self.accepting = false;
            return err;
        };
        if (navigation_error) |err| {
            self.last_error = err;
            return err;
        }
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
        if (self.wake) |*wake| wake.disable();
        var failure: ?host_mod.Error = null;
        self.navigation.close() catch |err| {
            failure = err;
        };
        self.resolution.requestStop() catch |err| {
            failure = err;
        };
        self.controller.requestStop() catch |err| {
            failure = err;
        };
        self.closeModel() catch |err| {
            failure = err;
        };
        self.drainWake() catch |err| {
            failure = err;
        };
        self.last_error = failure;
        if (failure) |err| return err;
    }

    pub fn checkDrained(self: *const Binding) error{Busy}!void {
        if (self.model != null or self.poisoned) return error.Busy;
        try self.navigation.checkDrained();
        try self.resolution.checkDrained();
        try self.controller.checkDrained();
        if (self.wake) |*wake| try wake.checkDrained();
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

const MockNavigation = struct {
    callback: context_mod.ChangeFn = null,
    data: ?*anyopaque = null,
    fail_close: bool = false,

    fn get(_: ?*anyopaque, callback: context_mod.ChangeFn, data: ?*anyopaque) callconv(.c) abi.Status {
        var snapshot: context_mod.Snapshot = .{ .size = @sizeOf(context_mod.Snapshot), .directory = abi.view("one") };
        (callback orelse return abi.error_argument)(data, &snapshot);
        return abi.ok;
    }

    fn subscribe(user: ?*anyopaque, callback: context_mod.ChangeFn, data: ?*anyopaque, out: [*c]context_mod.SubscriptionId) callconv(.c) abi.Status {
        const self: *MockNavigation = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.callback = callback;
        self.data = data;
        out.* = 3;
        return abi.ok;
    }

    fn unsubscribe(user: ?*anyopaque, id: context_mod.SubscriptionId) callconv(.c) abi.Status {
        const self: *MockNavigation = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (id != 3) return abi.error_argument;
        if (self.fail_close) return abi.error_permission;
        self.callback = null;
        self.data = null;
        return abi.ok;
    }

    fn table(self: *MockNavigation) context_mod.Table {
        return .{ .raw = .{
            .size = @sizeOf(context_mod.TableV1),
            .version = context_mod.version_1,
            .context = self,
            .get = &get,
            .subscribe = &subscribe,
            .unsubscribe = &unsubscribe,
        } };
    }

    fn navigate(self: *MockNavigation, path: []const u8) void {
        var snapshot: context_mod.Snapshot = .{ .size = @sizeOf(context_mod.Snapshot), .directory = abi.view(path) };
        if (self.callback) |callback| callback(self.data, &snapshot);
    }
};

test "navigation tickets prevent obsolete selection and result publication" {
    var mock: Mock = .{};
    var host_ui: MockUi = .{};
    var host_context: MockNavigation = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.openWithTable(host_ui.table());
    try binding.openNavigationWithTable(host_context.table());
    const ticket = (try binding.takeNavigation()).?;
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try std.testing.expectError(error.State, binding.select(mock.provider(), &workspace));
    try binding.selectResolved(&ticket, mock.provider(), &workspace);
    mock.runWork();
    host_context.navigate("two");
    // Explicit render must invalidate the result before a pump or UI command.
    try binding.render();
    try std.testing.expectEqual(panel.Phase.empty, binding.controller.view().phase);
    try std.testing.expectError(error.State, binding.selectResolved(&ticket, mock.provider(), &workspace));
    // The mock cancel changes state to cancelling even if work had finished.
    mock.state = .completed;
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.empty, binding.controller.view().phase);
    try std.testing.expect(binding.controller.view().snapshot == null);
    const next = (try binding.takeNavigation()).?;
    try std.testing.expectEqualStrings("two", next.directory().?);
    host_context.fail_close = true;
    try std.testing.expectError(error.Permission, binding.requestStop());
    try std.testing.expectError(error.Busy, binding.checkDrained());
    host_context.navigate("late");
    host_context.fail_close = false;
    try binding.requestStop();
    try binding.checkDrained();
    try std.testing.expect(host_context.callback == null);
}

const MockResolver = struct {
    host_task: *Mock,
    calls: usize = 0,
    denied: bool = false,
    no_repository: bool = false,

    fn resolve(user: *anyopaque, directory: *const identity.Path) contract.Error!?Resolved {
        const self: *MockResolver = @ptrCast(@alignCast(user));
        self.calls += 1;
        if (self.denied) return error.Permission;
        if (self.no_repository) return null;
        const workspace = identity.Workspace.init(.git, directory.slice(), directory.slice()) catch return error.Parse;
        return .{ .provider = self.host_task.provider(), .workspace = workspace };
    }

    fn resolver(self: *MockResolver) Resolver {
        return .{ .ctx = self, .resolve = &resolve };
    }
};

test "resolver release failure retains ownership and never starts a summary early" {
    var mock: Mock = .{};
    var resolver: MockResolver = .{ .host_task = &mock };
    var resolution = try Resolution.init(mock.table());
    var ticket: Resolution.Ticket = .{ .generation = 7, .len = 3 };
    @memcpy(ticket.bytes[0..3], "one");
    try resolution.start(resolver.resolver(), &ticket);
    try std.testing.expect((try resolution.poll()) == null);
    mock.runWork();
    mock.fail_release = true;
    try std.testing.expectError(error.State, resolution.poll());
    try std.testing.expectError(error.Busy, resolution.checkDrained());
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
    mock.fail_release = false;
    const finished = (try resolution.poll()).?;
    try std.testing.expectEqual(@as(u64, 7), finished.ticket.generation);
    const selected = (try finished.selection).?;
    try std.testing.expect(selected.workspace.root.eql("one"));
    try resolution.checkDrained();
}

test "binding serializes resolver and summary across obsolete navigation" {
    var mock: Mock = .{};
    var resolver: MockResolver = .{ .host_task = &mock };
    var host_ui: MockUi = .{};
    var host_context: MockNavigation = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.configureResolver(resolver.resolver());
    try binding.openWithTable(host_ui.table());
    try binding.openNavigationWithTable(host_context.table());
    try binding.pump();
    try std.testing.expect(binding.resolution.task.occupied());
    try std.testing.expect(!binding.controller.query.task.occupied());
    mock.runWork();
    host_context.navigate("two");
    host_context.navigate("three");
    try binding.pump();
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
    mock.state = .completed;
    try binding.pump();
    try std.testing.expect(binding.resolution.task.occupied());
    try std.testing.expect(!binding.controller.query.task.occupied());
    mock.runWork();
    try binding.pump();
    try std.testing.expect(!binding.resolution.task.occupied());
    try std.testing.expect(binding.controller.query.task.occupied());
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.ready, binding.controller.view().phase);
    try std.testing.expect(binding.controller.view().workspace.?.root.eql("three"));
    try std.testing.expectEqual(@as(usize, 2), resolver.calls);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    try binding.requestStop();
    try binding.checkDrained();
}

test "resolver denial and cancellation never admit a VCS summary" {
    var mock: Mock = .{};
    var resolver: MockResolver = .{ .host_task = &mock, .denied = true };
    var host_ui: MockUi = .{};
    var host_context: MockNavigation = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.configureResolver(resolver.resolver());
    try binding.openWithTable(host_ui.table());
    try binding.openNavigationWithTable(host_context.table());
    try binding.pump();
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.failed, binding.controller.view().phase);
    try std.testing.expectEqual(error.Permission, binding.controller.view().failure.?);
    resolver.denied = false;
    host_context.navigate("two");
    try binding.pump();
    host_ui.click(7, panel.command_cancel);
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.cancelled, binding.controller.view().phase);
    try std.testing.expectEqual(@as(usize, 1), resolver.calls);
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
    host_context.navigate("three");
    try binding.pump();
    try binding.requestStop();
    try std.testing.expectError(error.Busy, binding.checkDrained());
    mock.runWork();
    try binding.pump();
    try binding.checkDrained();
}

const DiscoveryFixture = struct {
    host_task: *Mock,
    policy_calls: usize = 0,
    lookups: usize = 0,
    deny: bool = false,
    wrong_root: bool = false,

    fn lookup(user: *anyopaque, path: []const u8) detect.EntryType {
        const self: *DiscoveryFixture = @ptrCast(@alignCast(user));
        self.lookups += 1;
        return if (std.mem.endsWith(u8, path, std.fs.path.sep_str ++ ".git")) .directory else .missing;
    }

    fn authorize(user: *anyopaque, _: *const identity.Path, candidates: *const detect.Result) contract.Error!?Resolved {
        const self: *DiscoveryFixture = @ptrCast(@alignCast(user));
        self.policy_calls += 1;
        if (self.deny) return error.Permission;
        const candidate = candidates.find(.git) orelse return null;
        const root = if (self.wrong_root) "unrelated" else candidate.root.slice();
        const workspace = identity.Workspace.init(.git, root, root) catch return error.Parse;
        return .{ .provider = self.host_task.provider(), .workspace = workspace };
    }
};

test "discovery requires local candidate and explicit policy decision" {
    var mock: Mock = .{};
    var fixture: DiscoveryFixture = .{ .host_task = &mock, .deny = true };
    var discovery: Discovery = .{
        .probe = .{ .ctx = &fixture, .lookup = &DiscoveryFixture.lookup },
        .policy_ctx = &fixture,
        .authorizeAndResolve = &DiscoveryFixture.authorize,
    };
    const relative = try identity.Path.init("relative");
    try std.testing.expectError(error.Permission, Discovery.resolve(&discovery, &relative));
    try std.testing.expectEqual(@as(usize, 0), fixture.lookups);
    const local = try identity.Path.init(if (builtin.os.tag == .windows) "C:\\work" else "/work");
    try std.testing.expectError(error.Permission, Discovery.resolve(&discovery, &local));
    try std.testing.expectEqual(@as(usize, 1), fixture.policy_calls);
    fixture.deny = false;
    fixture.wrong_root = true;
    try std.testing.expectError(error.Permission, Discovery.resolve(&discovery, &local));
    fixture.wrong_root = false;
    const selected = (try Discovery.resolve(&discovery, &local)).?;
    try std.testing.expect(selected.workspace.root.eql(local.slice()));
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
}

test "explicit refresh re-enters repository authorization instead of reusing the provider" {
    var mock: Mock = .{};
    var resolver: MockResolver = .{ .host_task = &mock };
    var host_ui: MockUi = .{};
    var host_context: MockNavigation = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.configureResolver(resolver.resolver());
    try binding.openWithTable(host_ui.table());
    try binding.openNavigationWithTable(host_context.table());
    try binding.pump();
    mock.runWork();
    try binding.pump();
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.ready, binding.controller.view().phase);
    resolver.denied = true;
    host_ui.click(7, panel.command_refresh);
    try std.testing.expect(binding.resolution.task.occupied());
    try std.testing.expect(!binding.controller.query.task.occupied());
    try std.testing.expect(binding.controller.view().snapshot == null);
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(error.Permission, binding.controller.view().failure.?);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    resolver.denied = false;
    host_ui.click(7, panel.command_refresh);
    try std.testing.expect(binding.resolution.task.occupied());
    mock.runWork();
    try binding.pump();
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.ready, binding.controller.view().phase);
    try std.testing.expectEqual(@as(usize, 3), resolver.calls);
    try std.testing.expectEqual(@as(usize, 2), mock.calls);
    try binding.requestStop();
    try binding.checkDrained();
}

const MockDispatch = struct {
    callback: async_host.DispatchCallback = null,
    data: ?*anyopaque = null,
    reject: bool = false,
    fail_cancel: bool = false,
    inline_delivery: bool = false,
    posts: usize = 0,

    fn post(user: ?*anyopaque, callback: async_host.DispatchCallback, data: ?*anyopaque, out: [*c]u64) callconv(.c) abi.Status {
        const self: *MockDispatch = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.posts += 1;
        if (self.reject or self.callback != null) return abi.error_state;
        self.callback = callback;
        self.data = data;
        if (self.inline_delivery) self.deliver();
        out.* = @intCast(self.posts);
        return abi.ok;
    }

    fn cancel(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *MockDispatch = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (self.fail_cancel or self.callback == null) return abi.error_state;
        self.callback = null;
        self.data = null;
        return abi.ok;
    }

    fn dispatch(self: *MockDispatch) async_host.Dispatch {
        return .{ .table = .{
            .size = @sizeOf(@FieldType(async_host.Dispatch, "table")),
            .version = 1,
            .context = self,
            .post = &post,
            .cancel = &cancel,
        } };
    }

    fn deliver(self: *MockDispatch) void {
        const callback = self.callback orelse return;
        const data = self.data;
        self.callback = null;
        self.data = null;
        callback(data);
    }
};

test "dispatch hints advance navigation and terminal query without a polling loop" {
    var mock: Mock = .{};
    var resolver: MockResolver = .{ .host_task = &mock };
    var host_ui: MockUi = .{};
    var host_context: MockNavigation = .{};
    var dispatch: MockDispatch = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.configureResolver(resolver.resolver());
    try binding.configureDispatch(dispatch.dispatch());
    try binding.openWithTable(host_ui.table());
    try binding.openNavigationWithTable(host_context.table());
    try std.testing.expect(!binding.resolution.task.occupied());
    dispatch.deliver();
    try std.testing.expect(binding.resolution.task.occupied());
    mock.runWork();
    // Host has published terminal state before this delivery.
    dispatch.deliver();
    try std.testing.expect(binding.controller.query.task.occupied());
    mock.runWork();
    dispatch.deliver();
    try std.testing.expectEqual(panel.Phase.ready, binding.controller.view().phase);
    try std.testing.expectEqual(@as(usize, 3), dispatch.posts);
    try std.testing.expect(dispatch.callback == null);
    try binding.requestStop();
    try binding.checkDrained();
}

test "early dispatch does not publish or recursively poll before host terminal state" {
    var mock: Mock = .{};
    var host_ui: MockUi = .{};
    var dispatch: MockDispatch = .{ .inline_delivery = true };
    var binding = try Binding.init(mock.table(), .en);
    try binding.configureDispatch(dispatch.dispatch());
    try binding.openWithTable(host_ui.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try binding.select(mock.provider(), &workspace);
    // runWork assigns terminal state only after the worker function returns.
    mock.runWork();
    try std.testing.expectEqual(panel.Phase.refreshing, binding.controller.view().phase);
    try std.testing.expectEqual(@as(usize, 1), dispatch.posts);
    try std.testing.expect(binding.controller.view().snapshot == null);
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.ready, binding.controller.view().phase);
    try binding.requestStop();
    try binding.checkDrained();
}

test "dispatch rejection preserves manual result delivery and failed cancel retains binding" {
    var mock: Mock = .{};
    var host_ui: MockUi = .{};
    var dispatch: MockDispatch = .{ .reject = true };
    var binding = try Binding.init(mock.table(), .en);
    try binding.configureDispatch(dispatch.dispatch());
    try binding.openWithTable(host_ui.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try binding.select(mock.provider(), &workspace);
    mock.runWork();
    try std.testing.expectEqual(error.State, binding.notificationFailure().?);
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.ready, binding.controller.view().phase);
    dispatch.reject = false;
    host_ui.click(7, panel.command_refresh);
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.ready, binding.controller.view().phase);
    dispatch.fail_cancel = true;
    try std.testing.expectError(error.State, binding.requestStop());
    try std.testing.expectError(error.Busy, binding.checkDrained());
    dispatch.deliver();
    try binding.requestStop();
    try binding.checkDrained();
}

test "locked lifecycle binding rejects every execution entry and retains failed close" {
    var mock: Mock = .{};
    var model: MockUi = .{};
    var navigation: MockNavigation = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.lockExecution();
    try binding.openWithTable(model.table());
    try binding.openNavigationWithTable(navigation.table());
    const workspace = try identity.Workspace.init(.git, "one", "one");
    try std.testing.expectError(error.Permission, binding.select(mock.provider(), &workspace));
    const ticket = (try binding.takeNavigation()).?;
    try std.testing.expectError(error.Permission, binding.selectResolved(&ticket, mock.provider(), &workspace));
    model.click(7, panel.command_refresh);
    try std.testing.expectEqual(error.Permission, binding.last_error.?);
    navigation.navigate("two");
    model.click(7, panel.command_check);
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
    try std.testing.expect(!binding.resolution.task.occupied());
    try std.testing.expect(!binding.controller.query.task.occupied());
    model.fail_close = true;
    try std.testing.expectError(error.Permission, binding.requestStop());
    try std.testing.expectError(error.Busy, binding.checkDrained());
    model.fail_close = false;
    try binding.requestStop();
    try binding.checkDrained();
    try std.testing.expect(navigation.callback == null);
    try std.testing.expect(model.callback == null);
}
