//! Experimental native Share panel and host-owned managed tasks.

const std = @import("std");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const commands = @import("pulse_commands");
const context = @import("pulse_context");
const ui = @import("pulse_ui_model");
const diag = @import("pulse_diagnostics");

const pulse_raw = @import("pulse_raw");
const async_host = @import("pulse_async_host");
const managed = @import("managed.zig");
const view = @import("presentation.zig");
const prefs = @import("preferences.zig");
const choices = @import("choices.zig");
const pickers = @import("pulse_pickers");
const allocator = std.heap.page_allocator;
const command_names = [_][]const u8{ "share-discover", "share-send", "share-receive", "share-refresh", "share-cancel", "share-identity-init", "share-identity-show", "share-peer-add", "share-peer-list", "share-peer-revoke", "share-private-init", "share-recovery-list", "share-approve", "share-decline", "share-apply-prefs", "share-receive-advertise", "share-interfaces", "share-spool-init", "share-spool-recovery", "share-use-local", "share-use-peer", "share-use-endpoint", "share-browse-destination", "share-browse-parent", "share-save-prefs" };
const field_names = view.fields;

const Instance = struct {
    host: host_mod.Host,
    menu: ?commands.Table = null,
    command_id: commands.CommandId = 0,
    panel: ?ui.Panel = null,
    task: ?async_host.Task = null,
    settings: prefs.Settings,
    wake: ?async_host.Wake = null,
    draft: [field_names.len]managed.Field = @splat(.{}),
    draft_valid: bool = false,
    last_result: [4096]u8 = @splat(0),
    last_len: usize = 0,
    inventory: [3100]u8 = @splat(0),
    inventory_len: usize = 0,
    history: [2048]u8 = @splat(0),
    history_len: usize = 0,
    recorded_terminal: bool = false,
    local_choices: choices.List = .{},
    endpoint_choices: choices.List = .{},
    peer_choices: choices.List = .{},
    discovery_bind: managed.Field = .{},
    peer_store: managed.Field = .{},
    choices_dirty: bool = false,
    choices_ready: bool = false,
    selection_count: ?u32 = null,
    picker: ?pickers.Table = null,
    picker_request: u64 = 0,
    picker_panel: u64 = 0,
    picker_parent: bool = false,
    picker_poisoned: bool = false,
    request: managed.Request = .{},
    decisions: managed.Decisions = .{},
    shown_prompt: u32 = 0,
    selected: managed.Field = .{},
    active: bool = false,

    fn close(self: *Instance) host_mod.Error!void {
        self.shown_prompt = 0;
        if (self.picker_request != 0) {
            const picker = self.picker orelse return error.State;
            const cancel = picker.cancel orelse return error.Unavailable;
            try host_mod.mapStatus(cancel(picker.context, self.picker_request));
            self.picker_request = 0;
        }
        if (self.picker_poisoned) return error.State;
        if (self.panel) |*panel| {
            // Save draft inputs only if all reads succeed; no trust is created.
            var next: [field_names.len]managed.Field = @splat(.{});
            var valid = true;
            for (field_names, 0..) |key, i| {
                self.readField(key, &next[i]) catch {
                    valid = false;
                    break;
                };
            }
            if (valid) {
                self.draft = next;
                self.draft_valid = true;
            }
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

    const Snapshot = struct {
        text: [4096]u8 = undefined,
        len: usize = 0,
        done: u64 = 0,
        total: u64 = 0,
        fn capture(user: ?*anyopaque, snap: [*c]const pulse_raw.PulseTaskSnapshot) callconv(.c) void {
            const self: *Snapshot = @ptrCast(@alignCast(user orelse return));
            if (snap == null or snap.*.size < @sizeOf(pulse_raw.PulseTaskSnapshot)) return;
            const v = snap.*.progress.current_item;
            if (v.length > self.text.len) return;
            const value = abi.slice(v) orelse return;
            @memcpy(self.text[0..value.len], value);
            self.len = value.len;
            self.done = snap.*.progress.completed_bytes;
            self.total = snap.*.progress.total_bytes;
        }
    };

    fn rememberTerminal(self: *Instance, state: async_host.TaskState, message: []const u8) void {
        if (self.recorded_terminal) return;
        self.recorded_terminal = true;
        if (state == .completed) {
            switch (self.request.mode) {
                .interfaces => {
                    self.local_choices = choices.parse(.local, message);
                    self.choices_dirty = true;
                },
                .discover => {
                    self.endpoint_choices = choices.parse(.endpoint, message);
                    self.discovery_bind = self.request.bind;
                    self.choices_dirty = true;
                },
                .peer_list => {
                    self.peer_choices = choices.parse(.peer, message);
                    self.peer_store = self.request.store;
                    self.choices_dirty = true;
                },
                .peer_add, .peer_revoke => {
                    self.peer_choices = .{};
                    self.choices_dirty = true;
                },
                else => {},
            }
        }
        if (state != .completed) {
            switch (self.request.mode) {
                .interfaces => {
                    self.local_choices = .{};
                    self.choices_dirty = true;
                },
                .discover => {
                    self.endpoint_choices = .{};
                    self.choices_dirty = true;
                },
                .peer_list, .peer_add, .peer_revoke => {
                    self.peer_choices = .{};
                    self.choices_dirty = true;
                },
                else => {},
            }
        }
        if (self.request.mode == .interfaces or self.request.mode == .discover or self.request.mode == .peer_list or self.request.mode == .recovery_list) {
            self.inventory_len = @min(message.len, self.inventory.len);
            // Child output has already been checked as UTF-8; avoid splitting a character.
            while (self.inventory_len > 0 and !std.unicode.utf8ValidateSlice(message[0..self.inventory_len])) self.inventory_len -= 1;
            @memcpy(self.inventory[0..self.inventory_len], message[0..self.inventory_len]);
        }
        if (self.request.mode != .send and self.request.mode != .receive) return;
        var line: [256]u8 = undefined;
        const record = std.fmt.bufPrint(&line, "{s} · {s} · {s}\n", .{
            if (self.request.mode == .send) "发送" else "接收",
            self.request.paired.slice(),
            switch (state) {
                .completed => "完成",
                .cancelled => "已取消",
                else => "失败或结果不确定",
            },
        }) catch return;
        // Keep only a bounded, session-local history; do not persist paths.
        if (record.len + self.history_len > self.history.len) {
            const remove = std.mem.indexOfScalar(u8, self.history[0..self.history_len], '\n') orelse self.history_len;
            const count = @min(remove + 1, self.history_len);
            std.mem.copyForwards(u8, self.history[0 .. self.history_len - count], self.history[count..self.history_len]);
            self.history_len -= count;
        }
        if (record.len + self.history_len <= self.history.len) {
            @memcpy(self.history[self.history_len..][0..record.len], record);
            self.history_len += record.len;
        }
    }

    fn refresh(self: *Instance) void {
        if (self.wake) |*wake| wake.reap();
        self.shown_prompt = 0;
        if (self.task) |*task| {
            if (!task.occupied()) return self.updateChoices();
            const state = task.poll() catch return self.status("任务状态不可用 / Task state unavailable");
            var snap: Snapshot = .{};
            const get = task.table.get orelse return;
            host_mod.mapStatus(get(task.table.context, task.id, &Snapshot.capture, &snap)) catch return self.status("任务详情不可用");
            const value = snap.text[0..snap.len];
            const prefix: []const u8 = switch (state) {
                .running => "运行中",
                .cancelling => "正在取消",
                .completed => "完成",
                .cancelled => "已取消",
                .failed, .partial => "失败或结果不确定",
            };
            var buffer: [4300]u8 = undefined;
            const detail = std.fmt.bufPrint(&buffer, "{s}\n{s}", .{ prefix, value }) catch prefix;
            if (state.terminal()) {
                self.rememberTerminal(state, value);
                self.last_len = @min(detail.len, self.last_result.len);
                while (self.last_len > 0 and !std.unicode.utf8ValidateSlice(detail[0..self.last_len])) self.last_len -= 1;
                @memcpy(self.last_result[0..self.last_len], detail[0..self.last_len]);
            }
            const panel = if (self.panel) |*p| p else {
                if (state.terminal()) task.releaseTerminal() catch {};
                return;
            };
            var percent_buf: [4]u8 = undefined;
            const percent = if (snap.total != 0 and snap.done <= snap.total)
                @as(u32, @intCast(@as(u128, snap.done) * 100 / snap.total))
            else
                0;
            const progress = std.fmt.bufPrint(&percent_buf, "{d}", .{percent}) catch "0";
            var bytes_buf: [128]u8 = undefined;
            const bytes_text = std.fmt.bufPrint(&bytes_buf, "{d} / {d} 字节", .{ snap.done, snap.total }) catch "";
            var generation: u32 = 0;
            if (state == .running and !task.cancellation_requested and std.mem.startsWith(u8, value, "PROMPT ")) {
                if (std.mem.indexOfScalar(u8, value[7..], ' ')) |stop| {
                    generation = std.fmt.parseInt(u32, value[7..][0..stop], 10) catch 0;
                    if (generation > 16 or self.decisions.answer.load(.acquire) / 2 == generation) generation = 0;
                }
            }
            const states = [_]ui.State{
                .{ .key = abi.view("status"), .value = abi.view(detail) },
                .{ .key = abi.view("progress"), .value = abi.view(progress) },
                .{ .key = abi.view("bytes"), .value = abi.view(bytes_text) },
                .{ .key = abi.view("busy"), .value = abi.view(if (state.terminal()) "false" else "true") },
                .{ .key = abi.view("idle"), .value = abi.view(if (state.terminal() and managed.configured()) "true" else "false") },
                .{ .key = abi.view("confirm"), .value = abi.view(if (generation != 0) "true" else "false") },
                .{ .key = abi.view("inventory"), .value = abi.view(if (self.inventory_len != 0) self.inventory[0..self.inventory_len] else "尚未读取设备或目录信息") },
                .{ .key = abi.view("history"), .value = abi.view(if (self.history_len != 0) self.history[0..self.history_len] else "本次会话尚无传输记录") },
            };
            panel.setStates(&states) catch return;
            self.shown_prompt = generation;
            if (state.terminal()) {
                task.releaseTerminal() catch {
                    self.status("终态任务尚未释放；请重试刷新");
                    return;
                };
                self.updateChoices();
            }
        }
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

    fn start(self: *Instance, mode: managed.Mode, advertise: bool, use_spool: bool) host_mod.Error!void {
        if (!self.active or !managed.configured()) return error.Unavailable;
        if (self.picker_request != 0 or self.picker_poisoned) return error.State;
        if (self.task) |*task| {
            if (task.occupied()) return error.State;
        } else {
            self.task = try async_host.Task.init(try async_host.taskTable(self.host));
        }
        var next: managed.Request = .{ .mode = mode, .advertise = advertise };
        switch (mode) {
            .discover, .send, .receive => try self.readField("bind", &next.bind),
            else => {},
        }
        if (mode != .discover and mode != .interfaces) try self.readField(if (use_spool) "spool" else "store", &next.store);
        switch (mode) {
            .send, .receive, .peer_add, .peer_revoke => try self.readField("paired", &next.paired),
            else => {},
        }
        if (mode == .peer_add) try self.readField("fingerprint", &next.fingerprint);
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
        self.recorded_terminal = false;
        self.shown_prompt = 0;
        self.decisions.answer.store(0, .release);
        var descriptor = std.mem.zeroes(pulse_raw.PulseTaskDescriptor);
        descriptor.size = @sizeOf(pulse_raw.PulseTaskDescriptor);
        descriptor.title = abi.view(switch (mode) {
            .discover => "Pulse Share discovery",
            .send => "Pulse Share send selected file",
            .receive => "Pulse Share receive",
            else => "Pulse Share device management",
        });
        descriptor.type = abi.view("share");
        descriptor.work = &work;
        descriptor.user = self;
        try self.task.?.start(&descriptor);
        if (self.panel) |*panel| {
            const states = [_]ui.State{
                .{ .key = abi.view("status"), .value = abi.view("任务已启动，等待结果") },
                .{ .key = abi.view("idle"), .value = abi.view("false") },
                .{ .key = abi.view("busy"), .value = abi.view("true") },
                .{ .key = abi.view("confirm"), .value = abi.view("false") },
                .{ .key = abi.view("progress"), .value = abi.view("0") },
                .{ .key = abi.view("bytes"), .value = abi.view("") },
            };
            panel.setStates(&states) catch |err| diag.status("share-task-state", @intFromError(err));
        }
        self.refresh();
    }

    fn savePreferences(self: *Instance) void {
        if (self.picker_request != 0 or self.picker_poisoned) return self.status("请先结束目录选择");
        if (self.task) |*task| {
            if (task.occupied()) return self.status("请先结束当前任务");
        }
        var values: prefs.Values = .{};
        for (prefs.indices, 0..) |index, n| {
            self.readField(field_names[index], &values.fields[n]) catch return self.status("读取配置失败");
        }
        self.settings.saveValues(&values) catch return self.status("无法提交设置；请检查长度、端口或在扩展设置中重新读取");
        self.status("已提交保存请求；请在扩展设置页查看宿主确认结果");
    }

    fn applyPreferences(self: *Instance) void {
        if (!self.settings.loaded) return self.status("常用设置尚未读取，请先在扩展设置中重新读取");
        const panel = if (self.panel) |*p| p else return;
        const indices = [_]usize{ 0, 2, 4, 5, 6 };
        var states: [indices.len]ui.State = undefined;
        for (indices, 0..) |index, n| states[n] = .{ .key = abi.view(field_names[index]), .value = abi.view(self.settings.saved.value(index)) };
        panel.setStates(&states) catch return self.status("无法应用设置");
        self.status("已应用默认值；请核对本次操作");
    }

    fn open(self: *Instance, count: ?u32) host_mod.Error!void {
        try self.close();
        self.selection_count = count;
        try self.render(false);
        if (self.task != null) self.refresh();
    }

    fn updateChoices(self: *Instance) void {
        if (!self.choices_dirty or self.panel == null) return;
        self.choices_ready = false;
        const panel = if (self.panel) |*p| p else return;
        const reset = [_]ui.State{
            .{ .key = abi.view("local-choice"), .value = abi.view("0") },
            .{ .key = abi.view("endpoint-choice"), .value = abi.view("0") },
            .{ .key = abi.view("peer-choice"), .value = abi.view("0") },
        };
        panel.setStates(&reset) catch return self.status("无法重置设备选项，请重新打开面板");
        self.render(true) catch return self.status("无法更新设备选项，请重新打开面板");
    }

    fn applyChoice(self: *Instance, kind: choices.Kind) void {
        if (self.picker_request != 0 or self.picker_poisoned) return self.status("请先结束目录选择");
        if (!self.choices_ready or self.choices_dirty) return self.status("请先查询设备或重新打开面板");
        if (self.task) |*task| {
            if (task.occupied()) return self.status("请先结束当前任务");
        }
        const key: []const u8 = switch (kind) {
            .local => "local-choice",
            .endpoint => "endpoint-choice",
            .peer => "peer-choice",
        };
        var field: managed.Field = .{};
        self.readField(key, &field) catch return self.status("无法读取选择");
        const index = std.fmt.parseInt(usize, field.slice(), 10) catch return self.status("无效选项");
        const list = switch (kind) {
            .local => &self.local_choices,
            .endpoint => &self.endpoint_choices,
            .peer => &self.peer_choices,
        };
        const value = list.selected(index) orelse return self.status("请选择有效条目");
        if (kind == .endpoint) {
            self.readField("bind", &field) catch return self.status("本机地址无效");
            if (!std.mem.eql(u8, field.slice(), self.discovery_bind.slice())) return self.status("本机地址已改变，请重新发现");
        }
        if (kind == .peer) {
            self.readField("store", &field) catch return self.status("身份目录无效");
            if (!std.mem.eql(u8, field.slice(), self.peer_store.slice())) return self.status("身份目录已改变，请重新查询配对");
        }
        const target: []const u8 = switch (kind) {
            .local => "bind",
            .endpoint => "peer",
            .peer => "paired",
        };
        const panel = if (self.panel) |*p| p else return;
        const states = [_]ui.State{.{ .key = abi.view(target), .value = abi.view(value) }};
        panel.setStates(&states) catch return self.status("无法应用选项");
        self.status("已填入选项；请核对后再操作。发现结果不代表信任。");
    }

    fn pickerCompleted(user: ?*anyopaque, result: [*c]const pickers.Result) callconv(.c) void {
        const self: *Instance = @ptrCast(@alignCast(user orelse return));
        if (result == null or result.*.size < @sizeOf(pickers.Result) or self.picker_request == 0 or result.*.request_id != self.picker_request) return;
        self.picker_request = 0;
        if (!self.active or self.panel == null or self.panel.?.id != self.picker_panel) return;
        if (result.*.outcome != pickers.accepted or result.*.path_count != 1 or result.*.paths == null) return self.status("未选择目录");
        const path = abi.slice(result.*.paths[0]) orelse return self.status("目录结果无效");
        var checked: managed.Field = .{};
        checked.set(path) catch return self.status("目录过长或格式无效");
        if (path.len < 3 or path[1] != ':' or path[2] != '\\' or !std.ascii.isAlphabetic(path[0])) return self.status("请选择本机绝对目录");
        const panel = if (self.panel) |*p| p else return;
        if (self.picker_parent) {
            var store: [2048]u8 = undefined;
            var spool: [2048]u8 = undefined;
            const parent = std.mem.trimEnd(u8, path, "\\/");
            const store_path = std.fmt.bufPrint(&store, "{s}\\PulseShare-identity", .{parent}) catch return self.status("路径过长");
            const spool_path = std.fmt.bufPrint(&spool, "{s}\\PulseShare-spool", .{parent}) catch return self.status("路径过长");
            const states = [_]ui.State{
                .{ .key = abi.view("store"), .value = abi.view(store_path) },
                .{ .key = abi.view("spool"), .value = abi.view(spool_path) },
            };
            panel.setStates(&states) catch return self.status("无法填入目录");
            return self.status("已建议两个独立目录；请核对后分别创建，尚未写入磁盘");
        }
        const states = [_]ui.State{.{ .key = abi.view("destination"), .value = abi.view(path) }};
        panel.setStates(&states) catch return self.status("无法填入接收目录");
        self.status("已选接收目录；接收时仍会验证");
    }

    fn browse(self: *Instance, parent: bool) void {
        if (self.picker_request != 0 or self.picker_poisoned) return self.status("已有目录选择请求");
        if (self.task) |*task| {
            if (task.occupied()) return self.status("请先结束当前任务");
        }
        const panel = self.panel orelse return;
        const picker = self.picker orelse return self.status("此宿主未提供目录选择器，可手动填写");
        const pick = picker.pick_folders orelse return self.status("此宿主未提供目录选择器");
        self.picker_panel = panel.id;
        self.picker_parent = parent;
        const request: pickers.Request = .{ .title = abi.view(if (parent) "选择私有目录的父文件夹" else "选择接收目录"), .ok_label = abi.view("选择") };
        var id: u64 = 0;
        host_mod.mapStatus(pick(picker.context, &request, &pickerCompleted, self, &id)) catch return self.status("打开目录选择器失败");
        if (id == 0) {
            self.picker_poisoned = true;
            return self.status("宿主未返回有效请求标识");
        }
        self.picker_request = id;
    }

    fn render(self: *Instance, update: bool) host_mod.Error!void {
        const count = self.selection_count;
        var selection_buffer: [96]u8 = undefined;
        const selection = if (count) |n|
            std.fmt.bufPrint(&selection_buffer, "选中 {d} 项", .{n}) catch return error.State
        else
            "选中项不可用";
        var storage: [field_names.len]view.FieldNodes = @splat(.{});
        var fields: [field_names.len]ui.Node = undefined;
        for (&storage, 0..) |*item, n| fields[n] = item.build(n);
        const discover_actions = [_]ui.Node{
            view.button("本机网络地址", "share-interfaces", "standard", "state.idle"),
            view.button("查找附近设备", "share-discover", "primary", "state.idle"),
            view.button("已配对设备", "share-peer-list", "standard", "state.idle"),
            view.button("显示我的指纹", "share-identity-show", "standard", "state.idle"),
        };
        const pair_actions = [_]ui.Node{
            view.button("添加配对", "share-peer-add", "primary", "state.idle"),
            view.button("撤销配对", "share-peer-revoke", "danger", "state.idle"),
        };
        var local_options: choices.Options = undefined;
        var endpoint_options: choices.Options = undefined;
        var peer_options: choices.Options = undefined;
        const inventory_children = [_]ui.Node{view.bound("inventory-text", "state.inventory")};
        const device_content = [_]ui.Node{
            view.text("discovery-help", "先查看本机网络地址，再填写同一局域网的地址。发现结果不代表设备已受信任。", "body"),
            fields[0],
            view.grid("discovery-actions", &discover_actions),
            view.select("local-options", "local-choice", "可用本机地址", self.local_choices.options(&local_options)),
            view.button("使用所选本机地址", "share-use-local", "standard", "state.idle"),
            view.select("peer-options", "peer-choice", "已配对设备", self.peer_choices.options(&peer_options)),
            view.button("使用所选配对设备", "share-use-peer", "standard", "state.idle"),
            view.group("inventory-group", "最近一次查询", &inventory_children),
            fields[3],
            fields[7],
            view.text("pair-help", "首次配对：通过独立可信渠道核对双方完整指纹；提交后在上方任务区确认。", "caption"),
            view.grid("pair-actions", &pair_actions),
        };
        const transfer_actions = [_]ui.Node{
            view.button("发送选中文件", "share-send", "primary", "state.idle"),
            view.button("接收一次", "share-receive", "standard", "state.idle"),
            view.button("接收并允许发现", "share-receive-advertise", "standard", "state.idle"),
        };
        const transfer_content = [_]ui.Node{
            view.text("selection", selection, "caption"),
            view.text("source", if (self.selected.len != 0) self.selected.slice() else "请从文件列表右键选中一个普通文件进行发送。", "body"),
            view.select("endpoint-options", "endpoint-choice", "发现的未验证地址", self.endpoint_choices.options(&endpoint_options)),
            view.button("使用所选对端地址", "share-use-endpoint", "standard", "state.idle"),
            fields[1],
            view.text("transfer-help", "使用设备页填写的本机地址与已配对设备。接收时仍须核对并批准每个请求。", "caption"),
            view.grid("transfer-actions", &transfer_actions),
        };
        const setup_actions = [_]ui.Node{
            view.button("应用已保存设置", "share-apply-prefs", "standard", "state.idle"),
            view.button("保存当前配置", "share-save-prefs", "primary", "state.idle"),
            view.button("创建身份目录", "share-private-init", "standard", "state.idle"),
            view.button("创建设备身份", "share-identity-init", "primary", "state.idle"),
            view.button("创建暂存目录", "share-spool-init", "standard", "state.idle"),
            view.button("检查暂存残留", "share-spool-recovery", "standard", "state.idle"),
            view.button("检查身份目录残留", "share-recovery-list", "standard", "state.idle"),
        };
        const setup_content = [_]ui.Node{
            view.text("setup-help", "首次使用：填写新的身份目录，创建目录后创建设备身份。接收暂存目录也必须是独立的私有目录。常用设置可在 Pulse 扩展设置页保存。", "body"),
            view.button("选择私有目录的父文件夹", "share-browse-parent", "standard", "state.idle"),
            fields[2],
            fields[4],
            view.button("浏览接收目录", "share-browse-destination", "standard", "state.idle"),
            fields[5],
            fields[6],
            view.grid("setup-actions", &setup_actions),
        };
        const history_content = [_]ui.Node{
            view.text("history-note", "仅记录本次插件会话的传输结果，不保存文件路径。", "caption"),
            view.bound("history-text", "state.history"),
        };
        const tabs_children = [_]ui.Node{
            view.tab("devices-tab", "设备", &device_content),
            view.tab("transfer-tab", "传输", &transfer_content),
            view.tab("history-tab", "记录", &history_content),
            view.tab("setup-tab", "配置", &setup_content),
        };
        var tabs = view.container(ui.NodeKind.tabs, "share-tabs", &tabs_children);
        tabs.state = .{ .present = 1, .value = abi.view("active-tab") };
        var bar = ui.node(ui.NodeKind.progress);
        bar.id = abi.view("transfer-progress");
        bar.binding = .{ .present = 1, .value = abi.view("state.progress") };
        const controls = [_]ui.Node{
            view.button("刷新状态", "share-refresh", "standard", null),
            view.button("取消任务", "share-cancel", "danger", "state.busy"),
            view.button("批准请求", "share-approve", "primary", "state.confirm"),
            view.button("拒绝请求", "share-decline", "standard", "state.confirm"),
        };
        const task_content = [_]ui.Node{
            view.bound("status-line", "state.status"),
            bar,
            view.bound("byte-count", "state.bytes"),
            view.grid("task-controls", &controls),
        };
        const children = [_]ui.Node{
            view.text("share-heading", "局域网文件共享", "section"),
            view.text("share-notice", if (managed.configured()) "仅与明确配对的设备传输；不自动接收或覆盖文件。" else "当前构建未绑定工作进程，传输不可用。", "caption"),
            view.group("task-group", "当前任务", &task_content),
            tabs,
        };
        const root = view.container(ui.NodeKind.stack, "share-root", &children);
        var states: [field_names.len + 12]ui.State = undefined;
        for (field_names, 0..) |key, n| {
            const value = if (self.draft_valid) self.draft[n].slice() else self.settings.saved.value(n);
            states[n] = .{ .key = abi.view(key), .value = abi.view(value) };
        }
        const busy = if (self.task) |*task| task.occupied() else false;
        const extra = [_]ui.State{
            .{ .key = abi.view("status"), .value = abi.view(if (self.last_len != 0) self.last_result[0..self.last_len] else "空闲，等待操作") },
            .{ .key = abi.view("progress"), .value = abi.view("0") },
            .{ .key = abi.view("bytes"), .value = abi.view("") },
            .{ .key = abi.view("idle"), .value = abi.view(if (!busy and managed.configured()) "true" else "false") },
            .{ .key = abi.view("busy"), .value = abi.view(if (busy) "true" else "false") },
            .{ .key = abi.view("confirm"), .value = abi.view("false") },
            .{ .key = abi.view("inventory"), .value = abi.view(if (self.inventory_len != 0) self.inventory[0..self.inventory_len] else "尚未读取设备或目录信息") },
            .{ .key = abi.view("history"), .value = abi.view(if (self.history_len != 0) self.history[0..self.history_len] else "本次会话尚无传输记录") },
        };
        @memcpy(states[field_names.len..][0..extra.len], &extra);
        const selections = [_]ui.State{
            .{ .key = abi.view("local-choice"), .value = abi.view("0") },
            .{ .key = abi.view("endpoint-choice"), .value = abi.view("0") },
            .{ .key = abi.view("peer-choice"), .value = abi.view("0") },
            .{ .key = abi.view("active-tab"), .value = abi.view("0") },
        };
        @memcpy(states[field_names.len + extra.len ..], &selections);
        var declared: [command_names.len]abi.StringView = undefined;
        for (command_names, 0..) |name, n| declared[n] = abi.view(name);
        var tree = std.mem.zeroes(ui.Tree);
        tree.size = @sizeOf(ui.Tree);
        tree.root = &root;
        tree.states = &states;
        tree.state_count = states.len;
        tree.commands = &declared;
        tree.command_count = declared.len;
        if (update) {
            const panel = if (self.panel) |*p| p else return error.State;
            try panel.update(&tree);
            self.choices_dirty = false;
            self.choices_ready = true;
            return;
        }
        self.panel = try ui.Panel.open(self.host, "Pulse Share", &tree);
        self.choices_dirty = false;
        self.choices_ready = true;
        for (command_names) |name| {
            _ = self.panel.?.subscribeCommand(name, &onCommand, self) catch |err| {
                self.close() catch |close_err| diag.status("share-panel-close", @intFromError(close_err));
                return err;
            };
        }
    }
};

fn wakeUI(user: *anyopaque) void {
    const self: *Instance = @ptrCast(@alignCast(user));
    if (self.active) self.refresh();
}

fn work(user: ?*anyopaque, context_ptr: [*c]const pulse_raw.PulseTaskContext) callconv(.c) pulse_raw.PulseTaskState {
    const self: *Instance = @ptrCast(@alignCast(user orelse return 4));
    if (context_ptr == null) return 4;
    const ctx: *const pulse_raw.PulseTaskContext = &context_ptr.*;
    var progress = std.mem.zeroes(pulse_raw.PulseTaskProgress);
    progress.size = @sizeOf(pulse_raw.PulseTaskProgress);
    progress.percent = std.math.maxInt(u32);
    progress.current_item = abi.view("正在准备任务 / Preparing task");
    if (ctx.report) |report| _ = report(ctx.context, &progress);
    managed.run(&self.request, ctx, &self.decisions, if (self.wake) |*wake| wake else null) catch |err| {
        diag.status("share-task-failed", @intFromError(err));
        return if (err == error.Cancelled) 5 else 4;
    };
    return 2;
}

fn onCommand(user: ?*anyopaque, panel_id: u64, command: abi.StringView) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!self.active or self.panel == null or self.panel.?.id != panel_id) return;
    const name = abi.slice(command) orelse return;
    if (std.mem.eql(u8, name, "share-refresh")) return self.refresh();
    if (std.mem.eql(u8, name, "share-apply-prefs")) return self.applyPreferences();
    if (std.mem.eql(u8, name, "share-save-prefs")) return self.savePreferences();
    if (std.mem.eql(u8, name, "share-use-local")) return self.applyChoice(.local);
    if (std.mem.eql(u8, name, "share-use-endpoint")) return self.applyChoice(.endpoint);
    if (std.mem.eql(u8, name, "share-use-peer")) return self.applyChoice(.peer);
    if (std.mem.eql(u8, name, "share-browse-parent")) return self.browse(true);
    if (std.mem.eql(u8, name, "share-browse-destination")) return self.browse(false);
    if (std.mem.eql(u8, name, "share-cancel")) {
        self.shown_prompt = 0;
        if (self.task) |*task| {
            task.cancel() catch return self.status("取消请求失败 / Cancel request failed");
            if (self.panel) |*panel| {
                const states = [_]ui.State{
                    .{ .key = abi.view("confirm"), .value = abi.view("false") },
                    .{ .key = abi.view("status"), .value = abi.view("已请求取消，等待任务结束") },
                };
                panel.setStates(&states) catch |err| diag.status("share-cancel-state", @intFromError(err));
            }
        }
        return;
    }
    if (std.mem.eql(u8, name, "share-approve") or std.mem.eql(u8, name, "share-decline")) {
        if (self.shown_prompt == 0) return self.status("请先刷新并核对当前请求");
        self.decisions.submit(self.shown_prompt, std.mem.eql(u8, name, "share-approve"));
        self.shown_prompt = 0;
        if (self.panel) |*panel| {
            const states = [_]ui.State{
                .{ .key = abi.view("confirm"), .value = abi.view("false") },
                .{ .key = abi.view("status"), .value = abi.view("确认已提交") },
            };
            panel.setStates(&states) catch |err| diag.status("share-confirm", @intFromError(err));
        }
        return;
    }
    const mode: managed.Mode = if (std.mem.eql(u8, name, "share-discover"))
        .discover
    else if (std.mem.eql(u8, name, "share-send"))
        .send
    else if (std.mem.eql(u8, name, "share-receive") or std.mem.eql(u8, name, "share-receive-advertise"))
        .receive
    else if (std.mem.eql(u8, name, "share-interfaces"))
        .interfaces
    else if (std.mem.eql(u8, name, "share-identity-init"))
        .identity_init
    else if (std.mem.eql(u8, name, "share-identity-show"))
        .identity_show
    else if (std.mem.eql(u8, name, "share-peer-add"))
        .peer_add
    else if (std.mem.eql(u8, name, "share-peer-list"))
        .peer_list
    else if (std.mem.eql(u8, name, "share-peer-revoke"))
        .peer_revoke
    else if (std.mem.eql(u8, name, "share-private-init") or std.mem.eql(u8, name, "share-spool-init"))
        .private_init
    else if (std.mem.eql(u8, name, "share-recovery-list") or std.mem.eql(u8, name, "share-spool-recovery"))
        .recovery_list
    else
        return;
    self.start(mode, std.mem.eql(u8, name, "share-receive-advertise"), std.mem.eql(u8, name, "share-spool-init") or std.mem.eql(u8, name, "share-spool-recovery")) catch |err| self.status(switch (err) {
        error.Argument => "参数不完整或无效，请检查设备和配置页",
        error.State => "已有任务，请先刷新或取消",
        error.Unavailable => "当前构建或宿主接口不支持此操作",
        else => @errorName(err),
    });
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
        const entries: [*]const context.SelectionEntry = @ptrCast(snapshot.*.entries);
        const entry = &entries[0];
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
    if (self.wake) |*wake| wake.enabled.store(true, .release);
    self.settings.open() catch |err| diag.status("share-settings-open", @intFromError(err));
    if (self.host.queryOptional(pickers.Table, pickers.name, pickers.version)) |optional| {
        if (optional) |picker| {
            if (picker.pick_folders != null and picker.cancel != null) self.picker = picker;
        }
    } else |_| {}
    return abi.ok;
}

fn deactivate(raw: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(raw orelse return));
    self.active = false;
    if (self.wake) |*wake| wake.disable();
    self.settings.close() catch |err| diag.status("share-settings-close", @intFromError(err));
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
    self.settings.close() catch |err| {
        diag.status("share-settings-destroy", @intFromError(err));
        return;
    };
    if (self.task) |*task| task.retireAtHostDestroy();
    if (self.wake) |*wake| wake.retireAtHostDestroy() catch return;
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
    self.* = .{ .host = validated, .menu = table, .settings = .{ .host = validated } };
    if (async_host.Dispatch.init(validated)) |dispatch| {
        self.wake = async_host.Wake.init(dispatch, &wakeUI, self) catch null;
    } else |_| {}
    var descriptor = commands.descriptor("strangelion.share.open", "Pulse Share / 文件共享", &invoke);
    descriptor.kinds = commands.Kind.files | commands.Kind.directories;
    descriptor.min_selection = 0;
    descriptor.max_selection = 4096;
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
