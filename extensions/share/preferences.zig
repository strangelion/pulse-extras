//! Package-owned preferences. A saved path is a suggestion, not permission.
const std = @import("std");
const abi = @import("pulse_abi");
const raw = @import("pulse_raw");
const host_mod = @import("pulse_host");
const ui = @import("pulse_ui_model");
const managed = @import("managed.zig");
const view = @import("presentation.zig");
const diag = @import("pulse_diagnostics");

const indices = [_]usize{ 0, 2, 4, 5, 6 };
const key = "share.preferences.v1";
const limit = 1024;
const commands = [_][]const u8{ "share-prefs-load", "share-prefs-save" };

pub const Values = struct {
    fields: [indices.len]managed.Field = @splat(.{}),

    pub fn value(self: *const Values, index: usize) []const u8 {
        for (indices, 0..) |n, i| {
            if (n != index) continue;
            const s = self.fields[i].slice();
            return if (index == 6 and s.len == 0) "0" else s;
        }
        return "";
    }

    fn encode(self: *const Values, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "v1\n{s}\n{s}\n{s}\n{s}\n{s}", .{
            self.value(0), self.value(2), self.value(4), self.value(5), self.value(6),
        });
    }

    fn decode(data: []const u8) !Values {
        if (data.len > limit) return error.InvalidSettings;
        var result: Values = .{};
        var lines = std.mem.splitScalar(u8, data, '\n');
        if (!std.mem.eql(u8, lines.next() orelse return error.InvalidSettings, "v1")) return error.InvalidSettings;
        for (&result.fields) |*field| try field.set(lines.next() orelse return error.InvalidSettings);
        if (lines.next() != null) return error.InvalidSettings;
        _ = try std.fmt.parseInt(u16, result.value(6), 10);
        return result;
    }
};

pub const Settings = struct {
    host: host_mod.Host,
    pages: ?raw.PulseSettingsPagesV1 = null,
    resources: ?raw.PulseResourcesV1 = null,
    panel: ?ui.Panel = null,
    page: u64 = 0,
    pending: u64 = 0,
    operation: u32 = 0,
    version: u64 = 0,
    loaded: bool = false,
    active: bool = false,
    poisoned: bool = false,
    saved: Values = .{},

    fn status(self: *Settings, message: []const u8) void {
        if (self.panel) |*p| {
            const states = [_]ui.State{
                .{ .key = abi.view("pref-status"), .value = abi.view(message) },
                .{ .key = abi.view("pref-ready"), .value = abi.view(if (self.loaded and self.pending == 0 and !self.poisoned) "true" else "false") },
            };
            p.setStates(&states) catch |err| diag.status("share-preferences", @intFromError(err));
        }
    }

    pub fn open(self: *Settings) host_mod.Error!void {
        if (self.active) return;
        if (self.page != 0 or self.pending != 0 or self.poisoned) return error.State;
        const pages = try self.host.query(raw.PulseSettingsPagesV1, raw.PULSE_SETTINGS_PAGES_INTERFACE_NAME, raw.PULSE_SETTINGS_PAGES_VERSION_1);
        const resources = try self.host.query(raw.PulseResourcesV1, raw.PULSE_RESOURCES_INTERFACE_NAME, raw.PULSE_RESOURCES_VERSION_1);
        const create = pages.create orelse return error.Unavailable;
        const query = pages.query orelse return error.Unavailable;
        if (pages.remove == null or resources.settings_get == null or resources.settings_set == null or resources.cancel_request == null) return error.Unavailable;
        self.pages = pages;
        self.resources = resources;
        var storage: [indices.len]view.FieldNodes = @splat(.{});
        var fields: [indices.len]ui.Node = undefined;
        var states: [indices.len + 2]ui.State = undefined;
        for (indices, 0..) |index, i| {
            fields[i] = storage[i].build(index);
            states[i] = .{ .key = abi.view(view.fields[index]), .value = abi.view(self.saved.value(index)) };
        }
        states[indices.len] = .{ .key = abi.view("pref-status"), .value = abi.view("正在读取设置") };
        states[indices.len + 1] = .{ .key = abi.view("pref-ready"), .value = abi.view("false") };
        const actions = [_]ui.Node{
            view.button("重新读取", commands[0], "standard", null),
            view.button("保存常用设置", commands[1], "primary", "state.pref-ready"),
        };
        const children = [_]ui.Node{
            view.text("pref-intro", "设备与传输默认值", "section"),
            view.text("pref-help", "保存后在共享面板打开或点击“应用已保存设置”生效。目录仍需实际存在并通过检查；不会自动启动监听。", "body"),
            view.group("pref-fields", "常用设置", &fields),
            view.grid("pref-actions", &actions),
            view.bound("pref-result", "state.pref-status"),
        };
        const root = view.container(ui.NodeKind.stack, "pref-root", &children);
        var declared: [commands.len]abi.StringView = undefined;
        for (commands, 0..) |cmd, i| declared[i] = abi.view(cmd);
        var tree = std.mem.zeroes(ui.Tree);
        tree.size = @sizeOf(ui.Tree);
        tree.root = &root;
        tree.states = &states;
        tree.state_count = states.len;
        tree.commands = &declared;
        tree.command_count = declared.len;
        var page: u64 = 0;
        try host_mod.mapStatus(create(pages.context, abi.view("Share / 文件共享"), &tree, &page));
        if (page == 0) {
            self.poisoned = true;
            return error.State;
        }
        self.page = page;
        errdefer self.close() catch |err| diag.status("share-preferences-close", @intFromError(err));
        var model = std.mem.zeroes(ui.TableV1);
        try host_mod.mapStatus(query(pages.context, page, abi.view(ui.interface_name), ui.version_1, &model, @sizeOf(ui.TableV1)));
        if (model.size < @sizeOf(ui.TableV1) or model.version < ui.version_1 or model.get_state == null or model.set_states == null or model.subscribe_command == null) return error.Unavailable;
        self.panel = .{ .id = page, .table = model };
        for (commands) |cmd| _ = try self.panel.?.subscribeCommand(cmd, &onCommand, self);
        self.active = true;
        self.reload();
    }

    pub fn close(self: *Settings) host_mod.Error!void {
        self.active = false;
        self.loaded = false;
        if (self.pending != 0) {
            const resources = self.resources orelse return error.State;
            const cancel = resources.cancel_request orelse return error.Unavailable;
            try host_mod.mapStatus(cancel(resources.context, self.pending));
            self.pending = 0;
        }
        if (self.page != 0) {
            const pages = self.pages orelse return error.State;
            const remove = pages.remove orelse return error.Unavailable;
            host_mod.mapStatus(remove(pages.context, self.page)) catch |err| switch (err) {
                error.State => {},
                else => return err,
            };
            self.page = 0;
            self.panel = null;
        }
    }

    fn admitted(self: *Settings, result: abi.Status, id: u64, operation: u32) void {
        if (result == abi.ok and id != 0) {
            self.pending = id;
            self.operation = operation;
            self.status("等待宿主确认");
        } else {
            self.loaded = false;
            if (result == abi.ok) self.poisoned = true;
            self.status("设置请求未被接受，请重新读取");
        }
    }

    fn reload(self: *Settings) void {
        if (!self.active or self.pending != 0 or self.poisoned) return;
        const resources = self.resources orelse return;
        var id: u64 = 0;
        const result = resources.settings_get.?(resources.context, &completed, self, &id);
        self.admitted(result, id, raw.PULSE_RESOURCES_SETTINGS_GET);
    }

    fn save(self: *Settings) void {
        if (!self.active or !self.loaded or self.pending != 0 or self.poisoned) return;
        const panel = self.panel orelse return;
        var values: Values = .{};
        for (indices, 0..) |index, i| {
            var bytes: [1025]u8 = undefined;
            var needed: u32 = 0;
            host_mod.mapStatus(panel.table.get_state.?(panel.table.context, panel.id, abi.view(view.fields[index]), &bytes, bytes.len, &needed)) catch return self.status("读取输入失败");
            if (needed >= bytes.len) return self.status("输入过长");
            values.fields[i].set(bytes[0..needed]) catch return self.status("输入格式无效");
        }
        var data: [limit]u8 = undefined;
        const encoded = values.encode(&data) catch return self.status("常用设置总长度超过 1024 字节");
        _ = Values.decode(encoded) catch return self.status("端口须为 0–65535");
        const resources = self.resources orelse return;
        var id: u64 = 0;
        const result = resources.settings_set.?(resources.context, abi.view(key), abi.view(encoded), 0, self.version, &completed, self, &id);
        self.admitted(result, id, raw.PULSE_RESOURCES_SETTINGS_SET);
    }

    fn completed(user: ?*anyopaque, reply: [*c]const raw.PulseResourcesReply) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(user orelse return));
        if (reply == null or reply.*.size < @sizeOf(raw.PulseResourcesReply) or self.pending == 0 or reply.*.request_id != self.pending) return;
        self.pending = 0;
        self.loaded = false;
        if (!self.active) return;
        if (reply.*.status != abi.ok or reply.*.operation != self.operation) return self.status("读取或保存失败；请重新读取，不强制覆盖");
        const snapshot = reply.*.settings;
        if (snapshot.count > 1024 or (snapshot.count != 0 and snapshot.values == null)) return self.status("设置响应无效");
        var values: Values = .{};
        var found = false;
        for (0..snapshot.count) |i| {
            const item = snapshot.values[i];
            if (!std.mem.eql(u8, abi.slice(item.key) orelse return self.status("设置键无效"), key)) continue;
            if (found) return self.status("重复设置记录");
            found = true;
            values = Values.decode(abi.slice(item.value) orelse return self.status("设置值无效")) catch return self.status("设置格式无效，未覆盖");
        }
        self.saved = values;
        self.version = snapshot.version;
        self.loaded = true;
        if (self.panel) |*panel| {
            var states: [indices.len]ui.State = undefined;
            for (indices, 0..) |index, i| states[i] = .{ .key = abi.view(view.fields[index]), .value = abi.view(self.saved.value(index)) };
            panel.setStates(&states) catch {
                self.loaded = false;
                return self.status("设置同步失败");
            };
        }
        self.status(if (self.operation == raw.PULSE_RESOURCES_SETTINGS_SET) "宿主已确认保存" else "已读取常用设置");
    }

    fn onCommand(user: ?*anyopaque, panel_id: u64, command: abi.StringView) callconv(.c) void {
        const self: *Settings = @ptrCast(@alignCast(user orelse return));
        if (!self.active or self.page != panel_id) return;
        const cmd = abi.slice(command) orelse return;
        if (std.mem.eql(u8, cmd, commands[0])) self.reload() else if (std.mem.eql(u8, cmd, commands[1])) self.save();
    }
};

test "preferences roundtrip and malformed data rejected" {
    var values: Values = .{};
    try values.fields[1].set("C:\\中文\\identity");
    try values.fields[4].set("45843");
    var buffer: [limit]u8 = undefined;
    const decoded = try Values.decode(try values.encode(&buffer));
    try std.testing.expectEqualStrings("C:\\中文\\identity", decoded.value(2));
    try std.testing.expectEqualStrings("45843", decoded.value(6));
    try std.testing.expectError(error.InvalidSettings, Values.decode("v2\n"));
    try std.testing.expectError(error.InvalidSettings, Values.decode("v1\n\n\n\n\n0\nextra"));
}
