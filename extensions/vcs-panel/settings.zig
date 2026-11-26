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

const max_projects = 32;
const max_value = 1024;
const keys = [_][]const u8{ "tool.git", "tool.jj", "tool.svn" };
const names = [_][]const u8{ "Git", "Jujutsu", "Subversion" };
const tools = [_]cli.Tool{ .git, .jj, .svn };
const fields = [_][]const u8{ "settings.git", "settings.jj", "settings.svn" };
const commands = [_][]const u8{ "vcs.settings.reload", "vcs.settings.save-git", "vcs.settings.save-jj", "vcs.settings.save-svn", "vcs.settings.browse-git", "vcs.settings.browse-jj", "vcs.settings.browse-svn", "vcs.projects.current", "vcs.projects.save", "vcs.projects.remove", "vcs.projects.website", "vcs.projects.check" };
const root_key = "settings.project.root";
const url_key = "settings.project.url";
const selection_key = "settings.project.selected";
const project_prefix = "project.";
const key_len = project_prefix.len + 32;

pub const Tools = [3]?identity.Path;
pub const Current = struct { root: identity.Path, remote: contract.Text = .{} };

const Project = struct {
    key: [key_len]u8,
    root: identity.Path,
    remote: contract.Text = .{},

    fn make(root: []const u8, url: []const u8) !Project {
        if (!approval.strictPath(root)) return error.InvalidSettings;
        const path = identity.Path.init(root) catch return error.InvalidSettings;
        const remote = if (url.len == 0) contract.Text{} else contract.repositoryWebUrl(url) orelse return error.InvalidSettings;
        if (root.len + 1 + remote.slice().len > max_value) return error.InvalidSettings;
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(root, &digest, .{});
        var key: [key_len]u8 = undefined;
        @memcpy(key[0..project_prefix.len], project_prefix);
        const hex = std.fmt.bytesToHex(digest[0..16].*, .lower);
        @memcpy(key[project_prefix.len..], &hex);
        return .{ .key = key, .root = path, .remote = remote };
    }

    fn encode(self: *const Project, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "{s}\n{s}", .{ self.root.slice(), self.remote.slice() });
    }

    fn decode(key: []const u8, value: []const u8) !Project {
        if (value.len > max_value) return error.InvalidSettings;
        const split = std.mem.indexOfScalar(u8, value, '\n') orelse return error.InvalidSettings;
        const item = try make(value[0..split], value[split + 1 ..]);
        if (!std.mem.eql(u8, key, &item.key) or !item.remote.eql(value[split + 1 ..])) return error.InvalidSettings;
        return item;
    }
};

fn toolPath(index: usize, value: []const u8) !?identity.Path {
    if (index >= tools.len or value.len > max_value) return error.InvalidSettings;
    if (value.len == 0) return null;
    if (!approval.strictPath(value) or !std.ascii.eqlIgnoreCase(std.fs.path.basename(value), tools[index].exeName())) return error.InvalidSettings;
    return identity.Path.init(value) catch error.InvalidSettings;
}

const Stored = struct {
    version: u64 = 0,
    tools: Tools = .{ null, null, null },
    projects: [max_projects]Project = undefined,
    count: usize = 0,

    fn find(self: *const Stored, key: []const u8) ?usize {
        for (self.projects[0..self.count], 0..) |*project, index| {
            if (std.mem.eql(u8, key, &project.key)) return index;
        }
        return null;
    }

    fn decode(value: raw.PulseSettings, out: *Stored) !void {
        if (value.version > (1 << 53) - 1 or value.count > 1024 or (value.count != 0 and value.values == null)) return error.InvalidSettings;
        out.* = .{ .version = value.version };
        var seen: [3]bool = @splat(false);
        for (0..value.count) |n| {
            const pair = value.values[n];
            const key = abi.slice(pair.key) orelse return error.InvalidSettings;
            if (key.len > 64) return error.InvalidSettings;
            for (keys, 0..) |name, i| {
                if (!std.mem.eql(u8, key, name)) continue;
                if (seen[i]) return error.InvalidSettings;
                seen[i] = true;
                const data = if (pair.value.length == 0) "" else abi.slice(pair.value) orelse return error.InvalidSettings;
                out.tools[i] = try toolPath(i, data);
            }
            if (!std.mem.startsWith(u8, key, project_prefix)) continue;
            if (out.count == max_projects or out.find(key) != null) return error.InvalidSettings;
            const data = abi.slice(pair.value) orelse return error.InvalidSettings;
            out.projects[out.count] = try Project.decode(key, data);
            out.count += 1;
        }
    }
};

const Content = struct {
    nodes: [32]ui.Node = undefined,
    len: usize = 0,
    root: ui.Node = undefined,
    states: [6]ui.State = undefined,
    vocabulary: [commands.len]abi.StringView = undefined,
    rows: [max_projects]raw.PulseUiModelRow = undefined,
    cells: [max_projects][3]abi.StringView = undefined,
    columns: [3]raw.PulseUiModelColumn = undefined,

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
        const idle = owner.loaded and owner.pending == 0 and owner.picker_request == 0 and !owner.poisoned;
        self.add(ui.text("版本控制工具 · 保存路径不等于执行授权"), "settings.tools");
        self.add(ui.text(owner.status), "settings.status");
        self.button(0, "重新读取设置", owner.pending == 0 and !owner.poisoned);
        for (fields, names, 0..) |field, name, i| {
            self.input(field, name, idle);
            self.button(1 + i, "保存路径（留空恢复自动检测）", idle);
            if (owner.picker != null) self.button(4 + i, "浏览工具所在文件夹", idle);
            self.states[i] = .{ .key = abi.view(field), .value = abi.view(if (owner.stored.tools[i]) |*path| path.slice() else "") };
        }
        self.add(ui.text("项目库 · 仅记录位置，不自动授予权限或运行命令"), "settings.projects");
        self.input(root_key, "项目根目录（绝对路径）", idle);
        self.input(url_key, "远程仓库地址（可选：GitHub / GitLab / Bitbucket）", idle);
        self.button(7, "填入当前 VCS 仓库", idle);
        self.button(8, "保存项目 / 更新远程地址", idle);
        self.states[3] = .{ .key = abi.view(root_key), .value = abi.view("") };
        self.states[4] = .{ .key = abi.view(url_key), .value = abi.view("") };
        self.states[5] = .{ .key = abi.view(selection_key), .value = abi.view("") };
        const headers = [_][]const u8{ "项目", "本地目录", "远程仓库" };
        const ids = [_][]const u8{ "name", "path", "remote" };
        for (headers, ids, 0..) |heading, id, i| {
            self.columns[i] = std.mem.zeroes(raw.PulseUiModelColumn);
            self.columns[i].size = @sizeOf(raw.PulseUiModelColumn);
            self.columns[i].id = abi.view(id);
            self.columns[i].text = abi.view(heading);
        }
        for (owner.stored.projects[0..owner.stored.count], 0..) |*project, i| {
            self.cells[i] = .{ abi.view(std.fs.path.basename(project.root.slice())), abi.view(project.root.slice()), abi.view(project.remote.slice()) };
            self.rows[i] = std.mem.zeroes(raw.PulseUiModelRow);
            self.rows[i].size = @sizeOf(raw.PulseUiModelRow);
            self.rows[i].id = abi.view(&project.key);
            self.rows[i].cells = .{ .present = 1, .data = &self.cells[i], .count = 3 };
        }
        if (owner.stored.count != 0) {
            var table = ui.node(ui.NodeKind.data_table);
            table.state = .{ .present = 1, .value = abi.view(selection_key) };
            table.min_height = .{ .present = 1, .value = 176 };
            table.rows = .{ .present = 1, .data = &self.rows, .count = @intCast(owner.stored.count) };
            table.data_columns = .{ .present = 1, .data = &self.columns, .count = self.columns.len };
            self.add(table, "settings.project.table");
            self.button(9, "移除选中记录（不删除项目文件）", idle);
            self.button(10, "在浏览器打开远程仓库", idle and (if (owner.browser) |*task| !task.occupied() else false));
        } else self.add(ui.text("尚未记录项目（最多 32 项）"), "settings.project.empty");
        self.button(11, "检查浏览器任务结果", if (owner.browser) |*task| task.occupied() else false);
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
    updated: *const fn (*anyopaque, Tools) void,
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
    status: []const u8 = "准备读取设置",
    picker: ?pickers.Table = null,
    picker_request: u64 = 0,
    picker_index: usize = 0,
    browser: ?async_host.Task = null,
    browser_url: contract.Text = .{},

    pub fn open(self: *Settings) host_mod.Error!void {
        if (self.active) return;
        if (self.poisoned) return error.State;
        // A previous deactivate can have removed the page while a browser
        // worker or callback is still retained. Never overwrite that owner.
        if (self.page != 0 or self.pending != 0 or self.picker_request != 0 or self.browser != null) try self.close();
        const pages = (try self.host.queryOptional(raw.PulseSettingsPagesV1, raw.PULSE_SETTINGS_PAGES_INTERFACE_NAME, raw.PULSE_SETTINGS_PAGES_VERSION_1)) orelse return;
        const resources = (try self.host.queryOptional(raw.PulseResourcesV1, raw.PULSE_RESOURCES_INTERFACE_NAME, raw.PULSE_RESOURCES_VERSION_1)) orelse return;
        const create = pages.create orelse return error.Unavailable;
        const query = pages.query orelse return error.Unavailable;
        if (pages.remove == null or resources.settings_get == null or resources.settings_set == null or resources.cancel_request == null) return error.Unavailable;
        self.pages = pages;
        self.resources = resources;
        if (self.host.queryOptional(pickers.Table, pickers.name, pickers.version)) |optional| {
            if (optional) |picker| {
                if (picker.pick_folders != null and picker.cancel != null) self.picker = picker;
            }
        } else |_| {}
        if (comptime builtin.os.tag == .windows) {
            if (async_host.taskTable(self.host)) |table| {
                self.browser = async_host.Task.init(table) catch null;
            } else |_| {}
        }
        var content: Content = undefined;
        var tree: ui.Tree = undefined;
        content.build(self, &tree);
        var page: u64 = 0;
        try host_mod.mapStatus(create(pages.context, abi.view("VCS 设置与项目"), &tree, &page));
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
        model.update(&tree) catch |err| diag.status("vcs-settings-render", @intFromError(err));
    }

    fn syncTools(self: *Settings) void {
        const model = if (self.panel) |*value| value else return;
        var states: [4]ui.State = undefined;
        for (fields, 0..) |field, i| {
            states[i] = .{ .key = abi.view(field), .value = abi.view(if (self.stored.tools[i]) |*path| path.slice() else "") };
        }
        states[3] = .{ .key = abi.view(selection_key), .value = abi.view("") };
        model.setStates(&states) catch |err| {
            self.loaded = false;
            self.status = "界面状态同步失败；请重新读取";
            diag.status("vcs-settings-sync", @intFromError(err));
        };
    }

    fn completed(user: ?*anyopaque, reply: [*c]const raw.PulseResourcesReply) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(user orelse return));
        if (reply == null or reply.*.size < @sizeOf(raw.PulseResourcesReply) or self.pending == 0 or reply.*.request_id != self.pending) return;
        const operation = self.operation;
        self.pending = 0;
        self.operation = 0;
        self.loaded = false;
        if (!self.active) return;
        if (reply.*.status != abi.ok or reply.*.operation != operation) {
            self.status = "设置操作失败或版本冲突；请重新读取，未强制覆盖";
        } else if (Stored.decode(reply.*.settings, &self.scratch)) |_| {
            self.stored = self.scratch;
            self.loaded = true;
            self.status = if (operation == raw.PULSE_RESOURCES_SETTINGS_GET) "已读取设置" else "宿主已确认保存";
            self.updated(self.user, self.stored.tools);
            self.render();
            self.syncTools();
        } else |_| {
            self.status = "设置数据无效；未覆盖原有记录";
        }
        self.render();
    }

    fn admitted(self: *Settings, status: abi.Status, id: u64, operation: u32) void {
        if (status == abi.ok and id != 0) {
            self.pending = id;
            self.operation = operation;
            self.status = "等待宿主确认";
        } else {
            self.loaded = false;
            if (status == abi.ok) self.poisoned = true;
            self.status = "请求未被正常接受；请重新读取";
        }
        self.render();
    }

    fn reload(self: *Settings) void {
        if (!self.active or self.pending != 0 or self.poisoned) return;
        const resources = self.resources orelse return;
        const get = resources.settings_get orelse return;
        var id: u64 = 0;
        const status = get(resources.context, completed, self, &id);
        self.admitted(status, id, raw.PULSE_RESOURCES_SETTINGS_GET);
    }

    fn save(self: *Settings, key: []const u8, value: []const u8, remove: bool) void {
        if (!self.active or !self.loaded or self.pending != 0 or self.poisoned or value.len > max_value) return;
        const resources = self.resources orelse return;
        const set = resources.settings_set orelse return;
        var id: u64 = 0;
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

    fn fillCurrent(self: *Settings) !void {
        const current = self.current(self.user) orelse return error.State;
        const model = if (self.panel) |*value| value else return error.State;
        const states = [_]ui.State{
            .{ .key = abi.view(root_key), .value = abi.view(current.root.slice()) },
            .{ .key = abi.view(url_key), .value = abi.view(current.remote.slice()) },
        };
        try model.setStates(&states);
        self.status = "已填入当前仓库；请检查后保存";
    }

    fn saveProject(self: *Settings) !void {
        var root: [max_value + 1]u8 = undefined;
        var url: [513]u8 = undefined;
        const item = try Project.make(try self.read(root_key, &root), try self.read(url_key, &url));
        if (self.stored.find(&item.key)) |index| {
            if (!self.stored.projects[index].root.eql(item.root.slice())) return error.InvalidSettings;
        } else if (self.stored.count == max_projects) return error.InvalidSettings;
        var bytes: [max_value]u8 = undefined;
        self.save(&item.key, try item.encode(&bytes), false);
    }

    fn selected(self: *const Settings) !*const Project {
        var key: [key_len + 1]u8 = undefined;
        const index = self.stored.find(try self.read(selection_key, &key)) orelse return error.State;
        return &self.stored.projects[index];
    }

    fn pickerCompleted(user: ?*anyopaque, result: [*c]const pickers.Result) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(user orelse return));
        if (result == null or result.*.size < @sizeOf(pickers.Result) or self.picker_request == 0 or result.*.request_id != self.picker_request) return;
        self.picker_request = 0;
        if (!self.active) return;
        self.status = "未选择工具目录；可手动填写";
        if (result.*.outcome == pickers.accepted and result.*.path_count == 1 and result.*.paths != null) blk: {
            const path = abi.slice(result.*.paths[0]) orelse break :blk;
            var bytes: [max_value]u8 = undefined;
            const candidate = std.fmt.bufPrint(&bytes, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ std.mem.trimEnd(u8, path, "\\/"), tools[self.picker_index].exeName() }) catch break :blk;
            _ = toolPath(self.picker_index, candidate) catch break :blk;
            const model = if (self.panel) |*value| value else break :blk;
            const states = [_]ui.State{.{ .key = abi.view(fields[self.picker_index]), .value = abi.view(candidate) }};
            model.setStates(&states) catch break :blk;
            self.status = "已填入候选路径；请确认文件名并保存（尚未验证）";
        }
        self.render();
    }

    fn browse(self: *Settings, index: usize) !void {
        const picker = self.picker orelse return error.Unavailable;
        const pick = picker.pick_folders orelse return error.Unavailable;
        self.picker_index = index;
        var id: u64 = 0;
        const request: pickers.Request = .{ .title = abi.view("选择工具可执行文件所在文件夹"), .ok_label = abi.view("选择") };
        try host_mod.mapStatus(pick(picker.context, &request, pickerCompleted, self, &id));
        if (id == 0) {
            self.poisoned = true;
            return error.State;
        }
        self.picker_request = id;
        self.status = "正在选择工具目录";
    }

    fn browserWork(user: ?*anyopaque, context: [*c]const async_host.Context) callconv(.c) u32 {
        const self: *Settings = @ptrCast(@alignCast(user orelse return @backingInt(async_host.TaskState.failed)));
        if (context == null) return @backingInt(async_host.TaskState.failed);
        const cancelled = context.*.cancelled orelse return @backingInt(async_host.TaskState.failed);
        if (cancelled(context.*.context) != 0) return @backingInt(async_host.TaskState.cancelled);
        openWebsite(self.browser_url.slice()) catch return @backingInt(async_host.TaskState.failed);
        return @backingInt(async_host.TaskState.completed);
    }

    fn openSelected(self: *Settings) !void {
        const task = if (self.browser) |*value| value else return error.Unavailable;
        if (task.occupied()) return error.State;
        const project = try self.selected();
        const url = contract.repositoryWebUrl(project.remote.slice()) orelse return error.Argument;
        self.browser_url = url;
        const descriptor: async_host.Descriptor = .{
            .size = @sizeOf(async_host.Descriptor),
            .title = abi.view("Open repository website"),
            .type = abi.view("vcs.projects.website"),
            .work = &browserWork,
            .user = self,
        };
        try task.start(&descriptor);
        self.status = "已提交浏览器任务；可检查结果";
    }

    fn pollBrowser(self: *Settings) !void {
        const task = if (self.browser) |*value| value else return;
        if (!task.occupied()) return;
        const state = try task.poll();
        if (!state.terminal()) return;
        try task.releaseTerminal();
        self.status = if (state == .completed) "已交给默认浏览器；不代表网页加载成功" else "浏览器任务未完成";
    }

    fn onCommand(user: ?*anyopaque, page: u64, command: abi.StringView) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(user orelse return));
        if (!self.active or page == 0 or page != self.page or self.poisoned) return;
        const name = abi.slice(command) orelse return;
        self.pollBrowser() catch |err| diag.status("vcs-settings-browser-poll", @intFromError(err));
        if (std.mem.eql(u8, name, commands[0])) {
            self.reload();
            return;
        }
        if (!self.loaded or self.pending != 0 or self.picker_request != 0) return;
        for (commands[1..], 1..) |key, index| {
            if (!std.mem.eql(u8, name, key)) continue;
            const result: anyerror!void = switch (index) {
                1...3 => self.saveTool(index - 1),
                4...6 => self.browse(index - 4),
                7 => self.fillCurrent(),
                8 => self.saveProject(),
                9 => blk: {
                    const project = self.selected() catch |err| break :blk err;
                    self.save(&project.key, "", true);
                    break :blk {};
                },
                10 => self.openSelected(),
                11 => self.pollBrowser(),
                else => return,
            };
            result catch |err| {
                self.status = "操作未完成：请检查路径、选择及当前任务状态";
                diag.status("vcs-settings-command", @intFromError(err));
            };
            self.render();
            return;
        }
    }

    pub fn close(self: *Settings) host_mod.Error!void {
        self.active = false;
        if (self.poisoned) return error.State;
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
        self.pages = null;
        self.resources = null;
        self.picker = null;
        self.loaded = false;
    }

    pub fn retireAtHostDestroy(self: *Settings) void {
        // Host stop suppresses resource/picker/UI callbacks and joins tasks.
        self.active = false;
        if (self.browser) |*task| task.retireAtHostDestroy();
        self.browser = null;
        self.panel = null;
        self.page = 0;
        self.pending = 0;
        self.picker_request = 0;
    }
};

extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?*anyopaque, u32) callconv(.winapi) usize;
extern "kernel32" fn GetProcAddress(usize, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(usize) callconv(.winapi) c_int;
const ShellOpen = *const fn (?*anyopaque, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, c_int) callconv(.winapi) usize;
const ComInit = *const fn (?*anyopaque, u32) callconv(.winapi) i32;
const ComUninit = *const fn () callconv(.winapi) void;

fn openWebsite(value: []const u8) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const url = contract.repositoryWebUrl(value) orelse return error.InvalidSettings;
    if (!url.eql(value)) return error.InvalidSettings;
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
