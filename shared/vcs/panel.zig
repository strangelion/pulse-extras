//! Host-independent VCS panel controller and native SDK model builder.
//! A single serialized coordinator owns Controller, Session, providers and
//! Runner. Blocking joins are coordinator operations, never UI callbacks.
//! UI delivery must copy View by value and use the official host dispatch;
//! do not share this mutable controller with a UI thread. No SDK calls here.
//! The caller supplies a resolved, authorized workspace and approved tool.
//! This module does not authorize execution or start filesystem discovery.

const std = @import("std");
const identity = @import("vcs_identity");
const contract = @import("vcs_provider");
const Session = @import("vcs_session").Session;
const abi = @import("pulse_abi");
const ui = @import("pulse_ui_model");
const capabilities = @import("vcs_capabilities");
const detect = @import("vcs_detect");

pub const Phase = enum { empty, queued, refreshing, ready, failed, cancelled, stopped };
pub const Language = enum { en, zh };
pub const command_refresh = "vcs.refresh";
pub const command_cancel = "vcs.cancel";
pub const command_check = "vcs.check";
pub const Command = enum { refresh, cancel, check };

pub fn parseCommand(name: []const u8) ?Command {
    if (std.mem.eql(u8, name, command_refresh)) return .refresh;
    if (std.mem.eql(u8, name, command_cancel)) return .cancel;
    if (std.mem.eql(u8, name, command_check)) return .check;
    return null;
}

pub const View = struct {
    phase: Phase,
    workspace: ?identity.Workspace = null,
    snapshot: ?contract.Snapshot = null,
    stale: bool = false,
    failure: ?contract.Error = null,
    discovery_available: bool = false,
    approval_required: bool = false,
};

const Selection = struct {
    provider: contract.Provider,
    workspace: identity.Workspace,
};

pub const Controller = struct {
    session: Session,
    selection: ?Selection = null,
    phase: Phase = .empty,
    failure: ?contract.Error = null,

    pub fn init(io: std.Io, ttl_ms: i64, now: *const fn () i64) Controller {
        return .{ .session = Session.init(io, ttl_ms, now) };
    }

    /// Successful admission commits the selection; a failed admission clears
    /// the previous selection and invalidates its pending publication.
    pub fn select(self: *Controller, provider: contract.Provider, workspace: *const identity.Workspace) error{ Stopped, Unsupported, ResourceBusy }!void {
        if (self.phase == .stopped) return error.Stopped;
        _ = self.session.request(provider, workspace) catch |err| {
            self.clear();
            self.selection = .{ .provider = provider, .workspace = workspace.* };
            self.phase = .failed;
            self.failure = if (err == error.Unsupported) error.Unsupported else error.ResourceLimit;
            return err;
        };
        self.selection = .{ .provider = provider, .workspace = workspace.* };
        self.phase = .queued;
        self.failure = null;
    }

    pub fn refresh(self: *Controller) error{ Stopped, Unsupported, ResourceBusy, NoSelection }!void {
        if (self.phase == .stopped) return error.Stopped;
        const selected = self.selection orelse return error.NoSelection;
        try self.select(selected.provider, &selected.workspace);
    }

    /// Clear selection immediately; an outstanding obsolete job still needs
    /// joining. Keep the owner alive until shutdown returns.
    pub fn clear(self: *Controller) void {
        if (self.phase == .stopped) return;
        self.session.invalidate();
        self.selection = null;
        self.failure = null;
        self.phase = .empty;
    }

    /// Failed admission leaves work queued for an explicit retry.
    pub fn startNext(self: *Controller) error{ Stopped, Busy, ResourceBusy, ConcurrencyUnavailable }!bool {
        const started = try self.session.startNext();
        if (started) self.phase = .refreshing;
        return started;
    }

    pub fn join(self: *Controller) error{NoActiveTask}!void {
        const result = try self.session.awaitActive();
        switch (result) {
            .published => self.phase = .ready,
            .failed => |err| {
                self.phase = .failed;
                self.failure = err;
            },
            .discarded => {
                // A newer queued selection or clear already owns the phase.
            },
        }
    }

    /// Cancel the current selection, including any waiting query. Invalidate
    /// before the join so a raced completion can never publish. May block.
    pub fn cancel(self: *Controller) void {
        if (self.phase == .stopped or self.selection == null) return;
        self.session.invalidate();
        if (self.session.hasActive()) self.session.cancelActive() catch unreachable;
        self.failure = null;
        self.phase = .cancelled;
    }

    pub fn shutdown(self: *Controller) void {
        self.session.shutdown();
        self.selection = null;
        self.failure = null;
        self.phase = .stopped;
    }

    /// Copy by value; cache never exports mutable or borrowed storage.
    /// A stale snapshot remains stale even when its previous phase was ready.
    pub fn view(self: *Controller) View {
        var result: View = .{ .phase = self.phase, .failure = self.failure };
        const selected = self.selection orelse return result;
        result.workspace = selected.workspace;
        switch (self.session.lookup(&selected.workspace)) {
            .missing => {},
            .fresh => |value| result.snapshot = value,
            .stale => |value| {
                result.snapshot = value;
                result.stale = true;
            },
        }
        return result;
    }
};

fn loc(lang: Language, en: []const u8, zh: []const u8) []const u8 {
    return if (lang == .zh) zh else en;
}

fn phaseLabel(lang: Language, phase: Phase) []const u8 {
    return switch (phase) {
        .empty => loc(lang, "No repository selected", "未选择仓库"),
        .queued => loc(lang, "Waiting to refresh", "等待刷新"),
        .refreshing => loc(lang, "Refreshing", "正在刷新"),
        .ready => loc(lang, "Query complete", "查询完成"),
        .failed => loc(lang, "Query failed", "查询失败"),
        .cancelled => loc(lang, "Cancelled", "已取消"),
        .stopped => loc(lang, "Stopped", "已停止"),
    };
}

fn availabilityLabel(lang: Language, state: contract.Availability) []const u8 {
    return switch (state) {
        .ready => loc(lang, "Available", "可用"),
        .empty => loc(lang, "Empty", "空"),
        .unknown => loc(lang, "Unknown", "未知"),
        .unsupported => loc(lang, "Unsupported", "不支持"),
        .not_queried => loc(lang, "Not queried", "未查询"),
        .not_connected => loc(lang, "Not connected", "未连接"),
        .stale => loc(lang, "Stale", "过期"),
    };
}

fn failureLabel(lang: Language, err: contract.Error) []const u8 {
    return switch (err) {
        error.CliMissing => loc(lang, "CLI unavailable", "工具不可用"),
        error.CliTooOld => loc(lang, "CLI version too old", "工具版本过低"),
        error.NotConnected => loc(lang, "Repository unavailable", "仓库不可用"),
        error.Unsupported => loc(lang, "Unsupported operation", "不支持的操作"),
        error.Stale => loc(lang, "Repository changed", "仓库已变化"),
        error.Parse => loc(lang, "Invalid tool output", "工具输出无效"),
        error.Timeout => loc(lang, "Timed out", "执行超时"),
        error.Cancelled => loc(lang, "Cancelled", "已取消"),
        error.Permission => loc(lang, "Permission or approval required", "需要权限或审批"),
        error.Io => loc(lang, "I/O failure", "输入输出失败"),
        error.OutOfMemory => loc(lang, "Memory allocation failed", "内存分配失败"),
        error.ResourceLimit => loc(lang, "Resource limit reached", "达到资源限制"),
    };
}

/// Caller-owned buffers and nodes; do not move the Content after build until
/// the synchronous UI model create/update call has copied its contents.
/// All visible data is copied; no references into the View or cache remain.
/// build is read-only; buildInteractive declares the fixed owner commands.
pub const Content = struct {
    const capacity = 20;
    const line_bytes = identity.max_path_bytes + 64;
    lines: [capacity][line_bytes]u8 = undefined,
    nodes: [capacity]ui.Node = undefined,
    len: usize = 0,
    root: ui.Node = undefined,
    commands: [3]abi.StringView = undefined,

    fn add(self: *Content, id: []const u8, label: []const u8, value: []const u8) void {
        std.debug.assert(self.len < capacity);
        const buffer = &self.lines[self.len];
        const line = std.fmt.bufPrint(buffer, "{s}{s}", .{ label, value }) catch unreachable;
        // Prevent display controls from forging additional lines. Preserve
        // UTF-8, but replace ASCII control characters in display text only.
        for (buffer[0..line.len]) |*byte| {
            if (byte.* < 0x20 or byte.* == 0x7f) byte.* = ' ';
        }
        var node = ui.text(buffer[0..line.len]);
        node.id = abi.view(id);
        self.nodes[self.len] = node;
        self.len += 1;
    }

    fn count(self: *Content, lang: Language, id: []const u8, label: []const u8, number: u32, availability: contract.Availability, snapshot_availability: contract.Availability) void {
        if (snapshot_availability != .ready) {
            self.add(id, label, availabilityLabel(lang, snapshot_availability));
            return;
        }
        if (availability != .ready) {
            self.add(id, label, availabilityLabel(lang, availability));
            return;
        }
        var buffer: [16]u8 = undefined;
        self.add(id, label, std.fmt.bufPrint(&buffer, "{d}", .{number}) catch unreachable);
    }

    pub fn build(self: *Content, lang: Language, view: *const View, tree: *ui.Tree) void {
        self.len = 0;
        const status = if (view.discovery_available and view.workspace == null) switch (view.phase) {
            .queued => loc(lang, "Waiting to discover repository", "等待识别仓库"),
            .refreshing => loc(lang, "Discovering repository", "正在识别仓库"),
            else => phaseLabel(lang, view.phase),
        } else phaseLabel(lang, view.phase);
        self.add("vcs.phase", "", status);
        if (view.approval_required) self.add("vcs.approval", "", loc(lang, "Execution locked: production approval unavailable", "执行已锁定：尚未提供生产授权"));
        if (view.failure) |err| self.add("vcs.error", "", failureLabel(lang, err));
        if (view.workspace) |workspace| {
            self.add("vcs.provider", loc(lang, "Provider: ", "类型："), workspace.kind.displayName());
            self.add("vcs.root", loc(lang, "Workspace: ", "工作区："), workspace.root.slice());
        }
        if (view.snapshot) |snapshot| {
            self.add("vcs.freshness", "", if (view.stale) loc(lang, "Previous data — stale", "历史数据（已过期）") else availabilityLabel(lang, snapshot.availability));
            self.add("vcs.reference", loc(lang, "Reference: ", "引用："), if (snapshot.reference.slice().len == 0) loc(lang, "Not reported", "未报告") else snapshot.reference.slice());
            self.add("vcs.revision", loc(lang, "Revision: ", "版本："), if (snapshot.revision) |revision| revision.slice() else loc(lang, "Not reported", "未报告"));
            self.count(lang, "vcs.staged", loc(lang, "Staged: ", "暂存："), snapshot.changes.staged, snapshot.counts.staged, snapshot.availability);
            self.count(lang, "vcs.modified", loc(lang, "Modified: ", "修改："), snapshot.changes.modified, snapshot.counts.modified, snapshot.availability);
            self.count(lang, "vcs.untracked", loc(lang, "Untracked: ", "未跟踪："), snapshot.changes.untracked, snapshot.counts.untracked, snapshot.availability);
            self.count(lang, "vcs.conflicted", loc(lang, "Conflict count: ", "冲突数量："), snapshot.changes.conflicted, snapshot.counts.conflicted, snapshot.availability);
            if (snapshot.availability == .ready) {
                if (snapshot.has_conflict) |conflict| self.add("vcs.conflict_presence", loc(lang, "Conflicts present: ", "存在冲突："), if (conflict) loc(lang, "Yes", "是") else loc(lang, "No", "否"));
            }
            self.count(lang, "vcs.ahead", loc(lang, "Ahead: ", "领先："), snapshot.changes.ahead, snapshot.counts.ahead, snapshot.availability);
            self.count(lang, "vcs.behind", loc(lang, "Behind: ", "落后："), snapshot.changes.behind, snapshot.counts.behind, snapshot.availability);
            if (snapshot.detail.slice().len != 0) self.add("vcs.detail", "", snapshot.detail.slice());
        }
        self.root = ui.node(ui.NodeKind.stack);
        self.root.id = abi.view("vcs.root.stack");
        self.root.gap = .{ .present = 1, .value = 6 };
        ui.withChildren(&self.root, self.nodes[0..self.len]);
        tree.* = std.mem.zeroes(ui.Tree);
        tree.size = @sizeOf(ui.Tree);
        tree.root = &self.root;
    }

    fn addButton(self: *Content, id: []const u8, label: []const u8, command: []const u8) void {
        std.debug.assert(self.len < capacity);
        var node = ui.button(label, command);
        node.id = abi.view(id);
        self.nodes[self.len] = node;
        self.len += 1;
    }

    /// Declare a stable vocabulary so subscriptions survive model updates.
    /// The owner still validates commands against current controller state.
    pub fn buildInteractive(self: *Content, lang: Language, view: *const View, tree: *ui.Tree) void {
        self.build(lang, view, tree);
        self.commands = .{ abi.view(command_refresh), abi.view(command_cancel), abi.view(command_check) };
        tree.commands = &self.commands;
        tree.command_count = self.commands.len;
        if (view.phase != .stopped) {
            if (!view.approval_required and (view.workspace != null or view.discovery_available)) {
                if (view.phase == .queued or view.phase == .refreshing) {
                    self.addButton("vcs.action.cancel", loc(lang, "Cancel", "取消"), command_cancel);
                } else {
                    self.addButton("vcs.action.refresh", loc(lang, "Refresh", "刷新"), command_refresh);
                }
            }
            self.addButton("vcs.action.check", loc(lang, "Check result", "检查结果"), command_check);
        }
        ui.withChildren(&self.root, self.nodes[0..self.len]);
    }

    pub fn textFor(self: *const Content, id: []const u8) ?[]const u8 {
        for (self.nodes[0..self.len]) |node| {
            if (std.mem.eql(u8, abi.slice(node.id) orelse continue, id)) return abi.slice(node.text.value);
        }
        return null;
    }
};

fn clock() i64 {
    return 1000;
}

const Fake = struct {
    fail: bool = false,

    fn detectImpl(_: *anyopaque, _: []const u8, _: *detect.Result) void {}

    fn summarize(ctx: *anyopaque, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.Permission;
        return .{
            .availability = .ready,
            .workspace = workspace.*,
            .changes = .{ .modified = 3 },
            .counts = .{ .modified = .ready, .staged = .unsupported },
            .has_conflict = true,
        };
    }

    fn provider(self: *Fake, kind: identity.Kind) contract.Provider {
        var set: capabilities.Set = .empty;
        set.insert(.status);
        return .{
            .kind = kind,
            .display_name = "fixture",
            .capabilities = set,
            .ctx = self,
            .vtable = .{ .detect = detectImpl, .summarize = summarize },
        };
    }
};

test "controller renders only the latest selection and retains stale data on failure" {
    var fake: Fake = .{};
    var controller = Controller.init(std.testing.io, 1000, clock);
    defer controller.shutdown();
    const a = try identity.Workspace.init(.git, "a", "a");
    const b = try identity.Workspace.init(.jj, "b", "b");
    try controller.select(fake.provider(.git), &a);
    try std.testing.expectEqual(Phase.queued, controller.view().phase);
    try std.testing.expect(try controller.startNext());
    try controller.select(fake.provider(.jj), &b);
    try controller.join();
    try std.testing.expectEqual(Phase.queued, controller.view().phase);
    try std.testing.expect(controller.view().snapshot == null);
    try std.testing.expect(try controller.startNext());
    try controller.join();
    try std.testing.expectEqual(Phase.ready, controller.view().phase);
    try std.testing.expect(controller.view().workspace.?.root.eql("b"));

    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    const ready = controller.view();
    content.build(.zh, &ready, &tree);
    try std.testing.expectEqualStrings("暂存：不支持", content.textFor("vcs.staged").?);
    try std.testing.expectEqualStrings("修改：3", content.textFor("vcs.modified").?);
    try std.testing.expectEqualStrings("存在冲突：是", content.textFor("vcs.conflict_presence").?);

    fake.fail = true;
    try controller.refresh();
    try std.testing.expect(controller.view().stale);
    try std.testing.expect(try controller.startNext());
    try controller.join();
    const failed = controller.view();
    try std.testing.expectEqual(Phase.failed, failed.phase);
    try std.testing.expect(failed.stale);
    content.build(.en, &failed, &tree);
    try std.testing.expectEqualStrings("Previous data — stale", content.textFor("vcs.freshness").?);
    try std.testing.expectEqualStrings("Permission or approval required", content.textFor("vcs.error").?);
}

test "clearing and cancellation discard outstanding work and stop rejects new admission" {
    var fake: Fake = .{};
    var controller = Controller.init(std.testing.io, 1000, clock);
    defer controller.shutdown();
    const a = try identity.Workspace.init(.git, "a", "a");
    try controller.select(fake.provider(.git), &a);
    try std.testing.expect(try controller.startNext());
    controller.clear();
    try controller.join();
    try std.testing.expectEqual(Phase.empty, controller.view().phase);
    try std.testing.expect(controller.view().snapshot == null);
    try controller.select(fake.provider(.git), &a);
    try std.testing.expect(try controller.startNext());
    try controller.refresh();
    controller.cancel();
    try std.testing.expectEqual(Phase.cancelled, controller.view().phase);
    try std.testing.expect(!controller.session.hasActive());
    try std.testing.expect(!controller.session.hasQueued());
    controller.shutdown();
    try std.testing.expectError(error.Stopped, controller.select(fake.provider(.git), &a));
}

test "model owns its text and never renders unknown counts as numeric zero" {
    var view: View = .{
        .phase = .ready,
        .workspace = try identity.Workspace.init(.git, "repo", "repo"),
        .snapshot = .{ .availability = .ready, .counts = .{ .modified = .ready } },
    };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    content.build(.en, &view, &tree);
    view = .{ .phase = .empty };
    try std.testing.expectEqualStrings("Modified: 0", content.textFor("vcs.modified").?);
    try std.testing.expectEqualStrings("Ahead: Not queried", content.textFor("vcs.ahead").?);
    try std.testing.expectEqualStrings("Workspace: repo", content.textFor("vcs.root").?);
    try std.testing.expectEqual(@as(u32, @intCast(content.len)), content.root.children.count);
    try std.testing.expect(content.len <= Content.capacity);
}

test "discovery phase offers cancel before a workspace and refresh after failure" {
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    var view: View = .{ .phase = .refreshing, .discovery_available = true };
    content.buildInteractive(.en, &view, &tree);
    try std.testing.expectEqualStrings("Discovering repository", content.textFor("vcs.phase").?);
    var found = false;
    for (content.nodes[0..content.len]) |node| {
        if (std.mem.eql(u8, abi.slice(node.id) orelse continue, "vcs.action.cancel")) found = true;
    }
    try std.testing.expect(found);
    view.phase = .failed;
    view.failure = error.Permission;
    content.buildInteractive(.en, &view, &tree);
    found = false;
    for (content.nodes[0..content.len]) |node| {
        if (std.mem.eql(u8, abi.slice(node.id) orelse continue, "vcs.action.refresh")) found = true;
    }
    try std.testing.expect(found);
}
