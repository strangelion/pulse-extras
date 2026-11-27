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
pub const command_trust_reset = "vcs.trust.reset";
pub const command_trust_remember = "vcs.trust.remember";
pub const command_trust_reuse = "vcs.trust.reuse";
pub const command_trust_forget = "vcs.trust.forget";
pub const command_trust_forget_all = "vcs.trust.forget-all";
pub const state_executable = "vcs.executable";
pub const state_file_filter = "vcs.files.filter";
pub const command_file_filter = "vcs.files.search";
pub const command_file_prev = "vcs.files.prev";
pub const command_file_next = "vcs.files.next";

pub const state_detail_path = "vcs.detail.path";
pub const state_detail_revision = "vcs.detail.revision";
pub const state_history_offset = "vcs.detail.offset";
pub const detail_kinds = [_]contract.DetailKind{ .history, .file_history, .revision_info, .working_diff, .staged_diff, .revision_diff, .content, .refs, .workspaces, .operations, .local_info, .properties };
pub const detail_actions = [_][]const u8{ "vcs.detail.history", "vcs.detail.file-history", "vcs.detail.revision-info", "vcs.detail.working-diff", "vcs.detail.staged-diff", "vcs.detail.revision-diff", "vcs.detail.content", "vcs.detail.refs", "vcs.detail.workspaces", "vcs.detail.operations", "vcs.detail.local-info", "vcs.detail.properties" };
pub const pick_actions = [_][]const u8{ "vcs.pick.0", "vcs.pick.1", "vcs.pick.2", "vcs.pick.3", "vcs.pick.4", "vcs.pick.5", "vcs.pick.6", "vcs.pick.7" };
pub const revision_pick_actions = [_][]const u8{ "vcs.rev.0", "vcs.rev.1", "vcs.rev.2", "vcs.rev.3", "vcs.rev.4", "vcs.rev.5", "vcs.rev.6", "vcs.rev.7" };
pub const command_detail_prev = "vcs.detail.prev";
pub const command_detail_next = "vcs.detail.next";
pub const advanced_commands = detail_actions ++ pick_actions ++ revision_pick_actions ++ [_][]const u8{ command_detail_prev, command_detail_next };
pub const full_command_count = 17 + advanced_commands.len;

pub fn isDetailCommand(name: []const u8) bool {
    for (advanced_commands) |command| {
        if (std.mem.eql(u8, command, name)) return true;
    }
    return false;
}

pub fn isFileCommand(name: []const u8) bool {
    return std.mem.eql(u8, name, command_file_filter) or std.mem.eql(u8, name, command_file_prev) or std.mem.eql(u8, name, command_file_next);
}

pub const TrustMode = enum { session, remember, reuse };

pub const LocalReview = struct {
    root: identity.Path,
    executable: identity.Path,
    kind: identity.Kind,
    generation: u64,
    mode: TrustMode = .session,
};

pub const SetupIssue = enum { invalid, busy, changed, denied, forgotten, all_forgotten };

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
    file_page: usize = 0,
    file_filter: contract.Text = .{},
    file_controls: bool = false,
    detail_supported: bool = false,
    detail_pending: bool = false,
    detail_scope: ?*const contract.DetailRequest = null,
    detail_data: ?*const contract.DetailText = null,
    detail_error: ?contract.Error = null,
    detail_page: usize = 0,
    detail_path: identity.Path = .{},
    detail_revision: contract.Text = .{},
    history_offset: contract.Text = .{},
    workspace: ?identity.Workspace = null,
    snapshot: ?contract.Snapshot = null,
    stale: bool = false,
    failure: ?contract.Error = null,
    discovery_available: bool = false,
    approval_required: bool = false,
    metadata_only: bool = false,
    local_setup: bool = false,
    reset_configured: bool = false,
    saved_trust_configured: bool = false,
    saved_trust_selected: bool = false,
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
    const capacity = 96;
    const line_bytes = identity.max_path_bytes + 64;
    lines: [capacity][line_bytes]u8 = undefined,
    nodes: [capacity]ui.Node = undefined,
    len: usize = 0,
    root: ui.Node = undefined,
    commands: [full_command_count]abi.StringView = undefined,
    states: [5]ui.State = undefined,

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
            self.add("vcs.local-trust", "", if (view.reset_configured) loc(lang, "Trusted local session (not a sandbox). Change repository or provider only through a fresh review.", "本次会话已信任（非沙箱）。更换仓库或类型需重新确认。") else loc(lang, "Trusted local session (not a sandbox). Close and reopen to change repository or provider.", "本次会话已信任（非沙箱）。更换仓库或类型需关闭后重新打开。"));
        }
        if (view.saved_trust_selected and !view.approval_required) self.add("vcs.saved-trust", "", loc(lang, "Saved local approval selected; identity and tool digest must match before use.", "已选择持久化本地授权；使用前必须匹配仓库身份与工具摘要。"));
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
                if (snapshot.operation.len != 0) self.add("vcs.operation", loc(lang, "Recorded operation: ", "已记录操作："), snapshot.operation.slice());
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
                if (!view.approval_required and snapshot.files.available) self.addFiles(lang, view, &snapshot.files);
                if (view.detail_supported and !view.approval_required and !view.stale and view.phase == .ready) {
                    if (snapshot.workspace) |workspace| self.addDetails(lang, view, workspace.kind);
                }
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

    fn addFiles(self: *Content, lang: Language, view: *const View, files: *const contract.FileList) void {
        const filter = view.file_filter.slice();
        const total = files.matchCount(filter);
        const page_count = @max(1, (total + contract.FileList.page_size - 1) / contract.FileList.page_size);
        const page = @min(view.file_page, page_count - 1);
        var heading: [96]u8 = undefined;
        self.add("vcs.files.heading", loc(lang, "File status: ", "文件状态："), std.fmt.bufPrint(&heading, "{d}/{d} · {d}/{d}", .{ page + 1, page_count, total, files.count }) catch "");
        if (files.omitted != 0) {
            var count_text: [16]u8 = undefined;
            self.add("vcs.files.omitted", loc(lang, "Not retained (limit/invalid path/unknown record): ", "未保留（上限、无效路径或未知记录）："), std.fmt.bufPrint(&count_text, "{d}", .{files.omitted}) catch "");
        }
        const ids = [_][]const u8{ "vcs.file.0", "vcs.file.1", "vcs.file.2", "vcs.file.3", "vcs.file.4", "vcs.file.5", "vcs.file.6", "vcs.file.7" };
        const sources = [_][]const u8{ "vcs.file.source.0", "vcs.file.source.1", "vcs.file.source.2", "vcs.file.source.3", "vcs.file.source.4", "vcs.file.source.5", "vcs.file.source.6", "vcs.file.source.7" };
        var matched: usize = 0;
        var shown: usize = 0;
        for (files.rows[0..files.count]) |row| {
            if (!files.matches(row, filter)) continue;
            matched += 1;
            if (matched <= page * contract.FileList.page_size) continue;
            if (shown == ids.len) break;
            var label: [64]u8 = undefined;
            const prefix = if (row.xy[0] != 0)
                std.fmt.bufPrint(&label, "[{c}{c}] {s}: ", .{ row.xy[0], row.xy[1], row.kind.label() }) catch ""
            else if (row.revision) |rev|
                std.fmt.bufPrint(&label, "{s} r{d}{s}{s}: ", .{ row.kind.label(), rev, if (row.property_changed) " P" else "", if (row.tree_conflict) " T" else "" }) catch ""
            else
                std.fmt.bufPrint(&label, "{s}{s}{s}: ", .{ row.kind.label(), if (row.property_changed) " P" else "", if (row.tree_conflict) " T" else "" }) catch "";
            self.add(ids[shown], prefix, files.slice(row.path));
            if (row.original.len != 0) self.add(sources[shown], loc(lang, "From: ", "原路径："), files.slice(row.original));
            if (view.detail_supported and !view.detail_pending and !view.stale and view.phase == .ready) self.addButton(pick_actions[shown], loc(lang, "Select this file", "选择此文件"), pick_actions[shown]);
            shown += 1;
        }
        if (shown == 0) self.add("vcs.files.empty", "", loc(lang, "No matching retained records", "没有匹配的已保留记录"));
        if (view.file_controls and !view.stale and view.phase == .ready) {
            var node = ui.node(ui.NodeKind.text_input);
            node.id = abi.view(state_file_filter);
            node.state = .{ .present = 1, .value = abi.view(state_file_filter) };
            node.text = .{ .present = 1, .value = abi.view(loc(lang, "Search retained path/status (case-sensitive)", "搜索已保留路径或状态（区分大小写）")) };
            self.nodes[self.len] = node;
            self.len += 1;
            self.addButton("vcs.files.search.action", loc(lang, "Search / clear", "搜索 / 清除"), command_file_filter);
            if (page > 0) self.addButton("vcs.files.prev.action", loc(lang, "Previous files", "上一页文件"), command_file_prev);
            if (page + 1 < page_count) self.addButton("vcs.files.next.action", loc(lang, "Next files", "下一页文件"), command_file_next);
        }
    }

    fn detailInput(self: *Content, key: []const u8, label: []const u8) void {
        var node = ui.node(ui.NodeKind.text_input);
        node.id = abi.view(key);
        node.state = .{ .present = 1, .value = abi.view(key) };
        node.text = .{ .present = 1, .value = abi.view(label) };
        self.nodes[self.len] = node;
        self.len += 1;
    }

    fn addDetails(self: *Content, lang: Language, view: *const View, kind: identity.Kind) void {
        self.add("vcs.detail.heading", "", loc(lang, "Local read-only details", "本地只读详情"));
        if (kind == .svn) self.add("vcs.detail.svn-limit", "", loc(lang, "Server history is not authorized; BASE/diff require a supported pristine-copy version.", "服务器历史未授权；本地 BASE 与差异需要支持完整 pristine 副本的版本。"));
        if (kind == .jj) self.add("vcs.detail.jj-limit", "", loc(lang, "Recorded revisions only; unsnapshotted edits are not included.", "仅已记录版本，不包含尚未快照的编辑。"));
        if (view.detail_pending) {
            self.add("vcs.detail.pending", "", loc(lang, "Query in progress; check or cancel", "正在查询；可检查结果或取消"));
            return;
        }
        self.detailInput(state_detail_path, loc(lang, "File (relative to repository; select above or enter)", "文件（相对仓库路径；在上方选中或填写）"));
        if (kind != .svn) self.detailInput(state_detail_revision, loc(lang, "Full commit ID (empty uses current recorded revision)", "完整提交 ID（留空使用当前已记录版本）"));
        if (kind == .git) self.detailInput(state_history_offset, loc(lang, "History offset (0, 32, 64 ... up to 4096)", "历史偏移（0、32、64……至 4096）")) else if (kind == .jj) self.detailInput(state_history_offset, loc(lang, "History offset (0, 32, 64 ... up to 224)", "历史偏移（0、32、64……至 224）"));
        const en = [_][]const u8{ "History (32 revisions)", "File history", "Revision details", "Working / recorded file diff", "Staged file diff", "Revision file diff", "Revision file content / BASE", "References / bookmarks", "Workspaces", "Operation log", "Local revision metadata", "Local property names" };
        const zh = [_][]const u8{ "提交历史（32 条）", "文件历史", "版本详情", "工作区 / 已记录文件差异", "暂存文件差异", "版本文件差异", "版本文件内容 / BASE", "引用 / 书签", "工作区", "操作日志", "本地版本元数据", "本地属性名" };
        for (detail_kinds, 0..) |action, i| {
            if (contract.detailSupported(kind, action)) self.addButton(detail_actions[i], loc(lang, en[i], zh[i]), detail_actions[i]);
        }
        if (view.detail_error) |err| self.add("vcs.detail.error", "", failureLabel(lang, err));
        if (view.detail_scope) |scope| {
            self.add("vcs.detail.kind", loc(lang, "Result: ", "结果："), @tagName(scope.kind));
            if (scope.path.len != 0) self.add("vcs.detail.result-path", loc(lang, "File: ", "文件："), scope.path.slice());
            if (scope.revision) |rev| self.add("vcs.detail.result-revision", loc(lang, "Revision: ", "版本："), rev.slice());
        }
        if (view.detail_data) |data| {
            switch (data.state) {
                .binary => self.add("vcs.detail.binary", "", loc(lang, "Binary content; not rendered as text", "二进制内容；不作为文本显示")),
                .invalid_encoding => self.add("vcs.detail.encoding", "", loc(lang, "Not valid UTF-8; text preview unavailable", "不是有效 UTF-8；无法显示文本")),
                .text => {
                    const pages = data.pages();
                    const page = @min(view.detail_page, pages - 1);
                    var heading: [64]u8 = undefined;
                    self.add("vcs.detail.page", loc(lang, "Output page: ", "输出页："), std.fmt.bufPrint(&heading, "{d}/{d}", .{ page + 1, pages }) catch "");
                    const ids = [_][]const u8{ "vcs.output.0", "vcs.output.1", "vcs.output.2", "vcs.output.3", "vcs.output.4", "vcs.output.5", "vcs.output.6", "vcs.output.7" };
                    var cursor: usize = 0;
                    var index: usize = 0;
                    while (data.nextChunk(&cursor)) |line| : (index += 1) {
                        if (index < page * contract.DetailText.page_size) continue;
                        const row = index - page * contract.DetailText.page_size;
                        if (row >= ids.len) break;
                        self.add(ids[row], "", if (line.len == 0) " " else line);
                        if (view.detail_scope) |scope| {
                            if ((scope.kind == .history or scope.kind == .file_history) and data.revisionAt(kind, index) != null) self.addButton(revision_pick_actions[row], loc(lang, "Select this revision", "选择此版本"), revision_pick_actions[row]);
                        }
                    }
                    if (data.len == 0) self.add("vcs.detail.empty", "", loc(lang, "No text returned", "没有返回文本"));
                    if (page > 0) self.addButton("vcs.detail.prev.action", loc(lang, "Previous output page", "上一页输出"), command_detail_prev);
                    if (page + 1 < pages) self.addButton("vcs.detail.next.action", loc(lang, "Next output page", "下一页输出"), command_detail_next);
                },
            }
        }
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
            .forgotten => loc(lang, "Saved approval for this root/provider revoked", "已撤销此目录及类型的持久授权"),
            .all_forgotten => loc(lang, "All saved local approvals revoked", "已撤销所有持久化本地授权"),
        });
        if (view.saved_trust_configured and view.metadata_only and !view.approval_required) self.addButton("vcs.action.trust-forget-all", loc(lang, "Revoke all saved local approvals", "撤销所有持久化本地授权"), command_trust_forget_all);
        if (!view.metadata_only or view.approval_required) return;
        if (view.phase != .ready or view.workspace == null or view.snapshot == null) return;
        if (view.local_review) |review| {
            self.add("vcs.review-kind", loc(lang, "Tool: ", "工具："), review.kind.displayName());
            self.add("vcs.review-exe", loc(lang, "Executable: ", "程序："), review.executable.slice());
            self.add("vcs.review-root", loc(lang, "Repository: ", "仓库："), review.root.slice());
            self.add("vcs.review-warning", "", loc(lang, "Trust only known installations and repositories, including dependencies and configuration. Commands run as you; NOT a sandbox. Saved trust pins identities and executable digest, not all dependencies/configuration.", "仅信任已知的工具安装和仓库（含依赖及配置）。命令以当前用户身份运行，不是沙箱。持久授权校验身份和工具摘要，不审核全部依赖及配置。"));
            self.add("vcs.review-scope", "", loc(lang, "Scope: local status, history, revision content, diff and references where supported. Older saved approvals require fresh Trust and remember.", "范围：支持的本地状态、历史、版本内容、差异和引用。旧持久授权需重新选择信任并记住。"));
            self.addButton("vcs.action.trust-confirm", loc(lang, "Trust tool and repository for this session", "信任工具及仓库（仅本次会话）"), command_trust_confirm);
            if (view.saved_trust_configured) {
                self.addButton("vcs.action.trust-remember", loc(lang, "Trust and remember this root/provider/tool", "信任并记住此仓库、类型及工具"), command_trust_remember);
                self.addButton("vcs.action.trust-reuse", loc(lang, "Use previously saved approval (exact match only)", "使用已有授权（仅完全匹配）"), command_trust_reuse);
                self.addButton("vcs.action.trust-forget", loc(lang, "Revoke saved approval for this root/provider", "撤销此仓库及类型的持久授权"), command_trust_forget);
            }
            self.addButton("vcs.action.trust-cancel", loc(lang, "Cancel review", "取消确认"), command_trust_cancel);
        } else {
            const snapshot = view.snapshot orelse return;
            if (view.stale) return;
            self.addExecutableInput(lang);
            self.add("vcs.setup-help", "", loc(lang, "Leave empty for configured, previously saved, or detected tool path, in that order. A saved record is not verified until explicit reuse.", "留空依次使用已配置、曾授权或检测到的工具路径。持久记录须明确选择复用后才能验证。"));
            const kinds = [_]identity.Kind{ .git, .jj, .svn };
            const ids = [_][]const u8{ "vcs.candidate.git", "vcs.candidate.jj", "vcs.candidate.svn" };
            const button_ids = [_][]const u8{ "vcs.action.trust-git", "vcs.action.trust-jj", "vcs.action.trust-svn" };
            const labels = [_][]const u8{ "Git: ", "Jujutsu: ", "SVN: " };
            const en = [_][]const u8{ "Review Git access", "Review Jujutsu access", "Review SVN access" };
            const zh = [_][]const u8{ "确认 Git 访问", "确认 Jujutsu 访问", "确认 SVN 访问" };
            const actions = [_][]const u8{ command_trust_git, command_trust_jj, command_trust_svn };
            const saved_ids = [_][]const u8{ "vcs.saved.git", "vcs.saved.jj", "vcs.saved.svn" };
            const saved_paths = [_][]const u8{ "vcs.saved-path.git", "vcs.saved-path.jj", "vcs.saved-path.svn" };
            for (kinds, ids, button_ids, labels, en, zh, actions, saved_ids, saved_paths) |kind, id, button_id, label, english, chinese, action, saved_id, saved_path| {
                if (!snapshot.previewHas(kind)) continue;
                if (snapshot.previewTool(kind)) |path| {
                    self.add(id, label, path.slice());
                } else self.add(id, label, loc(lang, "Not found; enter the installed path", "未找到，请填写已安装路径"));
                if (view.saved_trust_configured) {
                    const hint = snapshot.savedHint(kind);
                    self.add(saved_id, label, switch (hint.state) {
                        .not_checked => loc(lang, "Saved approval not checked", "尚未检查持久授权"),
                        .absent => loc(lang, "No saved approval observed", "未发现持久授权"),
                        .recorded => loc(lang, "Saved record observed; NOT revalidated", "发现持久授权记录，尚未重新验证"),
                        .unavailable => loc(lang, "Saved approval unavailable", "无法读取持久授权"),
                    });
                    if (hint.executable) |path| self.add(saved_path, loc(lang, "Saved tool: ", "记录中的工具："), path.slice());
                }
                self.addButton(button_id, loc(lang, english, chinese), action);
            }
        }
    }

    /// Declare a stable vocabulary so subscriptions survive model updates.
    /// The owner still validates commands against current controller state.
    pub fn buildInteractive(self: *Content, lang: Language, view: *const View, tree: *ui.Tree) void {
        self.build(lang, view, tree);
        const base_commands = [_]abi.StringView{ abi.view(command_refresh), abi.view(command_cancel), abi.view(command_check), abi.view(command_revoke), abi.view(command_trust_git), abi.view(command_trust_jj), abi.view(command_trust_svn), abi.view(command_trust_confirm), abi.view(command_trust_cancel), abi.view(command_trust_reset), abi.view(command_trust_remember), abi.view(command_trust_reuse), abi.view(command_trust_forget), abi.view(command_trust_forget_all), abi.view(command_file_filter), abi.view(command_file_prev), abi.view(command_file_next) };
        @memcpy(self.commands[0..base_commands.len], &base_commands);
        for (advanced_commands, base_commands.len..) |command, i| self.commands[i] = abi.view(command);
        tree.commands = &self.commands;
        tree.command_count = if (view.local_setup and view.saved_trust_configured) (if (view.file_controls) @as(u32, full_command_count) else 14) else if (view.local_setup) 10 else if (view.revocation_configured) 4 else 3;
        if (view.local_setup) {
            self.states[0] = .{ .key = abi.view(state_executable), .value = abi.view("") };
            tree.states = &self.states;
            self.states[1] = .{ .key = abi.view(state_file_filter), .value = abi.view(view.file_filter.slice()) };
            self.states[2] = .{ .key = abi.view(state_detail_path), .value = abi.view(view.detail_path.slice()) };
            self.states[3] = .{ .key = abi.view(state_detail_revision), .value = abi.view(view.detail_revision.slice()) };
            self.states[4] = .{ .key = abi.view(state_history_offset), .value = abi.view(view.history_offset.slice()) };
            tree.state_count = if (view.file_controls) 5 else 1;
            self.addLocalSetup(lang, view);
            if (view.reset_configured and (!view.metadata_only or view.approval_required)) self.addButton("vcs.action.trust-reset", loc(lang, "Choose repository / provider again", "重新选择仓库 / 版本控制类型"), command_trust_reset);
        }
        if (view.phase != .stopped) {
            if (!view.approval_required and (view.workspace != null or view.discovery_available)) {
                if (view.phase == .queued or view.phase == .refreshing or view.detail_pending) {
                    self.addButton("vcs.action.cancel", loc(lang, "Cancel", "取消"), command_cancel);
                } else {
                    self.addButton("vcs.action.refresh", loc(lang, "Refresh", "刷新"), command_refresh);
                }
            }
            self.addButton("vcs.action.check", loc(lang, "Check result", "检查结果"), command_check);
            if (view.revocation_configured and !view.approval_required) self.addButton("vcs.action.revoke", if (view.persistent_revocation or view.saved_trust_selected) loc(lang, "Revoke saved approval", "永久撤销授权") else loc(lang, "Revoke session approval", "撤销本次授权"), command_revoke);
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
    try std.testing.expectEqual(@as(u32, 10), tree.command_count);
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

test "saved local approval commands require an explicit reviewed view" {
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    const workspace = try identity.Workspace.init(.git, "root", "root");
    var view: View = .{ .phase = .ready, .workspace = workspace, .snapshot = .{ .workspace = workspace }, .metadata_only = true, .local_setup = true, .saved_trust_configured = true };
    content.buildInteractive(.en, &view, &tree);
    try std.testing.expectEqual(@as(u32, 14), tree.command_count);
    try std.testing.expect(content.textFor("vcs.action.trust-remember") == null);
    try std.testing.expect(content.textFor("vcs.action.trust-forget-all") != null);
    view.snapshot.?.preview_kinds = 1;
    view.snapshot.?.preview_saved[0] = .{ .state = .recorded, .executable = try identity.Path.init("git.exe") };
    content.buildInteractive(.en, &view, &tree);
    try std.testing.expectEqualStrings("Git: Saved record observed; NOT revalidated", content.textFor("vcs.saved.git").?);
    try std.testing.expectEqualStrings("Saved tool: git.exe", content.textFor("vcs.saved-path.git").?);
    view.local_review = .{ .root = workspace.root, .executable = try identity.Path.init("git.exe"), .kind = .git, .generation = 1 };
    content.buildInteractive(.en, &view, &tree);
    try std.testing.expect(content.textFor("vcs.action.trust-remember") != null);
    try std.testing.expect(content.textFor("vcs.action.trust-reuse") != null);
    try std.testing.expect(content.textFor("vcs.action.trust-forget") != null);
}
