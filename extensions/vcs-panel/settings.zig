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

const max_projects = 64;
const page_size = 12;
const max_value = 1024;
const keys = [_][]const u8{ "tool.git", "tool.jj", "tool.svn" };
const names = [_][]const u8{ "Git", "Jujutsu", "Subversion" };
const tools = [_]cli.Tool{ .git, .jj, .svn };
const fields = [_][]const u8{ "settings.git", "settings.jj", "settings.svn" };
const commands = [_][]const u8{ "vcs.settings.reload", "vcs.settings.save-git", "vcs.settings.save-jj", "vcs.settings.save-svn", "vcs.settings.browse-git", "vcs.settings.browse-jj", "vcs.settings.browse-svn", "vcs.projects.current", "vcs.projects.save", "vcs.projects.remove", "vcs.projects.website", "vcs.projects.check", "vcs.settings.locale-auto", "vcs.settings.locale-en", "vcs.settings.locale-zh", "vcs.projects.new", "vcs.projects.edit", "vcs.projects.update", "vcs.projects.favorite", "vcs.projects.search", "vcs.projects.prev", "vcs.projects.next", "vcs.projects.jump", "vcs.projects.browse", "vcs.projects.cancel-jump", "vcs.projects.cancel-identity", "vcs.projects.inspect-grants", "vcs.projects.revoke-git", "vcs.projects.revoke-jj", "vcs.projects.revoke-svn", "vcs.forge.issues", "vcs.forge.reviews", "vcs.forge.ci", "vcs.forge.releases", "vcs.forge.discover", "vcs.forge.remote.0", "vcs.forge.remote.1", "vcs.forge.remote.2", "vcs.forge.remote.3", "vcs.forge.remote.4", "vcs.forge.remote.5", "vcs.forge.metadata", "vcs.client.save-code", "vcs.client.save-svn", "vcs.client.review-code", "vcs.client.review-svn", "vcs.client.confirm", "vcs.client.cancel" };
const clients = [_]forge.Client{ .vscode, .tortoise_svn };
const client_keys = [_][]const u8{ "client.vscode", "client.tortoise_svn" };
const client_fields = [_][]const u8{ "settings.client.vscode", "settings.client.tortoise_svn" };
const root_key = "settings.project.root";
const url_key = "settings.project.url";
const selection_key = "settings.project.selected";
const name_key = "settings.project.name";
const tags_key = "settings.project.tags";
const search_key = "settings.project.search";
const project_prefix = "project.";
const key_len = project_prefix.len + 32;

pub const Tools = [3]?identity.Path;
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
        };
    }
};
pub const Current = struct { root: identity.Path, remote: contract.Text = .{}, kind: ?identity.Kind = null };

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
        for ([_]identity.Kind{ .git, .jj, .svn }) |kind| {
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

fn toolPath(index: usize, value: []const u8) !?identity.Path {
    if (index >= tools.len or value.len > max_value) return error.InvalidSettings;
    if (value.len == 0) return null;
    if (!approval.strictPath(value) or !std.ascii.eqlIgnoreCase(std.fs.path.basename(value), tools[index].exeName())) return error.InvalidSettings;
    return identity.Path.init(value) catch error.InvalidSettings;
}

const Stored = struct {
    version: u64 = 0,
    locale: Locale = .auto,
    tools: Tools = .{ null, null, null },
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
        out.* = .{ .version = value.version };
        var seen: [3]bool = @splat(false);
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
    hints: [3]contract.SavedHint = @splat(.{}),
};

const GrantJob = struct {
    review: GrantReview,
    revoke: ?identity.Kind = null,
};

const grant_kinds = [_]identity.Kind{ .git, .jj, .svn };

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
const ExternalJob = union(enum) {
    website: struct { scope: Scope, page: forge.Page },
    discover: Scope,
    metadata: Scope,
    client: ClientReview,

    fn scope(self: *const ExternalJob) *const Scope {
        return switch (self.*) {
            .website => |*job| &job.scope,
            .discover => |*job| job,
            .metadata => |*job| job,
            .client => |*job| &job.scope,
        };
    }
};
const RemoteReview = struct { scope: Scope, value: forge.Remotes };
const MetadataReview = struct { scope: Scope, value: forge.Metadata };

const Content = struct {
    nodes: [112]ui.Node = undefined,
    len: usize = 0,
    root: ui.Node = undefined,
    states: [11]ui.State = undefined,
    vocabulary: [commands.len]abi.StringView = undefined,
    rows: [page_size]raw.PulseUiModelRow = undefined,
    cells: [page_size][7]abi.StringView = undefined,
    columns: [7]raw.PulseUiModelColumn = undefined,
    recency_labels: [page_size][32]u8 = undefined,
    page_label: [96]u8 = undefined,
    edit_label: [128]u8 = undefined,
    grant_labels: [3][96]u8 = undefined,
    remote_labels: [forge.Remotes.capacity][384]u8 = undefined,
    meta_label: [256]u8 = undefined,

    fn add(self: *Content, node: ui.Node, id: []const u8) void {
        std.debug.assert(self.len < self.nodes.len);
        self.nodes[self.len] = node;
        self.nodes[self.len].id = abi.view(id);
        self.len += 1;
    }

    fn button(self: *Content, index: usize, text: []const u8, enabled: bool) void {
        var node = ui.button(text, commands[index]);
        node.enabled = .{ .present = 1, .value = @intFromBool(enabled) };
        self.add(node, commands[index]);
    }

    fn input(self: *Content, key: []const u8, caption: []const u8, enabled: bool) void {
        var node = ui.node(ui.NodeKind.text_input);
        node.text = .{ .present = 1, .value = abi.view(caption) };
        node.state = .{ .present = 1, .value = abi.view(key) };
        node.enabled = .{ .present = 1, .value = @intFromBool(enabled) };
        self.add(node, key);
    }

    fn build(self: *Content, owner: *const Settings, tree: *ui.Tree) void {
        self.len = 0;
        const idle = owner.loaded and owner.pending == 0 and owner.picker_request == 0 and !owner.poisoned and !owner.route.busy() and !owner.checkingProject();
        const lang = owner.stored.locale.language();
        self.add(ui.text(owner.status.label(lang)), "settings.status");
        self.button(0, tr(lang, "Reload settings", "重新读取设置"), owner.pending == 0 and owner.picker_request == 0 and !owner.poisoned and !owner.route.busy() and !owner.checkingProject());
        self.add(ui.text(tr(lang, "Projects · bookmarks only; no execution or trust", "项目库 · 记录项目，不自动授予权限")), "settings.projects");
        const visible = owner.visible();
        self.input(search_key, tr(lang, "Search name, path, tags or remote", "搜索名称、路径、标签或远程地址"), idle);
        self.button(19, tr(lang, "Search / clear search", "搜索 / 清除搜索"), idle);
        const page_text = std.fmt.bufPrint(&self.page_label, "{d}/{d} · {d} / {d}", .{ owner.project_page + 1, @max(1, (visible.total + page_size - 1) / page_size), visible.total, owner.stored.count }) catch "";
        self.add(ui.text(page_text), "settings.project.page");
        self.button(20, tr(lang, "Previous page", "上一页"), idle and owner.project_page > 0);
        self.button(21, tr(lang, "Next page", "下一页"), idle and (owner.project_page + 1) * page_size < visible.total);
        self.states[3] = .{ .key = abi.view(root_key), .value = abi.view("") };
        self.states[4] = .{ .key = abi.view(url_key), .value = abi.view("") };
        self.states[5] = .{ .key = abi.view(selection_key), .value = abi.view("") };
        self.states[6] = .{ .key = abi.view(name_key), .value = abi.view("") };
        self.states[7] = .{ .key = abi.view(tags_key), .value = abi.view("") };
        self.states[8] = .{ .key = abi.view(search_key), .value = abi.view(owner.search.slice()) };
        const headers = [_][]const u8{ tr(lang, "Favorite", "收藏"), tr(lang, "Project", "项目"), tr(lang, "Provider hint", "类型提示"), tr(lang, "Local directory", "本地目录"), tr(lang, "Tags", "标签"), tr(lang, "Remote", "远程仓库"), tr(lang, "Open order", "打开顺序") };
        const ids = [_][]const u8{ "favorite", "name", "provider", "path", "tags", "remote", "opened" };
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
                abi.view(if (project.opened_order == 0) tr(lang, "Never", "未记录") else std.fmt.bufPrint(&self.recency_labels[i], "{d}", .{project.opened_order}) catch ""),
            };
            self.rows[i] = std.mem.zeroes(raw.PulseUiModelRow);
            self.rows[i].size = @sizeOf(raw.PulseUiModelRow);
            self.rows[i].id = abi.view(&project.key);
            self.rows[i].cells = .{ .present = 1, .data = &self.cells[i], .count = self.cells[i].len };
        }
        if (visible.count != 0) {
            var table = ui.node(ui.NodeKind.data_table);
            table.state = .{ .present = 1, .value = abi.view(selection_key) };
            table.min_height = .{ .present = 1, .value = 176 };
            table.rows = .{ .present = 1, .data = &self.rows, .count = @intCast(visible.count) };
            table.data_columns = .{ .present = 1, .data = &self.columns, .count = self.columns.len };
            self.add(table, "settings.project.table");
            self.button(16, tr(lang, "Edit selected / show path", "编辑选中项目 / 查看路径"), idle);
            self.button(18, tr(lang, "Toggle favorite", "切换收藏"), idle);
            self.button(9, tr(lang, "Remove selected bookmark (keep files)", "移除选中记录（不删除项目文件）"), idle);
            if (owner.route.table != null) {
                self.button(22, tr(lang, "Open selected project in Pulse", "在 Pulse 中打开选中项目"), idle);
            } else self.add(ui.text(tr(lang, "Host navigation unavailable: edit selected and open its path manually.", "宿主不支持跳转：编辑选中项目并手动打开路径。")), "settings.project.route-fallback");
            const external_idle = idle and (if (owner.browser) |*task| !task.occupied() else false);
            self.button(10, tr(lang, "Open remote repository in browser", "在浏览器打开远程仓库"), external_idle);
            self.button(30, tr(lang, "Open Issues", "打开 Issues"), external_idle);
            self.button(31, tr(lang, "Open PR / MR", "打开 PR / MR"), external_idle);
            self.button(32, tr(lang, "Open Actions / Pipelines", "打开 Actions / Pipelines"), external_idle);
            self.button(33, tr(lang, "Open Releases (GitHub / GitLab)", "打开 Releases（GitHub / GitLab）"), external_idle);
            self.button(34, tr(lang, "Inspect literal local Git remotes", "检查本地 Git 远程地址"), external_idle);
            self.button(41, tr(lang, "Fetch public GitHub metadata (api.github.com, no account)", "获取公开 GitHub 元数据（api.github.com，无账号）"), external_idle);
            self.button(44, tr(lang, "Review opening selected folder in VS Code", "审核使用 VS Code 打开项目"), external_idle and owner.stored.client_paths[0] != null);
            self.button(45, tr(lang, "Review opening SVN status dialog", "审核打开 TortoiseSVN 状态窗口"), external_idle and owner.stored.client_paths[1] != null);
            self.add(ui.text(tr(lang, "Browser availability and private access are not verified; external apps may access files/network independently.", "未验证网页可用性与私有访问权限；外部程序可自行访问文件或网络。")), "settings.forge.warning");
            if (owner.grant_access != null and owner.project_task != null) self.button(26, tr(lang, "Inspect selected project saved approvals", "检查选中项目的持久授权"), idle);
        } else self.add(ui.text(tr(lang, "No matching projects (up to 64 records)", "没有匹配项目（最多 64 项）")), "settings.project.empty");
        if (owner.remote_review) |*review| {
            self.add(ui.text(review.scope.root.slice()), "settings.forge.review-root");
            const remote_ids = [_][]const u8{ "settings.remote.0", "settings.remote.1", "settings.remote.2", "settings.remote.3", "settings.remote.4", "settings.remote.5" };
            for (review.value.rows[0..review.value.count], 0..) |row, i| {
                const label = std.fmt.bufPrint(&self.remote_labels[i], "{s}: {s}", .{ row.name.slice(), row.url.slice() }) catch "";
                self.add(ui.text(label), remote_ids[i]);
                self.button(35 + i, tr(lang, "Save this detected address for same selected project", "将此检测地址保存至同一选中项目"), idle and !owner.externalBusy());
            }
            if (review.value.count == 0) self.add(ui.text(tr(lang, "No supported literal remote", "没有支持的字面远程地址")), "settings.remote.empty");
            if (review.value.omitted != 0) self.add(ui.text(tr(lang, "Some remote values were rejected or exceed the retained limit; raw values hidden.", "部分远程地址无效或超出保留上限；原始值不显示。")), "settings.remote.omitted");
        }
        if (owner.metadata_review) |*review| {
            self.add(ui.text(review.scope.remote.slice()), "settings.meta.repository");
            const result = review.value;
            self.add(ui.text(tr(lang, "Last explicit public snapshot (not live; no automatic refresh)", "最近一次显式公开快照（非实时；不自动刷新）")), "settings.meta.heading");
            const status = if (result.status == .ready and forge.nowMs() -| result.fetched_ms > 300000) tr(lang, "Expired; fetch again", "已过期；请重新获取") else switch (result.status) {
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
            self.add(ui.text(status), "settings.meta.status");
            if (result.status == .ready and forge.nowMs() -| result.fetched_ms <= 300000) {
                const label = std.fmt.bufPrint(&self.meta_label, "Stars {d} | Forks {d} | Open issues + PRs {d} | Archived {s}", .{ result.stars, result.forks, result.open_items, if (result.archived) "yes" else "no" }) catch "";
                self.add(ui.text(label), "settings.meta.counts");
                self.add(ui.text(result.branch.slice()), "settings.meta.branch");
            }
        }
        if (owner.client_review) |*review| {
            self.add(ui.text(review.client.name()), "settings.client.review-kind");
            self.add(ui.text(review.executable.slice()), "settings.client.review-exe");
            self.add(ui.text(review.scope.root.slice()), "settings.client.review-root");
            self.button(46, tr(lang, "Confirm external launch (not a sandbox)", "确认启动外部程序（非沙箱）"), idle and !owner.externalBusy());
            self.button(47, tr(lang, "Cancel launch review", "取消启动审核"), idle and !owner.externalBusy());
        }
        if (owner.route.busy()) self.button(24, tr(lang, "Cancel directory lookup", "取消目录查找"), true);
        if (owner.grant_review) |*review| {
            self.add(ui.text(tr(lang, "Reviewed approval scope (no execution; select this same row before revoking)", "已检查授权范围（不执行；撤销前请选中同一项目）")), "settings.grants.heading");
            self.add(ui.text(review.root.slice()), "settings.grants.root");
            const ids_grant = [_][]const u8{ "settings.grants.git", "settings.grants.jj", "settings.grants.svn" };
            const ids_path = [_][]const u8{ "settings.grants.git.path", "settings.grants.jj.path", "settings.grants.svn.path" };
            const en = [_][]const u8{ "Revoke Git approval", "Revoke Jujutsu approval", "Revoke SVN approval" };
            const zh = [_][]const u8{ "撤销 Git 授权", "撤销 Jujutsu 授权", "撤销 SVN 授权" };
            for (review.hints, grant_kinds, 0..) |hint, kind, i| {
                const label = switch (hint.state) {
                    .not_checked => tr(lang, "Not checked", "未检查"),
                    .absent => tr(lang, "No record observed", "未发现记录"),
                    .recorded => tr(lang, "Recorded; not revalidated", "存在记录；尚未验证"),
                    .unavailable => tr(lang, "Unavailable", "无法读取"),
                };
                self.add(ui.text(std.fmt.bufPrint(&self.grant_labels[i], "{s}: {s}", .{ kind.displayName(), label }) catch ""), ids_grant[i]);
                if (hint.executable) |*path| self.add(ui.text(path.slice()), ids_path[i]);
                self.button(27 + i, tr(lang, en[i], zh[i]), idle and review.version == owner.stored.version and hint.state == .recorded);
            }
        }
        if (owner.checkingProject() and !owner.grant_revoke_pending) self.button(25, tr(lang, "Cancel pending check", "取消待处理检查"), !owner.project_discard);
        self.button(11, tr(lang, "Check pending task result", "检查待处理任务结果"), owner.checkingProject() or (if (owner.browser) |*task| task.occupied() else false));
        const edit_text = if (owner.edit_key) |key| std.fmt.bufPrint(&self.edit_label, "{s}: {s}", .{ tr(lang, "Editing", "编辑"), &key }) catch "" else tr(lang, "New project", "新建项目");
        self.add(ui.text(edit_text), "settings.project.edit-mode");
        self.button(15, tr(lang, "New project / clear form", "新建项目 / 清空表单"), idle);
        self.input(root_key, tr(lang, "Project root (absolute path)", "项目根目录（绝对路径）"), idle);
        self.input(name_key, tr(lang, "Project name (optional)", "项目名称（可选）"), idle);
        self.input(tags_key, tr(lang, "Tags (optional)", "标签（可选）"), idle);
        self.input(url_key, tr(lang, "Remote repository (optional: GitHub / GitLab / Bitbucket)", "远程仓库地址（可选：GitHub / GitLab / Bitbucket）"), idle);
        if (owner.picker != null) self.button(23, tr(lang, "Browse project folder", "浏览项目文件夹"), idle);
        self.button(7, tr(lang, "Fill current VCS repository", "填入当前 VCS 仓库"), idle);
        if (owner.edit_key != null) {
            self.button(17, tr(lang, "Update / relink selected record", "更新 / 重新关联记录"), idle);
        } else self.button(8, tr(lang, "Add project", "添加项目"), idle);
        self.add(ui.text(tr(lang, "VCS tools · Saving a path does not authorize execution", "版本控制工具 · 保存路径不等于执行授权")), "settings.tools");
        self.add(ui.text(tr(lang, "Language / 语言", "语言 / Language")), "settings.locale");
        self.button(12, tr(lang, "System language (Auto)", "跟随系统 (Auto)"), idle and owner.stored.locale != .auto);
        self.button(13, "English", idle and owner.stored.locale != .en);
        self.button(14, "简体中文", idle and owner.stored.locale != .zh);
        for (fields, names, 0..) |field, name, i| {
            self.input(field, name, idle);
            self.button(1 + i, tr(lang, "Save path (empty restores detection)", "保存路径（留空恢复自动检测）"), idle);
            if (owner.picker != null) self.button(4 + i, tr(lang, "Browse tool folder", "浏览工具所在文件夹"), idle);
            self.states[i] = .{ .key = abi.view(field), .value = abi.view(if (owner.stored.tools[i]) |*path| path.slice() else "") };
        }
        self.add(ui.text(tr(lang, "External client paths · save does not launch or grant VCS access", "外部客户端路径 · 保存不启动或授予 VCS 权限")), "settings.client.heading");
        for (clients, client_fields, 0..) |client, field, i| {
            self.input(field, client.name(), idle);
            self.button(42 + i, tr(lang, "Save exact executable (empty clears)", "保存准确可执行文件路径（留空清除）"), idle);
            self.states[9 + i] = .{ .key = abi.view(field), .value = abi.view(if (owner.stored.client_paths[i]) |*path| path.slice() else "") };
        }
        for (commands, 0..) |command, i| self.vocabulary[i] = abi.view(command);
        self.root = ui.node(ui.NodeKind.stack);
        self.root.id = abi.view("vcs.settings.root");
        ui.withChildren(&self.root, self.nodes[0..self.len]);
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
    browser: ?async_host.Task = null,
    external_job: ?ExternalJob = null,
    remote_review: ?RemoteReview = null,
    metadata_review: ?MetadataReview = null,
    client_review: ?ClientReview = null,
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

    pub fn open(self: *Settings) host_mod.Error!void {
        if (self.active) return;
        if (self.poisoned) return error.State;
        // A previous deactivate can have removed the page while a browser
        // worker or callback is still retained. Never overwrite that owner.
        if (self.page != 0 or self.pending != 0 or self.picker_request != 0 or self.browser != null or self.project_task != null or self.route.busy()) try self.close();
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
        var content: Content = undefined;
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
        var content: Content = undefined;
        var tree: ui.Tree = undefined;
        content.build(self, &tree);
        self.render_ok = false;
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
        var states: [6]ui.State = undefined;
        var count: usize = 0;
        for (fields, 0..) |field, i| {
            if (mask & (@as(u8, 1) << @as(u3, @intCast(i))) == 0) continue;
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
        self.client_review = null;
        if (!self.active) return;
        if (reply.*.status != abi.ok or reply.*.operation != operation) {
            self.status = .conflict;
        } else if (Stored.decode(reply.*.settings, &self.scratch)) |_| {
            self.stored = self.scratch;
            self.clampPage();
            self.loaded = true;
            // An edit draft is bound to the version from which it was loaded.
            // Do not silently rebase it over a concurrent change.
            if (mask & 8 != 0) self.edit_key = null;
            self.status = if (operation == raw.PULSE_RESOURCES_SETTINGS_GET) .loaded else if (recency) .route_dispatched else .saved;
            self.updated(self.user, self.stored.tools, self.stored.locale.language());
            self.render();
            self.syncTools(mask);
        } else |_| {
            self.status = .invalid;
        }
        self.render();
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
        if (!self.active or self.pending != 0 or self.picker_request != 0 or self.poisoned or self.route.busy() or self.checkingProject()) return;
        const resources = self.resources orelse return;
        const get = resources.settings_get orelse return;
        var id: u64 = 0;
        self.grant_review = null;
        self.sync_mask = 63;
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
            if (std.mem.eql(u8, key, tool_key)) self.sync_mask = @as(u8, 1) << @as(u3, @intCast(i));
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

    fn saveProject(self: *Settings, update: bool) !void {
        var root: [max_value + 1]u8 = undefined;
        var url: [513]u8 = undefined;
        var name: [97]u8 = undefined;
        var tags: [161]u8 = undefined;
        var item = try Project.make(try self.read(root_key, &root), try self.read(url_key, &url));
        item.name = try Project.field(try self.read(name_key, &name), 96);
        item.tags = try Project.field(try self.read(tags_key, &tags), 160);
        if (self.form_root.eql(item.root.slice())) item.kind = self.form_kind;
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
            .size = @sizeOf(async_host.Descriptor),
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
            .size = @sizeOf(async_host.Descriptor),
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
        if (!self.active or !self.loaded or !self.render_ok or self.pending != 0 or self.picker_request != 0 or self.poisoned or self.route.busy() or self.checkingProject()) return error.State;
        if (!approval.strictPath(path)) return error.Argument;
        const root = try identity.Path.init(path);
        if (self.stored.findRoot(path)) |index| {
            const project = &self.stored.projects[index];
            if (!project.root.eql(path)) return error.Argument;
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
            } else tool: {
                if (self.picker_index >= tools.len) break :blk;
                const value = std.fmt.bufPrint(&bytes, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ std.mem.trimEnd(u8, path, "\\/"), tools[self.picker_index].exeName() }) catch break :blk;
                _ = toolPath(self.picker_index, value) catch break :blk;
                break :tool value;
            };
            const model = if (self.panel) |*value| value else break :blk;
            const field = if (self.picker_index == tools.len) root_key else fields[self.picker_index];
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
        if (context == null) return @backingInt(async_host.TaskState.failed);
        const cancelled = context.*.cancelled orelse return @backingInt(async_host.TaskState.failed);
        if (cancelled(context.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
        const job = self.external_job orelse return @backingInt(async_host.TaskState.failed);
        switch (job) {
            .website => |value| openWebsite(value.scope.remote.slice(), value.page) catch return @backingInt(async_host.TaskState.failed),
            .discover => |scope| self.remote_result = forge.inspectRemotes(scope.root.slice()) catch return @backingInt(async_host.TaskState.failed),
            .metadata => |scope| self.metadata_result = forge.fetchMetadata(scope.remote.slice(), cancelled, context.*.context),
            .client => |review| forge.launchClient(review.client, review.executable.slice(), review.scope.root.slice(), review.scope.kind) catch return @backingInt(async_host.TaskState.failed),
        }
        return @backingInt(async_host.TaskState.completed);
    }

    fn startExternal(self: *Settings, job: ExternalJob) !void {
        const task = if (self.browser) |*value| value else return error.Unavailable;
        if (task.occupied()) return error.State;
        self.external_job = job;
        self.remote_result = null;
        self.metadata_result = null;
        const descriptor: async_host.Descriptor = .{
            .size = @sizeOf(async_host.Descriptor),
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

    fn pollBrowser(self: *Settings) !void {
        const task = if (self.browser) |*value| value else return;
        if (!task.occupied()) return;
        const state = try task.poll();
        if (!state.terminal()) return;
        try task.releaseTerminal();
        const job = self.external_job orelse return error.State;
        defer {
            self.external_job = null;
            self.remote_result = null;
            self.metadata_result = null;
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
        }
    }

    fn onCommand(user: ?*anyopaque, page: u64, command: abi.StringView) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(user orelse return));
        if (!self.active or page == 0 or page != self.page or self.poisoned) return;
        const name = abi.slice(command) orelse return;
        if (std.mem.eql(u8, name, commands[11])) {
            if (self.checkingProject()) {
                self.pollProject() catch |err| diag.status("vcs-project-identity-poll", @intFromError(err));
            } else {
                self.pollBrowser() catch |err| diag.status("vcs-settings-browser-poll", @intFromError(err));
                self.render();
            }
            return;
        }
        if (std.mem.eql(u8, name, commands[25])) {
            self.cancelProject() catch |err| diag.status("vcs-project-identity-cancel", @intFromError(err));
            self.render();
            return;
        }
        if (self.checkingProject()) return;
        self.pollBrowser() catch |err| diag.status("vcs-settings-browser-poll", @intFromError(err));
        if (std.mem.eql(u8, name, commands[0])) {
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
                11 => self.pollBrowser(),
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
                47 => { self.client_review = null; },
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
        if (self.browser) |*task| {
            if (task.occupied()) {
                const state = try task.poll();
                if (!state.terminal()) {
                    try task.cancel();
                    return error.State;
                }
                try task.releaseTerminal();
            }
        }
        self.browser = null;
        self.external_job = null;
        self.remote_result = null;
        self.metadata_result = null;
        self.remote_review = null;
        self.metadata_review = null;
        self.client_review = null;
        if (self.project_task) |*task| {
            if (task.occupied()) {
                const state = try task.poll();
                if (!state.terminal()) {
                    try task.cancel();
                    return error.State;
                }
                try task.releaseTerminal();
            }
        }
        self.project_task = null;
        self.checked_project = null;
        self.grant_job = null;
        self.grant_review = null;
        self.grant_revoke_pending = false;
        self.pages = null;
        self.resources = null;
        self.picker = null;
        self.route.table = null;
        self.loaded = false;
    }

    pub fn retireAtHostDestroy(self: *Settings) void {
        // Host stop suppresses resource/picker/UI callbacks and joins tasks.
        self.active = false;
        self.render_ok = false;
        self.route.retire();
        if (self.browser) |*task| task.retireAtHostDestroy();
        self.browser = null;
        self.external_job = null;
        self.remote_result = null;
        self.metadata_result = null;
        self.remote_review = null;
        self.metadata_review = null;
        self.client_review = null;
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

    fn getState(user: ?*anyopaque, _: u64, _: abi.StringView, bytes: [*c]u8, capacity: u32, needed: [*c]u32) callconv(.c) abi.Status {
        const self: *SettingsFixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (self.input.len >= capacity) return abi.error_argument;
        @memcpy(bytes[0..self.input.len], self.input);
        needed.* = @intCast(self.input.len);
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
    try std.testing.expectEqual(@as(usize, 5), fixture.synced);
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
