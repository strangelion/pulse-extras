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

pub const HostError = host_mod.Error;

pub const Query = struct {
    task: async_host.Task,
    provider: contract.Provider = undefined,
    workspace: identity.Workspace = undefined,
    result: contract.Error!contract.Snapshot = error.Cancelled,
    detail_request: ?contract.DetailRequest = null,
    detail_result: contract.Error!contract.DetailText = error.Cancelled,
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
        self.detail_request = null;
        self.detail_result = error.Cancelled;
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

    pub fn startDetail(self: *Query, provider: contract.Provider, workspace: *const identity.Workspace, request: contract.DetailRequest) host_mod.Error!void {
        if (self.stopped or self.task.occupied()) return error.State;
        if (provider.kind != workspace.kind or provider.vtable.detail == null or !contract.detailSupported(provider.kind, request.kind)) return error.Unavailable;
        self.provider = provider;
        self.workspace = workspace.*;
        self.detail_request = request;
        self.detail_result = error.Cancelled;
        self.published.store(false, .monotonic);
        self.discard = false;
        const descriptor: async_host.Descriptor = .{ .size = @sizeOf(async_host.Descriptor), .title = abi.view("VCS read-only detail"), .type = abi.view("vcs.detail"), .work = &work, .user = self };
        self.admitting = true;
        defer self.admitting = false;
        errdefer if (!self.task.occupied()) {
            self.detail_request = null;
        };
        try self.task.start(&descriptor);
    }

    fn work(user: ?*anyopaque, context: [*c]const async_host.Context) callconv(.c) u32 {
        const self: *Query = @ptrCast(@alignCast(user orelse return @backingInt(async_host.TaskState.failed)));
        defer if (self.wake) |wake| wake.request();
        if (context == null) return @backingInt(async_host.TaskState.failed);
        const cancelled = context.*.cancelled orelse return @backingInt(async_host.TaskState.failed);
        if (cancelled(context.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
        if (self.detail_request) |*request| {
            self.detail_result = self.provider.detail(&self.workspace, request);
            self.published.store(true, .release);
            if (self.detail_result) |_| {
                return @backingInt(if (cancelled(context.*.context) != 0) async_host.TaskState.cancelled else async_host.TaskState.completed);
            } else |err| {
                return @backingInt(if (err == error.Cancelled) async_host.TaskState.cancelled else async_host.TaskState.failed);
            }
        }
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
        if (self.detail_request != null) return error.State;
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

    pub const DetailTerminal = struct { result: contract.Error!contract.DetailText };

    pub fn pollDetail(self: *Query) host_mod.Error!?DetailTerminal {
        if (!self.task.occupied() or self.detail_request == null) return null;
        const state = try self.task.poll();
        if (!state.terminal()) return null;
        var result: contract.Error!contract.DetailText = error.Cancelled;
        if (!self.discard and !self.stopped and state != .cancelled and self.published.load(.acquire)) {
            if (self.detail_result) |data| {
                result = if (state == .completed) data else error.Io;
            } else |err| result = err;
        }
        try self.task.releaseTerminal();
        self.detail_request = null;
        self.detail_result = error.Cancelled;
        return .{ .result = result };
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
    tool_version: contract.Text = .{},
    cache_token: ?[32]u8 = null,
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
    detail_data: ?contract.DetailText = null,
    detail_error: ?contract.Error = null,
    detail_scope: ?contract.DetailRequest = null,
    detail_pending: bool = false,
    stopped: bool = false,

    pub fn init(table: async_host.TaskTable) host_mod.Error!Controller {
        return .{ .query = try Query.init(table) };
    }

    fn dropDetail(self: *Controller) void {
        self.detail_data = null;
        self.detail_error = null;
        self.detail_scope = null;
        self.detail_pending = false;
    }

    pub fn queryDetail(self: *Controller, request: contract.DetailRequest) host_mod.Error!void {
        if (self.stopped or self.query.task.occupied() or self.queued != null or self.current.phase != .ready or self.current.stale) return error.State;
        const selected = self.selection orelse return error.State;
        self.dropDetail();
        try self.query.startDetail(selected.provider, &selected.workspace, request);
        self.detail_scope = request;
        self.detail_pending = true;
    }

    pub fn select(self: *Controller, provider: contract.Provider, workspace: *const identity.Workspace) host_mod.Error!void {
        self.dropDetail();
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
        self.dropDetail();
        self.selection = null;
        self.queued = null;
        self.current = .{ .phase = .empty };
        try self.query.cancel();
    }

    pub fn cancel(self: *Controller) host_mod.Error!void {
        if (self.stopped) return error.State;
        if (self.query.detail_request != null) {
            self.dropDetail();
            self.detail_error = error.Cancelled;
            try self.query.cancel();
            return;
        }
        self.dropDetail();
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
        if (self.query.detail_request != null) {
            if (try self.query.pollDetail()) |terminal| {
                self.detail_pending = false;
                if (!obsolete and self.queued == null and self.selection != null and self.current.phase == .ready and !self.current.stale) {
                    if (terminal.result) |data| {
                        self.detail_data = data;
                    } else |err| self.detail_error = err;
                }
            }
            try self.startQueued();
            return;
        }
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
        self.dropDetail();
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
                if (self.current.phase != .queued and self.current.phase != .refreshing and !self.detail_pending) return error.State;
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
const RecentSnapshots = struct {
    const Entry = struct { workspace: identity.Workspace, token: [32]u8, snapshot: contract.Snapshot };
    entries: [8]Entry = undefined,
    len: usize = 0,
    next: usize = 0,

    fn same(entry: *const Entry, workspace: *const identity.Workspace, token: [32]u8) bool {
        return entry.workspace.kind == workspace.kind and entry.workspace.root.eql(workspace.root.slice()) and
            entry.workspace.repository_root.eql(workspace.repository_root.slice()) and std.mem.eql(u8, &entry.token, &token);
    }

    fn get(self: *const RecentSnapshots, workspace: *const identity.Workspace, token: [32]u8) ?contract.Snapshot {
        for (self.entries[0..self.len]) |*entry| {
            if (same(entry, workspace, token)) return entry.snapshot;
        }
        return null;
    }

    fn put(self: *RecentSnapshots, workspace: *const identity.Workspace, token: [32]u8, snapshot: contract.Snapshot) void {
        for (self.entries[0..self.len]) |*entry| {
            if (same(entry, workspace, token)) {
                entry.snapshot = snapshot;
                return;
            }
        }
        const index = if (self.len < self.entries.len) self.len else self.next;
        self.entries[index] = .{ .workspace = workspace.*, .token = token, .snapshot = snapshot };
        if (self.len < self.entries.len) self.len += 1 else self.next = (self.next + 1) % self.entries.len;
    }

    fn removeScope(self: *RecentSnapshots, root: *const identity.Path, kind: identity.Kind) void {
        var i: usize = 0;
        while (i < self.len) {
            const entry = &self.entries[i];
            if (entry.workspace.kind == kind and entry.workspace.root.eql(root.slice())) {
                self.len -= 1;
                if (i != self.len) self.entries[i] = self.entries[self.len];
                self.next = 0;
            } else i += 1;
        }
    }

    fn clear(self: *RecentSnapshots) void {
        self.len = 0;
        self.next = 0;
    }
};

pub const Binding = struct {
    pub const Navigation = context_mod.Navigation(identity.max_path_bytes);
    pub const Revocation = struct { ctx: *anyopaque, revoke: *const fn (*anyopaque) host_mod.Error!void };
    pub const LocalAccess = struct {
        ctx: *anyopaque,
        authorize: *const fn (*anyopaque, *const panel.LocalReview) host_mod.Error!Resolver,
        revoke: *const fn (*anyopaque) host_mod.Error!void,
        finish: *const fn (*anyopaque) host_mod.Error!void,
        reset: ?*const fn (*anyopaque) host_mod.Error!void = null,
        forget: ?*const fn (*anyopaque, *const panel.LocalReview) host_mod.Error!void = null,
        forget_all: ?*const fn (*anyopaque) host_mod.Error!void = null,
        revoke_saved: ?*const fn (*anyopaque) host_mod.Error!void = null,
    };

    controller: Controller,
    resolution: Resolution,
    resolver: ?Resolver = null,
    preview_resolver: ?Resolver = null,
    wake: ?async_host.Wake = null,
    pumping: bool = false,
    navigation: Navigation = .{},
    navigation_generation: ?u64 = null,
    model: ?ui.Panel = null,
    language: panel.Language,
    approval_locked: bool = false,
    metadata_only: bool = false,
    local_access: ?LocalAccess = null,
    local_ui: bool = false,
    configured_tools: [4]?identity.Path = @splat(null),
    verified_version: contract.Text = .{},
    recent: RecentSnapshots = .{},
    cache_token: ?[32]u8 = null,
    local_review: ?panel.LocalReview = null,
    file_page: usize = 0,
    file_filter: contract.Text = .{},
    detail_path: identity.Path = .{},
    detail_revision: contract.Text = .{},
    history_offset: contract.Text = .{},
    detail_page: usize = 0,
    pending_file: ?identity.Path = null,
    pending_file_generation: ?u64 = null,
    setup_issue: ?panel.SetupIssue = null,
    revocation: ?Revocation = null,
    approved_root: ?identity.Path = null,
    persistent_revocation: bool = false,
    saved_trust_selected: bool = false,
    local_approved_kind: ?identity.Kind = null,
    revocation_failed: bool = false,
    destroyed: bool = false,
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

    /// Fixed, non-executing metadata resolver. This is not an approval.
    /// Keep the preview and reviewed execution sessions mutually exclusive.
    pub fn configureMetadataPreview(self: *Binding, resolver: Resolver) host_mod.Error!void {
        if (self.revocation != null or self.approved_root != null or self.model != null) return error.State;
        try self.configureResolver(resolver);
        self.preview_resolver = resolver;
        self.metadata_only = true;
    }

    pub fn configureLocalAccess(self: *Binding, access: LocalAccess) host_mod.Error!void {
        if (!self.metadata_only or self.local_access != null or self.model != null) return error.State;
        self.local_access = access;
    }

    /// Only after successful normal drain or the final host destroy boundary.
    pub fn finishLocalAccess(self: *Binding) host_mod.Error!void {
        self.checkDrained() catch return error.State;
        if (self.local_access) |access| {
            try access.finish(access.ctx);
            self.local_access = null;
        }
    }

    pub fn configureRevocation(self: *Binding, revocation: Revocation) host_mod.Error!void {
        if (self.metadata_only) return error.Permission;
        if (self.approval_locked or self.revocation != null or self.resolver == null or self.model != null or self.navigation.table != null or self.controller.stopped) return error.State;
        self.revocation = revocation;
    }

    /// Revoke future command admission before discarding any old result.
    /// Do not access the worker-owned Runner until task drain.
    pub fn revokeApproval(self: *Binding) host_mod.Error!void {
        if (!self.accepting or self.approval_locked) return error.State;
        const action = self.revocation orelse return error.Permission;
        self.approval_locked = true;
        self.verified_version = .{};
        self.cache_token = null;
        self.recent.clear();
        action.revoke(action.ctx) catch {
            self.revocation_failed = true;
            self.navigation.pending = false;
            self.clear() catch {};
            return error.Permission;
        };
        self.navigation.pending = false;
        try self.clear();
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
        self.local_ui = self.local_access != null and table.get_state != null;
        var content: panel.Content = undefined;
        var tree: ui.Tree = undefined;
        var current = self.controller.view();
        current.approval_required = self.approval_locked;
        current.metadata_only = self.metadata_only;
        current.local_setup = self.local_ui;
        current.reset_configured = if (self.local_access) |access| access.reset != null else false;
        current.saved_trust_configured = self.savedTrustAvailable();
        current.file_controls = self.local_ui and self.savedTrustAvailable();
        current.file_page = self.file_page;
        current.file_filter = self.file_filter;
        current.detail_supported = current.file_controls and (if (self.controller.selection) |selected| selected.provider.vtable.detail != null else false);
        current.detail_pending = self.controller.detail_pending;
        current.detail_scope = if (self.controller.detail_scope) |*scope| scope else null;
        current.detail_data = if (self.controller.detail_data) |*data| data else null;
        current.detail_error = self.controller.detail_error;
        current.detail_page = self.detail_page;
        current.detail_path = self.detail_path;
        current.detail_revision = self.detail_revision;
        current.history_offset = self.history_offset;
        current.saved_trust_selected = self.saved_trust_selected;
        current.tool_version = self.verified_version;
        if (current.snapshot) |*snapshot| {
            if (self.metadata_only) {
                for (self.configured_tools, 0..) |configured, index| {
                    if (configured) |path| snapshot.preview_tools[index] = path;
                }
            }
        }
        current.local_review = self.local_review;
        current.setup_issue = self.setup_issue;
        current.revocation_configured = self.revocation != null;
        current.approved_root = self.approved_root;
        current.persistent_revocation = self.persistent_revocation;
        current.revocation_failed = self.revocation_failed;
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
        const base_commands = [_][]const u8{ panel.command_refresh, panel.command_cancel, panel.command_check, panel.command_revoke, panel.command_trust_git, panel.command_trust_jj, panel.command_trust_svn, panel.command_trust_hg, panel.command_trust_confirm, panel.command_trust_cancel, panel.command_trust_reset, panel.command_trust_remember, panel.command_trust_reuse, panel.command_trust_forget, panel.command_trust_forget_all, panel.command_file_filter, panel.command_file_prev, panel.command_file_next };
        const commands = base_commands ++ panel.advanced_commands;
        for (commands[0..if (self.local_ui and self.savedTrustAvailable()) @as(usize, panel.full_command_count) else if (self.local_ui) @as(usize, 11) else if (self.revocation != null) @as(usize, 4) else 3]) |name| {
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
        self.local_review = null;
        self.setup_issue = null;
        self.verified_version = .{};
        self.cache_token = null;
        var failure: ?host_mod.Error = null;
        self.resolution.cancel() catch |err| {
            failure = err;
        };
        self.controller.clear() catch |err| {
            failure = err;
        };
        if (failure) |err| return err;
        self.file_page = 0;
        self.file_filter = .{};
        self.detail_path = .{};
        self.detail_revision = .{};
        self.history_offset = .{};
        self.detail_page = 0;
        self.pending_file = null;
        self.pending_file_generation = null;
        self.navigation_generation = latest.generation;
        if (!self.approval_locked and self.resolver != null and self.navigation.pending and latest.directory() != null) self.controller.current = .{ .phase = .queued };
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

    fn currentReviewRoot(self: *Binding) host_mod.Error!identity.Path {
        if (!self.accepting or !self.local_ui or !self.metadata_only or self.approval_locked) return error.Permission;
        // Read the actual current context before approving, rather than
        // relying on a deferred navigation notification or stale tree.
        try self.navigation.refreshCurrent();
        try self.invalidateNavigation();
        if (self.navigation.pending or self.resolution.task.occupied() or self.controller.query.task.occupied() or self.controller.queued != null) return error.State;
        const current = self.controller.current;
        if (current.phase != .ready or current.snapshot == null or current.stale) return error.State;
        const workspace = current.workspace orelse return error.State;
        return workspace.root;
    }

    fn beginLocalReview(self: *Binding, kind: identity.Kind) host_mod.Error!void {
        self.local_review = null;
        const root = try self.currentReviewRoot();
        const model = self.model orelse return error.State;
        const get = model.table.get_state orelse return error.Unavailable;
        var bytes: [identity.max_path_bytes + 1]u8 = undefined;
        var needed: u32 = 0;
        try host_mod.mapStatus(get(model.table.context, model.id, abi.view(panel.state_executable), &bytes, bytes.len, &needed));
        if (needed >= bytes.len) return error.Argument;
        const snapshot = self.controller.current.snapshot orelse return error.State;
        if (!snapshot.previewHas(kind)) return error.Permission;
        const index = contract.Snapshot.previewIndex(kind) orelse return error.Argument;
        const executable = if (needed == 0)
            self.configured_tools[index] orelse snapshot.savedHint(kind).executable orelse snapshot.previewTool(kind) orelse return error.Argument
        else
            identity.Path.init(bytes[0..needed]) catch return error.Argument;
        // No tool discovery or execution occurs here. Confirmation owns
        // the exact copied path and repository shown in the review.
        const latest = self.navigation.latest orelse return error.State;
        self.local_review = .{ .root = root, .executable = executable, .kind = kind, .generation = latest.generation };
    }

    fn savedTrustAvailable(self: *const Binding) bool {
        const access = self.local_access orelse return false;
        return access.forget != null and access.forget_all != null and access.revoke_saved != null;
    }

    fn reviewedCurrent(self: *Binding) host_mod.Error!panel.LocalReview {
        const review = self.local_review orelse return error.State;
        const root = try self.currentReviewRoot();
        const latest = self.navigation.latest orelse return error.State;
        if (review.generation != latest.generation or !root.eql(review.root.slice()) or self.local_review == null) return error.State;
        return review;
    }

    fn confirmLocalReview(self: *Binding, mode: panel.TrustMode) host_mod.Error!void {
        var review = try self.reviewedCurrent();
        const access = self.local_access orelse return error.Unavailable;
        if (mode != .session and !self.savedTrustAvailable()) return error.Unavailable;
        review.mode = mode;
        // Only the explicit confirmation callback can switch the resolver.
        // Both worker slots are drained, no old preview can publish as status.
        const resolver = try access.authorize(access.ctx, &review);
        self.local_review = null;
        self.metadata_only = false;
        self.approved_root = review.root;
        self.local_approved_kind = review.kind;
        self.saved_trust_selected = mode != .session;
        self.revocation = .{ .ctx = access.ctx, .revoke = if (self.saved_trust_selected) access.revoke_saved orelse return error.Unavailable else access.revoke };
        self.resolver = resolver;
        self.persistent_revocation = false;
        try self.retryResolution();
    }

    /// Explicit session change, never automatic trust of a new directory.
    /// Worker slots and provider pointers must be completely released first.
    fn resetLocalSession(self: *Binding) host_mod.Error!void {
        if (!self.accepting or !self.local_ui or self.persistent_revocation or (self.metadata_only and !self.approval_locked)) return error.Permission;
        const access = self.local_access orelse return error.Unavailable;
        const reset = access.reset orelse return error.Unavailable;
        const preview = self.preview_resolver orelse return error.State;
        try self.navigation.refreshCurrent();
        try self.invalidateNavigation();
        if (self.resolution.task.occupied() or self.controller.query.task.occupied() or self.controller.queued != null) return error.State;
        // No old authorized work or result can survive this transition.
        self.approval_locked = true;
        self.verified_version = .{};
        self.cache_token = null;
        self.local_review = null;
        self.navigation.pending = false;
        try access.revoke(access.ctx);
        try self.controller.clear();
        try reset(access.ctx);
        self.revocation = null;
        self.saved_trust_selected = false;
        self.local_approved_kind = null;
        self.revocation_failed = false;
        self.approved_root = null;
        self.resolver = preview;
        self.metadata_only = true;
        self.approval_locked = false;
        if (self.navigation.latest) |latest| {
            if (latest.directory() != null) try self.retryResolution();
        }
    }

    fn forgetLocal(self: *Binding, all: bool) host_mod.Error!void {
        if (!self.savedTrustAvailable() or !self.metadata_only or self.approval_locked) return error.Permission;
        const access = self.local_access orelse return error.Unavailable;
        if (all) {
            try (access.forget_all orelse return error.Unavailable)(access.ctx);
            self.local_review = null;
            self.recent.clear();
            self.setup_issue = .all_forgotten;
            if (self.controller.current.snapshot) |*snapshot| snapshot.preview_saved = @splat(.{ .state = .absent });
        } else {
            const review = try self.reviewedCurrent();
            try (access.forget orelse return error.Unavailable)(access.ctx, &review);
            self.local_review = null;
            self.recent.clear();
            self.setup_issue = .forgotten;
            if (self.controller.current.snapshot) |*snapshot| {
                if (contract.Snapshot.previewIndex(review.kind)) |index| snapshot.preview_saved[index] = .{ .state = .absent };
            }
        }
    }

    fn fileCommand(self: *Binding, name: []const u8) host_mod.Error!void {
        if (!self.local_ui or !self.savedTrustAvailable() or self.metadata_only or self.approval_locked) return error.Permission;
        try self.navigation.refreshCurrent();
        try self.invalidateNavigation();
        const current = &self.controller.current;
        if (current.phase != .ready or current.stale or self.navigation.pending or self.controller.query.task.occupied() or self.resolution.task.occupied()) return error.State;
        const snapshot = if (current.snapshot) |*value| value else return error.State;
        if (!snapshot.files.available) return error.Unavailable;
        if (std.mem.eql(u8, name, panel.command_file_filter)) {
            const model = self.model orelse return error.State;
            const get = model.table.get_state orelse return error.Unavailable;
            var bytes: [contract.Text.capacity + 1]u8 = undefined;
            var needed: u32 = 0;
            try host_mod.mapStatus(get(model.table.context, model.id, abi.view(panel.state_file_filter), &bytes, bytes.len, &needed));
            if (needed >= bytes.len) return error.Argument;
            self.file_filter = contract.Text.init(bytes[0..needed]) catch return error.Argument;
            self.file_page = 0;
        } else if (std.mem.eql(u8, name, panel.command_file_prev)) {
            self.file_page -|= 1;
        } else {
            const total = snapshot.files.matchCount(self.file_filter.slice());
            if ((self.file_page + 1) * contract.FileList.page_size < total) self.file_page += 1;
        }
        try self.render();
    }

    /// The native menu has independently re-read and copied the exact
    /// selected file. Only prefill the owner UI, never authorize or query it.
    pub fn prepareSelectedFile(self: *Binding, absolute: *const identity.Path) host_mod.Error!void {
        if (!self.accepting or !self.local_ui or !self.savedTrustAvailable() or self.approval_locked) return error.Unavailable;
        try self.navigation.refreshCurrent();
        try self.invalidateNavigation();
        const latest = self.navigation.latest orelse return error.State;
        const directory = latest.directory() orelse return error.State;
        if (!std.mem.eql(u8, std.fs.path.dirname(absolute.slice()) orelse return error.Argument, directory)) return error.State;
        self.pending_file = absolute.*;
        self.pending_file_generation = latest.generation;
        try self.applySelectedFile();
        try self.render();
    }

    fn applySelectedFile(self: *Binding) host_mod.Error!void {
        const pending = self.pending_file orelse return;
        if (self.pending_file_generation != self.navigation_generation) {
            self.pending_file = null;
            self.pending_file_generation = null;
            return;
        }
        if (self.metadata_only or self.approval_locked or self.navigation.pending or self.controller.query.task.occupied() or self.resolution.task.occupied() or self.controller.current.phase != .ready or self.controller.current.stale) return;
        self.pending_file = null;
        self.pending_file_generation = null;
        const workspace = self.controller.current.workspace orelse return error.State;
        const root = workspace.root.slice();
        const path = pending.slice();
        if (path.len <= root.len + 1 or !std.mem.startsWith(u8, path, root) or (path[root.len] != '\\' and path[root.len] != '/')) return error.Argument;
        const tail = path[root.len + 1 ..];
        var normalized: [identity.max_path_bytes]u8 = undefined;
        for (tail, 0..) |byte, i| normalized[i] = if (byte == '\\') '/' else byte;
        const relative = normalized[0..tail.len];
        if (!contract.safeRelativePath(relative)) return error.Argument;
        const selected = identity.Path.init(relative) catch return error.Argument;
        const model = if (self.model) |*value| value else return error.State;
        try model.setStates(&.{.{ .key = abi.view(panel.state_detail_path), .value = abi.view(selected.slice()) }});
        self.detail_path = selected;
        self.controller.dropDetail();
        self.detail_page = 0;
    }

    fn readDetailState(self: *Binding, key: []const u8, bytes: []u8) host_mod.Error![]const u8 {
        const model = self.model orelse return error.State;
        const get = model.table.get_state orelse return error.Unavailable;
        var needed: u32 = 0;
        try host_mod.mapStatus(get(model.table.context, model.id, abi.view(key), bytes.ptr, @intCast(bytes.len), &needed));
        if (needed >= bytes.len) return error.Argument;
        return bytes[0..needed];
    }

    fn chooseFile(self: *Binding, snapshot: *const contract.Snapshot, slot: usize) host_mod.Error!void {
        const files = &snapshot.files;
        const pages = @max(1, (files.matchCount(self.file_filter.slice()) + contract.FileList.page_size - 1) / contract.FileList.page_size);
        const index = @min(self.file_page, pages - 1) * contract.FileList.page_size + slot;
        var matched: usize = 0;
        for (files.rows[0..files.count]) |row| {
            if (!files.matches(row, self.file_filter.slice())) continue;
            if (matched != index) {
                matched += 1;
                continue;
            }
            const workspace = snapshot.workspace orelse return error.State;
            var path = files.slice(row.path);
            if (workspace.kind == .svn and std.mem.startsWith(u8, path, workspace.root.slice()) and path.len > workspace.root.len and (path[workspace.root.len] == '/' or path[workspace.root.len] == '\\')) path = path[workspace.root.len + 1 ..];
            var normalized: [identity.max_path_bytes]u8 = undefined;
            for (path, 0..) |byte, i| normalized[i] = if ((workspace.kind == .svn or workspace.kind == .hg) and byte == '\\') '/' else byte;
            const relative = normalized[0..path.len];
            if (!contract.safeRelativePath(relative)) return error.Argument;
            const candidate = identity.Path.init(relative) catch return error.Argument;
            const model = if (self.model) |*value| value else return error.State;
            try model.setStates(&.{.{ .key = abi.view(panel.state_detail_path), .value = abi.view(candidate.slice()) }});
            self.detail_path = candidate;
            self.controller.dropDetail();
            self.detail_page = 0;
            return;
        }
        return error.Argument;
    }

    fn detailCommand(self: *Binding, name: []const u8) host_mod.Error!void {
        if (!self.local_ui or !self.savedTrustAvailable() or self.metadata_only or self.approval_locked) return error.Permission;
        try self.navigation.refreshCurrent();
        try self.invalidateNavigation();
        const current = &self.controller.current;
        if (current.phase != .ready or current.stale or self.navigation.pending or self.controller.query.task.occupied() or self.resolution.task.occupied()) return error.State;
        const snapshot = if (current.snapshot) |*value| value else return error.State;
        const workspace = snapshot.workspace orelse return error.State;
        if (std.mem.eql(u8, name, panel.command_detail_prev)) {
            self.detail_page -|= 1;
        } else if (std.mem.eql(u8, name, panel.command_detail_next)) {
            if (self.controller.detail_data) |*data| {
                if (self.detail_page + 1 < data.pages()) self.detail_page += 1;
            }
        } else {
            for (panel.pick_actions, 0..) |action, slot| {
                if (std.mem.eql(u8, name, action)) {
                    try self.chooseFile(snapshot, slot);
                    try self.render();
                    return;
                }
            }
            for (panel.revision_pick_actions, 0..) |action, slot| {
                if (!std.mem.eql(u8, name, action)) continue;
                const scope = self.controller.detail_scope orelse return error.State;
                if (scope.kind != .history and scope.kind != .file_history) return error.State;
                const data = if (self.controller.detail_data) |*value| value else return error.State;
                const revision = data.revisionAt(workspace.kind, @min(self.detail_page, data.pages() - 1) * contract.DetailText.page_size + slot) orelse return error.Argument;
                const model = if (self.model) |*value| value else return error.State;
                try model.setStates(&.{.{ .key = abi.view(panel.state_detail_revision), .value = abi.view(revision.slice()) }});
                self.detail_revision = contract.Text.init(revision.slice()) catch return error.Argument;
                try self.render();
                return;
            }
            for (panel.detail_actions, panel.detail_kinds) |action, kind| {
                if (!std.mem.eql(u8, name, action)) continue;
                if (!contract.detailSupported(workspace.kind, kind)) return error.Unavailable;
                var request: contract.DetailRequest = .{ .kind = kind };
                const needs_path = switch (kind) {
                    .file_history, .working_diff, .staged_diff, .revision_diff, .content, .local_info, .properties => true,
                    else => false,
                };
                if (needs_path) {
                    var bytes: [identity.max_path_bytes + 1]u8 = undefined;
                    const path = try self.readDetailState(panel.state_detail_path, &bytes);
                    if (path.len != 0) {
                        if (!contract.safeRelativePath(path)) return error.Argument;
                        request.path = identity.Path.init(path) catch return error.Argument;
                    } else if (kind != .local_info and kind != .properties) return error.Argument;
                    self.detail_path = request.path;
                }
                if (workspace.kind != .svn) {
                    const needs_revision = switch (kind) {
                        .history, .file_history, .revision_info, .staged_diff, .revision_diff, .content => true,
                        .working_diff => workspace.kind == .jj,
                        else => false,
                    };
                    if (needs_revision) {
                        var bytes: [contract.Text.capacity + 1]u8 = undefined;
                        const entered = try self.readDetailState(panel.state_detail_revision, &bytes);
                        const revision = if (entered.len != 0) entered else if (snapshot.revision) |*value| value.slice() else return error.State;
                        if (!contract.safeRevision(workspace.kind, revision)) return error.Argument;
                        request.revision = identity.RevisionId.init(workspace.kind, revision) catch return error.Argument;
                        self.detail_revision = contract.Text.init(entered) catch return error.Argument;
                    }
                    if (kind == .history or kind == .file_history) {
                        var bytes: [17]u8 = undefined;
                        const entered = try self.readDetailState(panel.state_history_offset, &bytes);
                        const offset = if (entered.len == 0) 0 else std.fmt.parseInt(u16, entered, 10) catch return error.Argument;
                        if (offset > @as(u16, if (workspace.kind == .git or workspace.kind == .hg) 4096 else 224) or offset % 32 != 0) return error.Argument;
                        request.offset = offset;
                        self.history_offset = contract.Text.init(entered) catch return error.Argument;
                    }
                }
                self.detail_page = 0;
                try self.controller.queryDetail(request);
                try self.render();
                return;
            }
            return error.Argument;
        }
        try self.render();
    }

    fn localCommand(self: *Binding, name: []const u8) bool {
        if (!self.local_ui) return false;
        self.setup_issue = null;
        if (panel.trustKind(name)) |kind| {
            self.beginLocalReview(kind) catch |err| {
                self.last_error = err;
                self.setup_issue = if (err == error.Argument) .invalid else if (err == error.State) .busy else .denied;
            };
        } else if (std.mem.eql(u8, name, panel.command_trust_confirm) or std.mem.eql(u8, name, panel.command_trust_remember) or std.mem.eql(u8, name, panel.command_trust_reuse)) {
            const mode: panel.TrustMode = if (std.mem.eql(u8, name, panel.command_trust_remember)) .remember else if (std.mem.eql(u8, name, panel.command_trust_reuse)) .reuse else .session;
            self.confirmLocalReview(mode) catch |err| {
                self.last_error = err;
                self.setup_issue = if (err == error.Argument) .invalid else if (err == error.State) .changed else .denied;
            };
        } else if (std.mem.eql(u8, name, panel.command_trust_forget)) {
            self.forgetLocal(false) catch |err| {
                self.last_error = err;
                self.setup_issue = .denied;
            };
        } else if (std.mem.eql(u8, name, panel.command_trust_forget_all)) {
            self.forgetLocal(true) catch |err| {
                self.last_error = err;
                self.setup_issue = .denied;
            };
        } else if (std.mem.eql(u8, name, panel.command_trust_cancel)) {
            self.local_review = null;
        } else if (std.mem.eql(u8, name, panel.command_trust_reset)) {
            self.resetLocalSession() catch |err| {
                self.last_error = err;
                self.setup_issue = if (err == error.State) .busy else .denied;
            };
        } else return false;
        self.render() catch |err| {
            self.last_error = err;
        };
        return true;
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
        if (panel.isDetailCommand(name)) {
            self.detailCommand(name) catch |err| {
                self.last_error = err;
                if (!self.controller.detail_pending) {
                    self.controller.dropDetail();
                    self.controller.detail_error = if (err == error.Argument) error.Parse else if (err == error.Permission) error.Permission else error.Unsupported;
                }
                self.render() catch {};
            };
            return;
        }
        if (panel.isFileCommand(name)) {
            self.fileCommand(name) catch |err| {
                self.last_error = err;
                self.render() catch {};
            };
            return;
        }
        if (self.localCommand(name)) return;
        if (std.mem.eql(u8, name, panel.command_revoke)) {
            self.revokeApproval() catch |err| {
                self.last_error = err;
            };
            return;
        }
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

    /// A separate project-library revoke has been explicitly admitted. Close
    /// matching saved-session admission locally without issuing a second
    /// registry mutation. The worker reports the durable operation result.
    pub fn invalidateSavedScope(self: *Binding, root: *const identity.Path, kind: identity.Kind) host_mod.Error!void {
        self.recent.removeScope(root, kind);
        if (self.local_review) |review| {
            if (review.kind == kind and review.root.eql(root.slice())) self.local_review = null;
        }
        if (self.metadata_only) {
            if (self.controller.current.workspace) |*workspace| {
                if (workspace.root.eql(root.slice())) {
                    if (self.controller.current.snapshot) |*snapshot| {
                        if (contract.Snapshot.previewIndex(kind)) |index| snapshot.preview_saved[index] = .{};
                    }
                }
            }
        }
        if (self.accepting and self.saved_trust_selected and self.local_approved_kind == kind) {
            if (self.approved_root) |*approved| {
                if (approved.eql(root.slice())) {
                    const access = self.local_access orelse return error.State;
                    self.approval_locked = true;
                    try access.revoke(access.ctx);
                    try self.clear();
                    return;
                }
            }
        }
        if (self.accepting) try self.render();
    }

    pub fn clear(self: *Binding) host_mod.Error!void {
        if (!self.accepting) return error.State;
        self.pending_file = null;
        self.pending_file_generation = null;
        self.verified_version = .{};
        self.cache_token = null;
        self.local_review = null;
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
        if (self.controller.current.phase == .queued or self.controller.current.phase == .refreshing or self.controller.detail_pending) return error.State;
        const latest = self.navigation.latest orelse return error.State;
        if (latest.directory() == null) return error.State;
        self.local_review = null;
        self.file_page = 0;
        self.verified_version = .{};
        self.cache_token = null;
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
        self.local_review = null;
        self.verified_version = .{};
        self.cache_token = null;
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
            if (self.accepting and !self.approval_locked and !discarded and self.navigation.isCurrent(&finished.ticket)) {
                if (finished.selection) |selection| {
                    if (selection) |selected| {
                        try self.controller.select(selected.provider, &selected.workspace);
                        self.verified_version = selected.tool_version;
                        self.cache_token = if (self.metadata_only) null else selected.cache_token;
                        if (self.cache_token) |token| {
                            if (self.recent.get(&selected.workspace, token)) |snapshot| {
                                self.controller.current.snapshot = snapshot;
                                self.controller.current.stale = true;
                            }
                        }
                    } else self.controller.current = .{ .phase = .empty };
                } else |err| {
                    self.controller.current = .{ .phase = if (err == error.Cancelled) .cancelled else .failed, .failure = if (err == error.Cancelled) null else err };
                }
            }
        }
        if (!self.accepting or self.approval_locked or self.controller.stopped or self.resolution.task.occupied() or self.controller.query.task.occupied() or !self.navigation.pending) return;
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
        if (self.destroyed or self.pumping) return error.State;
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
        const permission_denied = (if (self.controller.current.failure) |failure| failure == error.Permission else false) or (if (self.controller.detail_error) |failure| failure == error.Permission else false);
        if (self.saved_trust_selected and permission_denied) {
            self.controller.current.failure = error.Permission;
            self.controller.current.phase = .failed;
            self.controller.dropDetail();
            self.controller.current.snapshot = null;
            self.controller.current.stale = false;
            self.cache_token = null;
            self.recent.clear();
        }
        if (self.cache_token) |token| {
            const current = &self.controller.current;
            if (self.accepting and !self.approval_locked and !self.metadata_only and current.phase == .ready and !current.stale) {
                if (current.workspace) |*workspace| {
                    if (current.snapshot) |snapshot| self.recent.put(workspace, token, snapshot);
                }
            }
        }
        self.pumpResolution() catch |err| {
            self.last_error = err;
            if (self.accepting) self.render() catch {};
            return err;
        };
        self.last_error = null;
        if (self.accepting) {
            self.applySelectedFile() catch |err| {
                self.last_error = err;
                self.controller.detail_error = error.Parse;
            };
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
        current.metadata_only = self.metadata_only;
        current.local_setup = self.local_ui;
        current.reset_configured = if (self.local_access) |access| access.reset != null else false;
        current.saved_trust_configured = self.savedTrustAvailable();
        current.file_controls = self.local_ui and self.savedTrustAvailable();
        current.file_page = self.file_page;
        current.file_filter = self.file_filter;
        current.detail_supported = current.file_controls and (if (self.controller.selection) |selected| selected.provider.vtable.detail != null else false);
        current.detail_pending = self.controller.detail_pending;
        current.detail_scope = if (self.controller.detail_scope) |*scope| scope else null;
        current.detail_data = if (self.controller.detail_data) |*data| data else null;
        current.detail_error = self.controller.detail_error;
        current.detail_page = self.detail_page;
        current.detail_path = self.detail_path;
        current.detail_revision = self.detail_revision;
        current.history_offset = self.history_offset;
        current.saved_trust_selected = self.saved_trust_selected;
        current.tool_version = self.verified_version;
        if (current.snapshot) |*snapshot| {
            if (self.metadata_only) {
                for (self.configured_tools, 0..) |configured, index| {
                    if (configured) |path| snapshot.preview_tools[index] = path;
                }
            }
        }
        current.local_review = self.local_review;
        current.setup_issue = self.setup_issue;
        current.revocation_configured = self.revocation != null;
        current.approved_root = self.approved_root;
        current.persistent_revocation = self.persistent_revocation;
        current.revocation_failed = self.revocation_failed;
        if (!self.approval_locked and self.resolver != null and self.navigation.accepting) {
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
        if (self.destroyed) return;
        self.accepting = false;
        self.cache_token = null;
        self.recent.clear();
        if (self.wake) |*wake| wake.disable();
        var failure: ?host_mod.Error = null;
        // Close admission before requesting cancellation. In a multi-step
        // trusted query this prevents a subsequent CLI launch during drain.
        if (self.local_access) |access| {
            access.revoke(access.ctx) catch |err| {
                failure = err;
            };
        }
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

    /// Final host destroy, NOT deactivate. The caller attests the documented
    /// SDK boundary: host stop suppressed model/context/dispatch callbacks,
    /// host-owned task work and cancellation callbacks have returned, and
    /// all plugin-owned workers are joined. No SDK calls on closed tables.
    /// Do not infer this boundary from STATE or reuse the retired Binding.
    pub fn retireAtHostDestroy(self: *Binding) error{Busy}!void {
        if (self.pumping or self.navigation.notifying or self.controller.query.admitting or self.resolution.admitting) return error.Busy;
        if (self.wake) |*wake| try wake.retireAtHostDestroy();
        try self.navigation.retireAtHostDestroy();
        self.accepting = false;
        self.destroyed = true;
        self.approval_locked = true;
        self.model = null;
        self.poisoned = false;
        self.resolver = null;
        self.preview_resolver = null;
        self.revocation = null;
        self.navigation_generation = null;
        self.resolution.stopped = true;
        self.resolution.discard = true;
        self.resolution.task.retireAtHostDestroy();
        self.resolution.result = error.Cancelled;
        self.resolution.published.store(false, .monotonic);
        self.resolution.wake = null;
        self.controller.stopped = true;
        self.controller.selection = null;
        self.controller.queued = null;
        self.controller.current = .{ .phase = .stopped };
        self.controller.query.stopped = true;
        self.controller.query.discard = true;
        self.controller.query.task.retireAtHostDestroy();
        self.controller.dropDetail();
        self.controller.query.detail_request = null;
        self.controller.query.detail_result = error.Cancelled;
        self.controller.query.result = error.Cancelled;
        self.controller.query.published.store(false, .monotonic);
        self.controller.query.wake = null;
        self.last_error = null;
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
    deny_query: bool = false,
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
        if (self.deny_query) return error.Permission;
        if (self.fail_query) return error.Parse;
        var actual = workspace.*;
        if (self.wrong_workspace) actual.root = identity.Path.init("different") catch unreachable;
        return .{ .availability = .ready, .workspace = actual, .changes = .{ .modified = 4 }, .counts = .{ .modified = .ready } };
    }

    fn detail(_: *anyopaque, _: *const identity.Workspace, _: *const contract.DetailRequest) contract.Error!contract.DetailText {
        return contract.DetailText.init("fixture detail");
    }

    fn provider(self: *Mock) contract.Provider {
        var set: capabilities.Set = .empty;
        set.insert(.status);
        return .{
            .kind = .git,
            .display_name = "fixture",
            .capabilities = set,
            .ctx = self,
            .vtable = .{ .detect = detectImpl, .summarize = summarize, .detail = detail },
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
    commands_expected: u32 = 3,
    executable: []const u8 = "C:\\tools\\git.exe",
    fail_subscribe_at: usize = 0,
    fail_close: bool = false,
    fail_update: bool = false,
    callback: ui.ClickFn = null,
    callback_user: ?*anyopaque = null,

    fn create(user: ?*anyopaque, _: abi.StringView, tree: [*c]const ui.Tree, out: [*c]u64) callconv(.c) abi.Status {
        const self: *MockUi = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (tree == null or tree.*.root == null or tree.*.command_count != self.commands_expected) return abi.error_argument;
        self.created += 1;
        out.* = 7;
        return abi.ok;
    }

    fn update(user: ?*anyopaque, id: u64, tree: [*c]const ui.Tree) callconv(.c) abi.Status {
        const self: *MockUi = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (id != 7 or tree == null or tree.*.command_count != self.commands_expected) return abi.error_argument;
        if (self.fail_update) return abi.error_state;
        self.updates += 1;
        return abi.ok;
    }

    fn subscribe(user: ?*anyopaque, id: u64, command: abi.StringView, callback: ui.ClickFn, data: ?*anyopaque, out: [*c]u64) callconv(.c) abi.Status {
        const self: *MockUi = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (id != 7 or callback == null or data == null) return abi.error_argument;
        const name = abi.slice(command) orelse return abi.error_argument;
        const local = self.commands_expected >= 11 and (panel.trustKind(name) != null or std.mem.eql(u8, name, panel.command_trust_confirm) or std.mem.eql(u8, name, panel.command_trust_cancel) or std.mem.eql(u8, name, panel.command_trust_reset));
        const saved = self.commands_expected >= 15 and (std.mem.eql(u8, name, panel.command_trust_remember) or std.mem.eql(u8, name, panel.command_trust_reuse) or std.mem.eql(u8, name, panel.command_trust_forget) or std.mem.eql(u8, name, panel.command_trust_forget_all));
        if (panel.parseCommand(name) == null and !(self.commands_expected >= 4 and std.mem.eql(u8, name, panel.command_revoke)) and !local and !saved and !(self.commands_expected == panel.full_command_count and (panel.isFileCommand(name) or panel.isDetailCommand(name)))) return abi.error_argument;
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

    fn getState(user: ?*anyopaque, id: u64, key: abi.StringView, buffer: [*c]u8, capacity: u32, needed: [*c]u32) callconv(.c) abi.Status {
        const self: *MockUi = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (id != 7 or buffer == null or needed == null or !std.mem.eql(u8, abi.slice(key) orelse return abi.error_argument, panel.state_executable)) return abi.error_argument;
        if (self.executable.len >= capacity) return abi.error_argument;
        @memcpy(buffer[0..self.executable.len], self.executable);
        needed.* = @intCast(self.executable.len);
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
            .get_state = if (self.commands_expected >= 11) &getState else null,
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

test "saved trust permission denial clears stale snapshot and recent cache" {
    var mock: Mock = .{};
    var host_ui: MockUi = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.openWithTable(host_ui.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    const token: [32]u8 = @splat(1);
    binding.saved_trust_selected = true;
    binding.cache_token = token;
    try binding.select(mock.provider(), &workspace);
    mock.runWork();
    try binding.pump();
    try std.testing.expect(binding.controller.view().snapshot != null);
    try std.testing.expect(binding.recent.get(&workspace, token) != null);

    // Ordinary query failures retain the stale snapshot and cache.
    mock.fail_query = true;
    try binding.controller.refresh();
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(error.Parse, binding.controller.view().failure.?);
    try std.testing.expect(binding.controller.view().stale);
    try std.testing.expect(binding.recent.get(&workspace, token) != null);

    // A denied saved approval must not expose cached repository data.
    mock.fail_query = false;
    mock.deny_query = true;
    try binding.controller.refresh();
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(error.Permission, binding.controller.view().failure.?);
    try std.testing.expect(binding.controller.view().snapshot == null);
    try std.testing.expect(!binding.controller.view().stale);
    try std.testing.expect(binding.cache_token == null);
    try std.testing.expect(binding.recent.get(&workspace, token) == null);
    try binding.requestStop();
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
    directory: []const u8 = "one",

    fn get(user: ?*anyopaque, callback: context_mod.ChangeFn, data: ?*anyopaque) callconv(.c) abi.Status {
        const self: *MockNavigation = @ptrCast(@alignCast(user orelse return abi.error_argument));
        var snapshot: context_mod.Snapshot = .{ .size = @sizeOf(context_mod.Snapshot), .directory = abi.view(self.directory) };
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
        self.directory = path;
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

test "host destroy retires unreleased task and suppressed dispatch only at final boundary" {
    var mock: Mock = .{};
    var host_ui: MockUi = .{};
    var host_context: MockNavigation = .{};
    var dispatch: MockDispatch = .{};
    var resolver: MockResolver = .{ .host_task = &mock };
    var binding = try Binding.init(mock.table(), .en);
    try binding.configureResolver(resolver.resolver());
    try binding.configureDispatch(dispatch.dispatch());
    try binding.openWithTable(host_ui.table());
    try binding.openNavigationWithTable(host_context.table());
    dispatch.deliver();
    try std.testing.expect(binding.resolution.task.occupied());
    mock.runWork();
    try std.testing.expect(dispatch.callback != null);
    // A refused ordinary cancellation cannot be considered drain.
    mock.fail_cancel = true;
    try std.testing.expectError(error.Permission, binding.requestStop());
    try std.testing.expectError(error.Busy, binding.checkDrained());
    // Simulate the documented host stop boundary: the work already returned,
    // adapters suppress pending callbacks, no further host API is usable.
    dispatch.callback = null;
    dispatch.data = null;
    mock.fail_release = true;
    try binding.retireAtHostDestroy();
    try binding.checkDrained();
    try std.testing.expectEqual(panel.Phase.stopped, binding.controller.view().phase);
    try std.testing.expectEqual(@as(usize, 0), mock.calls);
    try std.testing.expectError(error.State, binding.pump());
    try std.testing.expectError(error.State, binding.openWithTable(host_ui.table()));
    try std.testing.expectError(error.Permission, binding.configureResolver(resolver.resolver()));
    try binding.requestStop();
}

test "destroy boundary discards completed summary that could not be released" {
    var mock: Mock = .{};
    var model: MockUi = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.openWithTable(model.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try binding.select(mock.provider(), &workspace);
    mock.runWork();
    mock.fail_release = true;
    try std.testing.expectError(error.State, binding.pump());
    try std.testing.expectError(error.Busy, binding.checkDrained());
    // Mock host stop invalidates its own registrations before destroy.
    model.callback = null;
    model.callback_user = null;
    try binding.retireAtHostDestroy();
    try binding.checkDrained();
    try std.testing.expect(binding.controller.view().snapshot == null);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
}

const RevocationFixture = struct {
    calls: usize = 0,

    fn revoke(user: *anyopaque) host_mod.Error!void {
        const self: *RevocationFixture = @ptrCast(@alignCast(user));
        self.calls += 1;
    }
};

test "session revoke suppresses raced summary and future navigation admission" {
    var mock: Mock = .{};
    var resolver: MockResolver = .{ .host_task = &mock };
    var revocation: RevocationFixture = .{};
    var model: MockUi = .{ .commands_expected = 4 };
    var navigation: MockNavigation = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.configureResolver(resolver.resolver());
    try binding.configureRevocation(.{ .ctx = &revocation, .revoke = &RevocationFixture.revoke });
    try binding.openWithTable(model.table());
    try binding.openNavigationWithTable(navigation.table());
    try binding.pump();
    mock.runWork();
    try binding.pump();
    try std.testing.expect(binding.controller.query.task.occupied());
    mock.runWork();
    model.click(7, panel.command_revoke);
    try std.testing.expect(binding.approval_locked);
    try std.testing.expectEqual(@as(usize, 1), revocation.calls);
    // The completed worker result raced the revocation, but is discarded.
    mock.state = .completed;
    try binding.pump();
    try std.testing.expect(binding.controller.view().snapshot == null);
    try std.testing.expect(!binding.controller.query.task.occupied());
    navigation.navigate("other");
    model.click(7, panel.command_check);
    try std.testing.expect(!binding.resolution.task.occupied());
    try std.testing.expectEqual(@as(usize, 1), resolver.calls);
    try std.testing.expectEqual(@as(usize, 1), mock.calls);
    model.click(7, panel.command_revoke);
    try std.testing.expectEqual(@as(usize, 1), revocation.calls);
    try binding.requestStop();
    try binding.checkDrained();
}

const LocalAccessFixture = struct {
    resolver: *MockResolver,
    authorized: usize = 0,
    revoked: usize = 0,
    finished: usize = 0,
    resets: usize = 0,
    forgotten: usize = 0,
    forgotten_kind: ?identity.Kind = null,

    fn forget(user: *anyopaque, review: *const panel.LocalReview) host_mod.Error!void {
        const self: *LocalAccessFixture = @ptrCast(@alignCast(user));
        self.forgotten += 1;
        self.forgotten_kind = review.kind;
    }

    fn forgetAll(user: *anyopaque) host_mod.Error!void {
        const self: *LocalAccessFixture = @ptrCast(@alignCast(user));
        self.forgotten += 1;
        self.forgotten_kind = null;
    }

    fn authorize(user: *anyopaque, review: *const panel.LocalReview) host_mod.Error!Resolver {
        const self: *LocalAccessFixture = @ptrCast(@alignCast(user));
        if (review.kind != .git or !review.executable.eql("C:\\tools\\git.exe")) return error.Argument;
        self.authorized += 1;
        return self.resolver.resolver();
    }

    fn revoke(user: *anyopaque) host_mod.Error!void {
        const self: *LocalAccessFixture = @ptrCast(@alignCast(user));
        self.revoked += 1;
    }

    fn reset(user: *anyopaque) host_mod.Error!void {
        const self: *LocalAccessFixture = @ptrCast(@alignCast(user));
        self.resets += 1;
    }

    fn finish(user: *anyopaque) host_mod.Error!void {
        const self: *LocalAccessFixture = @ptrCast(@alignCast(user));
        self.finished += 1;
    }
};

test "local consent is two step, navigation bound, and released only after drain" {
    var mock: Mock = .{};
    var preview: MockResolver = .{ .host_task = &mock };
    var trusted: MockResolver = .{ .host_task = &mock };
    var access: LocalAccessFixture = .{ .resolver = &trusted };
    var model: MockUi = .{ .commands_expected = 11 };
    var navigation: MockNavigation = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.configureMetadataPreview(preview.resolver());
    try binding.configureLocalAccess(.{ .ctx = &access, .authorize = &LocalAccessFixture.authorize, .revoke = &LocalAccessFixture.revoke, .finish = &LocalAccessFixture.finish, .reset = &LocalAccessFixture.reset });
    try binding.openWithTable(model.table());
    try binding.openNavigationWithTable(navigation.table());
    try std.testing.expectEqual(@as(usize, 11), model.subscriptions);
    try binding.pump();
    mock.runWork();
    try binding.pump();
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(panel.Phase.ready, binding.controller.current.phase);
    binding.controller.current.snapshot.?.preview_kinds = 1;
    binding.controller.current.snapshot.?.preview_tools[0] = try identity.Path.init("C:\\tools\\git.exe");
    model.click(7, panel.command_trust_confirm);
    try std.testing.expectEqual(@as(usize, 0), access.authorized);
    model.click(7, panel.command_trust_git);
    try std.testing.expect(binding.local_review != null and binding.metadata_only);
    try std.testing.expectEqual(@as(usize, 0), access.authorized);
    model.click(7, panel.command_trust_cancel);
    model.click(7, panel.command_trust_confirm);
    try std.testing.expectEqual(@as(usize, 0), access.authorized);
    model.click(7, panel.command_trust_git);
    navigation.navigate("two");
    model.click(7, panel.command_trust_confirm);
    try std.testing.expectEqual(@as(usize, 0), access.authorized);
    try std.testing.expect(binding.metadata_only and binding.local_review == null);
    try binding.pump();
    mock.runWork();
    try binding.pump();
    mock.runWork();
    try binding.pump();
    binding.controller.current.snapshot.?.preview_kinds = 1;
    binding.controller.current.snapshot.?.preview_tools[0] = try identity.Path.init("C:\\tools\\git.exe");
    model.executable = "";
    binding.configured_tools[0] = try identity.Path.init("C:\\configured\\git.exe");
    model.click(7, panel.command_trust_git);
    try std.testing.expect(binding.local_review.?.executable.eql("C:\\configured\\git.exe"));
    model.executable = "C:\\tools\\git.exe";
    model.click(7, panel.command_trust_git);
    try std.testing.expect(binding.local_review.?.executable.eql(model.executable));
    model.click(7, panel.command_trust_cancel);
    binding.configured_tools[0] = null;
    model.executable = "";
    model.click(7, panel.command_trust_svn);
    try std.testing.expect(binding.local_review == null);
    model.click(7, panel.command_trust_git);
    try std.testing.expect(binding.local_review != null);
    model.click(7, panel.command_trust_confirm);
    try std.testing.expectEqual(@as(usize, 1), access.authorized);
    try std.testing.expect(!binding.metadata_only and binding.revocation != null);
    try std.testing.expectError(error.State, binding.finishLocalAccess());
    mock.runWork();
    try binding.pump();
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(@as(usize, 1), trusted.calls);
    model.click(7, panel.command_revoke);
    try std.testing.expectEqual(@as(usize, 1), access.revoked);
    try std.testing.expect(binding.approval_locked);
    model.click(7, panel.command_trust_reset);
    try std.testing.expectEqual(@as(usize, 1), access.resets);
    try std.testing.expect(binding.metadata_only and !binding.approval_locked and binding.approved_root == null);
    mock.runWork();
    try binding.pump();
    mock.runWork();
    try binding.pump();
    try std.testing.expectEqual(@as(usize, 1), access.authorized);
    try std.testing.expectEqual(@as(usize, 1), trusted.calls);
    try binding.requestStop();
    try binding.finishLocalAccess();
    try binding.finishLocalAccess();
    try std.testing.expectEqual(@as(usize, 1), access.finished);
}

test "recent snapshots separate provider workspace and revalidated trust fingerprint" {
    var cache: RecentSnapshots = .{};
    const git = try identity.Workspace.init(.git, "root", "root/.git");
    const jj = try identity.Workspace.init(.jj, "root", "root/.jj");
    const token: [32]u8 = @splat(1);
    cache.put(&git, token, .{ .workspace = git, .changes = .{ .modified = 4 } });
    cache.put(&jj, token, .{ .workspace = jj, .changes = .{ .modified = 7 } });
    try std.testing.expectEqual(@as(u32, 4), cache.get(&git, token).?.changes.modified);
    try std.testing.expectEqual(@as(u32, 7), cache.get(&jj, token).?.changes.modified);
    try std.testing.expect(cache.get(&git, @splat(2)) == null);
    cache.removeScope(&git.root, .git);
    try std.testing.expect(cache.get(&git, token) == null);
    try std.testing.expectEqual(@as(u32, 7), cache.get(&jj, token).?.changes.modified);
    cache.clear();
    try std.testing.expect(cache.get(&jj, token) == null);
}

test "saved record can be reviewed and revoked without a discovered executable or CLI authorization" {
    var mock: Mock = .{};
    var preview: MockResolver = .{ .host_task = &mock };
    var trusted: MockResolver = .{ .host_task = &mock };
    var access: LocalAccessFixture = .{ .resolver = &trusted };
    var model: MockUi = .{ .commands_expected = panel.full_command_count, .executable = "" };
    var navigation: MockNavigation = .{};
    var binding = try Binding.init(mock.table(), .en);
    try binding.configureMetadataPreview(preview.resolver());
    try binding.configureLocalAccess(.{ .ctx = &access, .authorize = &LocalAccessFixture.authorize, .revoke = &LocalAccessFixture.revoke, .finish = &LocalAccessFixture.finish, .reset = &LocalAccessFixture.reset, .forget = &LocalAccessFixture.forget, .forget_all = &LocalAccessFixture.forgetAll, .revoke_saved = &LocalAccessFixture.revoke });
    try binding.openWithTable(model.table());
    try binding.openNavigationWithTable(navigation.table());
    try binding.pump();
    mock.runWork();
    try binding.pump();
    mock.runWork();
    try binding.pump();
    binding.controller.current.snapshot.?.preview_kinds = 3;
    binding.controller.current.snapshot.?.preview_saved[0] = .{ .state = .recorded, .executable = try identity.Path.init("C:\\old\\git.exe") };
    binding.controller.current.snapshot.?.preview_saved[1] = .{ .state = .recorded, .executable = try identity.Path.init("C:\\old\\jj.exe") };
    model.click(7, panel.command_trust_git);
    try std.testing.expect(binding.local_review.?.executable.eql("C:\\old\\git.exe"));
    try std.testing.expectEqual(@as(usize, 0), access.authorized);
    model.click(7, panel.command_trust_forget);
    try std.testing.expectEqual(@as(usize, 1), access.forgotten);
    try std.testing.expectEqual(identity.Kind.git, access.forgotten_kind.?);
    try std.testing.expectEqual(contract.SavedHint.State.absent, binding.controller.current.snapshot.?.preview_saved[0].state);
    try std.testing.expectEqual(contract.SavedHint.State.recorded, binding.controller.current.snapshot.?.preview_saved[1].state);
    model.click(7, panel.command_trust_forget_all);
    try std.testing.expectEqual(@as(usize, 2), access.forgotten);
    try std.testing.expectEqual(contract.SavedHint.State.absent, binding.controller.current.snapshot.?.preview_saved[1].state);
    try std.testing.expect(binding.metadata_only);
    try std.testing.expectEqual(@as(usize, 0), access.authorized);
    try binding.requestStop();
    try binding.finishLocalAccess();
}

test "detail task serializes with summary and discards cancelled result before release" {
    var mock: Mock = .{};
    var controller = try Controller.init(mock.table());
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    try controller.select(mock.provider(), &workspace);
    mock.runWork();
    try controller.pump();
    try controller.queryDetail(.{ .kind = .refs });
    try std.testing.expectError(error.State, controller.queryDetail(.{ .kind = .refs }));
    mock.runWork();
    mock.fail_release = true;
    try std.testing.expectError(error.State, controller.pump());
    try std.testing.expect(controller.detail_data == null);
    mock.fail_release = false;
    try controller.pump();
    try std.testing.expectEqualStrings("fixture detail", controller.detail_data.?.slice());
    try controller.queryDetail(.{ .kind = .refs });
    try controller.cancel();
    mock.runWork();
    try controller.pump();
    try std.testing.expect(controller.detail_data == null);
    try controller.requestStop();
    try controller.checkDrained();
}
