//! Package-owned preferences and project bookmarks. Paths are suggestions,
//! never authorization. All storage/UI APIs are owner-thread; all returned
//! strings are copied before the callback returns. No background polling.
const std = @import("std");
const builtin = @import("builtin");
const abi = @import("pulse_abi");
const raw = @import("pulse_raw");
const host_mod = @import("pulse_host");
const ui = @import("pulse_ui_model");
const pickers = @import("pulse_pickers");
const async_host = @import("pulse_async_host");
const identity = @import("vcs_identity");
const contract = @import("vcs_provider");
const approval = @import("vcs_approval");
const cli = @import("vcs_cli");
const diag = @import("pulse_diagnostics");
const vcs_panel = @import("vcs_panel");
const project_route = @import("project_route.zig");
const evidence = @import("vcs_windows_evidence");
const forge = @import("forge.zig");
const git_index = @import("vcs_git_index_transaction");

const max_projects = 64;
const page_size = 12;
const max_value = 1024;
const keys = [_][]const u8{ "tool.git", "tool.jj", "tool.svn", "tool.hg" };
const names = [_][]const u8{ "Git", "Jujutsu", "Subversion", "Mercurial" };
const tools = [_]cli.Tool{ .git, .jj, .svn, .hg };
const fields = [_][]const u8{ "settings.git", "settings.jj", "settings.svn", "settings.hg" };
const commands = [_][]const u8{ "vcs.settings.reload", "vcs.settings.save-git", "vcs.settings.save-jj", "vcs.settings.save-svn", "vcs.settings.browse-git", "vcs.settings.browse-jj", "vcs.settings.browse-svn", "vcs.projects.current", "vcs.projects.save", "vcs.projects.remove", "vcs.projects.website", "vcs.projects.check", "vcs.settings.locale-auto", "vcs.settings.locale-en", "vcs.settings.locale-zh", "vcs.projects.new", "vcs.projects.edit", "vcs.projects.update", "vcs.projects.favorite", "vcs.projects.search", "vcs.projects.prev", "vcs.projects.next", "vcs.projects.jump", "vcs.projects.browse", "vcs.projects.cancel-jump", "vcs.projects.cancel-identity", "vcs.projects.inspect-grants", "vcs.projects.revoke-git", "vcs.projects.revoke-jj", "vcs.projects.revoke-svn", "vcs.forge.issues", "vcs.forge.reviews", "vcs.forge.ci", "vcs.forge.releases", "vcs.forge.discover", "vcs.forge.remote.0", "vcs.forge.remote.1", "vcs.forge.remote.2", "vcs.forge.remote.3", "vcs.forge.remote.4", "vcs.forge.remote.5", "vcs.forge.metadata", "vcs.client.save-code", "vcs.client.save-svn", "vcs.client.review-code", "vcs.client.review-svn", "vcs.client.confirm", "vcs.client.cancel", "vcs.integration.cancel", "vcs.projects.local-summary", "vcs.projects.clear-summary", "vcs.settings.save-hg", "vcs.settings.browse-hg", "vcs.projects.revoke-hg", "vcs.git-index.review-stage", "vcs.git-index.review-unstage", "vcs.git-index.confirm", "vcs.git-index.cancel", "vcs.settings.tab-projects", "vcs.settings.tab-tools", "vcs.settings.tab-general", "vcs.projects.clear-search", "vcs.projects.cycle-kind", "vcs.client.browse-code", "vcs.client.browse-svn" };
const clients = [_]forge.Client{ .vscode, .tortoise_svn };
const client_keys = [_][]const u8{ "client.vscode", "client.tortoise_svn" };
const client_fields = [_][]const u8{ "settings.client.vscode", "settings.client.tortoise_svn" };
const root_key = "settings.project.root";
const url_key = "settings.project.url";
const selection_key = "settings.project.selected";
const name_key = "settings.project.name";
const tags_key = "settings.project.tags";
const search_key = "settings.project.search";
const index_path_key = "settings.git-index.path";
const project_prefix = "project.";
const key_len = project_prefix.len + 32;

pub const Tools = [4]?identity.Path;
const locale_key = "ui.locale";

pub const Locale = enum {
    auto,
    en,
    zh,

    fn parse(value: []const u8) !Locale {
        for ([_]Locale{ .auto, .en, .zh }) |locale| {
            if (std.mem.eql(u8, value, @tagName(locale))) return locale;
        }
        return error.InvalidSettings;
    }

    pub fn language(self: Locale) vcs_panel.Language {
        return switch (self) {
            .en => .en,
            .zh => .zh,
            .auto => if (comptime builtin.os.tag == .windows)
                languageForWindows(GetUserDefaultUILanguage())
            else
                .en,
        };
    }
};

extern "kernel32" fn GetUserDefaultUILanguage() callconv(.winapi) u16;

fn languageForWindows(id: u16) vcs_panel.Language {
    return if ((id & 0x03ff) == 0x04) .zh else .en;
}

fn tr(lang: vcs_panel.Language, english: []const u8, chinese: []const u8) []const u8 {
    return if (lang == .zh) chinese else english;
}

const Status = enum {
    initial,
    sync_failed,
    conflict,
    saved,
    loaded,
    invalid,
    pending,
    rejected,
    filled,
    picker_cancel,
    picker_candidate,
    picking,
    browser_pending,
    browser_opened,
    browser_failed,
    command_failed,
    render_failed,
    edit_loaded,
    new_project,
    search_applied,
    route_pending,
    route_dispatched,
    route_failed,
    route_cancelled,
    identity_pending,
    identity_failed,
    identity_cancelled,
    folder_filled,
    grants_pending,
    grants_ready,
    grant_revoke_pending,
    grant_revoked,
    grants_failed,
    remotes_ready,
    remotes_failed,
    metadata_ready,
    client_review,
    client_launched,
    client_failed,
    external_changed,
    external_cancel_pending,
    external_cancelled,
    local_summary_ready,
    local_summary_unavailable,
    index_preparing,
    index_review_ready,
    index_applying,
    index_applied,
    index_cleanup_failed,
    index_not_applied,
    index_cancelled,

    fn label(self: Status, lang: vcs_panel.Language) []const u8 {
        return switch (self) {
            .initial => tr(lang, "Preparing settings", "准备读取设置"),
            .sync_failed => tr(lang, "UI state synchronization failed; reload settings", "界面状态同步失败；请重新读取"),
            .conflict => tr(lang, "Settings operation failed or version changed; reload without overwriting", "设置操作失败或版本冲突；请重新读取，未强制覆盖"),
            .saved => tr(lang, "Host confirmed settings saved", "宿主已确认保存"),
            .loaded => tr(lang, "Settings loaded", "已读取设置"),
            .invalid => tr(lang, "Invalid settings response; previous records retained", "设置数据无效；未覆盖原有记录"),
            .pending => tr(lang, "Waiting for host confirmation", "等待宿主确认"),
            .rejected => tr(lang, "Request not accepted; reload settings", "请求未被正常接受；请重新读取"),
            .filled => tr(lang, "Current repository filled in; review before saving", "已填入当前仓库；请检查后保存"),
            .picker_cancel => tr(lang, "No folder selected; enter a path manually", "未选择工具目录；可手动填写"),
            .picker_candidate => tr(lang, "Candidate filled in; review and save (not verified)", "已填入候选路径；请确认文件名并保存（尚未验证）"),
            .picking => tr(lang, "Selecting tool folder", "正在选择工具目录"),
            .browser_pending => tr(lang, "Browser task submitted; check result", "已提交浏览器任务；可检查结果"),
            .index_preparing => tr(lang, "Reading the local Git index and selected file", "正在检查本地 Git 索引与指定文件"),
            .index_review_ready => tr(lang, "Review the repository, file, Git executable and HEAD before confirming", "确认前请核对仓库、文件、Git 程序及 HEAD"),
            .index_applying => tr(lang, "Updating the reviewed Git index; check the result", "正在更新已审核的 Git 索引；请检查结果"),
            .index_applied => tr(lang, "Git index updated. Refresh the VCS panel for the latest status.", "Git 索引已更新。刷新 VCS 面板可查看最新状态。"),
            .index_cleanup_failed => tr(lang, "Git index updated. Temporary-file cleanup needs attention.", "Git 索引已更新，临时文件清理需要检查"),
            .index_not_applied => tr(lang, "Git index update could not complete. Review the current status before retrying.", "Git 索引操作未完成。请先核对当前状态再重试。"),
            .index_cancelled => tr(lang, "Cancelled before publishing the index", "已取消，正式索引未更新"),
            .browser_opened => tr(lang, "Handed off to the browser; page load not verified", "已交给默认浏览器；不代表网页加载成功"),
            .browser_failed => tr(lang, "Browser task did not complete", "浏览器任务未完成"),
            .command_failed => tr(lang, "Operation failed; check path, selection and pending tasks", "操作未完成：请检查路径、选择及当前任务状态"),
            .render_failed => tr(lang, "Settings model update failed; reload or reopen", "设置界面更新失败；请重新读取或重新打开"),
            .edit_loaded => tr(lang, "Editing selected bookmark; Update also relinks its root", "已加载选中记录；更新可同时重新关联目录"),
            .new_project => tr(lang, "New bookmark; fill in the fields then Add", "新建记录；填写后点击添加"),
            .search_applied => tr(lang, "Search applied", "已应用搜索"),
            .route_pending => tr(lang, "Looking up the project in Pulse; no VCS command runs", "正在 Pulse 中查找项目；不执行 VCS 命令"),
            .route_dispatched => tr(lang, "Pulse accepted directory navigation; verify the destination", "Pulse 已接受目录跳转；请确认实际到达目录"),
            .route_failed => tr(lang, "Cannot navigate to this root; it may be missing, moved, denied or unsupported. Edit/relink or open its path manually.", "无法跳转；目录可能已移动、不存在、被拒绝或不受支持。请编辑重新关联或手动打开路径。"),
            .route_cancelled => tr(lang, "Directory request cancelled; dispatched navigation is not rolled back", "已取消目录请求；已经提交的跳转不会回滚"),
            .identity_pending => tr(lang, "Checking local folder identity; use Check pending task result", "正在检查本地目录身份；请检查待处理任务结果"),
            .identity_failed => tr(lang, "Folder identity could not be verified or already exists; no record written", "目录身份无法验证或已存在；未写入记录"),
            .identity_cancelled => tr(lang, "Project identity check cancelled; no record written", "已取消目录身份检查；未写入记录"),
            .folder_filled => tr(lang, "Selected folder filled; review before adding. No execution approval granted.", "已填入选中文件夹；确认后添加，不授予执行权限。"),
            .grants_pending => tr(lang, "Reading selected project approval records; Check pending task result", "正在读取选中项目的授权记录；请检查待处理任务结果"),
            .grants_ready => tr(lang, "Observed saved records; not verified for execution", "已读取持久授权记录，尚未验证执行权限"),
            .grant_revoke_pending => tr(lang, "Revoking the reviewed scope; Check pending task result", "正在撤销已确认范围的授权；请检查待处理任务结果"),
            .grant_revoked => tr(lang, "Scope revoke completed; running commands cannot be rolled back", "指定范围撤销已完成；已运行的命令无法回滚"),
            .grants_failed => tr(lang, "Approval operation incomplete; inspect again before retrying", "授权操作未确认完成；请重新检查后再试"),
            .remotes_ready => tr(lang, "Literal local remote choices; select the same project before saving", "本地远程地址候选；保存前请选择同一项目"),
            .remotes_failed => tr(lang, "Ordinary .git/config not available; enter a repository address manually", "无法读取普通 .git/config；可手动填写仓库地址"),
            .metadata_ready => tr(lang, "Public GitHub request finished; see snapshot status", "公开 GitHub 查询已结束；请查看快照状态"),
            .client_review => tr(lang, "Review the exact external program and folder; launch requires confirmation", "请核对外部程序及目录；确认后才会启动"),
            .client_launched => tr(lang, "External application started; its window and state are not verified", "外部程序已启动；未验证窗口及应用状态"),
            .client_failed => tr(lang, "External application could not be launched", "外部程序启动失败"),
            .external_changed => tr(lang, "Project or settings changed; result discarded", "项目或设置发生变化；已丢弃结果"),
            .external_cancel_pending => tr(lang, "Cancellation requested; check result. An existing app/browser handoff cannot be undone.", "已请求取消；请检查结果。已完成的程序或浏览器启动无法撤回。"),
            .external_cancelled => tr(lang, "Integration result discarded; completed handoff may remain open", "已丢弃联动结果；已启动的应用可能仍然打开"),
            .local_summary_ready => tr(lang, "Copied matching local panel snapshot; no command started", "已复制匹配的本地面板快照；未启动命令"),
            .local_summary_unavailable => tr(lang, "No matching ready local panel; open project and refresh status explicitly", "没有匹配的就绪本地面板；请打开项目并显式刷新状态"),
        };
    }
};
pub const Current = struct {
    root: identity.Path,
    remote: contract.Text = .{},
    kind: ?identity.Kind = null,
    availability: contract.Availability = .not_queried,
    reference: contract.Text = .{},
    revision: ?identity.RevisionId = null,
    changes: contract.Changes = .{},
    counts: contract.CountAvailability = .{},
};

const Project = struct {
    key: [key_len]u8,
    root: identity.Path,
    remote: contract.Text = .{},
    remote_detected: bool = false,
    name: contract.Text = .{},
    tags: contract.Text = .{},
    favorite: bool = false,
    kind: ?identity.Kind = null,
    // Monotonic settings version at last accepted navigation, NOT wall time.
    opened_order: u64 = 0,

    fn make(root: []const u8, url: []const u8) !Project {
        if (!approval.strictPath(root)) return error.InvalidSettings;
        const path = identity.Path.init(root) catch return error.InvalidSettings;
        const remote = if (url.len == 0) contract.Text{} else contract.repositoryWebUrl(url) orelse return error.InvalidSettings;
        if (root.len + 1 + remote.slice().len > max_value) return error.InvalidSettings;
        return .{ .key = keyFor(root), .root = path, .remote = remote };
    }

    fn keyFor(root: []const u8) [key_len]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(root, &digest, .{});
        var key: [key_len]u8 = undefined;
        @memcpy(key[0..project_prefix.len], project_prefix);
        const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
        @memcpy(key[project_prefix.len..], &hex);
        return key;
    }

    fn validKey(key: []const u8) bool {
        if (key.len != key_len or !std.mem.startsWith(u8, key, project_prefix)) return false;
        for (key[project_prefix.len..]) |c| {
            if (!(std.ascii.isDigit(c) or (c >= 'a' and c <= 'f'))) return false;
        }
        return true;
    }

    fn field(value: []const u8, limit: usize) !contract.Text {
        if (value.len > limit) return error.InvalidSettings;
        for (value) |c| {
            if (c < 0x20 or c == 0x7f) return error.InvalidSettings;
        }
        return contract.Text.init(value) catch error.InvalidSettings;
    }

    fn parseKind(value: []const u8) !?identity.Kind {
        if (std.mem.eql(u8, value, "-")) return null;
        for ([_]identity.Kind{ .git, .jj, .svn, .hg }) |kind| {
            if (std.mem.eql(u8, value, @tagName(kind))) return kind;
        }
        return error.InvalidSettings;
    }

    fn displayName(self: *const Project) []const u8 {
        return if (self.name.slice().len == 0) std.fs.path.basename(self.root.slice()) else self.name.slice();
    }

    fn encode(self: *const Project, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "v3\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{d}\n{s}", .{
            self.root.slice(),
            self.remote.slice(),
            self.name.slice(),
            self.tags.slice(),
            if (self.favorite) "1" else "0",
            if (self.kind) |kind| @tagName(kind) else "-",
            self.opened_order,
            if (self.remote_detected) "detected" else "manual",
        });
    }

    fn decode(key: []const u8, value: []const u8) !Project {
        if (value.len > max_value or !validKey(key)) return error.InvalidSettings;
        const v3 = std.mem.startsWith(u8, value, "v3\n");
        if (!v3 and !std.mem.startsWith(u8, value, "v2\n")) {
            const split = std.mem.indexOfScalar(u8, value, '\n') orelse return error.InvalidSettings;
            const item = try make(value[0..split], value[split + 1 ..]);
            if (!std.mem.eql(u8, key, &item.key) or !item.remote.eql(value[split + 1 ..])) return error.InvalidSettings;
            return item;
        }
        var lines = std.mem.splitScalar(u8, value[3..], '\n');
        const root = lines.next() orelse return error.InvalidSettings;
        const remote = lines.next() orelse return error.InvalidSettings;
        var item = try make(root, remote);
        if (!item.remote.eql(remote)) return error.InvalidSettings;
        item.name = try field(lines.next() orelse return error.InvalidSettings, 96);
        item.tags = try field(lines.next() orelse return error.InvalidSettings, 160);
        const favorite = lines.next() orelse return error.InvalidSettings;
        item.favorite = if (std.mem.eql(u8, favorite, "1")) true else if (std.mem.eql(u8, favorite, "0")) false else return error.InvalidSettings;
        item.kind = try parseKind(lines.next() orelse return error.InvalidSettings);
        const order = lines.next() orelse return error.InvalidSettings;
        if (order.len == 0) return error.InvalidSettings;
        for (order) |c| {
            if (!std.ascii.isDigit(c)) return error.InvalidSettings;
        }
        item.opened_order = std.fmt.parseInt(u64, order, 10) catch return error.InvalidSettings;
        if (v3) {
            const source = lines.next() orelse return error.InvalidSettings;
            item.remote_detected = if (std.mem.eql(u8, source, "detected") and item.remote.len != 0) true else if (std.mem.eql(u8, source, "manual")) false else return error.InvalidSettings;
        }
        if (item.opened_order > (1 << 53) - 1 or lines.next() != null) return error.InvalidSettings;
        // V2 keys survive explicit relink. The new root never conveys trust.
        @memcpy(&item.key, key);
        return item;
    }

    fn matches(self: *const Project, query: []const u8) bool {
        if (query.len == 0) return true;
        for ([_][]const u8{ self.displayName(), self.root.slice(), self.tags.slice(), self.remote.slice(), if (self.kind) |kind| kind.displayName() else "" }) |value| {
            if (containsFold(value, query)) return true;
        }
        return false;
    }
};

fn containsFold(value: []const u8, query: []const u8) bool {
    if (query.len > value.len) return false;
    for (0..value.len - query.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(value[i .. i + query.len], query)) return true;
    }
    return false;
}

fn sameRoot(a: []const u8, b: []const u8) bool {
    // Conservative lexical duplicate check, not a physical identity claim.
    return if (builtin.os.tag == .windows) std.ascii.eqlIgnoreCase(a, b) else std.mem.eql(u8, a, b);
}

fn toolMask(index: usize) u8 {
    return if (index == 3) 64 else @as(u8, 1) << @as(u3, @intCast(index));
}

fn toolPath(index: usize, value: []const u8) !?identity.Path {
    if (index >= tools.len or value.len > max_value) return error.InvalidSettings;
    if (value.len == 0) return null;
    if (!approval.strictPath(value) or !std.ascii.eqlIgnoreCase(std.fs.path.basename(value), tools[index].exeName())) return error.InvalidSettings;
    return identity.Path.init(value) catch error.InvalidSettings;
}

const Stored = struct {
    version: u64 = 0,
    locale: Locale = .auto,
    tools: Tools = @splat(null),
    client_paths: [clients.len]?identity.Path = @splat(null),
    projects: [max_projects]Project = undefined,
    count: usize = 0,

    fn find(self: *const Stored, key: []const u8) ?usize {
        for (self.projects[0..self.count], 0..) |*project, index| {
            if (std.mem.eql(u8, key, &project.key)) return index;
        }
        return null;
    }

    fn findRoot(self: *const Stored, root: []const u8) ?usize {
        for (self.projects[0..self.count], 0..) |*project, index| {
            if (sameRoot(project.root.slice(), root)) return index;
        }
        return null;
    }

    fn newKey(self: *const Stored, root: []const u8) ![key_len]u8 {
        const first = Project.keyFor(root);
        if (self.find(&first) == null) return first;
        // A relink may retain the old root's ID. Allocate a different
        // deterministic candidate without overwriting that existing record.
        var buffer: [max_value + 64]u8 = undefined;
        for (0..max_projects) |attempt| {
            const salted = try std.fmt.bufPrint(&buffer, "{s}\n{d}\n{d}", .{ root, self.version, attempt });
            const key = Project.keyFor(salted);
            if (self.find(&key) == null) return key;
        }
        return error.InvalidSettings;
    }

    fn decode(value: raw.PulseSettings, out: *Stored) !void {
        if (value.version > (1 << 53) - 1 or value.count > 1024 or (value.count != 0 and value.values == null)) return error.InvalidSettings;
        // Reset only live fields; the unused project array is not read.
        // Avoid a whole Stored temporary on the host's small owner stack.
        out.version = value.version;
        out.locale = .auto;
        out.tools = @splat(null);
        out.client_paths = @splat(null);
        out.count = 0;
        var seen: [4]bool = @splat(false);
        var seen_locale = false;
        var seen_clients: [clients.len]bool = @splat(false);
        for (0..value.count) |n| {
            const pair = value.values[n];
            const key = abi.slice(pair.key) orelse return error.InvalidSettings;
            if (key.len > 64) return error.InvalidSettings;
            if (std.mem.eql(u8, key, locale_key)) {
                if (seen_locale) return error.InvalidSettings;
                seen_locale = true;
                out.locale = try Locale.parse(abi.slice(pair.value) orelse return error.InvalidSettings);
                continue;
            }
            for (keys, 0..) |name, i| {
                if (!std.mem.eql(u8, key, name)) continue;
                if (seen[i]) return error.InvalidSettings;
                seen[i] = true;
                const data = if (pair.value.length == 0) "" else abi.slice(pair.value) orelse return error.InvalidSettings;
                out.tools[i] = try toolPath(i, data);
            }
            for (client_keys, 0..) |client_key, i| {
                if (!std.mem.eql(u8, key, client_key)) continue;
                if (seen_clients[i]) return error.InvalidSettings;
                seen_clients[i] = true;
                const data = if (pair.value.length == 0) "" else abi.slice(pair.value) orelse return error.InvalidSettings;
                out.client_paths[i] = try forge.clientPath(clients[i], data);
            }
            if (!std.mem.startsWith(u8, key, project_prefix)) continue;
            if (out.count == max_projects or out.find(key) != null) return error.InvalidSettings;
            const data = abi.slice(pair.value) orelse return error.InvalidSettings;
            const item = try Project.decode(key, data);
            if (out.findRoot(item.root.slice()) != null or item.opened_order > value.version) return error.InvalidSettings;
            out.projects[out.count] = item;
            out.count += 1;
        }
    }
};

pub const GrantAccess = struct {
    inspect: *const fn (*anyopaque, *const identity.Path, identity.Kind) contract.SavedHint,
    forget: *const fn (*anyopaque, *const identity.Path, identity.Kind) host_mod.Error!void,
    invalidate: *const fn (*anyopaque, *const identity.Path, identity.Kind) void,
};

const GrantReview = struct {
    key: [key_len]u8,
    root: identity.Path,
    version: u64,
    hints: [4]contract.SavedHint = @splat(.{}),
};

const GrantJob = struct {
    review: GrantReview,
    revoke: ?identity.Kind = null,
};

const grant_kinds = [_]identity.Kind{ .git, .jj, .svn, .hg };

const Scope = struct {
    key: [key_len]u8,
    root: identity.Path,
    version: u64,
    remote: contract.Text,
    kind: ?identity.Kind,

    fn from(project: *const Project, version: u64) Scope {
        return .{ .key = project.key, .root = project.root, .version = version, .remote = project.remote, .kind = project.kind };
    }

    fn matches(self: *const Scope, project: *const Project, version: u64) bool {
        return self.version == version and std.mem.eql(u8, &self.key, &project.key) and self.root.eql(project.root.slice()) and self.remote.eql(project.remote.slice()) and self.kind == project.kind;
    }
};
const ClientReview = struct { scope: Scope, client: forge.Client, executable: identity.Path };
const IndexReview = struct { scope: Scope, plan: git_index.Plan };
const IndexResult = enum { applied, cleanup_failed, not_applied, cancelled };
const ExternalJob = union(enum) {
    website: struct { scope: Scope, page: forge.Page },
    discover: Scope,
    metadata: Scope,
    client: ClientReview,
    index_review: struct { scope: Scope, request: git_index.Plan.Scope },
    index_apply: IndexReview,

    fn scope(self: *const ExternalJob) *const Scope {
        return switch (self.*) {
            .website => |*job| &job.scope,
            .discover => |*job| job,
            .metadata => |*job| job,
            .client => |*job| &job.scope,
            .index_review => |*job| &job.scope,
            .index_apply => |*job| &job.scope,
        };
    }
};
const RemoteReview = struct { scope: Scope, value: forge.Remotes };
const MetadataReview = struct { scope: Scope, value: forge.Metadata };
const LocalSummary = struct { scope: Scope, value: Current };

fn countLabel(buffer: []u8, value: u32, availability: contract.Availability) []const u8 {
    if (availability != .ready) return "?";
    return std.fmt.bufPrint(buffer, "{d}", .{value}) catch "?";
}

const Section = enum { projects, tools, general };

const Content = struct {
    pool: [256]ui.Node = undefined,
    pool_len: usize = 0,
    root: ui.Node = undefined,
    states: [13]ui.State = undefined,
    vocabulary: [commands.len]abi.StringView = undefined,
    rows: [page_size]raw.PulseUiModelRow = undefined,
    cells: [page_size][8]abi.StringView = undefined,
    columns: [8]raw.PulseUiModelColumn = undefined,
    recency_labels: [page_size][32]u8 = undefined,
    page_label: [96]u8 = undefined,
    edit_label: [128]u8 = undefined,
    kind_label: [64]u8 = undefined,
    grant_labels: [4][96]u8 = undefined,
    remote_labels: [forge.Remotes.capacity][384]u8 = undefined,
    meta_label: [256]u8 = undefined,
    local_label: [256]u8 = undefined,
    local_counts: [6][16]u8 = undefined,
    client_command: [2 * identity.max_path_bytes + 128]u8 = undefined,

    fn allocNodes(self: *Content, slice: []const ui.Node) []const ui.Node {
        std.debug.assert(self.pool_len + slice.len <= self.pool.len);
        const start = self.pool_len;
        @memcpy(self.pool[start .. start + slice.len], slice);
        self.pool_len += slice.len;
        return self.pool[start .. start + slice.len];
    }

    fn textNode(id: []const u8, body: []const u8, role: ?[]const u8) ui.Node {
        var node = ui.text(body);
        node.id = abi.view(id);
        if (role) |r| node.role = .{ .present = 1, .value = abi.view(r) };
        return node;
    }

    fn buttonNode(index: usize, text: []const u8, enabled: bool, role: ?[]const u8) ui.Node {
        var node = ui.button(text, commands[index]);
        node.id = abi.view(commands[index]);
        node.enabled = .{ .present = 1, .value = @intFromBool(enabled) };
        if (role) |r| node.role = .{ .present = 1, .value = abi.view(r) };
        return node;
    }

    fn inputNode(key: []const u8, caption: []const u8, enabled: bool) ui.Node {
        var node = ui.node(ui.NodeKind.text_input);
        node.id = abi.view(key);
        node.text = .{ .present = 1, .value = abi.view(caption) };
        node.state = .{ .present = 1, .value = abi.view(key) };
        node.enabled = .{ .present = 1, .value = @intFromBool(enabled) };
        return node;
    }

    fn stackNode(self: *Content, id: []const u8, horizontal: bool, gap: i32, children: []const ui.Node) ui.Node {
        var node = ui.node(ui.NodeKind.stack);
        node.id = abi.view(id);
        if (horizontal) node.orientation = .{ .present = 1, .value = abi.view("horizontal") };
        node.gap = .{ .present = 1, .value = gap };
        ui.withChildren(&node, self.allocNodes(children));
        return node;
    }

    fn gridNode(self: *Content, id: []const u8, cols: i32, gap: i32, children: []const ui.Node) ui.Node {
        var node = ui.node(ui.NodeKind.grid);
        node.id = abi.view(id);
        node.columns = .{ .present = 1, .value = cols };
        node.gap = .{ .present = 1, .value = gap };
        ui.withChildren(&node, self.allocNodes(children));
        return node;
    }

    fn groupNode(self: *Content, id: []const u8, title: []const u8, children: []const ui.Node) ui.Node {
        var node = ui.node(ui.NodeKind.group);
        node.id = abi.view(id);
        node.text = .{ .present = 1, .value = abi.view(title) };
        node.bordered = .{ .present = 1, .value = 1 };
        node.gap = .{ .present = 1, .value = 8 };
        ui.withChildren(&node, self.allocNodes(children));
        return node;
    }

    fn build(self: *Content, owner: *const Settings, tree: *ui.Tree) void {
        self.pool_len = 0;
        const idle = owner.loaded and owner.pending == 0 and owner.picker_request == 0 and !owner.poisoned and !owner.route.busy() and !owner.checkingProject() and !owner.externalBusy();
        const lang = owner.stored.locale.language();

        // Always declare all states regardless of active tab so host syncTools() stays valid.
        for (fields, 0..) |field, i| {
            self.states[if (i == 3) 11 else i] = .{ .key = abi.view(field), .value = abi.view(if (owner.stored.tools[i]) |*path| path.slice() else "") };
        }
        self.states[3] = .{ .key = abi.view(root_key), .value = abi.view("") };
        self.states[4] = .{ .key = abi.view(url_key), .value = abi.view("") };
        self.states[5] = .{ .key = abi.view(selection_key), .value = abi.view("") };
        self.states[6] = .{ .key = abi.view(name_key), .value = abi.view("") };
        self.states[7] = .{ .key = abi.view(tags_key), .value = abi.view("") };
        self.states[8] = .{ .key = abi.view(search_key), .value = abi.view(owner.search.slice()) };
        for (client_fields, 0..) |field, i| {
            self.states[9 + i] = .{ .key = abi.view(field), .value = abi.view(if (owner.stored.client_paths[i]) |*path| path.slice() else "") };
        }
        self.states[12] = .{ .key = abi.view(index_path_key), .value = abi.view("") };

        var page_items: [16]ui.Node = undefined;
        var page_len: usize = 0;

        // Top 3-tab navigation bar.
        const nav_buttons = [_]ui.Node{
            buttonNode(58, tr(lang, "Projects", "项目库"), true, if (owner.section == .projects) "primary" else "transparent"),
            buttonNode(59, tr(lang, "Tools & Clients", "工具与客户端"), true, if (owner.section == .tools) "primary" else "transparent"),
            buttonNode(60, tr(lang, "General", "常规设置"), true, if (owner.section == .general) "primary" else "transparent"),
        };
        page_items[page_len] = self.gridNode("settings.nav", 3, 8, &nav_buttons);
        page_len += 1;

        // Always-visible top status & active-task bar so feedback is never off-screen.
        var header_items: [2]ui.Node = undefined;
        header_items[0] = textNode("settings.status", owner.status.label(lang), "caption");
        var top_actions: [5]ui.Node = undefined;
        var top_len: usize = 0;
        const can_reload = owner.pending == 0 and owner.picker_request == 0 and !owner.poisoned and !owner.route.busy() and !owner.checkingProject() and !owner.externalBusy();
        top_actions[top_len] = buttonNode(0, tr(lang, "Reload settings", "重新读取设置"), can_reload, "standard");
        top_len += 1;
        if (owner.checkingProject() or owner.externalBusy()) {
            top_actions[top_len] = buttonNode(11, tr(lang, "Check pending task result", "检查待处理任务结果"), true, "primary");
            top_len += 1;
        }
        if (owner.checkingProject() and !owner.grant_revoke_pending) {
            top_actions[top_len] = buttonNode(25, tr(lang, "Cancel pending check", "取消待处理检查"), !owner.project_discard, "standard");
            top_len += 1;
        }
        if (owner.externalBusy()) {
            top_actions[top_len] = buttonNode(48, tr(lang, "Cancel integration task", "取消联动任务"), !owner.external_discard, "standard");
            top_len += 1;
        }
        if (owner.route.busy()) {
            top_actions[top_len] = buttonNode(24, tr(lang, "Cancel directory lookup", "取消目录查找"), true, "standard");
            top_len += 1;
        }
        header_items[1] = self.stackNode("settings.header.actions", true, 8, top_actions[0..top_len]);
        page_items[page_len] = self.groupNode("settings.header", tr(lang, "Status", "状态"), &header_items);
        page_len += 1;

        switch (owner.section) {
            .projects => {
                const visible = owner.visible();
                var list_items: [12]ui.Node = undefined;
                var list_len: usize = 0;

                list_items[list_len] = textNode("settings.projects", tr(lang, "Bookmarks only — never grants execution or trust automatically.", "仅记录项目目录与备注，不自动授予执行权限。"), "caption");
                list_len += 1;

                // Search bar + Search/Clear buttons.
                const search_btns = [_]ui.Node{
                    buttonNode(19, tr(lang, "Search", "搜索"), idle, "standard"),
                    buttonNode(61, tr(lang, "Clear search", "清空搜索"), idle and owner.search.len != 0, "transparent"),
                };
                list_items[list_len] = inputNode(search_key, tr(lang, "Search name, path, tags or remote", "搜索名称、路径、标签或远程地址"), idle);
                list_len += 1;
                list_items[list_len] = self.stackNode("settings.project.search-bar", true, 8, &search_btns);
                list_len += 1;

                const headers = [_][]const u8{ tr(lang, "Favorite", "收藏"), tr(lang, "Project", "项目"), tr(lang, "Provider hint", "类型提示"), tr(lang, "Local directory", "本地目录"), tr(lang, "Tags", "标签"), tr(lang, "Remote", "远程仓库"), tr(lang, "Address source", "地址来源"), tr(lang, "Open order", "打开顺序") };
                const ids = [_][]const u8{ "favorite", "name", "provider", "path", "tags", "remote", "remote_source", "opened" };
                for (headers, ids, 0..) |heading, id, i| {
                    self.columns[i] = std.mem.zeroes(raw.PulseUiModelColumn);
                    self.columns[i].size = @sizeOf(raw.PulseUiModelColumn);
                    self.columns[i].id = abi.view(id);
                    self.columns[i].text = abi.view(heading);
                }
                for (visible.indices[0..visible.count], 0..) |index, i| {
                    const project = &owner.stored.projects[index];
                    self.cells[i] = .{
                        abi.view(if (project.favorite) tr(lang, "Yes", "是") else ""),
                        abi.view(project.displayName()),
                        abi.view(if (project.kind) |kind| kind.displayName() else tr(lang, "Unknown", "未知")),
                        abi.view(project.root.slice()),
                        abi.view(project.tags.slice()),
                        abi.view(project.remote.slice()),
                        abi.view(if (project.remote.len == 0) "" else if (project.remote_detected) tr(lang, "Local hint", "本地检测") else tr(lang, "Manual / legacy", "手动 / 旧记录")),
                        abi.view(if (project.opened_order == 0) tr(lang, "Never", "未记录") else std.fmt.bufPrint(&self.recency_labels[i], "{d}", .{project.opened_order}) catch ""),
                    };
                    self.rows[i] = std.mem.zeroes(raw.PulseUiModelRow);
                    self.rows[i].size = @sizeOf(raw.PulseUiModelRow);
                    self.rows[i].id = abi.view(&project.key);
                    self.rows[i].cells = .{ .present = 1, .data = &self.cells[i], .count = self.cells[i].len };
                }

                if (visible.count != 0) {
                    var table = ui.node(ui.NodeKind.data_table);
                    table.id = abi.view("settings.project.table");
                    table.state = .{ .present = 1, .value = abi.view(selection_key) };
                    table.min_height = .{ .present = 1, .value = 176 };
                    table.rows = .{ .present = 1, .data = &self.rows, .count = @intCast(visible.count) };
                    table.data_columns = .{ .present = 1, .data = &self.columns, .count = self.columns.len };
                    list_items[list_len] = table;
                    list_len += 1;

                    // Horizontal pager.
                    const page_text = std.fmt.bufPrint(&self.page_label, "{d}/{d} · {d} / {d}", .{ owner.project_page + 1, @max(1, (visible.total + page_size - 1) / page_size), visible.total, owner.stored.count }) catch "";
                    const pager = [_]ui.Node{
                        buttonNode(20, tr(lang, "Previous page", "上一页"), idle and owner.project_page > 0, "standard"),
                        textNode("settings.project.page", page_text, "caption"),
                        buttonNode(21, tr(lang, "Next page", "下一页"), idle and (owner.project_page + 1) * page_size < visible.total, "standard"),
                    };
                    list_items[list_len] = self.stackNode("settings.project.pager", true, 8, &pager);
                    list_len += 1;

                    // Core project row actions (horizontal 4-col grid).
                    var core_btns: [4]ui.Node = undefined;
                    var core_len: usize = 0;
                    if (owner.route.table != null) {
                        core_btns[core_len] = buttonNode(22, tr(lang, "Open in Pulse", "在 Pulse 中打开"), idle, "primary");
                        core_len += 1;
                    }
                    core_btns[core_len] = buttonNode(16, tr(lang, "Edit / show path", "编辑 / 查看路径"), idle, "standard");
                    core_len += 1;
                    core_btns[core_len] = buttonNode(18, tr(lang, "Toggle favorite", "切换收藏"), idle, "standard");
                    core_len += 1;
                    core_btns[core_len] = buttonNode(9, tr(lang, "Remove bookmark", "移除记录"), idle, "danger");
                    core_len += 1;
                    list_items[list_len] = self.gridNode("settings.project.core-actions", @intCast(core_len), 8, core_btns[0..core_len]);
                    list_len += 1;
                    if (owner.route.table == null) {
                        list_items[list_len] = textNode("settings.project.route-fallback", tr(lang, "Host navigation unavailable: edit selected and open its path manually.", "宿主不支持跳转：请编辑选中项目并手动打开路径。"), "caption");
                        list_len += 1;
                    }

                    // Remote / Forge web links (5-col grid).
                    const external_idle = idle and (if (owner.browser) |*task| !task.occupied() else false);
                    const web_btns = [_]ui.Node{
                        buttonNode(10, tr(lang, "Repository", "仓库主页"), external_idle, "standard"),
                        buttonNode(30, tr(lang, "Issues", "Issues"), external_idle, "standard"),
                        buttonNode(31, tr(lang, "PR / MR", "PR / MR"), external_idle, "standard"),
                        buttonNode(32, tr(lang, "Actions / CI", "Actions / CI"), external_idle, "standard"),
                        buttonNode(33, tr(lang, "Releases", "Releases"), external_idle, "standard"),
                    };
                    list_items[list_len] = self.gridNode("settings.forge.links", 5, 6, &web_btns);
                    list_len += 1;

                    // Inspect / Sync / External clients (grid).
                    var tool_btns: [6]ui.Node = undefined;
                    var tool_len: usize = 0;
                    tool_btns[tool_len] = buttonNode(34, tr(lang, "Detect local Git remotes", "检查本地 Git 远程"), external_idle, "standard");
                    tool_len += 1;
                    tool_btns[tool_len] = buttonNode(41, tr(lang, "Fetch GitHub info", "获取公开 GitHub 信息"), external_idle, "standard");
                    tool_len += 1;
                    tool_btns[tool_len] = buttonNode(49, tr(lang, "Copy panel summary", "复制面板摘要"), idle, "standard");
                    tool_len += 1;
                    if (owner.grant_access != null and owner.project_task != null) {
                        tool_btns[tool_len] = buttonNode(26, tr(lang, "Inspect saved approvals", "检查持久授权"), idle, "standard");
                        tool_len += 1;
                    }
                    tool_btns[tool_len] = buttonNode(44, tr(lang, "Open in VS Code…", "用 VS Code 打开…"), external_idle and owner.stored.client_paths[0] != null, "standard");
                    tool_len += 1;
                    tool_btns[tool_len] = buttonNode(45, tr(lang, "TortoiseSVN status…", "TortoiseSVN 状态…"), external_idle and owner.stored.client_paths[1] != null, "standard");
                    tool_len += 1;
                    list_items[list_len] = self.gridNode("settings.project.integrations", 3, 6, tool_btns[0..tool_len]);
                    list_len += 1;

                    // Windows Git single-file index review.
                    if (comptime builtin.os.tag == .windows) {
                        if (owner.stored.tools[0] != null) {
                            const idx_btns = [_]ui.Node{
                                buttonNode(54, tr(lang, "Review staging file", "审核暂存文件"), external_idle, "standard"),
                                buttonNode(55, tr(lang, "Review unstaging file", "审核取消暂存"), external_idle, "standard"),
                            };
                            list_items[list_len] = inputNode(index_path_key, tr(lang, "Git file path relative to selected project", "相对于选中 Git 项目的文件路径"), external_idle);
                            list_len += 1;
                            list_items[list_len] = self.stackNode("settings.git-index.bar", true, 8, &idx_btns);
                            list_len += 1;
                        }
                    }

                    list_items[list_len] = textNode("settings.forge.warning", tr(lang, "Browser availability and private access are not verified; external apps may access files/network independently.", "未验证网页可用性与私有访问权限；外部程序可自行访问文件或网络。"), "caption");
                    list_len += 1;
                } else {
                    var empty = ui.node(ui.NodeKind.empty_state);
                    empty.id = abi.view("settings.project.empty");
                    empty.text = .{ .present = 1, .value = abi.view(tr(lang, "No matching projects", "没有匹配项目")) };
                    empty.detail = .{ .present = 1, .value = abi.view(tr(lang, "Add a project below (up to 64 records) or clear your search filter.", "请在下方添加项目（最多 64 项）或清空搜索词。")) };
                    list_items[list_len] = empty;
                    list_len += 1;
                }

                page_items[page_len] = self.groupNode("settings.projects.card", tr(lang, "Project Library", "项目库"), list_items[0..list_len]);
                page_len += 1;

                // Inline transient review cards (bordered groups, only rendered when active).
                if (owner.remote_review) |*review| {
                    var r_items: [16]ui.Node = undefined;
                    var r_len: usize = 0;
                    r_items[r_len] = textNode("settings.forge.review-root", review.scope.root.slice(), "caption");
                    r_len += 1;
                    const remote_ids = [_][]const u8{ "settings.remote.0", "settings.remote.1", "settings.remote.2", "settings.remote.3", "settings.remote.4", "settings.remote.5" };
                    for (review.value.rows[0..review.value.count], 0..) |row, i| {
                        const label = std.fmt.bufPrint(&self.remote_labels[i], "{s}: {s}", .{ row.name.slice(), row.url.slice() }) catch "";
                        const pair = [_]ui.Node{
                            textNode(remote_ids[i], label, null),
                            buttonNode(35 + i, tr(lang, "Save address", "保存此地址"), idle and !owner.externalBusy(), "primary"),
                        };
                        r_items[r_len] = self.stackNode("settings.remote.row", true, 8, &pair);
                        r_len += 1;
                    }
                    if (review.value.count == 0) {
                        r_items[r_len] = textNode("settings.remote.empty", tr(lang, "No supported literal remote", "没有支持的字面远程地址"), "caption");
                        r_len += 1;
                    }
                    if (review.value.omitted != 0) {
                        r_items[r_len] = textNode("settings.remote.omitted", tr(lang, "Some remote values were rejected or exceed the retained limit; raw values hidden.", "部分远程地址无效或超出保留上限；原始值不显示。"), "caption");
                        r_len += 1;
                    }
                    page_items[page_len] = self.groupNode("settings.remote.card", tr(lang, "Detected Local Git Remotes", "检测到的本地 Git 远程"), r_items[0..r_len]);
                    page_len += 1;
                }

                if (owner.local_summary) |*review| {
                    const value = &review.value;
                    const c = value.changes;
                    const a = value.counts;
                    const values = [_][]const u8{
                        countLabel(&self.local_counts[0], c.staged, a.staged),
                        countLabel(&self.local_counts[1], c.modified, a.modified),
                        countLabel(&self.local_counts[2], c.untracked, a.untracked),
                        countLabel(&self.local_counts[3], c.conflicted, a.conflicted),
                        countLabel(&self.local_counts[4], c.ahead, a.ahead),
                        countLabel(&self.local_counts[5], c.behind, a.behind),
                    };
                    const label = if (lang == .zh)
                        std.fmt.bufPrint(&self.local_label, "暂存 {s} | 修改 {s} | 未跟踪 {s} | 冲突 {s} | 领先 {s} | 落后 {s}", .{ values[0], values[1], values[2], values[3], values[4], values[5] }) catch ""
                    else
                        std.fmt.bufPrint(&self.local_label, "Staged {s} | Modified {s} | Untracked {s} | Conflicts {s} | Ahead {s} | Behind {s}", .{ values[0], values[1], values[2], values[3], values[4], values[5] }) catch "";
                    const s_items = [_]ui.Node{
                        textNode("settings.local.heading", tr(lang, "Local panel snapshot, not live; may be cached", "本地面板快照，非实时，可能来自缓存"), "caption"),
                        textNode("settings.local.root", review.scope.root.slice(), null),
                        textNode("settings.local.provider", if (value.kind) |kind| kind.displayName() else "?", null),
                        textNode("settings.local.ref", if (value.reference.len == 0) "?" else value.reference.slice(), null),
                        textNode("settings.local.revision", if (value.revision) |*revision| revision.slice() else "?", null),
                        textNode("settings.local.counts", label, null),
                        buttonNode(50, tr(lang, "Clear local summary", "清除本地摘要"), idle, "standard"),
                    };
                    page_items[page_len] = self.groupNode("settings.local.card", tr(lang, "Local Panel Summary", "本地面板摘要"), &s_items);
                    page_len += 1;
                }

                if (owner.metadata_review) |*review| {
                    var m_items: [5]ui.Node = undefined;
                    var m_len: usize = 0;
                    m_items[m_len] = textNode("settings.meta.repository", review.scope.remote.slice(), null);
                    m_len += 1;
                    m_items[m_len] = textNode("settings.meta.heading", tr(lang, "Last explicit public snapshot (not live; no automatic refresh)", "最近一次显式公开快照（非实时；不自动刷新）"), "caption");
                    m_len += 1;
                    const result = review.value;
                    const status_text = if (result.status == .ready and forge.nowMs() -| result.fetched_ms > 300000) tr(lang, "Expired; fetch again", "已过期；请重新获取") else switch (result.status) {
                        .ready => tr(lang, "Public response verified", "已验证公开响应"),
                        .forbidden_or_limited => tr(lang, "Access denied or rate limited; retry manually later", "访问被拒绝或限流；稍后手动重试"),
                        .not_found => tr(lang, "Not found or private; no account connected", "不存在或为私有仓库；未连接账号"),
                        .redirected => tr(lang, "Redirect refused; review repository URL", "已拒绝重定向；请确认仓库地址"),
                        .http_error => tr(lang, "HTTP request failed", "HTTP 请求失败"),
                        .offline => tr(lang, "Offline, timeout or transport unavailable", "离线、超时或传输不可用"),
                        .invalid => tr(lang, "Invalid or mismatched response", "响应无效或仓库不匹配"),
                        .too_large => tr(lang, "Response exceeds 64 KiB", "响应超过 64 KiB"),
                        .cancelled => tr(lang, "Cancelled", "已取消"),
                    };
                    m_items[m_len] = textNode("settings.meta.status", status_text, null);
                    m_len += 1;
                    if (result.status == .ready and forge.nowMs() -| result.fetched_ms <= 300000) {
                        const label = if (lang == .zh)
                            std.fmt.bufPrint(&self.meta_label, "星标 {d} | Fork {d} | 开放 Issue/PR {d} | 已归档：{s}", .{ result.stars, result.forks, result.open_items, if (result.archived) "是" else "否" }) catch ""
                        else
                            std.fmt.bufPrint(&self.meta_label, "Stars {d} | Forks {d} | Open issues + PRs {d} | Archived {s}", .{ result.stars, result.forks, result.open_items, if (result.archived) "yes" else "no" }) catch "";
                        m_items[m_len] = textNode("settings.meta.counts", label, null);
                        m_len += 1;
                        m_items[m_len] = textNode("settings.meta.branch", result.branch.slice(), "caption");
                        m_len += 1;
                    }
                    page_items[page_len] = self.groupNode("settings.meta.card", tr(lang, "Public GitHub Metadata", "公开 GitHub 元数据"), m_items[0..m_len]);
                    page_len += 1;
                }

                if (owner.client_review) |*review| {
                    var c_items: [6]ui.Node = undefined;
                    var c_len: usize = 0;
                    c_items[c_len] = textNode("settings.client.review-kind", review.client.name(), null);
                    c_len += 1;
                    c_items[c_len] = textNode("settings.client.review-exe", review.executable.slice(), "caption");
                    c_len += 1;
                    const command = forge.commandLine(review.client, review.executable.slice(), review.scope.root.slice(), review.scope.kind, &self.client_command) catch "";
                    if (command.len != 0) {
                        c_items[c_len] = textNode("settings.client.review-command", command, "caption");
                        c_len += 1;
                    }
                    c_items[c_len] = textNode("settings.client.review-root", review.scope.root.slice(), null);
                    c_len += 1;
                    const c_btns = [_]ui.Node{
                        buttonNode(46, tr(lang, "Confirm external launch (not a sandbox)", "确认启动外部程序（非沙箱）"), idle and !owner.externalBusy(), "primary"),
                        buttonNode(47, tr(lang, "Cancel launch review", "取消启动审核"), idle and !owner.externalBusy(), "standard"),
                    };
                    c_items[c_len] = self.stackNode("settings.client.review-actions", true, 8, &c_btns);
                    c_len += 1;
                    page_items[page_len] = self.groupNode("settings.client.review-card", tr(lang, "External Launch Review", "外部程序启动审核"), c_items[0..c_len]);
                    page_len += 1;
                }

                if (owner.index_review) |*review| {
                    const plan = &review.plan;
                    const i_btns = [_]ui.Node{
                        buttonNode(56, tr(lang, "Confirm this Git index update", "确认这一次 Git 索引写入"), idle, "primary"),
                        buttonNode(57, tr(lang, "Cancel index review", "取消索引审核"), idle, "standard"),
                    };
                    const i_items = [_]ui.Node{
                        textNode("settings.git-index.action", if (plan.scope.action == .stage) tr(lang, "Stage one file to the local Git index", "暂存单个文件到本地 Git 索引") else tr(lang, "Restore one staged file to the reviewed HEAD entry", "将单个暂存项恢复到已审核的 HEAD 条目"), null),
                        textNode("settings.git-index.root", plan.scope.root.slice(), "caption"),
                        textNode("settings.git-index.target", plan.scope.path.slice(), null),
                        textNode("settings.git-index.tool", plan.scope.tool.slice(), "caption"),
                        textNode("settings.git-index.head", &plan.evidence.head, "caption"),
                        self.stackNode("settings.git-index.actions", true, 8, &i_btns),
                    };
                    page_items[page_len] = self.groupNode("settings.git-index.card", tr(lang, "Git Index Review", "Git 索引写入审核"), &i_items);
                    page_len += 1;
                }

                if (owner.grant_review) |*review| {
                    var g_items: [14]ui.Node = undefined;
                    var g_len: usize = 0;
                    g_items[g_len] = textNode("settings.grants.heading", tr(lang, "Reviewed approval scope (no execution; keep this same row selected to revoke)", "已检查授权范围（不执行；撤销前请保持选中同一项目）"), "caption");
                    g_len += 1;
                    g_items[g_len] = textNode("settings.grants.root", review.root.slice(), null);
                    g_len += 1;
                    const ids_grant = [_][]const u8{ "settings.grants.git", "settings.grants.jj", "settings.grants.svn", "settings.grants.hg" };
                    const ids_path = [_][]const u8{ "settings.grants.git.path", "settings.grants.jj.path", "settings.grants.svn.path", "settings.grants.hg.path" };
                    const en = [_][]const u8{ "Revoke Git approval", "Revoke Jujutsu approval", "Revoke SVN approval", "Revoke Mercurial approval" };
                    const zh = [_][]const u8{ "撤销 Git 授权", "撤销 Jujutsu 授权", "撤销 SVN 授权", "撤销 Mercurial 授权" };
                    for (review.hints, grant_kinds, 0..) |hint, kind, i| {
                        const label = switch (hint.state) {
                            .not_checked => tr(lang, "Not checked", "未检查"),
                            .absent => tr(lang, "No record observed", "未发现记录"),
                            .recorded => tr(lang, "Recorded; not revalidated", "存在记录；尚未验证"),
                            .unavailable => tr(lang, "Unavailable", "无法读取"),
                        };
                        const status_node = textNode(ids_grant[i], std.fmt.bufPrint(&self.grant_labels[i], "{s}: {s}", .{ kind.displayName(), label }) catch "", null);
                        const revoke_btn = buttonNode(if (i == 3) 53 else 27 + i, tr(lang, en[i], zh[i]), idle and review.version == owner.stored.version and hint.state == .recorded, "danger");
                        const row_nodes = [_]ui.Node{ status_node, revoke_btn };
                        g_items[g_len] = self.stackNode("settings.grants.row", true, 8, &row_nodes);
                        g_len += 1;
                        if (hint.executable) |*path| {
                            g_items[g_len] = textNode(ids_path[i], path.slice(), "caption");
                            g_len += 1;
                        }
                    }
                    page_items[page_len] = self.groupNode("settings.grants.card", tr(lang, "Saved Approvals", "持久授权记录"), g_items[0..g_len]);
                    page_len += 1;
                }

                // Project Bookmark Add/Edit Form card.
                var form_items: [6]ui.Node = undefined;
                var form_len: usize = 0;
                const edit_text = if (owner.edit_key) |key| blk: {
                    const display = if (owner.stored.find(&key)) |idx| owner.stored.projects[idx].displayName() else &key;
                    break :blk std.fmt.bufPrint(&self.edit_label, "{s}: {s}", .{ tr(lang, "Editing", "正在编辑"), display }) catch "";
                } else tr(lang, "New project", "新建项目");
                form_items[form_len] = textNode("settings.project.edit-mode", edit_text, "caption");
                form_len += 1;

                const row1 = [_]ui.Node{
                    inputNode(root_key, tr(lang, "Project root (absolute path)", "项目根目录（绝对路径）"), idle),
                    inputNode(name_key, tr(lang, "Project name (optional)", "项目名称（可选）"), idle),
                };
                form_items[form_len] = self.gridNode("settings.project.form-row1", 2, 8, &row1);
                form_len += 1;

                const row2 = [_]ui.Node{
                    inputNode(tags_key, tr(lang, "Tags (optional)", "标签（可选）"), idle),
                    inputNode(url_key, tr(lang, "Remote repository (optional: GitHub / GitLab / Bitbucket)", "远程仓库地址（可选：GitHub / GitLab / Bitbucket）"), idle),
                };
                form_items[form_len] = self.gridNode("settings.project.form-row2", 2, 8, &row2);
                form_len += 1;

                const kind_text = std.fmt.bufPrint(&self.kind_label, "{s}: {s}", .{
                    tr(lang, "Provider hint", "类型提示"),
                    if (owner.form_kind) |k| k.displayName() else tr(lang, "Auto / Unknown", "自动 / 未知"),
                }) catch "";
                var form_btns: [5]ui.Node = undefined;
                var fb_len: usize = 0;
                if (owner.edit_key != null) {
                    form_btns[fb_len] = buttonNode(17, tr(lang, "Update / relink", "更新 / 重新关联"), idle, "primary");
                } else {
                    form_btns[fb_len] = buttonNode(8, tr(lang, "Add project", "添加项目"), idle, "primary");
                }
                fb_len += 1;
                if (owner.picker != null) {
                    form_btns[fb_len] = buttonNode(23, tr(lang, "Browse folder", "浏览目录"), idle, "standard");
                    fb_len += 1;
                }
                form_btns[fb_len] = buttonNode(7, tr(lang, "Fill current repo", "填入当前仓库"), idle, "standard");
                fb_len += 1;
                form_btns[fb_len] = buttonNode(62, kind_text, idle, "standard");
                fb_len += 1;
                form_btns[fb_len] = buttonNode(15, tr(lang, "Clear form", "清空表单"), idle, "transparent");
                fb_len += 1;
                form_items[form_len] = self.stackNode("settings.project.form-actions", true, 8, form_btns[0..fb_len]);
                form_len += 1;

                page_items[page_len] = self.groupNode("settings.project.form-card", tr(lang, "Add or Edit Bookmark", "添加 / 编辑项目"), form_items[0..form_len]);
                page_len += 1;
            },
            .tools => {
                var tool_rows: [6]ui.Node = undefined;
                var tr_len: usize = 0;
                tool_rows[tr_len] = textNode("settings.tools", tr(lang, "Saving a path is only a suggestion and never authorizes execution.", "保存路径仅作候选提示，不等于授予执行权限。"), "caption");
                tr_len += 1;
                for (fields, names, 0..) |field, name, i| {
                    var btns: [2]ui.Node = undefined;
                    var blen: usize = 0;
                    btns[blen] = buttonNode(if (i == 3) 51 else 1 + i, tr(lang, "Save path (empty = auto)", "保存路径（留空自动检测）"), idle, "primary");
                    blen += 1;
                    if (owner.picker != null) {
                        btns[blen] = buttonNode(if (i == 3) 52 else 4 + i, tr(lang, "Browse folder", "浏览所在目录"), idle, "standard");
                        blen += 1;
                    }
                    const entry = [_]ui.Node{
                        inputNode(field, name, idle),
                        self.stackNode("settings.tool.actions", true, 8, btns[0..blen]),
                    };
                    tool_rows[tr_len] = self.stackNode("settings.tool.row", false, 4, &entry);
                    tr_len += 1;
                }
                page_items[page_len] = self.groupNode("settings.tools.card", tr(lang, "VCS Executables", "版本控制工具路径"), tool_rows[0..tr_len]);
                page_len += 1;

                var client_rows: [5]ui.Node = undefined;
                var cr_len: usize = 0;
                client_rows[cr_len] = textNode("settings.client.heading", tr(lang, "Saving a client path does not launch it or grant VCS access.", "保存客户端路径不会启动程序或授予 VCS 权限。"), "caption");
                cr_len += 1;
                client_rows[cr_len] = textNode("settings.client.unsupported", tr(lang, "GitHub Desktop direct launch is not yet verified; use its documented github command manually. Sourcetree / GitKraken adapters unavailable.", "GitHub Desktop 直接启动尚未验证，可手动使用官方 github 命令；Sourcetree / GitKraken 适配暂不可用。"), "caption");
                cr_len += 1;
                for (clients, client_fields, 0..) |client, field, i| {
                    var btns: [2]ui.Node = undefined;
                    var blen: usize = 0;
                    btns[blen] = buttonNode(42 + i, tr(lang, "Save executable (empty clears)", "保存可执行文件（留空清除）"), idle, "primary");
                    blen += 1;
                    if (owner.picker != null) {
                        btns[blen] = buttonNode(63 + i, tr(lang, "Browse folder", "浏览所在目录"), idle, "standard");
                        blen += 1;
                    }
                    const entry = [_]ui.Node{
                        inputNode(field, client.name(), idle),
                        self.stackNode("settings.client.actions", true, 8, btns[0..blen]),
                    };
                    client_rows[cr_len] = self.stackNode("settings.client.row", false, 4, &entry);
                    cr_len += 1;
                }
                page_items[page_len] = self.groupNode("settings.client.card", tr(lang, "External Clients", "外部客户端路径"), client_rows[0..cr_len]);
                page_len += 1;
            },
            .general => {
                const locale_btns = [_]ui.Node{
                    buttonNode(12, tr(lang, "System language (Auto)", "跟随系统 (Auto)"), idle and owner.stored.locale != .auto, if (owner.stored.locale == .auto) "primary" else "standard"),
                    buttonNode(13, "English", idle and owner.stored.locale != .en, if (owner.stored.locale == .en) "primary" else "standard"),
                    buttonNode(14, "简体中文", idle and owner.stored.locale != .zh, if (owner.stored.locale == .zh) "primary" else "standard"),
                };
                const gen_items = [_]ui.Node{
                    textNode("settings.locale", tr(lang, "Choose interface language for both the VCS panel and this settings page.", "选择 VCS 面板与设置页的显示语言。"), "caption"),
                    self.gridNode("settings.locale.grid", 3, 8, &locale_btns),
                };
                page_items[page_len] = self.groupNode("settings.locale.card", tr(lang, "Language / 语言", "语言 / Language"), &gen_items);
                page_len += 1;
            },
        }

        for (commands, 0..) |command, i| self.vocabulary[i] = abi.view(command);
        self.root = ui.node(ui.NodeKind.stack);
        self.root.id = abi.view("vcs.settings.root");
        self.root.gap = .{ .present = 1, .value = 12 };
        self.root.min_width = .{ .present = 1, .value = 320 };
        self.root.max_width = .{ .present = 1, .value = 1120 };
        ui.withChildren(&self.root, self.allocNodes(page_items[0..page_len]));
        tree.* = std.mem.zeroes(ui.Tree);
        tree.size = @sizeOf(ui.Tree);
        tree.root = &self.root;
        tree.commands = &self.vocabulary;
        tree.command_count = self.vocabulary.len;
        tree.states = &self.states;
        tree.state_count = self.states.len;
    }
};

pub const Settings = struct {
    host: host_mod.Host,
    user: *anyopaque,
    current: *const fn (*anyopaque) ?Current,
    updated: *const fn (*anyopaque, Tools, vcs_panel.Language) void,
    folder_opened: ?*const fn (*anyopaque) void = null,
    grant_access: ?GrantAccess = null,
    grant_review: ?GrantReview = null,
    grant_job: ?GrantJob = null,
    grant_revoke_pending: bool = false,
    pages: ?raw.PulseSettingsPagesV1 = null,
    resources: ?raw.PulseResourcesV1 = null,
    panel: ?ui.Panel = null,
    page: u64 = 0,
    section: Section = .projects,
    active: bool = false,
    loaded: bool = false,
    poisoned: bool = false,
    pending: u64 = 0,
    operation: u32 = 0,
    stored: Stored = .{},
    // Decode into a second owned buffer. Never partially publish a corrupt
    // host reply or retain a borrowed resource string.
    scratch: Stored = .{},
    status: Status = .initial,
    render_ok: bool = false,
    sync_mask: u8 = 0,
    picker: ?pickers.Table = null,
    picker_request: u64 = 0,
    picker_index: usize = 0,
    wake: ?async_host.Wake = null,
    browser: ?async_host.Task = null,
    external_job: ?ExternalJob = null,
    external_discard: bool = false,
    remote_review: ?RemoteReview = null,
    metadata_review: ?MetadataReview = null,
    local_summary: ?LocalSummary = null,
    client_review: ?ClientReview = null,
    index_review: ?IndexReview = null,
    index_review_result: ?git_index.Plan = null,
    index_result: ?IndexResult = null,
    remote_result: ?forge.Remotes = null,
    metadata_result: ?forge.Metadata = null,
    project_task: ?async_host.Task = null,
    checked_project: ?Project = null,
    checked_version: u64 = 0,
    project_discard: bool = false,
    observe_project: *const fn ([]const u8) ?evidence.FileIdentity = &observeProject,
    route: project_route.Route = .{},
    route_key: ?[key_len]u8 = null,
    route_folder: bool = false,
    route_version: u64 = 0,
    recency_write: bool = false,
    search: contract.Text = .{},
    project_page: usize = 0,
    edit_key: ?[key_len]u8 = null,
    edit_version: u64 = 0,
    form_kind: ?identity.Kind = null,
    form_root: identity.Path = .{},

    const initial: Settings = .{
        .host = undefined,
        .user = undefined,
        .current = undefined,
        .updated = undefined,
    };

    /// The project library and its decode scratch space belong to the
    /// persistent settings owner. Initialize them without a stack copy.
    pub fn initInPlace(self: *Settings, host: host_mod.Host, user: *anyopaque, current: *const fn (*anyopaque) ?Current, updated: *const fn (*anyopaque, Tools, vcs_panel.Language) void) void {
        @memcpy(std.mem.asBytes(self), std.mem.asBytes(&initial));
        self.host = host;
        self.user = user;
        self.current = current;
        self.updated = updated;
    }

    const Visible = struct {
        indices: [page_size]usize = undefined,
        count: usize = 0,
        total: usize = 0,
    };

    fn externalBusy(self: *const Settings) bool {
        return if (self.browser) |*task| task.occupied() else false;
    }

    fn checkingProject(self: *const Settings) bool {
        return if (self.project_task) |*task| task.occupied() else false;
    }

    fn visible(self: *const Settings) Visible {
        var ordered: [max_projects]usize = undefined;
        var count: usize = 0;
        for (self.stored.projects[0..self.stored.count], 0..) |*project, index| {
            if (!project.matches(self.search.slice())) continue;
            var pos = count;
            while (pos > 0) {
                const previous = &self.stored.projects[ordered[pos - 1]];
                if (previous.favorite and !project.favorite) break;
                if (previous.favorite == project.favorite and previous.opened_order >= project.opened_order) break;
                ordered[pos] = ordered[pos - 1];
                pos -= 1;
            }
            ordered[pos] = index;
            count += 1;
        }
        var result: Visible = .{ .total = count };
        const start = @min(self.project_page * page_size, count);
        const end = @min(start + page_size, count);
        result.count = end - start;
        @memcpy(result.indices[0..result.count], ordered[start..end]);
        return result;
    }

    fn clampPage(self: *Settings) void {
        const total = self.visible().total;
        const last = if (total == 0) 0 else (total - 1) / page_size;
        self.project_page = @min(self.project_page, last);
    }

    fn onWake(user: ?*anyopaque) void {
        const self: *Settings = @ptrCast(@alignCast(user));
        if (self.wake) |*wake| wake.reap();
        if (!self.active or self.poisoned) return;
        if (self.checkingProject()) {
            self.pollProject() catch |err| diag.status("vcs-project-identity-wake", @intFromError(err));
        }
        if (self.externalBusy()) {
            const was_busy = self.externalBusy();
            self.pollBrowser() catch |err| diag.status("vcs-settings-browser-wake", @intFromError(err));
            if (was_busy and !self.externalBusy()) self.render();
        }
    }

    pub fn open(self: *Settings) host_mod.Error!void {
        if (self.active) return;
        if (self.poisoned) return error.State;
        // A previous deactivate can have removed the page while a browser
        // worker or callback is still retained. Never overwrite that owner.
        if (self.page != 0 or self.pending != 0 or self.picker_request != 0 or self.browser != null or self.project_task != null or self.wake != null or self.route.busy()) try self.close();
        // Each synchronous host call owns its own frame, even during reentry.
        const content = std.heap.page_allocator.create(Content) catch return error.Initialization;
        defer std.heap.page_allocator.destroy(content);
        const pages = (try self.host.queryOptional(raw.PulseSettingsPagesV1, raw.PULSE_SETTINGS_PAGES_INTERFACE_NAME, raw.PULSE_SETTINGS_PAGES_VERSION_1)) orelse return;
        const resources = (try self.host.queryOptional(raw.PulseResourcesV1, raw.PULSE_RESOURCES_INTERFACE_NAME, raw.PULSE_RESOURCES_VERSION_1)) orelse return;
        const create = pages.create orelse return error.Unavailable;
        const query = pages.query orelse return error.Unavailable;
        if (pages.remove == null or resources.settings_get == null or resources.settings_set == null or resources.cancel_request == null) return error.Unavailable;
        self.pages = pages;
        self.resources = resources;
        self.route.configure(self.host);
        if (self.host.queryOptional(pickers.Table, pickers.name, pickers.version)) |optional| {
            if (optional) |picker| {
                if (picker.pick_folders != null and picker.cancel != null) self.picker = picker;
            }
        } else |_| {}
        if (comptime builtin.os.tag == .windows) {
            if (async_host.taskTable(self.host)) |table| {
                self.browser = async_host.Task.init(table) catch null;
                self.project_task = async_host.Task.init(table) catch null;
            } else |_| {}
        }
        if (async_host.Dispatch.init(self.host)) |dispatch| {
            self.wake = async_host.Wake.init(dispatch, &onWake, self) catch null;
        } else |_| {}
        var tree: ui.Tree = undefined;
        content.build(self, &tree);
        var page: u64 = 0;
        try host_mod.mapStatus(create(pages.context, abi.view("VCS / 设置与项目"), &tree, &page));
        if (page == 0) {
            self.poisoned = true;
            return error.State;
        }
        self.page = page;
        errdefer self.close() catch |err| diag.status("vcs-settings-cleanup", @intFromError(err));
        var model = std.mem.zeroes(ui.TableV1);
        try host_mod.mapStatus(query(pages.context, page, abi.view(ui.interface_name), ui.version_1, &model, @sizeOf(ui.TableV1)));
        if (model.size < @sizeOf(ui.TableV1) or model.version < ui.version_1) return error.Abi;
        if (model.update == null or model.subscribe_command == null or model.get_state == null or model.set_states == null) return error.Unavailable;
        self.panel = .{ .table = model, .id = page };
        for (commands) |command| _ = try self.panel.?.subscribeCommand(command, onCommand, self);
        self.active = true;
        self.reload();
    }

    fn render(self: *Settings) void {
        if (!self.active) return;
        const model = if (self.panel) |*value| value else return;
        self.render_ok = false;
        const content = std.heap.page_allocator.create(Content) catch {
            self.status = .render_failed;
            diag.event("vcs-settings-render-allocation-failed");
            return;
        };
        defer std.heap.page_allocator.destroy(content);
        var tree: ui.Tree = undefined;
        content.build(self, &tree);
        model.update(&tree) catch |err| {
            self.status = .render_failed;
            diag.status("vcs-settings-render", @intFromError(err));
            return;
        };
        self.render_ok = true;
    }

    // Only replace the saved field, or all fields on explicit reload.
    // Saving one tool or changing locale must not discard other draft edits.
    fn syncTools(self: *Settings, mask: u8) void {
        if (!self.render_ok) return;
        const model = if (self.panel) |*value| value else return;
        var states: [7]ui.State = undefined;
        var count: usize = 0;
        for (fields, 0..) |field, i| {
            if (mask & toolMask(i) == 0) continue;
            states[count] = .{ .key = abi.view(field), .value = abi.view(if (self.stored.tools[i]) |*path| path.slice() else "") };
            count += 1;
        }
        for (client_fields, 0..) |field, i| {
            if (mask & (@as(u8, 16) << @as(u3, @intCast(i))) == 0) continue;
            states[count] = .{ .key = abi.view(field), .value = abi.view(if (self.stored.client_paths[i]) |*path| path.slice() else "") };
            count += 1;
        }
        // Selection state belongs to the visible project table only.
        if (mask & 8 != 0 and self.visible().count != 0) {
            states[count] = .{ .key = abi.view(selection_key), .value = abi.view("") };
            count += 1;
        }
        if (count == 0) return;
        model.setStates(states[0..count]) catch |err| {
            self.loaded = false;
            self.status = .sync_failed;
            diag.status("vcs-settings-sync", @intFromError(err));
        };
    }

    fn completed(user: ?*anyopaque, reply: [*c]const raw.PulseResourcesReply) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(user orelse return));
        if (reply == null or reply.*.size < @sizeOf(raw.PulseResourcesReply) or self.pending == 0 or reply.*.request_id != self.pending) return;
        const operation = self.operation;
        const mask = self.sync_mask;
        const recency = self.recency_write;
        self.recency_write = false;
        self.sync_mask = 0;
        self.pending = 0;
        self.operation = 0;
        self.loaded = false;
        self.grant_review = null;
        self.remote_review = null;
        self.metadata_review = null;
        self.local_summary = null;
        self.client_review = null;
        self.index_review = null;
        if (!self.active) return;
        if (reply.*.status != abi.ok or reply.*.operation != operation) {
            self.status = .conflict;
            self.render();
            return;
        }
        if (Stored.decode(reply.*.settings, &self.scratch)) |_| {
            @memcpy(std.mem.asBytes(&self.stored), std.mem.asBytes(&self.scratch));
            self.clampPage();
            self.loaded = true;
            // An edit draft is bound to the version from which it was loaded.
            // Do not silently rebase it over a concurrent change.
            if (mask & 8 != 0) self.edit_key = null;
            self.status = if (operation == raw.PULSE_RESOURCES_SETTINGS_GET) .loaded else if (recency) .route_dispatched else .saved;
            self.updated(self.user, self.stored.tools, self.stored.locale.language());
            self.render();
            self.syncTools(mask);
            if (!self.loaded) self.render();
        } else |_| {
            self.status = .invalid;
            self.render();
        }
    }

    fn admitted(self: *Settings, status: abi.Status, id: u64, operation: u32) void {
        if (status == abi.ok and id != 0) {
            self.pending = id;
            self.operation = operation;
            self.status = .pending;
        } else {
            self.loaded = false;
            if (status == abi.ok) self.poisoned = true;
            self.status = .rejected;
        }
        self.render();
    }

    fn reload(self: *Settings) void {
        if (!self.active or self.pending != 0 or self.picker_request != 0 or self.poisoned or self.route.busy() or self.checkingProject() or self.externalBusy()) return;
        const resources = self.resources orelse return;
        const get = resources.settings_get orelse return;
        var id: u64 = 0;
        self.grant_review = null;
        self.sync_mask = 127;
        const status = get(resources.context, completed, self, &id);
        self.admitted(status, id, raw.PULSE_RESOURCES_SETTINGS_GET);
    }

    fn save(self: *Settings, key: []const u8, value: []const u8, remove: bool) void {
        if (!self.active or !self.loaded or self.pending != 0 or self.poisoned or value.len > max_value) return;
        const resources = self.resources orelse return;
        const set = resources.settings_set orelse return;
        var id: u64 = 0;
        self.grant_review = null;
        self.sync_mask = if (std.mem.startsWith(u8, key, project_prefix)) 8 else 0;
        for (keys, 0..) |tool_key, i| {
            if (std.mem.eql(u8, key, tool_key)) self.sync_mask = toolMask(i);
        }
        for (client_keys, 0..) |client_key, i| {
            if (std.mem.eql(u8, key, client_key)) self.sync_mask = @as(u8, 16) << @as(u3, @intCast(i));
        }
        const status = set(resources.context, abi.view(key), abi.view(value), @intFromBool(remove), self.stored.version, completed, self, &id);
        self.admitted(status, id, raw.PULSE_RESOURCES_SETTINGS_SET);
    }

    fn read(self: *const Settings, key: []const u8, bytes: []u8) ![]const u8 {
        const panel = self.panel orelse return error.State;
        const get = panel.table.get_state orelse return error.Unavailable;
        var needed: u32 = 0;
        try host_mod.mapStatus(get(panel.table.context, panel.id, abi.view(key), bytes.ptr, @intCast(bytes.len), &needed));
        if (needed >= bytes.len) return error.Argument;
        return bytes[0..needed];
    }

    fn saveTool(self: *Settings, index: usize) !void {
        var bytes: [max_value + 1]u8 = undefined;
        const value = try self.read(fields[index], &bytes);
        _ = try toolPath(index, value);
        self.save(keys[index], value, value.len == 0);
    }

    fn saveClient(self: *Settings, index: usize) !void {
        var bytes: [max_value + 1]u8 = undefined;
        const value = try self.read(client_fields[index], &bytes);
        _ = try forge.clientPath(clients[index], value);
        self.save(client_keys[index], value, value.len == 0);
    }

    fn fillForm(self: *Settings, root: []const u8, remote: []const u8, name: []const u8, tags: []const u8) !void {
        const model = if (self.panel) |*value| value else return error.State;
        const states = [_]ui.State{
            .{ .key = abi.view(root_key), .value = abi.view(root) },
            .{ .key = abi.view(url_key), .value = abi.view(remote) },
            .{ .key = abi.view(name_key), .value = abi.view(name) },
            .{ .key = abi.view(tags_key), .value = abi.view(tags) },
        };
        try model.setStates(&states);
    }

    fn newProject(self: *Settings) !void {
        try self.fillForm("", "", "", "");
        self.edit_key = null;
        self.form_kind = null;
        self.form_root = .{};
        self.status = .new_project;
    }

    fn fillCurrent(self: *Settings) !void {
        const current = self.current(self.user) orelse return error.State;
        try self.fillForm(current.root.slice(), current.remote.slice(), "", "");
        self.edit_key = null;
        self.form_kind = current.kind;
        self.form_root = current.root;
        self.status = .filled;
    }

    fn editProject(self: *Settings) !void {
        const project = (try self.selected()).*;
        try self.fillForm(project.root.slice(), project.remote.slice(), project.name.slice(), project.tags.slice());
        self.edit_key = project.key;
        self.edit_version = self.stored.version;
        self.form_kind = project.kind;
        self.form_root = project.root;
        self.status = .edit_loaded;
    }

    fn cycleKind(self: *Settings) void {
        self.form_kind = if (self.form_kind) |kind| switch (kind) {
            .git => .jj,
            .jj => .svn,
            .svn => .hg,
            else => null,
        } else .git;
    }

    fn saveProject(self: *Settings, update: bool) !void {
        var root: [max_value + 1]u8 = undefined;
        var url: [513]u8 = undefined;
        var name: [97]u8 = undefined;
        var tags: [161]u8 = undefined;
        var item = try Project.make(try self.read(root_key, &root), try self.read(url_key, &url));
        item.name = try Project.field(try self.read(name_key, &name), 96);
        item.tags = try Project.field(try self.read(tags_key, &tags), 160);
        // Preserve explicitly chosen or loaded provider hint across manual add & relink.
        item.kind = self.form_kind;
        if (update) {
            const key = self.edit_key orelse return error.State;
            if (self.edit_version != self.stored.version) return error.State;
            const index = self.stored.find(&key) orelse return error.State;
            if (self.stored.findRoot(item.root.slice())) |duplicate| {
                if (duplicate != index) return error.InvalidSettings;
            }
            const old = &self.stored.projects[index];
            item.key = old.key;
            item.favorite = old.favorite;
            item.opened_order = old.opened_order;
            item.remote_detected = old.remote_detected and old.root.eql(item.root.slice()) and old.remote.eql(item.remote.slice());
        } else {
            if (self.edit_key != null or self.stored.count == max_projects or self.stored.findRoot(item.root.slice()) != null) return error.InvalidSettings;
            item.key = try self.stored.newKey(item.root.slice());
        }
        // Validate full serialized budget before launching background identity check.
        var encoded_check: [max_value]u8 = undefined;
        _ = item.encode(&encoded_check) catch return error.InvalidSettings;
        if (update) {
            const index = self.stored.find(&item.key) orelse return error.State;
            // Editing metadata on a missing/moved existing root remains
            // possible; changing the root requires a fresh observation.
            if (self.stored.projects[index].root.eql(item.root.slice())) {
                try self.saveRecord(&item);
                return;
            }
        }
        try self.checkProject(&item);
    }

    fn inspectGrants(self: *Settings) !void {
        const item = try self.selected();
        try self.startGrant(.{ .review = .{ .key = item.key, .root = item.root, .version = self.stored.version } });
    }

    fn revokeGrant(self: *Settings, kind: identity.Kind) !void {
        const review = self.grant_review orelse return error.State;
        const item = try self.selected();
        const index = contract.Snapshot.previewIndex(kind) orelse return error.Argument;
        if (review.version != self.stored.version or !std.mem.eql(u8, &review.key, &item.key) or !review.root.eql(item.root.slice()) or review.hints[index].state != .recorded) return error.State;
        try self.startGrant(.{ .review = review, .revoke = kind });
        // Close this instance's matching local admission immediately. A failed
        // registry update is reported, not treated as a successful revocation.
        self.grant_access.?.invalidate(self.user, &review.root, kind);
    }

    fn startGrant(self: *Settings, job: GrantJob) !void {
        if (self.grant_access == null) return error.Unavailable;
        const task = if (self.project_task) |*value| value else return error.Unavailable;
        if (task.occupied()) return error.State;
        self.grant_review = null;
        self.grant_job = job;
        self.grant_revoke_pending = job.revoke != null;
        self.project_discard = false;
        errdefer if (!task.occupied()) {
            self.grant_job = null;
            self.grant_revoke_pending = false;
        };
        const descriptor: async_host.Descriptor = .{
            .size = async_host.descriptor_v1_size,
            .title = abi.view("Manage selected project saved approval"),
            .type = abi.view("vcs.projects.grants"),
            .work = &grantWork,
            .user = self,
        };
        try task.start(&descriptor);
        self.status = if (job.revoke != null) .grant_revoke_pending else .grants_pending;
    }

    fn grantWork(user: ?*anyopaque, work_context: [*c]const async_host.Context) callconv(.c) u32 {
        const self: *Settings = @ptrCast(@alignCast(user orelse return @backingInt(async_host.TaskState.failed)));
        defer if (self.wake) |*wake| wake.request();
        if (work_context == null) return @backingInt(async_host.TaskState.failed);
        const cancelled = work_context.*.cancelled orelse return @backingInt(async_host.TaskState.failed);
        if (cancelled(work_context.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
        const access = self.grant_access orelse return @backingInt(async_host.TaskState.failed);
        const job = if (self.grant_job) |*value| value else return @backingInt(async_host.TaskState.failed);
        if (job.revoke) |kind| {
            access.forget(self.user, &job.review.root, kind) catch return @backingInt(async_host.TaskState.failed);
        }
        // No filesystem lookup or CLI. Revoke is scope based, not a rollback.
        for (grant_kinds, 0..) |kind, i| {
            if (cancelled(work_context.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
            job.review.hints[i] = access.inspect(self.user, &job.review.root, kind);
        }
        return @backingInt(async_host.TaskState.completed);
    }

    fn checkProject(self: *Settings, item: *const Project) !void {
        const task = if (self.project_task) |*value| value else return error.Unavailable;
        if (task.occupied()) return error.State;
        self.checked_project = item.*;
        self.checked_version = self.stored.version;
        self.project_discard = false;
        errdefer if (!task.occupied()) {
            self.checked_project = null;
        };
        const descriptor: async_host.Descriptor = .{
            .size = async_host.descriptor_v1_size,
            .title = abi.view("Verify local project identity"),
            .type = abi.view("vcs.projects.identity"),
            .work = &projectWork,
            .user = self,
        };
        try task.start(&descriptor);
        self.status = .identity_pending;
    }

    fn projectWork(user: ?*anyopaque, work_context: [*c]const async_host.Context) callconv(.c) u32 {
        const self: *Settings = @ptrCast(@alignCast(user orelse return @backingInt(async_host.TaskState.failed)));
        defer if (self.wake) |*wake| wake.request();
        if (work_context == null) return @backingInt(async_host.TaskState.failed);
        const cancelled = work_context.*.cancelled orelse return @backingInt(async_host.TaskState.failed);
        if (cancelled(work_context.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
        const item = if (self.checked_project) |*value| value else return @backingInt(async_host.TaskState.failed);
        const observed = self.observe_project(item.root.slice()) orelse return @backingInt(async_host.TaskState.failed);
        // Stored and checked_project are immutable until this task releases.
        // No startup scan, no CLI, no follow-reparse exception.
        for (self.stored.projects[0..self.stored.count]) |*other| {
            if (cancelled(work_context.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
            if (std.mem.eql(u8, &item.key, &other.key)) continue;
            const existing = self.observe_project(other.root.slice()) orelse continue;
            if (observed.volume == existing.volume and observed.index == existing.index) return @backingInt(async_host.TaskState.failed);
        }
        return @backingInt(if (cancelled(work_context.*.context) != 0) async_host.TaskState.cancelled else async_host.TaskState.completed);
    }

    fn cancelProject(self: *Settings) !void {
        const task = if (self.project_task) |*value| value else return error.State;
        if (!task.occupied() or self.grant_revoke_pending) return error.State;
        // Cancellation suppresses publication even if completion already raced
        // the UI event. Keep the worker's immutable input until release.
        self.project_discard = true;
        self.status = .identity_cancelled;
        try task.cancel();
    }

    fn pollProject(self: *Settings) !void {
        const task = if (self.project_task) |*value| value else return;
        if (!task.occupied()) return;
        const state = try task.poll();
        if (!state.terminal()) return;
        try task.releaseTerminal();
        if (self.grant_job) |job| {
            self.grant_job = null;
            self.grant_revoke_pending = false;
            const discard_grant = self.project_discard;
            self.project_discard = false;
            self.status = .grants_failed;
            if (!discard_grant and state == .completed and self.active and self.loaded and self.render_ok and self.pending == 0 and job.review.version == self.stored.version) {
                self.grant_review = job.review;
                self.status = if (job.revoke != null) .grant_revoked else .grants_ready;
            }
            self.render();
            return;
        }
        const item = self.checked_project;
        self.checked_project = null;
        const discard = self.project_discard;
        self.project_discard = false;
        self.status = if (discard or state == .cancelled) .identity_cancelled else .identity_failed;
        defer self.render();
        if (!discard and state == .completed and self.active and self.loaded and self.render_ok and self.pending == 0 and self.checked_version == self.stored.version) {
            if (item) |project| try self.saveRecord(&project);
        }
    }

    fn saveRecord(self: *Settings, item: *const Project) !void {
        var bytes: [max_value]u8 = undefined;
        self.save(&item.key, try item.encode(&bytes), false);
    }

    fn favorite(self: *Settings) !void {
        var item = (try self.selected()).*;
        item.favorite = !item.favorite;
        try self.saveRecord(&item);
    }

    fn selected(self: *const Settings) !*const Project {
        var key: [key_len + 1]u8 = undefined;
        const value = try self.read(selection_key, &key);
        const view = self.visible();
        for (view.indices[0..view.count]) |index| {
            const project = &self.stored.projects[index];
            if (std.mem.eql(u8, value, &project.key)) return project;
        }
        return error.State;
    }

    fn clearSelection(self: *Settings) !void {
        self.grant_review = null;
        self.local_summary = null;
        self.metadata_review = null;
        self.remote_review = null;
        self.client_review = null;
        self.index_review = null;
        self.render();
        if (!self.render_ok or self.visible().count == 0) return;
        const model = if (self.panel) |*value| value else return error.State;
        const states = [_]ui.State{.{ .key = abi.view(selection_key), .value = abi.view("") }};
        model.setStates(&states) catch |err| {
            self.render_ok = false;
            self.loaded = false;
            return err;
        };
    }

    fn applySearch(self: *Settings) !void {
        var bytes: [257]u8 = undefined;
        self.search = try Project.field(try self.read(search_key, &bytes), 256);
        self.project_page = 0;
        self.status = .search_applied;
        try self.clearSelection();
    }

    fn clearSearch(self: *Settings) !void {
        self.search = .{};
        self.project_page = 0;
        self.status = .search_applied;
        if (self.panel) |*model| {
            const states = [_]ui.State{.{ .key = abi.view(search_key), .value = abi.view("") }};
            model.setStates(&states) catch {};
        }
        try self.clearSelection();
    }

    fn pageBy(self: *Settings, forward: bool) !void {
        if (forward) {
            if ((self.project_page + 1) * page_size >= self.visible().total) return error.State;
            self.project_page += 1;
        } else {
            if (self.project_page == 0) return error.State;
            self.project_page -= 1;
        }
        try self.clearSelection();
    }

    // An explicit, freshly validated menu selection prepares the project
    // form and requests the same public navigation as a saved bookmark.
    pub fn openFolder(self: *Settings, path: []const u8) !void {
        if (!self.active or !self.loaded or !self.render_ok or self.pending != 0 or self.picker_request != 0 or self.poisoned or self.route.busy() or self.checkingProject() or self.externalBusy()) return error.State;
        if (!approval.strictPath(path)) return error.Argument;
        const root = try identity.Path.init(path);
        if (self.stored.findRoot(path)) |index| {
            const project = &self.stored.projects[index];
            if (!sameRoot(project.root.slice(), path)) return error.Argument;
            try self.fillForm(project.root.slice(), project.remote.slice(), project.name.slice(), project.tags.slice());
            self.edit_key = project.key;
            self.edit_version = self.stored.version;
            self.form_kind = project.kind;
            self.route_key = project.key;
        } else {
            try self.fillForm(path, "", "", "");
            self.edit_key = null;
            self.form_kind = null;
            self.route_key = null;
        }
        self.form_root = root;
        self.route_version = self.stored.version;
        self.status = .folder_filled;
        self.route_folder = true;
        self.route.begin(path, self, &routeDone) catch {
            self.route_folder = false;
            self.route_key = null;
            self.status = .route_failed;
            self.render();
            return;
        };
        self.status = .route_pending;
        self.render();
    }

    fn jump(self: *Settings) !void {
        const project = (try self.selected()).*;
        self.route_folder = false;
        self.route_key = project.key;
        self.route_version = self.stored.version;
        errdefer self.route_key = null;
        try self.route.begin(project.root.slice(), self, &routeDone);
        self.status = .route_pending;
    }

    fn routeDone(user: *anyopaque, accepted: bool) void {
        const self: *Settings = @ptrCast(@alignCast(user));
        const key = self.route_key;
        const folder = self.route_folder;
        self.route_key = null;
        self.route_folder = false;
        if (!self.active) return;
        self.status = if (accepted) .route_dispatched else .route_failed;
        // Store recency only for the same current record/version, after the
        // host accepted navigation. A concurrent change cannot be overwritten.
        if (accepted and self.loaded and self.pending == 0 and self.route_version == self.stored.version and self.stored.version < (1 << 53) - 1) {
            if (key) |id| {
                if (self.stored.find(&id)) |index| {
                    var item = self.stored.projects[index];
                    item.opened_order = self.stored.version + 1;
                    self.recency_write = true;
                    self.saveRecord(&item) catch |err| diag.status("vcs-project-recency", @intFromError(err));
                    if (self.pending == 0) self.recency_write = false;
                }
            }
        }
        self.render();
        if (accepted and folder) {
            if (self.folder_opened) |notify| notify(self.user);
        }
    }

    fn pickerCompleted(user: ?*anyopaque, result: [*c]const pickers.Result) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(user orelse return));
        if (result == null or result.*.size < @sizeOf(pickers.Result) or self.picker_request == 0 or result.*.request_id != self.picker_request) return;
        self.picker_request = 0;
        if (!self.active) return;
        self.status = .picker_cancel;
        if (result.*.outcome == pickers.accepted and result.*.path_count == 1 and result.*.paths != null) blk: {
            const path = abi.slice(result.*.paths[0]) orelse break :blk;
            var bytes: [max_value]u8 = undefined;
            const candidate = if (self.picker_index == tools.len) root: {
                if (!approval.strictPath(path) or path.len > max_value) break :blk;
                break :root path;
            } else if (self.picker_index > tools.len) client: {
                const client_index = self.picker_index - tools.len - 1;
                if (client_index >= clients.len) break :blk;
                const value = std.fmt.bufPrint(&bytes, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ std.mem.trimEnd(u8, path, "\\/"), clients[client_index].executable() }) catch break :blk;
                _ = forge.clientPath(clients[client_index], value) catch break :blk;
                break :client value;
            } else tool: {
                const value = std.fmt.bufPrint(&bytes, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ std.mem.trimEnd(u8, path, "\\/"), tools[self.picker_index].exeName() }) catch break :blk;
                _ = toolPath(self.picker_index, value) catch break :blk;
                break :tool value;
            };
            const model = if (self.panel) |*value| value else break :blk;
            const field = if (self.picker_index == tools.len) root_key else if (self.picker_index > tools.len) client_fields[self.picker_index - tools.len - 1] else fields[self.picker_index];
            const states = [_]ui.State{.{ .key = abi.view(field), .value = abi.view(candidate) }};
            model.setStates(&states) catch break :blk;
            self.status = .picker_candidate;
        }
        self.render();
    }

    fn browse(self: *Settings, index: usize) !void {
        const picker = self.picker orelse return error.Unavailable;
        const pick = picker.pick_folders orelse return error.Unavailable;
        self.picker_index = index;
        var id: u64 = 0;
        const lang = self.stored.locale.language();
        const request: pickers.Request = .{ .title = abi.view(if (index == tools.len) tr(lang, "Select project directory", "选择项目目录") else tr(lang, "Select the folder containing the executable", "选择工具可执行文件所在文件夹")), .ok_label = abi.view(tr(lang, "Select", "选择")) };
        try host_mod.mapStatus(pick(picker.context, &request, pickerCompleted, self, &id));
        if (id == 0) {
            self.poisoned = true;
            return error.State;
        }
        self.picker_request = id;
        self.status = .picking;
    }

    fn browserWork(user: ?*anyopaque, context: [*c]const async_host.Context) callconv(.c) u32 {
        const self: *Settings = @ptrCast(@alignCast(user orelse return @backingInt(async_host.TaskState.failed)));
        defer if (self.wake) |*wake| wake.request();
        if (context == null) return @backingInt(async_host.TaskState.failed);
        const cancelled = context.*.cancelled orelse return @backingInt(async_host.TaskState.failed);
        if (cancelled(context.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
        const job = self.external_job orelse return @backingInt(async_host.TaskState.failed);
        switch (job) {
            .website => |value| openWebsite(value.scope.remote.slice(), value.page) catch return @backingInt(async_host.TaskState.failed),
            .discover => |scope| self.remote_result = forge.inspectRemotes(scope.root.slice()) catch return @backingInt(async_host.TaskState.failed),
            .metadata => |scope| self.metadata_result = forge.fetchMetadata(scope.remote.slice(), cancelled, context.*.context),
            .client => |review| forge.launchClient(review.client, review.executable.slice(), review.scope.root.slice(), review.scope.kind) catch return @backingInt(async_host.TaskState.failed),
            .index_review => |request| {
                const allocator = std.heap.page_allocator;
                var io = std.Io.Threaded.init(allocator, .{});
                defer io.deinit();
                self.index_review_result = git_index.observePlan(io.io(), request.request) catch |err| {
                    diag.status("vcs-git-index-review", @intFromError(err));
                    return @backingInt(async_host.TaskState.failed);
                };
            },
            .index_apply => |request| {
                const allocator = std.heap.page_allocator;
                var io = std.Io.Threaded.init(allocator, .{});
                defer io.deinit();
                git_index.applyPlan(allocator, io.io(), &request.plan, .{ .check = cancelled, .context = context.*.context }) catch |err| {
                    self.index_result = switch (err) {
                        error.IndexAppliedCleanupFailed => .cleanup_failed,
                        error.Cancelled => .cancelled,
                        else => .not_applied,
                    };
                    diag.status("vcs-git-index-apply", @intFromError(err));
                    return @backingInt(if (err == error.Cancelled) async_host.TaskState.cancelled else async_host.TaskState.failed);
                };
                self.index_result = .applied;
                diag.event("vcs-git-index-applied");
            },
        }
        return @backingInt(async_host.TaskState.completed);
    }

    fn startExternal(self: *Settings, job: ExternalJob) !void {
        const task = if (self.browser) |*value| value else return error.Unavailable;
        if (task.occupied()) return error.State;
        self.external_job = job;
        self.external_discard = false;
        self.remote_result = null;
        self.metadata_result = null;
        self.index_review_result = null;
        self.index_result = null;
        const descriptor: async_host.Descriptor = .{
            .size = async_host.descriptor_v1_size,
            .title = abi.view("Explicit project integration"),
            .type = abi.view("vcs.projects.integration"),
            .work = &browserWork,
            .user = self,
        };
        errdefer if (!task.occupied()) {
            self.external_job = null;
        };
        try task.start(&descriptor);
        self.status = .browser_pending;
    }

    fn openSelected(self: *Settings, page: forge.Page) !void {
        const project = try self.selected();
        _ = forge.pageUrl(project.remote.slice(), page) orelse return error.Argument;
        try self.startExternal(.{ .website = .{ .scope = Scope.from(project, self.stored.version), .page = page } });
    }

    fn discoverRemotes(self: *Settings) !void {
        const scope = Scope.from(try self.selected(), self.stored.version);
        self.remote_review = null;
        try self.startExternal(.{ .discover = scope });
    }

    fn saveDetected(self: *Settings, index: usize) !void {
        if (self.externalBusy()) return error.State;
        const review = if (self.remote_review) |*value| value else return error.State;
        var project = (try self.selected()).*;
        if (!review.scope.matches(&project, self.stored.version) or index >= review.value.count) return error.State;
        project.remote = review.value.rows[index].url;
        project.remote_detected = true;
        try self.saveRecord(&project);
    }

    fn copyLocalSummary(self: *Settings) !void {
        const scope = Scope.from(try self.selected(), self.stored.version);
        self.local_summary = null;
        const current = self.current(self.user) orelse {
            self.status = .local_summary_unavailable;
            return;
        };
        if (!scope.root.eql(current.root.slice()) or (scope.kind != null and scope.kind != current.kind) or current.availability != .ready) {
            self.status = .local_summary_unavailable;
            return;
        }
        self.local_summary = .{ .scope = scope, .value = current };
        self.status = .local_summary_ready;
    }

    fn fetchPublic(self: *Settings) !void {
        const scope = Scope.from(try self.selected(), self.stored.version);
        var endpoint: [contract.Text.capacity + 16]u8 = undefined;
        _ = forge.githubPath(scope.remote.slice(), &endpoint) orelse return error.Argument;
        self.metadata_review = null;
        try self.startExternal(.{ .metadata = scope });
    }

    fn reviewClient(self: *Settings, index: usize) !void {
        if (self.externalBusy()) return error.State;
        const scope = Scope.from(try self.selected(), self.stored.version);
        const executable = self.stored.client_paths[index] orelse return error.Argument;
        var command: [2 * identity.max_path_bytes + 128]u8 = undefined;
        _ = try forge.commandLine(clients[index], executable.slice(), scope.root.slice(), scope.kind, &command);
        self.client_review = .{ .scope = scope, .client = clients[index], .executable = executable };
        self.status = .client_review;
    }

    fn confirmClient(self: *Settings) !void {
        const review = self.client_review orelse return error.State;
        if (!review.scope.matches(try self.selected(), self.stored.version)) return error.State;
        const index: usize = if (review.client == .vscode) 0 else 1;
        const path = self.stored.client_paths[index] orelse return error.State;
        if (!path.eql(review.executable.slice())) return error.State;
        self.client_review = null;
        try self.startExternal(.{ .client = review });
    }

    fn indexScope(self: *Settings, project: *const Project, action: git_index.Action) !git_index.Plan.Scope {
        if (comptime builtin.os.tag != .windows) return error.Unavailable;
        if (project.kind) |kind| if (kind != .git) return error.Argument;
        var buffer: [identity.max_path_bytes + 1]u8 = undefined;
        const raw_path = try self.read(index_path_key, &buffer);
        var normalized: [identity.max_path_bytes]u8 = undefined;
        if (raw_path.len > normalized.len) return error.Argument;
        for (raw_path, 0..) |byte, i| normalized[i] = if (byte == '\\') '/' else byte;
        const path = normalized[0..raw_path.len];
        if (!contract.safeRelativePath(path)) return error.Argument;
        return .{
            .root = project.root,
            .tool = self.stored.tools[0] orelse return error.Argument,
            .path = try identity.Path.init(path),
            .action = action,
            .generation = self.stored.version,
        };
    }

    fn reviewIndex(self: *Settings, action: git_index.Action) !void {
        self.index_review = null;
        const project = try self.selected();
        const scope = Scope.from(project, self.stored.version);
        try self.startExternal(.{ .index_review = .{ .scope = scope, .request = try self.indexScope(project, action) } });
        self.status = .index_preparing;
    }

    fn confirmIndex(self: *Settings) !void {
        const review = self.index_review orelse return error.State;
        self.index_review = null;
        const project = try self.selected();
        if (!review.scope.matches(project, self.stored.version)) return error.State;
        const current = try self.indexScope(project, review.plan.scope.action);
        var pending: ?git_index.Plan = review.plan;
        const approved = try git_index.Plan.consume(&pending, &current);
        try self.startExternal(.{ .index_apply = .{ .scope = review.scope, .plan = approved } });
        self.status = .index_applying;
    }

    fn cancelExternal(self: *Settings) !void {
        const task = if (self.browser) |*value| value else return error.Unavailable;
        if (!task.occupied() or self.external_discard) return error.State;
        self.external_discard = true;
        self.status = .external_cancel_pending;
        try task.cancel();
    }

    fn pollBrowser(self: *Settings) !void {
        const task = if (self.browser) |*value| value else return;
        if (!task.occupied()) return;
        const state = try task.poll();
        if (!state.terminal()) return;
        try task.releaseTerminal();
        const job = self.external_job orelse return error.State;
        defer {
            self.external_job = null;
            self.external_discard = false;
            self.remote_result = null;
            self.metadata_result = null;
            self.index_review_result = null;
            self.index_result = null;
        }
        if (job == .index_apply) {
            self.status = switch (self.index_result orelse if (state == .cancelled) IndexResult.cancelled else .not_applied) {
                .applied => .index_applied,
                .cleanup_failed => .index_cleanup_failed,
                .not_applied => .index_not_applied,
                .cancelled => .index_cancelled,
            };
            return;
        }
        if (self.external_discard or state == .cancelled) {
            self.status = .external_cancelled;
            return;
        }
        const project = self.selected() catch {
            self.status = .external_changed;
            return;
        };
        if (!job.scope().matches(project, self.stored.version)) {
            self.status = .external_changed;
            return;
        }
        switch (job) {
            .website => self.status = if (state == .completed) .browser_opened else .browser_failed,
            .client => self.status = if (state == .completed) .client_launched else .client_failed,
            .discover => {
                if (state == .completed) {
                    if (self.remote_result) |result| {
                        self.remote_review = .{ .scope = job.discover, .value = result };
                        self.status = .remotes_ready;
                        return;
                    }
                }
                self.status = .remotes_failed;
            },
            .metadata => {
                if (state == .completed) {
                    if (self.metadata_result) |result| {
                        self.metadata_review = .{ .scope = job.metadata, .value = result };
                        self.status = .metadata_ready;
                        return;
                    }
                }
                self.status = .browser_failed;
            },
            .index_review => {
                if (state == .completed) {
                    if (self.index_review_result) |result| {
                        self.index_review = .{ .scope = job.index_review.scope, .plan = result };
                        self.status = .index_review_ready;
                        return;
                    }
                }
                self.status = .index_not_applied;
            },
            .index_apply => unreachable,
        }
    }

    fn onCommand(user: ?*anyopaque, page: u64, command: abi.StringView) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(user orelse return));
        if (!self.active or page == 0 or page != self.page or self.poisoned) return;
        const name = abi.slice(command) orelse return;
        // Tab switches are pure UI state transitions and stay responsive anytime.
        if (std.mem.eql(u8, name, commands[58])) {
            self.section = .projects;
            self.render();
            return;
        }
        if (std.mem.eql(u8, name, commands[59])) {
            self.section = .tools;
            self.render();
            return;
        }
        if (std.mem.eql(u8, name, commands[60])) {
            self.section = .general;
            self.render();
            return;
        }
        if (std.mem.eql(u8, name, commands[11])) {
            if (self.checkingProject()) {
                self.pollProject() catch |err| diag.status("vcs-project-identity-poll", @intFromError(err));
            } else {
                self.pollBrowser() catch |err| diag.status("vcs-settings-browser-poll", @intFromError(err));
                self.render();
            }
            return;
        }
        if (std.mem.eql(u8, name, commands[48])) {
            self.cancelExternal() catch |err| diag.status("vcs-integration-cancel", @intFromError(err));
            self.render();
            return;
        }
        if (std.mem.eql(u8, name, commands[25])) {
            self.cancelProject() catch |err| diag.status("vcs-project-identity-cancel", @intFromError(err));
            self.render();
            return;
        }
        if (self.checkingProject()) return;
        const was_external = self.externalBusy();
        self.pollBrowser() catch |err| diag.status("vcs-settings-browser-poll", @intFromError(err));
        if (std.mem.eql(u8, name, commands[0])) {
            if (was_external and !self.externalBusy()) {
                self.render();
                return;
            }
            self.reload();
            return;
        }
        if (std.mem.eql(u8, name, commands[24])) {
            self.route.stop() catch |err| {
                self.status = .route_failed;
                diag.status("vcs-project-route-cancel", @intFromError(err));
                self.render();
                return;
            };
            self.route_key = null;
            self.route_folder = false;
            self.status = .route_cancelled;
            self.render();
            return;
        }
        if (!self.loaded or !self.render_ok or self.pending != 0 or self.picker_request != 0 or self.route.busy() or self.externalBusy()) return;
        for (commands[1..], 1..) |key, index| {
            if (!std.mem.eql(u8, name, key)) continue;
            const result: anyerror!void = switch (index) {
                1...3 => self.saveTool(index - 1),
                4...6 => self.browse(index - 4),
                7 => self.fillCurrent(),
                8 => self.saveProject(false),
                9 => blk: {
                    const project = self.selected() catch |err| break :blk err;
                    self.save(&project.key, "", true);
                    break :blk {};
                },
                10 => self.openSelected(.repository),
                12...14 => self.save(locale_key, @tagName(([_]Locale{ .auto, .en, .zh })[index - 12]), false),
                15 => self.newProject(),
                16 => self.editProject(),
                17 => self.saveProject(true),
                18 => self.favorite(),
                19 => self.applySearch(),
                20 => self.pageBy(false),
                21 => self.pageBy(true),
                22 => self.jump(),
                23 => self.browse(tools.len),
                26 => self.inspectGrants(),
                27...29 => self.revokeGrant(grant_kinds[index - 27]),
                30...33 => self.openSelected(forge.pages[index - 29]),
                34 => self.discoverRemotes(),
                35...40 => self.saveDetected(index - 35),
                41 => self.fetchPublic(),
                42...43 => self.saveClient(index - 42),
                44...45 => self.reviewClient(index - 44),
                46 => self.confirmClient(),
                47 => {
                    self.client_review = null;
                },
                49 => self.copyLocalSummary(),
                50 => {
                    self.local_summary = null;
                },
                51 => self.saveTool(3),
                52 => self.browse(3),
                53 => self.revokeGrant(.hg),
                54 => self.reviewIndex(.stage),
                55 => self.reviewIndex(.unstage),
                56 => self.confirmIndex(),
                57 => {
                    self.index_review = null;
                    self.status = .index_cancelled;
                },
                61 => self.clearSearch(),
                62 => {
                    self.cycleKind();
                },
                63...64 => self.browse(tools.len + 1 + (index - 63)),
                else => return,
            };
            result catch |err| {
                self.status = .command_failed;
                diag.status("vcs-settings-command", @intFromError(err));
            };
            self.render();
            return;
        }
    }

    pub fn close(self: *Settings) host_mod.Error!void {
        self.active = false;
        self.render_ok = false;
        self.loaded = false;
        if (self.wake) |*wake| wake.disable();
        if (self.poisoned) return error.State;
        try self.route.stop();
        self.route_key = null;
        self.route_folder = false;
        if (self.picker_request != 0) {
            const picker = self.picker orelse return error.State;
            const cancel = picker.cancel orelse return error.Unavailable;
            host_mod.mapStatus(cancel(picker.context, self.picker_request)) catch |err| if (err != error.State) return err;
            self.picker_request = 0;
        }
        if (self.pending != 0) {
            const resources = self.resources orelse return error.State;
            const cancel = resources.cancel_request orelse return error.Unavailable;
            host_mod.mapStatus(cancel(resources.context, self.pending)) catch |err| if (err != error.State) return err;
            self.pending = 0;
            self.operation = 0;
            self.recency_write = false;
        }
        if (self.page != 0) {
            const pages = self.pages orelse return error.State;
            const remove = pages.remove orelse return error.Unavailable;
            host_mod.mapStatus(remove(pages.context, self.page)) catch |err| if (err != error.State) return err;
            self.page = 0;
            self.panel = null;
        }
        var pending_err: ?host_mod.Error = null;
        if (self.browser) |*task| {
            if (task.occupied()) {
                if (task.poll()) |state| {
                    if (!state.terminal()) {
                        task.cancel() catch |err| {
                            if (pending_err == null) pending_err = err;
                        };
                        if (pending_err == null) pending_err = error.State;
                    } else {
                        task.releaseTerminal() catch |err| {
                            if (pending_err == null) pending_err = err;
                        };
                    }
                } else |err| {
                    if (pending_err == null) pending_err = err;
                }
            }
        }
        if (self.project_task) |*task| {
            if (task.occupied()) {
                if (task.poll()) |state| {
                    if (!state.terminal()) {
                        task.cancel() catch |err| {
                            if (pending_err == null) pending_err = err;
                        };
                        if (pending_err == null) pending_err = error.State;
                    } else {
                        task.releaseTerminal() catch |err| {
                            if (pending_err == null) pending_err = err;
                        };
                    }
                } else |err| {
                    if (pending_err == null) pending_err = err;
                }
            }
        }
        if (pending_err) |err| return err;
        self.browser = null;
        self.external_job = null;
        self.external_discard = false;
        self.remote_result = null;
        self.metadata_result = null;
        self.remote_review = null;
        self.metadata_review = null;
        self.local_summary = null;
        self.client_review = null;
        self.index_review = null;
        self.project_task = null;
        self.checked_project = null;
        self.grant_job = null;
        self.grant_review = null;
        self.grant_revoke_pending = false;
        if (self.wake) |*wake| {
            try wake.drain();
            self.wake = null;
        }
        self.pages = null;
        self.resources = null;
        self.picker = null;
        self.route.table = null;
    }

    pub fn retireAtHostDestroy(self: *Settings) void {
        // Host stop suppresses resource/picker/UI callbacks and joins tasks.
        self.active = false;
        self.render_ok = false;
        self.loaded = false;
        if (self.wake) |*wake| {
            wake.retireAtHostDestroy() catch {};
            self.wake = null;
        }
        self.route.retire();
        if (self.browser) |*task| task.retireAtHostDestroy();
        self.browser = null;
        self.external_job = null;
        self.external_discard = false;
        self.remote_result = null;
        self.metadata_result = null;
        self.remote_review = null;
        self.metadata_review = null;
        self.local_summary = null;
        self.client_review = null;
        self.index_review = null;
        if (self.project_task) |*task| task.retireAtHostDestroy();
        self.project_task = null;
        self.checked_project = null;
        self.grant_job = null;
        self.grant_review = null;
        self.grant_revoke_pending = false;
        self.panel = null;
        self.page = 0;
        self.pending = 0;
        self.picker_request = 0;
    }
};

fn observeProject(path: []const u8) ?evidence.FileIdentity {
    return evidence.observeIdentity(path, true) catch null;
}

extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?*anyopaque, u32) callconv(.winapi) usize;
extern "kernel32" fn GetProcAddress(usize, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(usize) callconv(.winapi) c_int;
const ShellOpen = *const fn (?*anyopaque, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, c_int) callconv(.winapi) usize;
const ComInit = *const fn (?*anyopaque, u32) callconv(.winapi) i32;
const ComUninit = *const fn () callconv(.winapi) void;

fn openWebsite(value: []const u8, page: forge.Page) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const url = forge.pageUrl(value, page) orelse return error.InvalidSettings;
    // Only our canonical ASCII HTTPS forge URLs reach ShellExecuteW.
    var wide: [contract.Text.capacity + 1]u16 = undefined;
    for (url.slice(), 0..) |c, i| wide[i] = c;
    wide[url.slice().len] = 0;
    const ole = LoadLibraryExW(std.unicode.wtf8ToWtf16LeStringLiteral("ole32.dll"), null, 0x800);
    if (ole == 0) return error.BrowserUnavailable;
    defer _ = FreeLibrary(ole);
    const initialize: ComInit = @ptrCast(GetProcAddress(ole, "CoInitializeEx") orelse return error.BrowserUnavailable);
    const uninitialize: ComUninit = @ptrCast(GetProcAddress(ole, "CoUninitialize") orelse return error.BrowserUnavailable);
    if (initialize(null, 2) < 0) return error.BrowserUnavailable;
    defer uninitialize();
    const shell = LoadLibraryExW(std.unicode.wtf8ToWtf16LeStringLiteral("shell32.dll"), null, 0x800);
    if (shell == 0) return error.BrowserUnavailable;
    defer _ = FreeLibrary(shell);
    const open: ShellOpen = @ptrCast(GetProcAddress(shell, "ShellExecuteW") orelse return error.BrowserUnavailable);
    if (open(null, std.unicode.wtf8ToWtf16LeStringLiteral("open"), @ptrCast(&wide), null, null, 1) <= 32) return error.BrowserUnavailable;
}

test "project records are bounded, exact-keyed, and not grants" {
    const root = if (builtin.os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    const item = try Project.make(root, "git@github.com:owner/repo.git");
    var bytes: [max_value]u8 = undefined;
    const value = try item.encode(&bytes);
    const parsed = try Project.decode(&item.key, value);
    try std.testing.expect(parsed.root.eql(root));
    try std.testing.expect(parsed.remote.eql("https://github.com/owner/repo"));
    try std.testing.expectError(error.InvalidSettings, Project.decode("project.bad", value));
    try std.testing.expectError(error.InvalidSettings, Project.make(root, "https://token@github.com/a/b"));
    var stored: Stored = .{};
    const pairs = [_]raw.PulseSetting{ .{ .key = abi.view(&item.key), .value = abi.view(value) }, .{ .key = abi.view(&item.key), .value = abi.view(value) } };
    try Stored.decode(.{ .version = 2, .values = &pairs, .count = 1 }, &stored);
    try std.testing.expectEqual(@as(usize, 1), stored.count);
    try std.testing.expectError(error.InvalidSettings, Stored.decode(.{ .values = &pairs, .count = 2 }, &stored));
    try std.testing.expectError(error.InvalidSettings, Stored.decode(.{ .count = 1 }, &stored));
}

test "locale preferences validate and Chinese Windows language has English fallback" {
    try std.testing.expectEqual(Locale.zh, try Locale.parse("zh"));
    try std.testing.expectError(error.InvalidSettings, Locale.parse("invalid"));
    try std.testing.expectEqual(vcs_panel.Language.zh, languageForWindows(0x0804));
    try std.testing.expectEqual(vcs_panel.Language.en, languageForWindows(0x0409));
    const pairs = [_]raw.PulseSetting{.{ .key = abi.view(locale_key), .value = abi.view("en") }};
    var stored: Stored = .{};
    try Stored.decode(.{ .values = &pairs, .count = 1 }, &stored);
    try std.testing.expectEqual(Locale.en, stored.locale);
    const duplicates = [_]raw.PulseSetting{ pairs[0], pairs[0] };
    try std.testing.expectError(error.InvalidSettings, Stored.decode(.{ .values = &duplicates, .count = 2 }, &stored));
}

const SettingsFixture = struct {
    calls: usize = 0,
    last_version: u64 = 0,
    cancelled: usize = 0,
    last_key: [64]u8 = undefined,
    last_key_len: usize = 0,
    published: usize = 0,
    synced: usize = 0,
    sync_key: [64]u8 = undefined,
    sync_key_len: usize = 0,
    fail_update: bool = false,
    input: []const u8,
    index_input: []const u8 = "",

    task_state: async_host.TaskState = .running,
    task_descriptor: async_host.Descriptor = undefined,
    task_cancelled: bool = false,
    fail_task_release: bool = false,
    grant_revoked: ?identity.Kind = null,
    grant_invalidated: ?identity.Kind = null,

    fn inspectGrant(user: *anyopaque, _: *const identity.Path, kind: identity.Kind) contract.SavedHint {
        const self: *SettingsFixture = @ptrCast(@alignCast(user));
        if (self.grant_revoked == kind) return .{ .state = .absent };
        return .{ .state = .recorded };
    }

    fn forgetGrant(user: *anyopaque, _: *const identity.Path, kind: identity.Kind) host_mod.Error!void {
        const self: *SettingsFixture = @ptrCast(@alignCast(user));
        self.grant_revoked = kind;
    }

    fn invalidateGrant(user: *anyopaque, _: *const identity.Path, kind: identity.Kind) void {
        const self: *SettingsFixture = @ptrCast(@alignCast(user));
        self.grant_invalidated = kind;
    }

    fn taskCreate(user: ?*anyopaque, descriptor: [*c]const async_host.Descriptor, id: [*c]u64) callconv(.c) abi.Status {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.task_descriptor = descriptor.*;
        self.task_state = .running;
        self.task_cancelled = false;
        id.* = 71;
        return abi.ok;
    }

    fn taskGet(user: ?*anyopaque, id: u64, callback: ?*const fn (?*anyopaque, [*c]const async_host.Snapshot) callconv(.c) void, data: ?*anyopaque) callconv(.c) abi.Status {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        const snapshot: async_host.Snapshot = .{ .size = @sizeOf(async_host.Snapshot), .id = id, .state = @backingInt(self.task_state) };
        (callback orelse return abi.error_argument)(data, &snapshot);
        return abi.ok;
    }

    fn taskCancel(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.task_cancelled = true;
        return abi.ok;
    }

    fn taskRelease(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        return if (self.fail_task_release) abi.error_state else abi.ok;
    }

    fn taskCancelled(user: ?*anyopaque) callconv(.c) u32 {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return 1));
        return @intFromBool(self.task_cancelled);
    }

    fn taskTable(self: *SettingsFixture) async_host.TaskTable {
        return .{ .size = @sizeOf(async_host.TaskTable), .version = 1, .context = self, .create = &taskCreate, .get = &taskGet, .cancel = &taskCancel, .release = &taskRelease };
    }

    fn runProject(self: *SettingsFixture) void {
        const work_context: async_host.Context = .{ .id = 71, .context = self, .cancelled = &taskCancelled };
        self.task_state = @fromBackingInt(@intCast(self.task_descriptor.work.?(self.task_descriptor.user, &work_context)));
    }

    fn current(_: *anyopaque) ?Current {
        return null;
    }

    fn updated(user: *anyopaque, _: Tools, _: vcs_panel.Language) void {
        const self: *SettingsFixture = @ptrCast(@alignCast(user));
        self.published += 1;
    }

    fn get(_: ?*anyopaque, _: raw.PulseResourcesCompletionFn, _: ?*anyopaque, id: [*c]u64) callconv(.c) abi.Status {
        id.* = 4;
        return abi.ok;
    }

    fn set(user: ?*anyopaque, key: abi.StringView, _: abi.StringView, _: u32, version: u64, _: raw.PulseResourcesCompletionFn, _: ?*anyopaque, id: [*c]u64) callconv(.c) abi.Status {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        const name = abi.slice(key) orelse return abi.error_argument;
        if (name.len > self.last_key.len) return abi.error_argument;
        @memcpy(self.last_key[0..name.len], name);
        self.last_key_len = name.len;
        self.calls += 1;
        self.last_version = version;
        id.* = 5;
        return abi.ok;
    }

    fn cancel(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.cancelled += 1;
        return abi.ok;
    }

    fn update(user: ?*anyopaque, _: u64, tree: [*c]const ui.Tree) callconv(.c) abi.Status {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (tree == null or tree.*.command_count != commands.len or self.fail_update) return abi.error_state;
        return abi.ok;
    }

    fn getState(user: ?*anyopaque, _: u64, key: abi.StringView, bytes: [*c]u8, capacity: u32, needed: [*c]u32) callconv(.c) abi.Status {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        const input = if (std.mem.eql(u8, abi.slice(key) orelse "", index_path_key)) self.index_input else self.input;
        if (input.len >= capacity) return abi.error_argument;
        @memcpy(bytes[0..input.len], input);
        needed.* = @intCast(input.len);
        return abi.ok;
    }

    fn setStates(user: ?*anyopaque, _: u64, states: [*c]const ui.State, count: u32) callconv(.c) abi.Status {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (states == null or count == 0) return abi.error_argument;
        const key = abi.slice(states[0].key) orelse return abi.error_argument;
        if (key.len > self.sync_key.len) return abi.error_argument;
        @memcpy(self.sync_key[0..key.len], key);
        self.sync_key_len = key.len;
        self.synced += count;
        return abi.ok;
    }
};

test "settings writes use exact version and preserve drafts on conflict or unrelated save" {
    const tool = if (builtin.os.tag == .windows) "C:\\tools\\git.exe" else "/tools/git";
    var fixture: SettingsFixture = .{ .input = tool };
    const owner = try std.testing.allocator.create(Settings);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{
        .host = undefined,
        .user = &fixture,
        .current = &SettingsFixture.current,
        .updated = &SettingsFixture.updated,
        .active = true,
        .page = 7,
        .resources = .{ .context = &fixture, .settings_get = &SettingsFixture.get, .settings_set = &SettingsFixture.set, .cancel_request = &SettingsFixture.cancel },
        .panel = .{ .id = 7, .table = .{ .context = &fixture, .update = &SettingsFixture.update, .get_state = &SettingsFixture.getState, .set_states = &SettingsFixture.setStates } },
    };
    owner.reload();
    try std.testing.expectEqual(@as(u64, 4), owner.pending);
    const initial: raw.PulseResourcesReply = .{ .size = @sizeOf(raw.PulseResourcesReply), .operation = raw.PULSE_RESOURCES_SETTINGS_GET, .request_id = 4, .status = abi.ok, .settings = .{ .version = 9 } };
    Settings.completed(owner, &initial);
    try std.testing.expect(owner.loaded and owner.render_ok);
    try std.testing.expectEqual(@as(usize, 6), fixture.synced);
    Settings.onCommand(owner, 8, abi.view(commands[1]));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    Settings.onCommand(owner, 7, abi.view(commands[1]));
    try std.testing.expectEqual(@as(u64, 9), fixture.last_version);
    try std.testing.expectEqualStrings(keys[0], fixture.last_key[0..fixture.last_key_len]);
    Settings.onCommand(owner, 7, abi.view(commands[2]));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    const conflict: raw.PulseResourcesReply = .{ .size = @sizeOf(raw.PulseResourcesReply), .operation = raw.PULSE_RESOURCES_SETTINGS_SET, .request_id = 5, .status = abi.error_state };
    Settings.completed(owner, &conflict);
    try std.testing.expect(!owner.loaded);
    try std.testing.expectEqual(@as(usize, 1), fixture.published);
    Settings.onCommand(owner, 7, abi.view(commands[1]));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    owner.reload();
    Settings.completed(owner, &initial);
    Settings.onCommand(owner, 7, abi.view(commands[1]));
    const pair = [_]raw.PulseSetting{.{ .key = abi.view(keys[0]), .value = abi.view(tool) }};
    const saved: raw.PulseResourcesReply = .{ .size = @sizeOf(raw.PulseResourcesReply), .operation = raw.PULSE_RESOURCES_SETTINGS_SET, .request_id = 5, .status = abi.ok, .settings = .{ .version = 10, .values = &pair, .count = 1 } };
    const before = fixture.synced;
    Settings.completed(owner, &saved);
    try std.testing.expectEqual(before + 1, fixture.synced);
    try std.testing.expectEqualStrings(fields[0], fixture.sync_key[0..fixture.sync_key_len]);
    try std.testing.expect(owner.stored.tools[0].?.eql(tool));
    fixture.fail_update = true;
    owner.render();
    Settings.onCommand(owner, 7, abi.view(commands[1]));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
}

test "picker callback rejects stale request and only fills a matching candidate" {
    const folder = if (builtin.os.tag == .windows) "C:\\tools" else "/tools";
    const expected = if (builtin.os.tag == .windows) "C:\\tools\\jj.exe" else "/tools/jj";
    var fixture: SettingsFixture = .{ .input = expected };
    const owner = try std.testing.allocator.create(Settings);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{
        .host = undefined,
        .user = &fixture,
        .current = &SettingsFixture.current,
        .updated = &SettingsFixture.updated,
        .active = true,
        .page = 7,
        .picker_request = 22,
        .picker_index = 1,
        .panel = .{ .id = 7, .table = .{ .context = &fixture, .update = &SettingsFixture.update, .set_states = &SettingsFixture.setStates } },
    };
    const values = [_]abi.StringView{abi.view(folder)};
    var reply: pickers.Result = .{ .size = @sizeOf(pickers.Result), .outcome = pickers.accepted, .request_id = 21, .filter_index = 0, .path_count = 1, .paths = &values, .selected_id = .{}, .@"error" = .{} };
    Settings.pickerCompleted(owner, &reply);
    try std.testing.expectEqual(@as(u64, 22), owner.picker_request);
    try std.testing.expectEqual(@as(usize, 0), fixture.synced);
    reply.request_id = 22;
    Settings.pickerCompleted(owner, &reply);
    try std.testing.expectEqual(@as(u64, 0), owner.picker_request);
    try std.testing.expectEqualStrings(fields[1], fixture.sync_key[0..fixture.sync_key_len]);
    try std.testing.expectEqual(Status.picker_candidate, owner.status);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    owner.picker_request = 23;
    reply.request_id = 23;
    reply.outcome = pickers.cancelled;
    Settings.pickerCompleted(owner, &reply);
    try std.testing.expectEqual(Status.picker_cancel, owner.status);
    try std.testing.expectEqual(@as(usize, 1), fixture.synced);
}

test "legacy project migrates to a stable V2 record and relinks without implicit grant" {
    const root = if (builtin.os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    const moved = if (builtin.os.tag == .windows) "C:\\work\\moved" else "/work/moved";
    const original = try Project.make(root, "https://github.com/owner/repo");
    var legacy: [max_value]u8 = undefined;
    const value = try std.fmt.bufPrint(&legacy, "{s}\n{s}", .{ root, original.remote.slice() });
    var record = try Project.decode(&original.key, value);
    try std.testing.expect(record.root.eql(root));
    record.root = try identity.Path.init(moved);
    record.name = try Project.field("Example", 96);
    record.tags = try Project.field("zig, favorite", 160);
    record.favorite = true;
    record.kind = .jj;
    record.opened_order = 3;
    var buffer: [max_value]u8 = undefined;
    const encoded = try record.encode(&buffer);
    const parsed = try Project.decode(&original.key, encoded);
    try std.testing.expectEqual(original.key, parsed.key);
    try std.testing.expect(parsed.root.eql(moved));
    try std.testing.expect(parsed.matches("ZIG"));
    try std.testing.expect(parsed.favorite and parsed.kind == .jj);
    try std.testing.expectEqual(@as(u64, 3), parsed.opened_order);
    try std.testing.expectError(error.InvalidSettings, Project.field("bad\nfield", 96));
    var stored: Stored = .{ .version = 4 };
    stored.projects[0] = parsed;
    stored.count = 1;
    try std.testing.expect(stored.findRoot(moved) != null);
    try std.testing.expect(stored.findRoot(root) == null);
    const new_key = try stored.newKey(root);
    try std.testing.expect(!std.mem.eql(u8, &new_key, &original.key));
}

test "project view prioritizes favorites and recency and bounds page selection" {
    const owner = try std.testing.allocator.create(Settings);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{ .host = undefined, .user = undefined, .current = undefined, .updated = undefined };
    for (0..page_size + 1) |index| {
        var path: [96]u8 = undefined;
        const root = try std.fmt.bufPrint(&path, if (builtin.os.tag == .windows) "C:\\projects\\repo-{d}" else "/projects/repo-{d}", .{index});
        var item = try Project.make(root, "");
        item.opened_order = @intCast(index);
        item.favorite = index == 0;
        owner.stored.projects[index] = item;
        owner.stored.count += 1;
    }
    const first = owner.visible();
    try std.testing.expectEqual(@as(usize, page_size), first.count);
    try std.testing.expectEqual(@as(usize, 0), first.indices[0]);
    try std.testing.expectEqual(@as(usize, page_size), first.indices[1]);
    owner.project_page = 1;
    try std.testing.expectEqual(@as(usize, 1), owner.visible().count);
    owner.search = try Project.field("repo-0", 256);
    owner.clampPage();
    try std.testing.expectEqual(@as(usize, 0), owner.project_page);
    try std.testing.expectEqual(@as(usize, 1), owner.visible().count);
}

fn fixtureProjectIdentity(path: []const u8) ?evidence.FileIdentity {
    const leaf = std.fs.path.basename(path);
    if (std.mem.eql(u8, leaf, "missing")) return null;
    return .{ .volume = 1, .index = if (std.mem.eql(u8, leaf, "other")) 2 else 1 };
}

test "project identity validation rejects aliases and cancellation never publishes a raced result" {
    const root = if (builtin.os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    const alias = if (builtin.os.tag == .windows) "C:\\work\\alias" else "/work/alias";
    const other = if (builtin.os.tag == .windows) "C:\\work\\other" else "/work/other";
    const missing = if (builtin.os.tag == .windows) "C:\\work\\missing" else "/work/missing";
    var fixture: SettingsFixture = .{ .input = "" };
    const owner = try std.testing.allocator.create(Settings);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{
        .host = undefined,
        .user = &fixture,
        .current = &SettingsFixture.current,
        .updated = &SettingsFixture.updated,
        .active = true,
        .loaded = true,
        .render_ok = true,
        .page = 7,
        .resources = .{ .context = &fixture, .settings_set = &SettingsFixture.set },
        .panel = .{ .id = 7, .table = .{ .context = &fixture, .update = &SettingsFixture.update } },
        .project_task = try async_host.Task.init(fixture.taskTable()),
        .observe_project = &fixtureProjectIdentity,
    };
    owner.stored.version = 9;
    owner.stored.projects[0] = try Project.make(root, "");
    owner.stored.count = 1;

    try owner.checkProject(&(try Project.make(alias, "")));
    fixture.runProject();
    try std.testing.expectEqual(async_host.TaskState.failed, fixture.task_state);
    try owner.pollProject();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    try owner.checkProject(&(try Project.make(missing, "")));
    fixture.runProject();
    try owner.pollProject();
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    const item = try Project.make(other, "");
    try owner.checkProject(&item);
    fixture.runProject();
    try std.testing.expectEqual(async_host.TaskState.completed, fixture.task_state);
    try owner.cancelProject();
    fixture.fail_task_release = true;
    try std.testing.expectError(error.State, owner.pollProject());
    try std.testing.expect(owner.checkingProject() and owner.checked_project != null);
    fixture.fail_task_release = false;
    try owner.pollProject();
    try std.testing.expectEqual(Status.identity_cancelled, owner.status);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);

    try owner.checkProject(&item);
    fixture.runProject();
    try owner.pollProject();
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(u64, 9), fixture.last_version);
    try std.testing.expectEqualStrings(&item.key, fixture.last_key[0..fixture.last_key_len]);
    try std.testing.expect(!owner.checkingProject() and owner.checked_project == null);
}

test "project grant review supports missing roots and rejects a changed selection or version" {
    const root = if (builtin.os.tag == .windows) "C:\\missing\\repo" else "/missing/repo";
    const other = if (builtin.os.tag == .windows) "C:\\missing\\other" else "/missing/other";
    const item = try Project.make(root, "");
    const second = try Project.make(other, "");
    var fixture: SettingsFixture = .{ .input = &item.key };
    const owner = try std.testing.allocator.create(Settings);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{
        .host = undefined,
        .user = &fixture,
        .current = &SettingsFixture.current,
        .updated = &SettingsFixture.updated,
        .active = true,
        .loaded = true,
        .render_ok = true,
        .page = 7,
        .panel = .{ .id = 7, .table = .{ .context = &fixture, .update = &SettingsFixture.update, .get_state = &SettingsFixture.getState } },
        .project_task = try async_host.Task.init(fixture.taskTable()),
        .grant_access = .{ .inspect = &SettingsFixture.inspectGrant, .forget = &SettingsFixture.forgetGrant, .invalidate = &SettingsFixture.invalidateGrant },
    };
    owner.stored.version = 4;
    owner.stored.projects[0] = item;
    owner.stored.projects[1] = second;
    owner.stored.count = 2;
    try owner.inspectGrants();
    fixture.runProject();
    try owner.pollProject();
    try std.testing.expectEqual(Status.grants_ready, owner.status);
    try std.testing.expect(owner.grant_review.?.root.eql(root));
    fixture.input = &second.key;
    try std.testing.expectError(error.State, owner.revokeGrant(.git));
    fixture.input = &item.key;
    owner.stored.version = 5;
    try std.testing.expectError(error.State, owner.revokeGrant(.git));
    try owner.inspectGrants();
    fixture.runProject();
    try owner.pollProject();
    try owner.revokeGrant(.git);
    try std.testing.expectEqual(identity.Kind.git, fixture.grant_invalidated.?);
    try std.testing.expectError(error.State, owner.cancelProject());
    fixture.runProject();
    try owner.pollProject();
    try std.testing.expectEqual(Status.grant_revoked, owner.status);
    try std.testing.expectEqual(contract.SavedHint.State.absent, owner.grant_review.?.hints[0].state);
    try std.testing.expectEqual(contract.SavedHint.State.recorded, owner.grant_review.?.hints[1].state);
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
}

test "project remote provenance migrates old records and binds review to exact scope" {
    const root = if (builtin.os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    var item = try Project.make(root, "https://github.com/a/b");
    var bytes: [max_value]u8 = undefined;
    const old = try std.fmt.bufPrint(&bytes, "v2\n{s}\n{s}\n\n\n0\ngit\n0", .{ root, item.remote.slice() });
    try std.testing.expect(!(try Project.decode(&item.key, old)).remote_detected);
    item.remote_detected = true;
    const encoded = try item.encode(&bytes);
    try std.testing.expect((try Project.decode(&item.key, encoded)).remote_detected);
    const scope = Scope.from(&item, 7);
    try std.testing.expect(scope.matches(&item, 7));
    try std.testing.expect(!scope.matches(&item, 8));
    item.remote = try contract.Text.init("https://github.com/a/c");
    try std.testing.expect(!scope.matches(&item, 7));
}

test "external task release and cancellation suppress stale project results" {
    const root = if (builtin.os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    const other = if (builtin.os.tag == .windows) "C:\\work\\other" else "/work/other";
    const item = try Project.make(root, "https://github.com/a/b");
    const second = try Project.make(other, "https://github.com/a/c");
    var fixture: SettingsFixture = .{ .input = &item.key };
    const owner = try std.testing.allocator.create(Settings);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{
        .host = undefined,
        .user = &fixture,
        .current = &SettingsFixture.current,
        .updated = &SettingsFixture.updated,
        .active = true,
        .loaded = true,
        .render_ok = true,
        .page = 7,
        .panel = .{ .id = 7, .table = .{ .context = &fixture, .update = &SettingsFixture.update, .get_state = &SettingsFixture.getState } },
        .browser = try async_host.Task.init(fixture.taskTable()),
    };
    owner.stored.version = 4;
    owner.stored.projects[0] = item;
    owner.stored.projects[1] = second;
    owner.stored.count = 2;

    // Inject only the completed transport fixture, never a real HTTP request.
    try owner.fetchPublic();
    owner.metadata_result = .{ .status = .ready, .stars = 42 };
    fixture.task_state = .completed;
    fixture.fail_task_release = true;
    try std.testing.expectError(error.State, owner.pollBrowser());
    try std.testing.expect(owner.metadata_review == null and owner.externalBusy());
    fixture.fail_task_release = false;
    try owner.pollBrowser();
    try std.testing.expectEqual(@as(u64, 42), owner.metadata_review.?.value.stars);
    try std.testing.expect(!owner.externalBusy());

    try owner.fetchPublic();
    owner.metadata_result = .{ .status = .ready, .stars = 99 };
    fixture.task_state = .completed;
    fixture.input = &second.key;
    try owner.pollBrowser();
    try std.testing.expectEqual(Status.external_changed, owner.status);
    try std.testing.expect(owner.metadata_review == null);

    fixture.input = &item.key;
    try owner.fetchPublic();
    try owner.cancelExternal();
    owner.metadata_result = .{ .status = .ready, .stars = 100 };
    fixture.task_state = .completed;
    try owner.pollBrowser();
    try std.testing.expectEqual(Status.external_cancelled, owner.status);
    try std.testing.expect(owner.metadata_review == null and !owner.externalBusy());

    const exe = if (builtin.os.tag == .windows) "C:\\Programs\\Code.exe" else "/opt/Code.exe";
    owner.stored.client_paths[0] = (try forge.clientPath(.vscode, exe)).?;
    try owner.reviewClient(0);
    fixture.input = &second.key;
    try std.testing.expectError(error.State, owner.confirmClient());
    try std.testing.expect(!owner.externalBusy());
}

test "Git index review is consumed on target drift and keeps a published result after cancellation" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const project = try Project.make("C:\\work\\repo", "");
    var fixture: SettingsFixture = .{ .input = &project.key, .index_input = "selected.txt" };
    const owner = try std.testing.allocator.create(Settings);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{
        .host = undefined,
        .user = &fixture,
        .current = &SettingsFixture.current,
        .updated = &SettingsFixture.updated,
        .active = true,
        .loaded = true,
        .render_ok = true,
        .page = 7,
        .panel = .{ .id = 7, .table = .{ .context = &fixture, .update = &SettingsFixture.update, .get_state = &SettingsFixture.getState } },
        .browser = try async_host.Task.init(fixture.taskTable()),
    };
    owner.stored.projects[0] = project;
    owner.stored.count = 1;
    owner.stored.version = 4;
    owner.stored.tools[0] = try identity.Path.init("C:\\tools\\git.exe");
    const evidence_fixture = std.mem.zeroes(git_index.Plan.Evidence);
    try owner.reviewIndex(.stage);
    owner.index_review_result = .{ .scope = owner.external_job.?.index_review.request, .evidence = evidence_fixture };
    fixture.task_state = .completed;
    try owner.pollBrowser();
    try std.testing.expectEqual(Status.index_review_ready, owner.status);
    fixture.index_input = "different.txt";
    try std.testing.expectError(error.IndexReviewChanged, owner.confirmIndex());
    try std.testing.expect(!owner.externalBusy() and owner.index_review == null);

    fixture.index_input = "selected.txt";
    try owner.reviewIndex(.unstage);
    owner.index_review_result = .{ .scope = owner.external_job.?.index_review.request, .evidence = evidence_fixture };
    fixture.task_state = .completed;
    try owner.pollBrowser();
    try owner.confirmIndex();
    try std.testing.expect(owner.external_job.? == .index_apply and owner.index_review == null);
    try owner.cancelExternal();
    owner.index_result = .applied;
    fixture.task_state = .cancelled;
    try owner.pollBrowser();
    try std.testing.expectEqual(Status.index_applied, owner.status);
    try std.testing.expect(!owner.externalBusy());
}

test "local dashboard distinguishes absent counts and matches exact project root" {
    const root = if (builtin.os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    const other = if (builtin.os.tag == .windows) "C:\\work\\other" else "/work/other";
    const item = try Project.make(root, "https://github.com/a/b");
    const second = try Project.make(other, "");
    const Fixture = struct {
        fn current(_: *anyopaque) ?Current {
            return .{ .root = identity.Path.init(root) catch unreachable, .kind = .git, .availability = .ready, .changes = .{ .modified = 3 }, .counts = .{ .modified = .ready } };
        }
    };
    var fixture: SettingsFixture = .{ .input = &item.key };
    const owner = try std.testing.allocator.create(Settings);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{
        .host = undefined,
        .user = &fixture,
        .current = &Fixture.current,
        .updated = &SettingsFixture.updated,
        .active = true,
        .loaded = true,
        .render_ok = true,
        .page = 7,
        .panel = .{ .id = 7, .table = .{ .context = &fixture, .get_state = &SettingsFixture.getState } },
    };
    owner.stored.version = 1;
    owner.stored.projects[0] = item;
    owner.stored.projects[1] = second;
    owner.stored.count = 2;
    try owner.copyLocalSummary();
    try std.testing.expectEqual(Status.local_summary_ready, owner.status);
    try std.testing.expectEqual(@as(u32, 3), owner.local_summary.?.value.changes.modified);
    var bytes: [16]u8 = undefined;
    try std.testing.expectEqualStrings("?", countLabel(&bytes, 0, .not_queried));
    try std.testing.expectEqualStrings("0", countLabel(&bytes, 0, .ready));
    fixture.input = &second.key;
    try owner.copyLocalSummary();
    try std.testing.expectEqual(Status.local_summary_unavailable, owner.status);
    try std.testing.expect(owner.local_summary == null);
}

test "settings tabs, search reset, provider kind cycling, and grant_review reset" {
    const root = if (builtin.os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    const item = try Project.make(root, "");
    var fixture: SettingsFixture = .{ .input = &item.key };
    const owner = try std.testing.allocator.create(Settings);
    defer std.testing.allocator.destroy(owner);
    owner.* = .{
        .host = undefined,
        .user = &fixture,
        .current = &SettingsFixture.current,
        .updated = &SettingsFixture.updated,
        .active = true,
        .loaded = true,
        .render_ok = true,
        .page = 7,
        .panel = .{ .id = 7, .table = .{ .context = &fixture, .update = &SettingsFixture.update, .get_state = &SettingsFixture.getState, .set_states = &SettingsFixture.setStates } },
    };
    owner.stored.projects[0] = item;
    owner.stored.count = 1;
    owner.stored.version = 1;
    owner.grant_review = .{ .key = item.key, .root = item.root, .version = 1 };
    owner.search = try contract.Text.init("repo");

    Settings.onCommand(owner, 7, abi.view("vcs.settings.tab-tools"));
    try std.testing.expectEqual(Section.tools, owner.section);
    Settings.onCommand(owner, 7, abi.view("vcs.settings.tab-general"));
    try std.testing.expectEqual(Section.general, owner.section);
    Settings.onCommand(owner, 7, abi.view("vcs.settings.tab-projects"));
    try std.testing.expectEqual(Section.projects, owner.section);

    try owner.clearSearch();
    try std.testing.expectEqual(@as(usize, 0), owner.search.len);

    owner.cycleKind();
    try std.testing.expectEqual(@as(?identity.Kind, .git), owner.form_kind);
    owner.cycleKind();
    try std.testing.expectEqual(@as(?identity.Kind, .jj), owner.form_kind);
    owner.cycleKind();
    try std.testing.expectEqual(@as(?identity.Kind, .svn), owner.form_kind);
    owner.cycleKind();
    try std.testing.expectEqual(@as(?identity.Kind, .hg), owner.form_kind);
    owner.cycleKind();
    try std.testing.expect(owner.form_kind == null);

    try owner.clearSelection();
    try std.testing.expect(owner.grant_review == null);
    try std.testing.expect(owner.index_review == null);
}
