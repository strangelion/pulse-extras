//! Experimental native Companion settings contribution. All SDK calls
//! are on the UI thread. No file/network/process work in this DLL yet.
const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const ui = @import("pulse_ui_model");
const mount = @import("pulse_ui_mount");
const diag = @import("pulse_diagnostics");

const allocator = std.heap.page_allocator;
const title = "Pulse Companion";
const preference = "market.downloadConcurrency";
const Section = enum { library, running, market, global };
const names = [_][]const u8{ "素材库", "运行管理", "在线市场", "全局设置" };
const commands = [_][]const u8{ "companion.library", "companion.running", "companion.market", "companion.global", "companion.settings.refresh", "companion.download.less", "companion.download.more" };

const Instance = struct {
    host: host_mod.Host,
    pages: ?raw.PulseSettingsPagesV1 = null,
    page: u64 = 0,
    panel: ?ui.Panel = null,
    resources: ?raw.PulseResourcesV1 = null,
    pending: u64 = 0,
    subscriptions: [commands.len]u64 = @splat(0),
    section: Section = .library,
    saved: u8 = 4,
    version: u64 = 0,
    loaded: bool = false,
    active: bool = false,
    status: []const u8 = "设置尚未读取",
};

const Content = struct {
    declared: [commands.len]abi.StringView = undefined,
    navigation: [4]ui.Node = undefined,
    children: [7]ui.Node = undefined,
    root: ui.Node = undefined,
    value: [128]u8 = undefined,
};

fn label(id: []const u8, body: []const u8) ui.Node {
    var node = ui.text(body);
    node.id = abi.view(id);
    return node;
}

fn action(id: []const u8, body: []const u8, command: []const u8, enabled: bool) ui.Node {
    var node = ui.button(body, command);
    node.id = abi.view(id);
    node.enabled = .{ .present = 1, .value = @intFromBool(enabled) };
    return node;
}

fn fill(instance: *const Instance, content: *Content, tree: *ui.Tree) void {
    for (commands, 0..) |command, n| content.declared[n] = abi.view(command);
    const selected: usize = @backingInt(instance.section);
    for (names, 0..) |name, n| {
        content.navigation[n] = action(commands[n], name, commands[n], n != selected);
    }
    var navigation = ui.node(ui.NodeKind.stack);
    navigation.id = abi.view("navigation");
    navigation.orientation = .{ .present = 1, .value = abi.view("horizontal") };
    navigation.gap = .{ .present = 1, .value = 6 };
    ui.withChildren(&navigation, &content.navigation);
    content.children[0] = navigation;
    content.children[1] = label("section", names[selected]);
    content.children[1].role = .{ .present = 1, .value = abi.view("section") };
    var count: usize = 3;
    switch (instance.section) {
        .library => content.children[2] = label("library.status", "素材库尚未连接已批准的本地存储。导入、删除、标签与预览暂不可用。"),
        .running => content.children[2] = label("running.status", "运行管理尚未连接宿主进程监督器。当前不显示实例数量或资源统计。"),
        .market => content.children[2] = label("market.status", "市场服务已独立实现，尚未连接宿主工作线程。搜索、下载和安装暂不可用。"),
        .global => {
            const value = if (instance.loaded) std.fmt.bufPrint(&content.value, "已保存的下载并发偏好：{d}（1–8）", .{instance.saved}) catch unreachable else "下载并发偏好尚未确认";
            content.children[2] = label("settings.value", value);
            content.children[3] = label("settings.status", instance.status);
            content.children[4] = action("settings.refresh", "重新读取设置", commands[4], instance.resources != null and instance.pending == 0);
            content.children[5] = action("settings.less", "减少并发", commands[5], instance.loaded and instance.pending == 0 and instance.saved > 1);
            content.children[6] = action("settings.more", "增加并发", commands[6], instance.loaded and instance.pending == 0 and instance.saved < 8);
            count = 7;
        },
    }
    content.root = ui.node(ui.NodeKind.stack);
    content.root.id = abi.view("companion.root");
    content.root.gap = .{ .present = 1, .value = 8 };
    ui.withChildren(&content.root, content.children[0..count]);
    tree.* = std.mem.zeroes(ui.Tree);
    tree.size = @sizeOf(ui.Tree);
    tree.root = &content.root;
    tree.commands = &content.declared;
    tree.command_count = content.declared.len;
}

fn refresh(instance: *Instance) void {
    if (instance.panel) |*panel| {
        var content: Content = undefined;
        var tree: ui.Tree = undefined;
        fill(instance, &content, &tree);
        panel.update(&tree) catch |err| diag.status("companion-update-failed", @intFromError(err));
    }
}

fn readPreference(settings: raw.PulseSettings) !u8 {
    if (settings.version > (1 << 53) - 1 or settings.count > 1024 or (settings.count != 0 and settings.values == null)) return error.InvalidSettings;
    var found: ?u8 = null;
    for (0..settings.count) |n| {
        const pair = settings.values[n];
        const key = abi.slice(pair.key) orelse continue;
        if (!std.mem.eql(u8, key, preference)) continue;
        if (found != null) return error.InvalidSettings;
        const value = abi.slice(pair.value) orelse return error.InvalidSettings;
        if (value.len != 1 or value[0] < '1' or value[0] > '8') return error.InvalidSettings;
        found = value[0] - '0';
    }
    return found orelse 4;
}

fn completed(user: ?*anyopaque, reply: [*c]const raw.PulseResourcesReply) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (reply == null or reply[0].size < @sizeOf(raw.PulseResourcesReply) or instance.pending == 0 or reply[0].request_id != instance.pending) return;
    instance.pending = 0;
    instance.loaded = false;
    if (!instance.active) return;
    const value = &reply[0];
    if (value.status != abi.ok) {
        instance.status = "设置读取或写入失败；请重新读取（可能存在版本冲突）";
    } else if (readPreference(value.settings)) |saved| {
        instance.saved = saved;
        instance.version = value.settings.version;
        instance.loaded = true;
        instance.status = "偏好已确认保存；尚未连接实际下载运行时";
    } else |_| {
        instance.status = "宿主设置数据无效；未覆盖原有设置";
    }
    refresh(instance);
}

fn load(instance: *Instance) void {
    const resources = instance.resources orelse return;
    if (instance.pending != 0) return;
    const get = resources.settings_get orelse return;
    var request: u64 = 0;
    const status = get(resources.context, completed, instance, &request);
    instance.loaded = false;
    if (status == abi.ok and request != 0) {
        instance.pending = request;
        instance.status = "正在读取设置";
    } else {
        instance.status = "无法读取宿主设置";
    }
    refresh(instance);
}

fn save(instance: *Instance, next: u8) void {
    const resources = instance.resources orelse return;
    if (!instance.loaded or instance.pending != 0 or next < 1 or next > 8) return;
    const set = resources.settings_set orelse return;
    const value = [_]u8{'0' + next};
    var request: u64 = 0;
    const status = set(resources.context, abi.view(preference), abi.view(&value), 0, instance.version, completed, instance, &request);
    if (status == abi.ok and request != 0) {
        instance.pending = request;
        instance.status = "正在保存设置";
    } else {
        instance.loaded = false;
        instance.status = "保存请求被拒绝；请重新读取";
    }
    refresh(instance);
}

fn onCommand(user: ?*anyopaque, panel: u64, command: abi.StringView) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!instance.active or panel != instance.page) return;
    const name = abi.slice(command) orelse return;
    for (commands, 0..) |candidate, n| {
        if (!std.mem.eql(u8, candidate, name)) continue;
        switch (n) {
            0, 1, 2, 3 => {
                instance.section = @enumFromInt(n);
                refresh(instance);
            },
            4 => load(instance),
            5 => if (instance.saved > 1) save(instance, instance.saved - 1),
            6 => if (instance.saved < 8) save(instance, instance.saved + 1),
            else => {},
        }
        return;
    }
}

fn close(instance: *Instance) host_mod.Error!void {
    instance.active = false;
    if (instance.pending != 0) {
        const resources = instance.resources orelse return error.State;
        const cancel = resources.cancel_request orelse return error.Unavailable;
        host_mod.mapStatus(cancel(resources.context, instance.pending)) catch |err| switch (err) {
            error.State => {},
            else => return err,
        };
        instance.pending = 0;
    }
    if (instance.page != 0) {
        if (instance.pages) |pages| {
            const remove = pages.remove orelse return error.Unavailable;
            host_mod.mapStatus(remove(pages.context, instance.page)) catch |err| switch (err) {
                error.State => {},
                else => return err,
            };
        } else if (instance.panel) |*panel| {
            try panel.close();
        }
    }
    instance.page = 0;
    instance.panel = null;
    instance.pages = null;
    instance.subscriptions = @splat(0);
    instance.resources = null;
    instance.loaded = false;
}

fn open(instance: *Instance) host_mod.Error!void {
    if (instance.page != 0) return error.State;
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    fill(instance, &content, &tree);
    instance.pages = try instance.host.queryOptional(raw.PulseSettingsPagesV1, raw.PULSE_SETTINGS_PAGES_INTERFACE_NAME, raw.PULSE_SETTINGS_PAGES_VERSION_1);
    errdefer close(instance) catch |err| diag.status("companion-open-cleanup", @intFromError(err));
    if (instance.pages) |pages| {
        const create = pages.create orelse return error.Unavailable;
        const query = pages.query orelse return error.Unavailable;
        _ = pages.remove orelse return error.Unavailable;
        try host_mod.mapStatus(create(pages.context, abi.view(title), &tree, &instance.page));
        if (instance.page == 0) return error.State;
        var table = std.mem.zeroes(ui.TableV1);
        try host_mod.mapStatus(query(pages.context, instance.page, abi.view(ui.interface_name), ui.version_1, &table, @sizeOf(ui.TableV1)));
        if (table.size < @sizeOf(ui.TableV1) or table.version < ui.version_1) return error.Abi;
        instance.panel = .{ .table = table, .id = instance.page };
    } else {
        instance.panel = try ui.Panel.open(instance.host, title, &tree);
        instance.page = instance.panel.?.id;
        if (mount.Mount.init(instance.host)) |placement| {
            placement.request(instance.page, .workspace) catch |err| diag.status("companion-mount-refused", @intFromError(err));
        } else |err| diag.status("companion-mount-unavailable", @intFromError(err));
    }
    if (instance.panel) |*panel| {
        for (commands, 0..) |command, n| instance.subscriptions[n] = try panel.subscribeCommand(command, onCommand, instance);
    }
    instance.resources = try instance.host.queryOptional(raw.PulseResourcesV1, raw.PULSE_RESOURCES_INTERFACE_NAME, raw.PULSE_RESOURCES_VERSION_1);
    if (instance.resources) |resources| {
        if (resources.settings_get == null or resources.settings_set == null or resources.cancel_request == null) instance.resources = null;
    }
    instance.active = true;
    if (instance.resources != null) load(instance) else instance.status = "宿主设置接口不可用";
}

fn activate(user: ?*anyopaque) callconv(.c) abi.Status {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return abi.error_argument));
    open(instance) catch |err| {
        diag.status("companion-activate-failed", @intFromError(err));
        return abi.error_initialization;
    };
    return abi.ok;
}

fn deactivate(user: ?*anyopaque) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    close(instance) catch |err| diag.status("companion-deactivate-failed", @intFromError(err));
}

fn destroy(user: ?*anyopaque) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    close(instance) catch |err| {
        diag.status("companion-destroy-failed", @intFromError(err));
        return;
    };
    allocator.destroy(instance);
}

export fn PulsePluginSdkPreview() callconv(.c) u32 {
    return abi.sdk_preview;
}

export fn PulsePluginEntryV1(host_ptr: ?*const abi.HostV1, out_ptr: ?*abi.PluginV1) callconv(.c) abi.Status {
    const host = host_ptr orelse return abi.error_abi;
    const out = out_ptr orelse return abi.error_abi;
    if (host.size < @sizeOf(abi.HostV1) or out.size < @sizeOf(abi.PluginV1) or host.version != abi.abi_version or out.version != abi.abi_version) return abi.error_abi;
    const validated = host_mod.Host.init(host) catch return abi.error_unavailable;
    const instance = allocator.create(Instance) catch return abi.error_initialization;
    instance.* = .{ .host = validated };
    out.* = .{ .size = @sizeOf(abi.PluginV1), .version = abi.abi_version, .instance = instance, .activate = activate, .deactivate = deactivate, .destroy = destroy };
    return abi.ok;
}

test "settings preference validates exact value and duplicate keys" {
    var values = [_]raw.PulseSetting{ .{ .key = abi.view(preference), .value = abi.view("8") }, .{ .key = abi.view(preference), .value = abi.view("3") } };
    try std.testing.expectEqual(@as(u8, 4), try readPreference(.{}));
    try std.testing.expectEqual(@as(u8, 8), try readPreference(.{ .values = &values, .count = 1 }));
    try std.testing.expectError(error.InvalidSettings, readPreference(.{ .values = &values, .count = 2 }));
    values[0].value = abi.view("9");
    try std.testing.expectError(error.InvalidSettings, readPreference(.{ .values = &values, .count = 1 }));
}

test "four section tree declares only real navigation and preference actions" {
    var instance: Instance = .{ .host = undefined };
    var content: Content = undefined;
    var tree: ui.Tree = undefined;
    for (0..names.len) |n| {
        instance.section = @enumFromInt(n);
        fill(&instance, &content, &tree);
        try std.testing.expectEqual(@as(u32, commands.len), tree.command_count);
        try std.testing.expectEqual(@as(u32, 4), content.children[0].children.count);
        try std.testing.expectEqual(@as(u32, if (instance.section == .global) 7 else 3), content.root.children.count);
    }
    try std.testing.expectEqual(@as(u32, 0), content.children[6].enabled.value);
}
