//! Experimental native Share panel and host-owned managed tasks.

const std = @import("std");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const commands = @import("pulse_commands");
const context = @import("pulse_context");
const ui = @import("pulse_ui_model");
const diag = @import("pulse_diagnostics");

const raw = @import("pulse_raw");
const async_host = @import("pulse_async_host");
const managed = @import("managed.zig");
const allocator = std.heap.page_allocator;
const command_names = [_][]const u8{ "share-discover", "share-send", "share-receive", "share-refresh", "share-cancel" };
const field_names = [_][]const u8{ "bind", "peer", "store", "paired", "destination", "spool", "port" };
const field_labels = [_][]const u8{ "本机 IP / Local IP", "对端 IP:端口 / Peer", "设备存储目录 / Store", "已配对设备 / Peer label", "接收目录 / Destination", "私有暂存目录 / Spool", "监听端口 / Port" };

const Instance = struct {
    host: host_mod.Host,
    menu: ?commands.Table = null,
    command_id: commands.CommandId = 0,
    panel: ?ui.Panel = null,
    task: ?async_host.Task = null,
    request: managed.Request = .{},
    selected: managed.Field = .{},
    active: bool = false,

    fn close(self: *Instance) host_mod.Error!void {
        if (self.panel) |*panel| {
            try panel.close();
            self.panel = null;
        }
    }

    fn status(self: *Instance, message: []const u8) void {
        if (self.panel) |*panel| {
            const states = [_]ui.State{.{ .key = abi.view("status"), .value = abi.view(message) }};
            panel.setStates(&states) catch |err| diag.status("share-status", @intFromError(err));
        }
    }

    fn refresh(self: *Instance) void {
        if (self.task) |*task| {
            if (!task.occupied()) return self.status("空闲 / Idle");
            const state = task.poll() catch return self.status("任务状态不可用 / Task state unavailable");
            switch (state) {
                .running => self.status("运行中 / Running — see separate console"),
                .cancelling => self.status("正在取消 / Cancelling"),
                .completed => self.status("完成 / Completed"),
                .cancelled => self.status("已取消 / Cancelled"),
                .failed, .partial => self.status("失败或结果不确定 / Failed or uncertain — inspect task details"),
            }
            if (state.terminal()) task.releaseTerminal() catch {
                self.status("终态任务尚未释放 / Terminal task not released");
            };
        } else self.status("空闲 / Idle");
    }

    fn readField(self: *Instance, key: []const u8, field: *managed.Field) host_mod.Error!void {
        const panel = self.panel orelse return error.State;
        const read = panel.table.get_state orelse return error.Unavailable;
        var bytes: [2048]u8 = undefined;
        var needed: u32 = 0;
        try host_mod.mapStatus(read(panel.table.context, panel.id, abi.view(key), &bytes, bytes.len, &needed));
        if (needed >= bytes.len) return error.Argument;
        field.set(bytes[0..needed]) catch return error.Argument;
    }

    fn start(self: *Instance, mode: managed.Mode) host_mod.Error!void {
        if (!self.active or !managed.configured()) return error.Unavailable;
        if (self.task) |*task| {
            if (task.occupied()) return error.State;
        } else {
            self.task = try async_host.Task.init(try async_host.taskTable(self.host));
        }
        var next: managed.Request = .{ .mode = mode };
        try self.readField("bind", &next.bind);
        if (mode != .discover) {
            try self.readField("store", &next.store);
            try self.readField("paired", &next.paired);
        }
        if (mode == .send) {
            next.source = self.selected;
            try self.readField("peer", &next.peer);
        }
        if (mode == .receive) {
            try self.readField("destination", &next.destination);
            try self.readField("spool", &next.spool);
            try self.readField("port", &next.port);
        }
        next.validate() catch return error.Argument;
        self.request = next;
        var descriptor = std.mem.zeroes(raw.PulseTaskDescriptor);
        descriptor.size = @sizeOf(raw.PulseTaskDescriptor);
        descriptor.title = abi.view(switch (mode) {
            .discover => "Pulse Share discovery",
            .send => "Pulse Share send selected file",
            .receive => "Pulse Share receive",
        });
        descriptor.type = abi.view("share");
        descriptor.work = &work;
        descriptor.user = self;
        try self.task.?.start(&descriptor);
        self.status("已启动 / Started — review the separate console");
    }

    fn open(self: *Instance, count: ?u32) host_mod.Error!void {
        try self.close();
        var selection_buffer: [96]u8 = undefined;
        const selection = if (count) |n|
            std.fmt.bufPrint(&selection_buffer, "Selected items / 已选中: {d}", .{n}) catch return error.State
        else
            "Selection unavailable / 选中项不可用";
        var children: [17]ui.Node = undefined;
        children[0] = ui.text("Pulse Share / 文件共享");
        children[0].id = abi.view("title");
        children[1] = ui.text(selection);
        children[1].id = abi.view("selection");
        children[2] = ui.text(if (self.selected.len != 0) self.selected.slice() else "请选择一个普通文件以发送 / Select one regular file to send");
        children[2].id = abi.view("source");
        children[3] = ui.text(if (managed.configured()) "使用已配对设备；接收确认在独立控制台 / Saved peers; confirm receives in console" else "未绑定开发版 Worker 摘要 / Development worker digests not configured");
        children[3].id = abi.view("notice");
        var states: [8]ui.State = undefined;
        for (field_names, field_labels, 0..) |key, label, i| {
            var node = ui.node(ui.NodeKind.text_input);
            node.id = abi.view(key);
            node.text = .{ .present = 1, .value = abi.view(label) };
            node.state = .{ .present = 1, .value = abi.view(key) };
            children[4 + i] = node;
            states[i] = .{ .key = abi.view(key), .value = abi.view(if (std.mem.eql(u8, key, "port")) "0" else "") };
        }
        var status_node = ui.node(ui.NodeKind.text);
        status_node.id = abi.view("status-line");
        status_node.binding = .{ .present = 1, .value = abi.view("state.status") };
        children[11] = status_node;
        states[7] = .{ .key = abi.view("status"), .value = abi.view("空闲 / Idle") };
        const labels = [_][]const u8{ "发现设备 / Discover", "发送选中文件 / Send", "接收文件 / Receive", "刷新任务 / Refresh", "取消任务 / Cancel" };
        var declared: [command_names.len]abi.StringView = undefined;
        for (command_names, labels, 0..) |name, label, i| {
            declared[i] = abi.view(name);
            children[12 + i] = ui.button(label, name);
            children[12 + i].id = abi.view(name);
        }
        var root = ui.node(ui.NodeKind.stack);
        root.id = abi.view("share-root");
        root.gap = .{ .present = 1, .value = 8 };
        ui.withChildren(&root, &children);
        var tree = std.mem.zeroes(ui.Tree);
        tree.size = @sizeOf(ui.Tree);
        tree.root = &root;
        tree.states = &states;
        tree.state_count = states.len;
        tree.commands = &declared;
        tree.command_count = declared.len;
        self.panel = try ui.Panel.open(self.host, "Pulse Share", &tree);
        for (command_names) |name| {
            _ = self.panel.?.subscribeCommand(name, &onCommand, self) catch |err| {
                self.close() catch |close_err| diag.status("share-panel-close", @intFromError(close_err));
                return err;
            };
        }
        if (self.task != null) self.refresh();
    }
};

fn work(user: ?*anyopaque, context_ptr: [*c]const raw.PulseTaskContext) callconv(.c) raw.PulseTaskState {
    const self: *Instance = @ptrCast(@alignCast(user orelse return 4));
    if (context_ptr == null) return 4;
    const ctx: *const raw.PulseTaskContext = &context_ptr.*;
    var progress = std.mem.zeroes(raw.PulseTaskProgress);
    progress.size = @sizeOf(raw.PulseTaskProgress);
    progress.percent = std.math.maxInt(u32);
    progress.current_item = abi.view("Separate native console / 独立控制台");
    if (ctx.report) |report| _ = report(ctx.context, &progress);
    managed.run(&self.request, ctx) catch |err| {
        progress.@"error" = abi.view(@errorName(err));
        if (ctx.report) |report| _ = report(ctx.context, &progress);
        return if (err == error.Cancelled) 5 else 4;
    };
    return 2;
}

fn onCommand(user: ?*anyopaque, panel_id: u64, command: abi.StringView) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!self.active or self.panel == null or self.panel.?.id != panel_id) return;
    const name = abi.slice(command) orelse return;
    if (std.mem.eql(u8, name, "share-refresh")) return self.refresh();
    if (std.mem.eql(u8, name, "share-cancel")) {
        if (self.task) |*task| {
            task.cancel() catch return self.status("取消请求失败 / Cancel request failed");
            self.status("取消已请求 / Cancellation requested");
        }
        return;
    }
    const mode: managed.Mode = if (std.mem.eql(u8, name, "share-discover"))
        .discover
    else if (std.mem.eql(u8, name, "share-send"))
        .send
    else if (std.mem.eql(u8, name, "share-receive"))
        .receive
    else
        return;
    self.start(mode) catch |err| self.status(@errorName(err));
}

fn invoke(user: ?*anyopaque, _: commands.CommandId, snapshot: [*c]const commands.SelectionSnapshot) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!self.active) return;
    self.selected = .{};
    const count: ?u32 = if (snapshot != null and context.validSelection(snapshot))
        snapshot.*.entry_count
    else
        null;
    if (count == 1 and snapshot.*.entries != null) {
        const entry = &snapshot.*.entries[0];
        if (entry.size >= @sizeOf(context.SelectionEntry) and entry.flags & context.EntryFlag.directory == 0) {
            if (context.entryPath(entry)) |path| self.selected.set(path) catch {};
        }
    }
    self.open(count) catch |err| diag.status("share-panel-open", @intFromError(err));
}

fn statusOf(err: host_mod.Error) abi.Status {
    return switch (err) {
        error.Argument => abi.error_argument,
        error.Abi => abi.error_abi,
        error.Unavailable => abi.error_unavailable,
        error.Initialization => abi.error_initialization,
        error.State => abi.error_state,
        error.Load => abi.error_load,
        error.Entry => abi.error_entry,
        error.Permission => abi.error_permission,
        error.SdkPreview => abi.error_sdk_preview,
        error.Unknown => abi.error_state,
    };
}

fn activate(raw: ?*anyopaque) callconv(.c) abi.Status {
    const self: *Instance = @ptrCast(@alignCast(raw orelse return abi.error_argument));
    self.active = true;
    return abi.ok;
}

fn deactivate(raw: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(raw orelse return));
    self.active = false;
    if (self.task) |*task| task.cancel() catch |err| diag.status("share-cancel", @intFromError(err));
    self.close() catch |err| diag.status("share-panel-close", @intFromError(err));
}

fn destroy(raw: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(raw orelse return));
    self.active = false;
    if (self.menu) |table| {
        if (self.command_id != 0) {
            table.unregister(self.command_id) catch |err| switch (err) {
                error.State => {},
                else => {
                    diag.status("share-command-unregister", @intFromError(err));
                    // Retain userdata if the host refuses to release callbacks.
                    return;
                },
            };
            self.command_id = 0;
        }
    }
    self.close() catch |err| {
        diag.status("share-destroy-close", @intFromError(err));
        return;
    };
    if (self.task) |*task| task.retireAtHostDestroy();
    allocator.destroy(self);
}

export fn PulsePluginSdkPreview() callconv(.c) u32 {
    return abi.sdk_preview;
}

export fn PulsePluginEntryV1(host_ptr: ?*const abi.HostV1, out_ptr: ?*abi.PluginV1) callconv(.c) abi.Status {
    const host = host_ptr orelse return abi.error_abi;
    const out = out_ptr orelse return abi.error_abi;
    if (host.size < @sizeOf(abi.HostV1) or out.size < @sizeOf(abi.PluginV1)) return abi.error_abi;
    if (host.version != abi.abi_version or out.version != abi.abi_version) return abi.error_abi;
    const validated = host_mod.Host.init(host) catch |err| return statusOf(err);
    const table = commands.Table.init(validated) catch |err| return statusOf(err);
    if (table.raw.unregister_command == null) return abi.error_unavailable;
    const self = allocator.create(Instance) catch return abi.error_initialization;
    self.* = .{ .host = validated, .menu = table };
    var descriptor = commands.descriptor("strangelion.share.open", "Pulse Share / 文件共享", &invoke);
    descriptor.kinds = commands.Kind.files | commands.Kind.directories | commands.Kind.background;
    descriptor.user = self;
    self.command_id = table.register(&descriptor) catch |err| {
        allocator.destroy(self);
        return statusOf(err);
    };
    if (self.command_id == 0) {
        // Invalid host reply: no usable unregister token. Keep userdata inert.
        return abi.error_state;
    }
    out.* = .{
        .size = @sizeOf(abi.PluginV1),
        .version = abi.abi_version,
        .instance = self,
        .activate = activate,
        .deactivate = deactivate,
        .destroy = destroy,
    };
    return abi.ok;
}

test "reject null ABI inputs" {
    try std.testing.expectEqual(abi.error_abi, PulsePluginEntryV1(null, null));
    try std.testing.expectEqual(abi.sdk_preview, PulsePluginSdkPreview());
}
