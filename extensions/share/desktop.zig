//! Share's desktop controller. The window and task thread own their state independently of Pulse.
const std = @import("std");
const abi = @import("pulse_abi");
const ui = @import("pulse_ui_model");
const managed = @import("managed.zig");
const view = @import("presentation.zig");
const prefs = @import("preferences.zig");
const choices = @import("choices.zig");
const native = @import("desktop_panel.zig");
const task_mod = @import("desktop_task.zig");
const handoff = @import("handoff.zig");

extern fn share_desktop_create() c_int;
extern fn share_desktop_run() void;
extern fn share_desktop_finish() void;
extern fn share_desktop_pick(c_int, [*]u8, c_int) c_int;
extern fn share_desktop_preferences_read([*]u8, c_int) c_int;
extern fn share_desktop_preferences_write([*]const u8, c_int) c_int;

const field_names = view.fields;

const Instance = struct {
    panel: ?native.Panel = null,
    task: task_mod.Task = .{},
    saved: prefs.Values = .{},
    inventory: [3100]u8 = @splat(0),
    inventory_len: usize = 0,
    history: [2048]u8 = @splat(0),
    history_len: usize = 0,
    local_choices: choices.List = .{},
    endpoint_choices: choices.List = .{},
    pair_endpoint_choices: choices.List = .{},
    peer_choices: choices.List = .{},
    discovery_bind: managed.Field = .{},
    peer_store: managed.Field = .{},
    selected: managed.Field = .{},
    selected_batch: managed.Field = .{},
    selection_count: u32 = 0,
    shown_prompt: u32 = 0,
    closing: bool = false,
    session_only: bool = false,

    fn set(self: *Instance, key: []const u8, value: []const u8) void {
        if (self.panel) |p| p.setStates(&.{.{ .key = abi.view(key), .value = abi.view(value) }}) catch {};
    }

    fn status(self: *Instance, message: []const u8) void {
        self.set("status", message);
    }

    fn readField(self: *Instance, key: []const u8, field: *managed.Field) !void {
        var buffer: [2048]u8 = undefined;
        const panel = self.panel orelse return error.State;
        try field.set(try panel.read(key, &buffer));
    }

    fn refresh(self: *Instance) void {
        if (!self.task.occupied()) return;
        const terminal = self.task.reap();
        const snap = self.task.poll() orelse return;
        if (self.closing and terminal) return;
        const state = snap.state;
        const message = snap.message();
        var prompt: u32 = 0;
        var useful = message;
        if (std.mem.startsWith(u8, message, "PROMPT ")) {
            if (std.mem.indexOfScalar(u8, message[7..], ' ')) |end| {
                useful = message[end + 8 ..];
                if (state == .running) {
                    prompt = std.fmt.parseInt(u32, message[7..][0..end], 10) catch 0;
                    if (prompt > 16 or self.task.decisions.answer.load(.acquire) / 2 == prompt) prompt = 0;
                }
            }
        }
        self.shown_prompt = prompt;
        self.set("confirm", if (prompt != 0) "true" else "false");
        var detail: [4300]u8 = undefined;
        if (terminal or useful.len != 0 or state == .cancelling) {
            const prefix: []const u8 = switch (state) {
                .completed => "完成",
                .failed => "任务失败",
                .cancelled => "已取消",
                .cancelling => "正在取消",
                .running => if (prompt != 0) "请核对并确认" else "运行中",
            };
            const text = if (useful.len == 0) prefix else std.fmt.bufPrint(&detail, "{s}\r\n{s}", .{ prefix, useful }) catch prefix;
            self.status(text);
        }
        if (snap.total != 0 and snap.done <= snap.total) {
            var count: [72]u8 = undefined;
            var percent: [4]u8 = undefined;
            self.set("bytes", std.fmt.bufPrint(&count, "{d} / {d} 字节", .{ snap.done, snap.total }) catch "");
            self.set("progress", std.fmt.bufPrint(&percent, "{d}", .{@as(u128, snap.done) * 100 / snap.total}) catch "0");
        }
        if (self.task.request.mode == .pair_host) {
            const packed_code = self.task.decisions.display_code.load(.acquire);
            const code: u32 = @truncate(packed_code);
            var value: [80]u8 = undefined;
            defer @memset(&value, 0);
            const pair_code: []const u8 = if (terminal or state == .cancelling or prompt != 0)
                ""
            else if (code == 0)
                "等待生成连接码"
            else
                std.fmt.bufPrint(&value, "{d:0>8}  ·  约 {d} 秒后刷新", .{ code - 1, packed_code >> 32 }) catch "";
            self.set("pair-code", pair_code);
            self.set("pair-help", if (prompt != 0)
                "对端已连接。请核对下方指纹，再确认或拒绝。"
            else if (terminal)
                (if (state == .completed) "配对已完成。可刷新已配对设备列表。" else "配对已结束。请查看下方任务详情。")
            else
                "在另一台设备输入连接码，两边都需确认指纹。");
        }
        if (terminal) {
            self.set("busy", "false");
            self.set("idle", "true");
            self.set("ui-idle", "true");
            self.rememberTerminal(state, message);
        }
    }

    fn applyPreferences(self: *Instance) void {
        for (prefs.indices) |index| self.set(field_names[index], self.saved.value(index));
    }

    fn savePreferences(self: *Instance) void {
        if (self.session_only) return self.status("本次会话的设置仅保留在窗口中。");
        var values: prefs.Values = .{};
        for (prefs.indices, 0..) |index, n| {
            self.readField(field_names[index], &values.fields[n]) catch return self.status("输入无效，未保存设置。");
        }
        var buffer: [prefs.limit]u8 = undefined;
        const encoded = values.encode(&buffer) catch return self.status("设置过长，未保存。");
        _ = prefs.Values.decode(encoded) catch return self.status("请检查端口和通道等设置。");
        if (share_desktop_preferences_write(encoded.ptr, @intCast(encoded.len)) == 0) return self.status("无法写入本机设置。");
        self.saved = values;
        self.status("已保存设置。");
    }

    fn browse(self: *Instance, parent: bool) void {
        var buffer: [2048]u8 = undefined;
        const len = share_desktop_pick(1, &buffer, buffer.len);
        if (len < 0) return self.status("无法读取所选目录。");
        if (len == 0) return;
        const path = buffer[0..@intCast(len)];
        if (parent) {
            const root = std.mem.trimEnd(u8, path, "\\/");
            var store: [2048]u8 = undefined;
            var spool: [2048]u8 = undefined;
            self.set("store", std.fmt.bufPrint(&store, "{s}\\PulseShare-identity", .{root}) catch return self.status("目录太长。"));
            self.set("spool", std.fmt.bufPrint(&spool, "{s}\\PulseShare-spool", .{root}) catch return self.status("目录太长。"));
            self.status("已填入两个独立目录，请确认后创建。");
        } else self.set("destination", path);
    }

    fn pickSource(self: *Instance, folder: bool) void {
        var buffer: [2048]u8 = undefined;
        const len = share_desktop_pick(@intFromBool(folder), &buffer, buffer.len);
        if (len < 0) return self.status("无法读取所选文件或文件夹。");
        if (len == 0) return;
        const path = buffer[0..@intCast(len)];
        self.selected_batch.set(path) catch return self.status("所选路径过长或无效。");
        self.selected = if (folder) .{} else self.selected_batch;
        self.selection_count = 1;
        self.showSelection();
    }

    fn updateAlias(self: *Instance) void {
        var peer: managed.Field = .{};
        self.readField("paired", &peer) catch return;
        var buffer: [2110]u8 = undefined;
        self.set("current-peer", if (peer.len == 0)
            "当前对端 · 尚未选择配对设备"
        else
            std.fmt.bufPrint(&buffer, "当前对端 · {s}", .{peer.slice()}) catch "当前对端");
    }

    fn applySelection(self: *Instance, selection: handoff.Selection) !void {
        if (!selection.valid()) return error.Argument;
        try self.selected_batch.set(selection.paths);
        self.selected = if (selection.single_file) self.selected_batch else .{};
        self.selection_count = selection.count;
        self.showSelection();
    }

    fn showSelection(self: *Instance) void {
        var count: [72]u8 = undefined;
        self.set("source", if (self.selection_count == 0)
            "可将文件或文件夹拖到窗口，也可以点击上方按钮选择。"
        else if (self.selection_count == 1)
            self.selected_batch.slice()
        else
            std.fmt.bufPrint(&count, "已选择 {d} 项", .{self.selection_count}) catch "已选择多个项目");
    }

    fn rememberTerminal(self: *Instance, state: task_mod.State, message: []const u8) void {
        if (state == .completed) {
            switch (self.task.request.mode) {
                .interfaces => {
                    self.local_choices = choices.parse(.local, message);
                },
                .discover => {
                    self.endpoint_choices = choices.parse(.endpoint, message);
                    self.pair_endpoint_choices = choices.parse(.pair_endpoint, message);
                    self.discovery_bind = self.task.request.bind;
                },
                .peer_list => {
                    self.peer_choices = choices.parse(.peer, message);
                    self.peer_store = self.task.request.store;
                },
                .peer_add, .peer_revoke, .pair_host, .pair_join => {
                    self.peer_choices = .{};
                },
                else => {},
            }
        }
        if (state != .completed) {
            switch (self.task.request.mode) {
                .interfaces => self.local_choices = .{},
                .discover => {
                    self.endpoint_choices = .{};
                    self.pair_endpoint_choices = .{};
                },
                .peer_list, .peer_add, .peer_revoke, .pair_host, .pair_join => self.peer_choices = .{},
                else => {},
            }
        }
        if (self.task.request.mode == .interfaces or self.task.request.mode == .discover or self.task.request.mode == .peer_list or self.task.request.mode == .recovery_list or std.mem.eql(u8, self.task.request.queue_action, "list") or (self.task.request.browse and self.task.request.mode == .receive and self.task.request.remote_path.len == 0)) {
            self.inventory_len = @min(message.len, self.inventory.len);
            // Child output has already been checked as UTF-8; avoid splitting a character.
            while (self.inventory_len > 0 and !std.unicode.utf8ValidateSlice(message[0..self.inventory_len])) self.inventory_len -= 1;
            @memcpy(self.inventory[0..self.inventory_len], message[0..self.inventory_len]);
        }
        if (self.task.request.mode == .discover) {
            var counts: [200]u8 = undefined;
            const result = if (state != .completed)
                "查找已结束，请查看下方任务详情。"
            else if (self.endpoint_choices.count + self.pair_endpoint_choices.count == 0)
                "未发现设备。请确认两台设备在同一局域网，并在对端开启可发现的配对或接收。"
            else
                std.fmt.bufPrint(&counts, "可配对 {d} 台 · 可接收 {d} 台", .{ self.pair_endpoint_choices.count, self.endpoint_choices.count }) catch "已发现设备";
            self.set("discovery", result);
        }
        switch (self.task.request.mode) {
            .interfaces, .discover, .peer_list, .peer_add, .peer_revoke, .pair_host, .pair_join => self.render(true) catch self.set("status", "更新选项失败，请重新打开 Share"),
            else => {},
        }
        self.set("inventory", if (self.inventory_len == 0) "" else self.inventory[0..self.inventory_len]);
        if (self.task.request.mode != .send and self.task.request.mode != .receive) return;
        var line: [256]u8 = undefined;
        const record = std.fmt.bufPrint(&line, "{s} · {s} · {s}\n", .{
            if (self.task.request.mode == .send) "发送" else "接收",
            self.task.request.paired.slice(),
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
            self.set("history", self.history[0..self.history_len]);
        }
    }

    fn start(self: *Instance, mode: managed.Mode, advertise: bool, use_spool: bool, routed: bool, join_code: u32, quic: bool, batch_action: []const u8) !void {
        if (!managed.configured()) return error.Unavailable;
        if (managed.pairingMode(mode) and !managed.pairingConfigured()) return error.Unavailable;
        if (mode == .pair_join and (join_code == 0 or join_code > 100000000)) return error.Argument;
        if (self.task.occupied()) return error.State;
        var next: managed.Request = .{ .mode = mode, .advertise = advertise, .routed = routed, .quic = quic };
        if (batch_action.len != 0) {
            next.batch = true;
            next.queue_action = if (std.mem.eql(u8, batch_action, "share-queue-add"))
                "enqueue"
            else if (std.mem.eql(u8, batch_action, "share-queue-list"))
                "list"
            else if (std.mem.eql(u8, batch_action, "share-queue-run"))
                "run"
            else if (std.mem.eql(u8, batch_action, "share-queue-discard"))
                "discard"
            else if (std.mem.eql(u8, batch_action, "share-queue-prune"))
                "prune"
            else
                "";
            if (next.queue_action.len != 0 and !std.mem.eql(u8, next.queue_action, "enqueue")) {
                try self.readField("queue-id", &next.queue_id);
                if (std.mem.eql(u8, next.queue_action, "list")) try self.readField("browse-offset", &next.browse_offset);
                if (std.mem.eql(u8, next.queue_action, "discard") and next.queue_id.len == 0) return error.Argument;
            }
            next.sync_clipboard = std.mem.eql(u8, batch_action, "share-sync-send") or std.mem.eql(u8, batch_action, "share-sync-receive");
            next.root_service = std.mem.eql(u8, batch_action, "share-directory-service");
            next.root_connect = std.mem.eql(u8, batch_action, "share-directory-connect");
            if (!std.mem.eql(u8, batch_action, "share-send-selection") and !std.mem.eql(u8, batch_action, "share-receive-selection")) {
                var transport: managed.Field = .{};
                try self.readField("batch-mode", &transport);
                const value = transport.slice();
                next.quic = std.mem.eql(u8, value, "quic") or std.mem.eql(u8, value, "quic-routed");
                next.routed = std.mem.eql(u8, value, "tcp-routed") or std.mem.eql(u8, value, "quic-routed");
                if (value.len != 0 and !next.quic and !next.routed and !std.mem.eql(u8, value, "tcp")) return error.Argument;
                try self.readField("channels", &next.channels);
            }
            if (std.mem.eql(u8, batch_action, "share-clipboard-send") or std.mem.eql(u8, batch_action, "share-sync-send")) {
                try self.readField("clipboard-kind", &next.clipboard);
                if (next.clipboard.len == 0) return error.Argument;
            } else if (mode == .send) next.sources = self.selected_batch;
            if (std.mem.eql(u8, batch_action, "share-clipboard-receive") or std.mem.eql(u8, batch_action, "share-sync-receive")) {
                next.clipboard_receive = true;
                try self.readField("clipboard-kind", &next.clipboard);
                if (next.sync_clipboard) {
                    next.delivery.set("clipboard") catch return error.Argument;
                } else try self.readField("delivery", &next.delivery);
            }
            next.browse = std.mem.eql(u8, batch_action, "share-root-offer") or std.mem.eql(u8, batch_action, "share-root-receive") or next.root_connect;
            if (mode == .receive) {
                if (!next.sync_clipboard) try self.readField("resume", &next.resume_path);
                if (next.browse) {
                    try self.readField("remote-path", &next.remote_path);
                    try self.readField("browse-offset", &next.browse_offset);
                }
            }
        }
        switch (mode) {
            .discover, .send, .receive, .pair_host, .pair_join => try self.readField("bind", &next.bind),
            else => {},
        }
        if (mode != .discover and mode != .interfaces) try self.readField(if (use_spool) "spool" else "store", &next.store);
        switch (mode) {
            .send, .receive, .peer_add, .peer_revoke, .pair_host, .pair_join => try self.readField("paired", &next.paired),
            else => {},
        }
        if (mode == .peer_add) try self.readField("fingerprint", &next.fingerprint);
        if (mode == .send) {
            if (!next.batch) next.source = self.selected;
            try self.readField("peer", &next.peer);
            if (next.root_service) {
                try self.readField("port", &next.port);
                if (next.routed) try self.readField("allowed-source", &next.allowed_source);
            }
            if (next.queue_action.len != 0 and !std.mem.eql(u8, next.queue_action, "enqueue")) {
                next.batch = false;
                next.quic = false;
                next.routed = false;
            }
        }
        if (mode == .pair_host) {
            try self.readField("port", &next.port);
            if (next.routed) try self.readField("allowed-source", &next.allowed_source);
        }
        if (mode == .pair_join) try self.readField("pair-peer", &next.peer);
        if (mode == .receive) {
            if (next.root_connect) try self.readField("peer", &next.peer);
            if (next.routed and !next.root_connect) try self.readField("allowed-source", &next.allowed_source);
            try self.readField("destination", &next.destination);
            try self.readField("spool", &next.spool);
            try self.readField("port", &next.port);
        }
        switch (mode) {
            .interfaces => {},
            .discover, .send, .receive, .pair_host, .pair_join => {
                if (next.bind.len == 0 and (next.queue_action.len == 0 or std.mem.eql(u8, next.queue_action, "enqueue"))) return error.LocalAddressRequired;
            },
            else => {},
        }
        if (mode != .discover and mode != .interfaces and next.store.len == 0) return error.IdentityRequired;
        if ((mode == .send or mode == .receive or managed.pairingMode(mode) or mode == .peer_add or mode == .peer_revoke) and next.paired.len == 0 and
            (next.queue_action.len == 0 or std.mem.eql(u8, next.queue_action, "enqueue"))) return error.DeviceNameRequired;
        if (mode == .pair_join and next.peer.len == 0) return error.PeerAddressRequired;
        if (mode == .receive and !next.sync_clipboard and (next.destination.len == 0 or next.spool.len == 0)) return error.ReceiveDirectoriesRequired;
        next.validate() catch return error.Argument;
        try self.task.start(&next, join_code);
        self.shown_prompt = 0;
        self.set("status", switch (mode) {
            .discover => "正在查找附近设备…",
            .pair_host => "正在开启配对…",
            .pair_join => "正在连接对端…",
            else => "任务已启动…",
        });
        self.set("progress", "0");
        self.set("bytes", "");
        if (mode == .discover) self.set("discovery", "正在查找附近设备…");
        if (mode == .pair_host) self.set("pair-code", "等待生成连接码");
        self.set("idle", "false");
        self.set("ui-idle", "false");
        self.set("busy", "true");
        self.set("confirm", "false");
    }

    fn applyChoice(self: *Instance, kind: choices.Kind) void {
        if (self.task.occupied()) return self.status("请先结束当前任务");
        const key: []const u8 = switch (kind) {
            .local => "local-choice",
            .endpoint => "endpoint-choice",
            .pair_endpoint => "pair-endpoint-choice",
            .peer => "peer-choice",
        };
        var field: managed.Field = .{};
        self.readField(key, &field) catch return self.status("无法读取选择");
        const index = std.fmt.parseInt(usize, field.slice(), 10) catch return self.status("无效选项");
        const list = switch (kind) {
            .local => &self.local_choices,
            .endpoint => &self.endpoint_choices,
            .pair_endpoint => &self.pair_endpoint_choices,
            .peer => &self.peer_choices,
        };
        const value = list.selected(index) orelse return self.status("请选择有效条目");
        if (kind == .endpoint or kind == .pair_endpoint) {
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
            .pair_endpoint => "pair-peer",
            .peer => "paired",
        };
        self.set(target, value);
        self.updateAlias();
        switch (kind) {
            .endpoint => self.set("active-tab", "0"),
            .pair_endpoint => self.set("pair-help", "已填入配对地址。输入对端显示的连接码，再点「连接」。"),
            else => {},
        }
        self.status("已填入所选项，请核对后继续。");
    }

    fn render(self: *Instance, update: bool) !void {
        var storage: [field_names.len]view.FieldNodes = @splat(.{});
        var fields: [field_names.len]ui.Node = undefined;
        for (&storage, 0..) |*item, n| fields[n] = item.build(n);
        var local_options: choices.Options = undefined;
        var endpoint_options: choices.Options = undefined;
        var pair_endpoint_options: choices.Options = undefined;
        var peer_options: choices.Options = undefined;
        var pair_peer: view.FieldNodes = .{};
        var code_input = view.input("pair-input", true);
        code_input.text = .{ .present = 1, .value = abi.view("输入对端显示的 8 位连接码") };
        const network_actions = [_]ui.Node{
            view.button("查找附近设备", "share-discover", "primary", "state.idle"),
            view.button("列出本机地址", "share-interfaces", "standard", "state.idle"),
        };
        const device_content = [_]ui.Node{
            view.text("nearby-heading", "附近设备", "section"),
            fields[0],
            view.grid("network-actions", &network_actions),
            view.select("local-options", "local-choice", "选择本机地址", self.local_choices.options(&local_options)),
            view.button("填入本机地址", "share-use-local", "standard", "state.idle"),
            view.bound("discovery-text", "state.discovery"),
            view.text("receiver-options-label", "可接收的附近设备", "caption"),
            view.select("endpoint-options", "endpoint-choice", "可接收的附近设备", self.endpoint_choices.options(&endpoint_options)),
            view.button("使用地址并进入发送", "share-use-endpoint", "standard", "state.idle"),
            view.text("pair-endpoint-label", "等待配对的附近设备", "caption"),
            view.select("pair-endpoint-options", "pair-endpoint-choice", "等待配对的附近设备", self.pair_endpoint_choices.options(&pair_endpoint_options)),
            view.button("填入配对地址", "share-use-pair-endpoint", "standard", "state.idle"),
            view.text("pair-heading", "配对新设备", "section"),
            view.button("首次使用：去设置设备身份", "share-open-settings", "standard", "state.ui-idle"),
            fields[3],
            view.button("开启连接码并允许发现", "share-pair-host-advertise", "primary", "state.idle"),
            view.bound("pair-help", "state.pair-help"),
            pair_peer.buildCustom("pair-peer-group", "pair-peer-label", "pair-peer", "对端配对地址"),
            view.text("pair-input-label", "对端的 8 位连接码", "caption"),
            code_input,
            view.button("连接", "share-pair-join", "primary", "state.idle"),
            view.text("trusted-heading", "已配对的设备", "section"),
            view.button("刷新已配对设备", "share-peer-list", "standard", "state.idle"),
            view.select("peer-options", "peer-choice", "选择已配对设备", self.peer_choices.options(&peer_options)),
            view.button("设为当前对端", "share-use-peer", "standard", "state.idle"),
        };
        const file_actions = [_]ui.Node{
            view.button("选择文件", "share-pick-file", "standard", "state.ui-idle"),
            view.button("选择文件夹", "share-pick-folder", "standard", "state.ui-idle"),
        };
        const source_card = [_]ui.Node{
            view.bound("source", "state.source"),
            view.grid("file-actions", &file_actions),
        };
        const send_actions = [_]ui.Node{
            view.button("选设备", "share-open-devices", "standard", "state.ui-idle"),
            view.button("发送", "share-send-selection", "primary", "state.idle"),
        };
        const target_card = [_]ui.Node{
            view.bound("current-peer", "state.current-peer"),
            fields[1],
            view.grid("send-actions", &send_actions),
        };
        const send_cards = [_]ui.Node{
            view.group("source-card", "待发送内容", &source_card),
            view.group("target-card", "接收设备", &target_card),
        };
        const send_content = [_]ui.Node{
            view.text("send-heading", "发送文件或文件夹", "section"),
            view.grid("send-cards", &send_cards),
        };
        const receive_content = [_]ui.Node{
            view.text("receive-heading", "接收文件", "section"),
            fields[4],
            view.button("选择保存目录", "share-browse-destination", "standard", "state.ui-idle"),
            view.bound("receive-peer", "state.current-peer"),
            view.button("接收单文件", "share-receive", "primary", "state.idle"),
            view.button("接收单文件并允许发现", "share-receive-advertise", "standard", "state.idle"),
            view.button("接收多个文件或文件夹", "share-receive-selection", "standard", "state.idle"),
            view.text("receive-confirm", "文件到达时，在下方核对并确认接收。", "caption"),
        };
        const routed_actions = [_]ui.Node{
            view.button("发送（组网/转发）", "share-send-routed", "standard", "state.idle"),
            view.button("接收（组网/转发）", "share-receive-routed", "standard", "state.idle"),
        };
        const quic_actions = [_]ui.Node{
            view.button("QUIC 发送", "share-send-quic", "standard", "state.idle"),
            view.button("QUIC 接收", "share-receive-quic", "standard", "state.idle"),
            view.button("QUIC 组网发送", "share-send-quic-routed", "standard", "state.idle"),
            view.button("QUIC 组网接收", "share-receive-quic-routed", "standard", "state.idle"),
        };
        const batch_actions = [_]ui.Node{
            view.button("批量发送选中项", "share-batch-send", "primary", "state.idle"),
            view.button("批量接收 / 恢复", "share-batch-receive", "standard", "state.idle"),
            view.button("发送剪贴板", "share-clipboard-send", "standard", "state.idle"),
            view.button("接收剪贴板", "share-clipboard-receive", "standard", "state.idle"),
            view.button("提供只读目录", "share-root-offer", "standard", "state.idle"),
            view.button("浏览 / 下载目录", "share-root-receive", "standard", "state.idle"),
        };
        const queue_actions = [_]ui.Node{
            view.button("选中项加入队列", "share-queue-add", "standard", "state.idle"),
            view.button("查看持久化队列", "share-queue-list", "standard", "state.idle"),
            view.button("运行待发送任务", "share-queue-run", "primary", "state.idle"),
            view.button("放弃指定任务", "share-queue-discard", "standard", "state.idle"),
            view.button("清理终态记录", "share-queue-prune", "standard", "state.idle"),
        };
        const service_actions = [_]ui.Node{
            view.button("启动自动剪贴板发送", "share-sync-send", "standard", "state.idle"),
            view.button("启动自动剪贴板接收", "share-sync-receive", "standard", "state.idle"),
            view.button("启动只读目录服务", "share-directory-service", "standard", "state.idle"),
            view.button("连接目录服务", "share-directory-connect", "standard", "state.idle"),
        };
        const advanced_pair_actions = [_]ui.Node{
            view.button("开启连接码（不广播）", "share-pair-host", "standard", "state.idle"),
            view.button("显示本机指纹", "share-identity-show", "standard", "state.idle"),
            view.button("组网开启连接码", "share-pair-host-routed", "standard", "state.idle"),
            view.button("组网连接", "share-pair-join-routed", "standard", "state.idle"),
            view.button("手动指纹配对", "share-peer-add", "standard", "state.idle"),
            view.button("撤销当前配对", "share-peer-revoke", "danger", "state.idle"),
        };
        const advanced_pair = [_]ui.Node{
            fields[7],
            view.text("advanced-pair-help", "组网连接使用设备页中的配对地址和连接码。手动配对前请从另一渠道核对完整指纹。", "caption"),
            view.grid("advanced-pair-actions", &advanced_pair_actions),
        };
        const transport = [_]ui.Node{
            view.text("routed-help", "高级：仅已配对设备。使用具体数字 IP 和端口；接收须填写实际 TCP 来源 IP（代理场景可为代理地址）。不自动映射端口。", "caption"),
            fields[8],
            view.grid("routed-actions", &routed_actions),
            view.text("quic-help", "QUIC：使用 UDP，双方手动选择 QUIC，不自动回退 TCP；目前仅单文件。", "caption"),
            view.grid("quic-actions", &quic_actions),
        };
        const batch_options = [_]ui.Node{
            view.text("batch-help", "批量使用已配对设备。选择协议、通道和接收选项；多选路径受宿主命令长度限制。恢复须手动选择原事务。", "caption"),
            fields[9],
            fields[10],
            fields[11],
            fields[12],
            fields[13],
            fields[14],
            fields[15],
            view.text("shelf-help", "暂存区需宿主公开写入接口；目前可接收到系统剪贴板，再手动导入 Pulse。", "caption"),
            view.grid("batch-actions", &batch_actions),
        };
        const queue_and_services = [_]ui.Node{
            fields[16],
            view.text("queue-help", "队列保存在私有身份目录。留空 ID 分页查看或运行全部待发任务；每页 20 条，使用列表偏移。放弃需指定 ID。结果不确定时先检查接收端。", "caption"),
            view.grid("queue-actions", &queue_actions),
            view.text("service-help", "长期服务仅在显式启动并批准后运行，取消即停止；自动同步仅文本或图片，目录服务需固定端口。", "caption"),
            view.grid("service-actions", &service_actions),
            view.bound("batch-inventory", "state.inventory"),
        };
        const advanced_content = [_]ui.Node{
            view.text("advanced-heading", "高级操作", "section"),
            view.group("advanced-pair-card", "高级配对", &advanced_pair),
            view.group("transport-card", "组网与 QUIC", &transport),
            view.group("batch-card", "批量与内容类型", &batch_options),
            view.group("queue-card", "队列与服务", &queue_and_services),
        };
        const setup_actions = [_]ui.Node{
            view.button("应用已保存设置", "share-apply-prefs", "standard", "state.ui-idle"),
            view.button("保存当前配置", "share-save-prefs", "primary", "state.ui-idle"),
            view.button("创建身份目录", "share-private-init", "standard", "state.idle"),
            view.button("创建设备身份", "share-identity-init", "primary", "state.idle"),
            view.button("创建暂存目录", "share-spool-init", "standard", "state.idle"),
            view.button("检查暂存残留", "share-spool-recovery", "standard", "state.idle"),
            view.button("检查身份目录残留", "share-recovery-list", "standard", "state.idle"),
        };
        const setup_card = [_]ui.Node{
            view.text("setup-help", "首次使用：填写新的身份目录，创建目录后创建设备身份。接收暂存目录也必须是独立的私有目录。在接收页填写保存目录，然后回到这里保存设置。", "body"),
            view.button("选择私有目录的父文件夹", "share-browse-parent", "standard", "state.ui-idle"),
            fields[2],
            fields[5],
            fields[6],
            view.grid("setup-actions", &setup_actions),
        };
        const setup_content = [_]ui.Node{
            view.text("setup-heading", "设置", "section"),
            view.group("setup-card", "设备与存储", &setup_card),
        };
        const history_content = [_]ui.Node{
            view.text("history-note", "仅记录本次插件会话的传输结果，不保存文件路径。", "caption"),
            view.bound("history-text", "state.history"),
        };
        const tabs_children = [_]ui.Node{
            view.tab("send-tab", "发送", &send_content),
            view.tab("receive-tab", "接收", &receive_content),
            view.tab("devices-tab", "设备", &device_content),
            view.tab("history-tab", "记录", &history_content),
            view.tab("setup-tab", "设置", &setup_content),
            view.tab("advanced-tab", "高级", &advanced_content),
        };
        var tabs = view.container(ui.NodeKind.tabs, "share-tabs", &tabs_children);
        tabs.state = .{ .present = 1, .value = abi.view("active-tab") };
        var bar = ui.node(ui.NodeKind.progress);
        bar.id = abi.view("transfer-progress");
        bar.binding = .{ .present = 1, .value = abi.view("state.progress") };
        const controls = [_]ui.Node{
            view.button("取消任务", "share-cancel", "danger", "state.busy"),
            view.button("确认请求", "share-approve", "primary", "state.confirm"),
            view.button("拒绝请求", "share-decline", "standard", "state.confirm"),
        };
        const task_content = [_]ui.Node{
            view.bound("pair-code", "state.pair-code"),
            view.bound("status-line", "state.status"),
            bar,
            view.bound("byte-count", "state.bytes"),
            view.grid("task-controls", &controls),
        };
        const children = [_]ui.Node{
            view.group("task-group", "当前任务", &task_content),
            tabs,
        };
        const root = view.container(ui.NodeKind.stack, "share-root", &children);
        if (update) {
            if (self.panel) |panel| try panel.updateTree(&root);
            return;
        }
        self.panel = try native.Panel.openTree(&root);
        self.applyPreferences();
        self.set("local-choice", "0");
        self.set("endpoint-choice", "0");
        self.set("pair-endpoint-choice", "0");
        self.set("peer-choice", "0");
        self.set("active-tab", "0");
        self.set("status", if (managed.configured()) "就绪" else "界面预览 · 未绑定传输组件");
        self.set("idle", if (managed.configured()) "true" else "false");
        self.set("ui-idle", "true");
        self.set("busy", "false");
        self.set("confirm", "false");
        self.set("history", "本次会话尚无传输记录");
        self.set("discovery", "点击「查找附近设备」查看结果。");
        self.set("pair-help", "请在两台设备上核对并确认指纹。");
        self.showSelection();
        self.updateAlias();
    }
};

fn command(self: *Instance, name: []const u8) void {
    if (std.mem.eql(u8, name, "share-receive-selection")) {
        self.start(.receive, false, false, false, 0, false, name) catch |err| self.status(errorMessage(err));
        return;
    }
    if (std.mem.eql(u8, name, "share-open-settings")) return self.set("active-tab", "4");
    if (std.mem.eql(u8, name, "share-open-devices")) return self.set("active-tab", "2");
    if (std.mem.eql(u8, name, "share-pick-file")) return self.pickSource(false);
    if (std.mem.eql(u8, name, "share-pick-folder")) return self.pickSource(true);
    if (std.mem.eql(u8, name, "share-send-selection")) {
        if (self.selected_batch.len == 0) return self.status("请先选择文件或文件夹。");
        self.start(.send, false, false, false, 0, false, if (self.selected.len > 0) "" else "share-send-selection") catch |err| self.status(errorMessage(err));
        return;
    }
    if (std.mem.eql(u8, name, "share-pair-host") or std.mem.eql(u8, name, "share-pair-host-routed") or std.mem.eql(u8, name, "share-pair-host-advertise")) {
        const routed = std.mem.eql(u8, name, "share-pair-host-routed");
        self.start(.pair_host, std.mem.eql(u8, name, "share-pair-host-advertise"), false, routed, 0, false, "") catch |err| return self.status(errorMessage(err));
        self.set("active-tab", "2");
        return;
    }
    if (std.mem.eql(u8, name, "share-pair-join") or std.mem.eql(u8, name, "share-pair-join-routed")) {
        var value: [24]u8 = @splat(0);
        defer @memset(&value, 0);
        const panel = self.panel orelse return;
        const input = panel.read("pair-input", &value) catch return self.status("请输入完整的 8 位连接码。");
        const code = managed.parseCode(input) catch return self.status("请输入完整的 8 位连接码。");
        self.set("pair-input", "");
        self.start(.pair_join, false, false, std.mem.eql(u8, name, "share-pair-join-routed"), code, false, "") catch |err| self.status(errorMessage(err));
        return;
    }
    if (std.mem.eql(u8, name, "share-apply-prefs")) return self.applyPreferences();
    if (std.mem.eql(u8, name, "share-save-prefs")) return self.savePreferences();
    if (std.mem.eql(u8, name, "share-use-local")) return self.applyChoice(.local);
    if (std.mem.eql(u8, name, "share-use-endpoint")) return self.applyChoice(.endpoint);
    if (std.mem.eql(u8, name, "share-use-pair-endpoint")) return self.applyChoice(.pair_endpoint);
    if (std.mem.eql(u8, name, "share-use-peer")) return self.applyChoice(.peer);
    if (std.mem.eql(u8, name, "share-browse-parent")) return self.browse(true);
    if (std.mem.eql(u8, name, "share-browse-destination")) return self.browse(false);
    if (std.mem.eql(u8, name, "share-cancel")) {
        self.task.cancel();
        self.set("pair-input", "");
        self.shown_prompt = 0;
        self.set("confirm", "false");
        self.set("pair-code", "");
        return self.status("正在取消…");
    }
    if (std.mem.eql(u8, name, "share-approve") or std.mem.eql(u8, name, "share-decline")) {
        if (self.shown_prompt == 0) return;
        self.task.decisions.submit(self.shown_prompt, std.mem.eql(u8, name, "share-approve"));
        self.shown_prompt = 0;
        self.set("confirm", "false");
        return self.status("已提交确认，等待对端…");
    }
    if (std.mem.startsWith(u8, name, "share-queue-") or std.mem.eql(u8, name, "share-sync-send") or std.mem.eql(u8, name, "share-sync-receive") or std.mem.eql(u8, name, "share-directory-service") or std.mem.eql(u8, name, "share-directory-connect") or std.mem.eql(u8, name, "share-batch-send") or std.mem.eql(u8, name, "share-batch-receive") or std.mem.eql(u8, name, "share-clipboard-send") or std.mem.eql(u8, name, "share-clipboard-receive") or std.mem.eql(u8, name, "share-root-offer") or std.mem.eql(u8, name, "share-root-receive")) {
        const sending = std.mem.startsWith(u8, name, "share-queue-") or std.mem.eql(u8, name, "share-sync-send") or std.mem.eql(u8, name, "share-directory-service") or std.mem.eql(u8, name, "share-batch-send") or std.mem.eql(u8, name, "share-clipboard-send") or std.mem.eql(u8, name, "share-root-offer");
        self.start(if (sending) .send else .receive, false, false, false, 0, false, name) catch |err| self.status(errorMessage(err));
        return;
    }
    const mode: managed.Mode = if (std.mem.eql(u8, name, "share-discover"))
        .discover
    else if (std.mem.eql(u8, name, "share-send") or std.mem.eql(u8, name, "share-send-routed") or std.mem.eql(u8, name, "share-send-quic") or std.mem.eql(u8, name, "share-send-quic-routed"))
        .send
    else if (std.mem.eql(u8, name, "share-receive") or std.mem.eql(u8, name, "share-receive-advertise") or std.mem.eql(u8, name, "share-receive-routed") or std.mem.eql(u8, name, "share-receive-quic") or std.mem.eql(u8, name, "share-receive-quic-routed"))
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
    self.start(mode, std.mem.eql(u8, name, "share-receive-advertise"), std.mem.eql(u8, name, "share-spool-init") or std.mem.eql(u8, name, "share-spool-recovery"), std.mem.eql(u8, name, "share-send-routed") or std.mem.eql(u8, name, "share-receive-routed") or std.mem.eql(u8, name, "share-send-quic-routed") or std.mem.eql(u8, name, "share-receive-quic-routed"), 0, std.mem.eql(u8, name, "share-send-quic") or std.mem.eql(u8, name, "share-receive-quic") or std.mem.eql(u8, name, "share-send-quic-routed") or std.mem.eql(u8, name, "share-receive-quic-routed"), "") catch |err| self.status(errorMessage(err));
}

var instance: Instance = .{};

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.LocalAddressRequired => "请在「设备」页选择本机网络地址。",
        error.IdentityRequired => "请在「设置」页选择并初始化设备身份目录。",
        error.DeviceNameRequired => "请在「设备」页填写对端名称，或选择已配对设备。",
        error.PeerAddressRequired => "请填写对端配对地址，或从查找结果中选择。",
        error.ReceiveDirectoriesRequired => "请填写接收目录，并在「设置」页创建暂存目录。",
        error.InvalidInput, error.Argument => "参数无效，请检查设备地址、端口和设置。",
        error.State => "请先结束当前任务。",
        error.Unavailable => "此构建未绑定所需的工作进程。",
        else => @errorName(err),
    };
}

export fn share_desktop_command(name: [*:0]const u8) void {
    if (!instance.closing) command(&instance, std.mem.span(name));
}

export fn share_desktop_changed(name: [*:0]const u8) void {
    if (std.mem.eql(u8, std.mem.span(name), "paired")) instance.updateAlias();
}

export fn share_desktop_drop(paths: [*]const u8, len: usize, count: u32, is_file: c_int) void {
    if (instance.task.occupied() or instance.closing) return instance.status("请先结束当前任务。");
    instance.applySelection(.{ .paths = paths[0..len], .count = count, .single_file = is_file != 0 }) catch
        return instance.status("无法使用所选路径。请选择本机文件或文件夹，最多 64 项。");
    instance.set("active-tab", "0");
}

export fn share_desktop_tick() void {
    instance.refresh();
    if (instance.closing and !instance.task.occupied()) share_desktop_finish();
}

export fn share_desktop_close() c_int {
    if (!instance.task.occupied()) return 1;
    instance.closing = true;
    instance.task.cancel();
    instance.set("confirm", "false");
    instance.set("pair-code", "");
    instance.set("pair-input", "");
    instance.status("正在结束任务…");
    return 0;
}

pub fn main(init: std.process.Init) !void {
    var args = try init.minimal.args.iterateAllocator(std.heap.page_allocator);
    defer args.deinit();
    _ = args.next();
    var bytes: [handoff.capacity]u8 = undefined;
    var selection: handoff.Selection = .{};
    var failure: []const u8 = "";
    var arg = args.next();
    if (arg) |mode| {
        if (std.mem.eql(u8, mode, "--session-only")) {
            instance.session_only = true;
            arg = args.next();
        }
    }
    if (arg) |flag| {
        if (std.mem.eql(u8, flag, "--handoff")) {
            if (args.next()) |handle| {
                const payload = managed.readHandoff(handle, &bytes) catch "";
                if (payload.len != 0) selection = handoff.Selection.decode(payload) catch .{};
                if (payload.len == 0) failure = "Pulse 选区读取失败，请在此窗口重新选择文件。";
            }
        } else failure = "启动参数无效，请在此窗口重新选择文件。";
    }
    var saved: [prefs.limit]u8 = undefined;
    const read = if (instance.session_only) 0 else share_desktop_preferences_read(&saved, saved.len);
    if (read > 0) {
        instance.saved = prefs.Values.decode(saved[0..@intCast(read)]) catch blk: {
            failure = "本机设置无法读取，请检查设置页。";
            break :blk .{};
        };
    } else if (read == 0 and selection.preferences.len > 0) {
        instance.saved = prefs.Values.decode(selection.preferences) catch .{};
    } else if (read < 0) failure = "本机设置无法读取，请检查设置页。";
    if (share_desktop_create() == 0) return error.WindowCreation;
    if (selection.count > 0) instance.applySelection(selection) catch {
        failure = "Pulse 选区不可用，请在此窗口重新选择文件。";
    };
    try instance.render(false);
    if (failure.len > 0) instance.status(failure);
    share_desktop_run();
}
