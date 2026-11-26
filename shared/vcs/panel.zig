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
pub const command_revoke = "vcs.revoke";
pub const command_trust_git = "vcs.trust.git";
pub const command_trust_jj = "vcs.trust.jj";
pub const command_trust_svn = "vcs.trust.svn";
pub const command_trust_confirm = "vcs.trust.confirm";
pub const command_trust_cancel = "vcs.trust.cancel";
pub const state_executable = "vcs.executable";

pub const LocalReview = struct {
    root: identity.Path,
    executable: identity.Path,
    kind: identity.Kind,
    generation: u64,
};

pub const SetupIssue = enum { invalid, busy, changed, denied };

pub fn trustKind(name: []const u8) ?identity.Kind {
    if (std.mem.eql(u8, name, command_trust_git)) return .git;
    if (std.mem.eql(u8, name, command_trust_jj)) return .jj;
    if (std.mem.eql(u8, name, command_trust_svn)) return .svn;
    return null;
}
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
    metadata_only: bool = false,
    local_setup: bool = false,
    local_review: ?LocalReview = null,
    setup_issue: ?SetupIssue = null,
    tool_version: contract.Text = .{},
    revocation_configured: bool = false,
    approved_root: ?identity.Path = null,
    persistent_revocation: bool = false,
    revocation_failed: bool = false,
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
    const capacity = 36;
    const line_bytes = identity.max_path_bytes + 64;
    lines: [capacity][line_bytes]u8 = undefined,
    nodes: [capacity]ui.Node = undefined,
    len: usize = 0,
    root: ui.Node = undefined,
    commands: [9]abi.StringView = undefined,
    states: [1]ui.State = undefined,

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
        if (view.approval_required) {
            self.add("vcs.approval", "", if (view.revocation_configured)
                loc(lang, "Session approval revoked", "本次授权已撤销")
            else
                loc(lang, "Execution locked: production approval unavailable", "执行已锁定：尚未提供生产授权"));
        }
        if (view.metadata_only) {
            self.add("vcs.preview", "", loc(lang, "Repository preview (no external commands)", "仓库预览（不执行外部命令）"));
            self.add("vcs.preview-help", "", if (view.local_setup)
                loc(lang, "To query changes, select an installed tool and explicitly trust this repository.", "如需查询变更，请指定已安装的工具，并明确确认信任当前仓库。")
            else
                loc(lang, "External command access requires explicit approval.", "外部命令访问需要明确授权。"));
        } else if (view.local_setup and !view.approval_required) {
            self.add("vcs.local-trust", "", loc(lang, "Trusted local session (not a sandbox). To change tool, provider or root, close and reopen VCS from the context menu.", "本次会话已信任（非沙箱）。若要更换工具、类型或仓库，请关闭后从右键菜单重新打开 VCS。"));
        }
        if (view.approved_root) |root| self.add("vcs.approved-root", loc(lang, "Approved root: ", "授权根目录："), root.slice());
        if (!view.metadata_only and !view.approval_required and view.tool_version.slice().len != 0) self.add("vcs.tool-version", loc(lang, "Verified tool version: ", "已验证工具版本："), view.tool_version.slice());
        if (view.revocation_failed) self.add("vcs.revocation-error", "", loc(lang, "Session locked; permanent revocation failed. Use approval tool to revoke.", "会话已锁定；永久撤销失败，请使用授权工具撤销。"));
        if (view.failure) |err| self.add("vcs.error", "", failureLabel(lang, err));
        if (view.workspace) |workspace| {
            self.add("vcs.provider", loc(lang, "Provider: ", "类型："), workspace.kind.displayName());
            self.add("vcs.root", loc(lang, "Workspace: ", "工作区："), workspace.root.slice());
        }
        if (view.snapshot) |snapshot| {
            if (view.metadata_only) {
                if (snapshot.reference.slice().len != 0) self.add("vcs.reference", loc(lang, "HEAD branch: ", "HEAD 分支："), snapshot.reference.slice());
                if (snapshot.revision) |revision| self.add("vcs.revision", loc(lang, "Detached HEAD: ", "分离 HEAD："), revision.slice());
                self.add("vcs.detail", "", snapshot.detail.slice());
                self.add("vcs.status-unavailable", "", loc(lang, "Changes, staging and history: not queried", "变更、暂存及历史：未查询"));
            } else {
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

    fn addExecutableInput(self: *Content, lang: Language) void {
        std.debug.assert(self.len < capacity);
        var node = ui.node(ui.NodeKind.text_input);
        node.id = abi.view(state_executable);
        node.state = .{ .present = 1, .value = abi.view(state_executable) };
        node.text = .{ .present = 1, .value = abi.view(loc(lang, "Trusted executable (absolute path)", "受信任工具（绝对路径）")) };
        node.placeholder = .{ .present = 1, .value = abi.view("C:\\Program Files\\Git\\cmd\\git.exe") };
        self.nodes[self.len] = node;
        self.len += 1;
    }

    fn addLocalSetup(self: *Content, lang: Language, view: *const View) void {
        if (view.setup_issue) |issue| self.add("vcs.setup-error", "", switch (issue) {
            .invalid => loc(lang, "Enter the absolute path to the matching git.exe, jj.exe or svn.exe.", "请输入对应 git.exe、jj.exe 或 svn.exe 的绝对路径。"),
            .busy => loc(lang, "Wait for the current query to finish; Check result if needed.", "请等待当前查询结束，必要时点击检查结果。"),
            .changed => loc(lang, "Directory or selection changed. Review the current repository again.", "目录或选择已变化，请重新确认当前仓库。"),
            .denied => loc(lang, "Trust setup refused. Review the path and repository.", "授权设置被拒绝，请检查路径和仓库。"),
        });
        if (!view.metadata_only or view.approval_required) return;
        if (view.phase != .ready or view.workspace == null or view.snapshot == null) return;
        if (view.local_review) |review| {
            self.add("vcs.review-kind", loc(lang, "Tool: ", "工具："), review.kind.displayName());
            self.add("vcs.review-exe", loc(lang, "Executable: ", "程序："), review.executable.slice());
            self.add("vcs.review-root", loc(lang, "Repository: ", "仓库："), review.root.slice());
            self.add("vcs.review-warning", "", loc(lang, "Trust only a known installation and repository, including their dependencies and configuration. Commands run as you; this is NOT a sandbox. No automatic approval or saved grant.", "仅信任已知的工具安装和仓库（含依赖及配置）。命令以当前用户身份运行，不是沙箱；不会自动授权或保存授权。"));
            self.addButton("vcs.action.trust-confirm", loc(lang, "Trust tool and repository for this session", "信任工具及仓库（仅本次会话）"), command_trust_confirm);
            self.addButton("vcs.action.trust-cancel", loc(lang, "Cancel review", "取消确认"), command_trust_cancel);
        } else {
            const snapshot = view.snapshot orelse return;
            self.addExecutableInput(lang);
            self.add("vcs.setup-help", "", loc(lang, "Leave empty for the configured or detected path. Change saved paths in VCS settings. Detection never runs or approves a program.", "留空使用已配置或检测到的路径；可在 VCS 设置中更改。检测不会运行或授权程序。"));
            const kinds = [_]identity.Kind{ .git, .jj, .svn };
            const ids = [_][]const u8{ "vcs.candidate.git", "vcs.candidate.jj", "vcs.candidate.svn" };
            const button_ids = [_][]const u8{ "vcs.action.trust-git", "vcs.action.trust-jj", "vcs.action.trust-svn" };
            const labels = [_][]const u8{ "Git: ", "Jujutsu: ", "SVN: " };
            const en = [_][]const u8{ "Review Git access", "Review Jujutsu access", "Review SVN access" };
            const zh = [_][]const u8{ "确认 Git 访问", "确认 Jujutsu 访问", "确认 SVN 访问" };
            const actions = [_][]const u8{ command_trust_git, command_trust_jj, command_trust_svn };
            for (kinds, ids, button_ids, labels, en, zh, actions) |kind, id, button_id, label, english, chinese, action| {
                if (!snapshot.previewHas(kind)) continue;
                if (snapshot.previewTool(kind)) |path| {
                    self.add(id, label, path.slice());
                } else self.add(id, label, loc(lang, "Not found; enter the installed path", "未找到，请填写已安装路径"));
                self.addButton(button_id, loc(lang, english, chinese), action);
            }
        }
    }

    /// Declare a stable vocabulary so subscriptions survive model updates.
    /// The owner still validates commands against current controller state.
    pub fn buildInteractive(self: *Content, lang: Language, view: *const View, tree: *ui.Tree) void {
        self.build(lang, view, tree);
        self.commands = .{ abi.view(command_refresh), abi.view(command_cancel), abi.view(command_check), abi.view(command_revoke), abi.view(command_trust_git), abi.view(command_trust_jj), abi.view(command_trust_svn), abi.view(command_trust_confirm), abi.view(command_trust_cancel) };
        tree.commands = &self.commands;
        tree.command_count = if (view.local_setup) 9 else if (view.revocation_configured) 4 else 3;
        if (view.local_setup) {
            self.states[0] = .{ .key = abi.view(state_executable), .value = abi.view("") };
            tree.states = &self.states;
            tree.state_count = self.states.len;
            self.addLocalSetup(lang, view);
        }
        if (view.phase != .stopped) {
            if (!view.approval_required and (view.workspace != null or view.discovery_available)) {
                if (view.phase == .queued or view.phase == .refreshing) {
                    self.addButton("vcs.action.cancel", loc(lang, "Cancel", "取消"), command_cancel);
                } else {
                    self.addButton("vcs.action.refresh", loc(lang, "Refresh", "刷新"), command_refresh);
                }
            }
            self.addButton("vcs.action.check", loc(lang, "Check result", "检查结果"), command_check);
            if (view.revocation_configured and !view.approval_required) self.addButton("vcs.action.revoke", if (view.persistent_revocation) loc(lang, "Revoke saved approval", "永久撤销授权") else loc(lang, "Revoke session approval", "撤销本次授权"), command_revoke);
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

test "metadata-only view never presents unqueried changes as status counts" {
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    const workspace = try identity.Workspace.init(.git, "repo", "repo");
    const view: View = .{ .phase = .ready, .workspace = workspace, .metadata_only = true, .snapshot = .{ .workspace = workspace, .availability = .not_queried, .reference = try contract.Text.init("main") } };
    content.buildInteractive(.en, &view, &tree);
    try std.testing.expectEqualStrings("HEAD branch: main", content.textFor("vcs.reference") orelse return error.TestUnexpectedResult);
    try std.testing.expect(content.textFor("vcs.preview") != null);
    try std.testing.expect(content.textFor("vcs.modified") == null);
    try std.testing.expect(content.textFor("vcs.staged") == null);
}

test "local trust setup shows explicit review and never claims status without consent" {
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    const workspace = try identity.Workspace.init(.git, "C:\\repo", "C:\\repo");
    var view: View = .{ .phase = .ready, .workspace = workspace, .metadata_only = true, .local_setup = true, .snapshot = .{ .workspace = workspace, .availability = .not_queried, .preview_kinds = 3, .preview_tools = .{ try identity.Path.init("C:\\tools\\git.exe"), null, null } } };
    content.buildInteractive(.en, &view, &tree);
    try std.testing.expectEqual(@as(u32, 9), tree.command_count);
    try std.testing.expectEqual(@as(u32, 1), tree.state_count);
    try std.testing.expect(content.textFor("vcs.status-unavailable") != null);
    try std.testing.expect(content.textFor("vcs.review-warning") == null);
    try std.testing.expectEqualStrings("Git: C:\\tools\\git.exe", content.textFor("vcs.candidate.git") orelse return error.TestUnexpectedResult);
    try std.testing.expect(content.textFor("vcs.action.trust-svn") == null);
    view.local_review = .{ .root = workspace.root, .kind = .jj, .executable = try identity.Path.init("C:\\tools\\jj.exe"), .generation = 1 };
    content.buildInteractive(.en, &view, &tree);
    try std.testing.expectEqualStrings("Executable: C:\\tools\\jj.exe", content.textFor("vcs.review-exe") orelse return error.TestUnexpectedResult);
    try std.testing.expect(content.textFor("vcs.review-warning") != null);
}

test "verified tool version is visible only in an approved view" {
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    var view: View = .{ .phase = .ready, .tool_version = try contract.Text.init("git version 2.56.1") };
    content.buildInteractive(.en, &view, &tree);
    try std.testing.expectEqualStrings("Verified tool version: git version 2.56.1", content.textFor("vcs.tool-version") orelse return error.TestUnexpectedResult);
    content.buildInteractive(.zh, &view, &tree);
    try std.testing.expectEqualStrings("已验证工具版本：git version 2.56.1", content.textFor("vcs.tool-version") orelse return error.TestUnexpectedResult);
    view.metadata_only = true;
    content.buildInteractive(.zh, &view, &tree);
    try std.testing.expect(content.textFor("vcs.tool-version") == null);
    view.metadata_only = false;
    view.approval_required = true;
    content.buildInteractive(.en, &view, &tree);
    try std.testing.expect(content.textFor("vcs.tool-version") == null);
}
