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
const pair_ticket = @import("pair_ticket.zig");
const worker_messages = @import("worker_messages.zig");
const diagnostics = @import("diagnostic_history.zig");

extern fn share_desktop_create() c_int;
extern fn share_desktop_run() void;
extern fn share_desktop_finish() void;
extern fn share_desktop_stamp([*]u8, c_int) c_int;
extern fn share_desktop_export_diagnostics([*]const u8, c_int) c_int;
extern fn share_desktop_label_nonce() u64;
extern fn share_desktop_copy([*]const u8, c_int, c_int) c_int;
extern fn share_desktop_paste([*]u8, c_int) c_int;
extern fn share_desktop_clear_pair_clipboard() c_int;
extern fn share_desktop_pair_popup([*]const u8, c_int, [*]const u8, c_int, c_int) c_int;
extern fn share_desktop_pair_clear(c_int) void;
extern fn share_desktop_pair_copied(contains_code: c_int) void;
extern fn share_desktop_show_section([*:0]const u8) void;
extern fn share_desktop_notice([*]const u8, c_int, c_int) void;
extern fn share_desktop_pick(c_int, [*]u8, c_int) c_int;
extern fn share_desktop_default_network([*]u8, c_int) c_int;
extern fn share_desktop_default_path(c_int, [*]u8, c_int) c_int;
extern fn share_desktop_preferences_read([*]u8, c_int) c_int;
extern fn share_desktop_preferences_write([*]const u8, c_int) c_int;

const field_names = view.fields;
const initial_request: managed.Request = .{};
const Section = enum { send, receive, network, storage, address, join };

const Service = enum { clipboard_send, clipboard_receive, directory_host };
const services = [_]struct {
    service: Service,
    command: []const u8,
    title: []const u8,
    caption: []const u8,
    enabled: []const u8,
}{
    .{ .service = .clipboard_send, .command = "share-sync-send", .title = "自动发送剪贴板", .caption = "sync-send-caption", .enabled = "sync-send-enabled" },
    .{ .service = .clipboard_receive, .command = "share-sync-receive", .title = "自动接收剪贴板", .caption = "sync-receive-caption", .enabled = "sync-receive-enabled" },
    .{ .service = .directory_host, .command = "share-directory-service", .title = "只读目录服务", .caption = "directory-caption", .enabled = "directory-enabled" },
};

fn serviceFor(command_name: []const u8) ?Service {
    for (services) |item| if (std.mem.eql(u8, item.command, command_name)) return item.service;
    return null;
}

const clipboard_names = [_]abi.StringView{ abi.view("文本"), abi.view("图片"), abi.view("文件") };
const delivery_names = [_]abi.StringView{ abi.view("保存到接收目录"), abi.view("放入系统剪贴板") };

const Instance = struct {
    panel: ?native.Panel = null,
    task: task_mod.Task = .{},
    diagnostics: diagnostics.History = .{},
    active_service: ?Service = null,
    service_running: bool = false,
    saved: prefs.Values = .{},
    default_paths: [3]managed.Field = @splat(.{}),
    default_bind: managed.Field = .{},
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
    popup_shown: bool = false,
    copied_code: u32 = 0,
    closing: bool = false,
    expanded: [std.enums.values(Section).len]bool = @splat(false),
    session_only: bool = false,

    fn set(self: *Instance, key: []const u8, value: []const u8) void {
        if (self.panel) |p| p.setStates(&.{.{ .key = abi.view(key), .value = abi.view(value) }}) catch {};
    }

    fn status(self: *Instance, message: []const u8) void {
        self.set("status", message);
    }

    fn notice(message: []const u8, severe: bool) void {
        share_desktop_notice(message.ptr, @intCast(message.len), @intFromBool(severe));
    }

    fn feedback(self: *Instance, message: []const u8, severe: bool) void {
        self.status(message);
        notice(message, severe);
    }

    fn recordDiagnostic(self: *Instance, operation: []const u8, result: []const u8, finding: ?worker_messages.Finding) void {
        var stamp: [32]u8 = undefined;
        const len = share_desktop_stamp(&stamp, stamp.len);
        const time = if (len > 0 and len < stamp.len) stamp[0..@intCast(len)] else "-";
        self.diagnostics.add(time, operation, result, finding);
        self.set("diagnostic", self.diagnostics.latest);
    }

    fn reportError(self: *Instance, err: anyerror) void {
        const message = errorMessage(err);
        self.recordDiagnostic("input", "refused", .{ .code = @errorName(err), .message = message });
        self.feedback(message, true);
    }

    fn exportDiagnostics(self: *Instance) void {
        var buffer: [4608]u8 = undefined;
        const text = std.fmt.bufPrint(&buffer, "\xef\xbb\xbfPulse Share 诊断\r\n时间\t操作\t结果\t类别\t建议\r\n{s}", .{self.diagnostics.slice()}) catch return;
        const result = share_desktop_export_diagnostics(text.ptr, @intCast(text.len));
        if (result > 0) self.feedback("诊断已导出。", false) else if (result < 0) self.feedback("无法导出。请选择一个新的本机文件名。", true);
    }

    fn updateServices(self: *Instance, phase: ?task_mod.State, prompt: u32) void {
        for (services) |item| {
            var caption: [128]u8 = undefined;
            const current = self.active_service == item.service;
            const prefix: []const u8 = if (!current)
                "开启"
            else if (phase == .cancelling)
                "正在停止 "
            else if (prompt != 0)
                "待确认 · 停止"
            else if (self.service_running)
                "已开启 · 停止"
            else
                "正在连接 · 停止";
            self.set(item.caption, std.fmt.bufPrint(&caption, "{s}{s}", .{ prefix, item.title }) catch item.title);
            const enabled = if (phase == null) managed.configured() else current and phase != .cancelling;
            self.set(item.enabled, if (enabled) "true" else "false");
        }
    }

    fn readField(self: *Instance, key: []const u8, field: *managed.Field) !void {
        var buffer: [2048]u8 = undefined;
        const panel = self.panel orelse return error.State;
        try field.set(try panel.read(key, &buffer));
    }

    fn refresh(self: *Instance) void {
        if (!self.task.occupied()) {
            self.clearPairClipboard(0);
            return;
        }
        const terminal = self.task.reap();
        const snap = self.task.poll() orelse return;
        if (self.closing and terminal) return;
        const state = snap.state;
        const message = snap.message();
        const is_progress = std.mem.startsWith(u8, message, "PROGRESS ");
        var prompt: u32 = 0;
        var useful = if (is_progress) "" else message;
        if (std.mem.startsWith(u8, message, "PROMPT ")) {
            if (std.mem.indexOfScalar(u8, message[7..], ' ')) |end| {
                useful = message[end + 8 ..];
                if (state == .running) {
                    prompt = std.fmt.parseInt(u32, message[7..][0..end], 10) catch 0;
                    if (prompt > 16 or self.task.decisions.answer.load(.acquire) / 2 == prompt) prompt = 0;
                }
            }
        }
        useful = worker_messages.localize(useful);
        if (!self.service_running and state == .running and canClassifyService(self.active_service, &snap)) {
            self.service_running = true;
            notice("会话已开启，再点同一个按钮即可停止。", false);
        }
        self.updateServices(state, prompt);
        if (prompt != 0 and prompt != self.shown_prompt) notice("收到请求，请在下方核对并确认。", false);
        self.shown_prompt = prompt;
        self.set("confirm", if (prompt != 0) "true" else "false");
        var detail: [4300]u8 = undefined;
        if (terminal or useful.len != 0 or state == .cancelling or is_progress) {
            const prefix: []const u8 = switch (state) {
                .completed => "完成",
                .failed => "任务失败",
                .cancelled => "已取消",
                .cancelling => "正在取消",
                .running => if (prompt != 0) "请核对并确认" else if (is_progress) "正在传输…" else "运行中",
            };
            const text = if (self.task.request.mode == .device_prepare and state == .completed)
                "本机身份和私有暂存目录已就绪，可以开始配对。"
            else if (useful.len == 0) prefix else std.fmt.bufPrint(&detail, "{s}\r\n{s}", .{ prefix, useful }) catch prefix;
            self.status(text);
        }
        if (snap.total != 0 and snap.done <= snap.total) {
            var count: [96]u8 = undefined;
            var done_buf: [32]u8 = undefined;
            var total_buf: [32]u8 = undefined;
            var percent: [4]u8 = undefined;
            const pct = @as(u128, snap.done) * 100 / snap.total;
            self.set("bytes", std.fmt.bufPrint(&count, "{s} / {s}（{d}%）", .{
                formatByteSize(&done_buf, snap.done),
                formatByteSize(&total_buf, snap.total),
                pct,
            }) catch "");
            self.set("progress", std.fmt.bufPrint(&percent, "{d}", .{pct}) catch "0");
        } else if (terminal) {
            self.set("bytes", "");
        }
        self.updatePairDisplay(&snap, terminal, prompt);
        if (terminal) {
            const diagnostic: ?worker_messages.Finding = if (state == .failed)
                worker_messages.find(message) orelse worker_messages.Finding{ .code = "WORKER_UNCLASSIFIED", .message = "任务失败，暂未识别原因。可以导出诊断并记录刚才的操作。" }
            else
                null;
            self.recordDiagnostic(@tagName(self.task.request.mode), @tagName(state), diagnostic);
            const service_was_active = self.active_service != null;
            self.active_service = null;
            self.service_running = false;
            self.updateServices(null, 0);
            self.set("busy", "false");
            self.set("idle", "true");
            self.set("ui-idle", "true");
            self.rememberTerminal(state, message);
            if (diagnostic) |finding| {
                notice(finding.message, true);
            } else if (state == .completed) {
                const outcome: []const u8 = switch (self.task.request.mode) {
                    .pair_host, .pair_join => "配对完成，已保存设备。",
                    .device_prepare => "本机已初始化，可以开始配对。",
                    .peer_add => "已保存配对设备。",
                    .peer_revoke => "已撤销配对。",
                    .send, .receive => "任务已完成。详情见下方任务区。",
                    else => "",
                };
                if (outcome.len != 0) notice(outcome, false);
            } else if (state == .cancelled and service_was_active) {
                notice("会话已停止。", false);
            }
        }
    }

    fn clearPairClipboard(self: *Instance, current: u32) void {
        if (self.copied_code != 0 and self.copied_code != current and share_desktop_clear_pair_clipboard() != 0) {
            self.copied_code = 0;
        }
    }

    fn updatePairDisplay(self: *Instance, snap: *const task_mod.Snapshot, terminal: bool, prompt: u32) void {
        const can_copy = !terminal and snap.state == .running and prompt == 0;
        const mode = self.task.request.mode;
        const serving_directory = mode == .send and self.task.request.root_service;
        const address_ready = can_copy and (mode == .receive or serving_directory) and snap.endpoint_len > 0;
        self.set("copy-address-ready", if (address_ready) "true" else "false");
        if (!address_ready) {
            self.set("copy-address-caption", if (serving_directory) "复制服务地址" else "复制接收地址");
        } else if (serving_directory) {
            self.set("copy-address-caption", "复制服务地址");
        }
        const packed_code = self.task.decisions.display_code.load(.acquire);
        const available: u32 = @truncate(packed_code);
        const code: u32 = if (can_copy and mode == .pair_host and available <= 100000000) available else 0;
        self.clearPairClipboard(code);
        self.set("pair-popup-ready", if (code != 0 and snap.endpoint_len > 0) "true" else "false");
        if (mode != .pair_host) return;
        if (code != 0) {
            var digits: [8]u8 = undefined;
            defer @memset(&digits, 0);
            const display = std.fmt.bufPrint(&digits, "{d:0>8}", .{code - 1}) catch return;
            var status_buffer: [96]u8 = undefined;
            defer @memset(&status_buffer, 0);
            self.set("pair-code", std.fmt.bufPrint(&status_buffer, "{s}  ·  约 {d} 秒后刷新", .{ display, packed_code >> 32 }) catch display);
            if (snap.endpoint_len > 0) {
                const address = snap.listeningAddress();
                const shown = share_desktop_pair_popup(address.ptr, @intCast(address.len), display.ptr, @intCast(display.len), @intFromBool(!self.popup_shown));
                if (shown != 0) self.popup_shown = true;
            }
        } else {
            self.set("pair-code", if (terminal or prompt != 0 or snap.state == .cancelling) "" else "等待生成连接码");
            share_desktop_pair_clear(@intFromBool(terminal or prompt != 0 or snap.state == .cancelling));
        }
        self.set("pair-help", if (prompt != 0)
            "对端已连接。请核对下方指纹，再确认或拒绝。"
        else if (terminal)
            (if (snap.state == .completed) "配对已完成。" else "配对已结束。请查看下方任务详情。")
        else
            "在另一台设备输入连接码，两边都需确认指纹。");
    }

    fn quickCopy(self: *Instance, pairing: bool, open_popup: bool) void {
        if (!self.task.occupied()) return;
        const snap = self.task.poll() orelse return;
        if (snap.state != .running or self.shown_prompt != 0) return;
        var buffer: [pair_ticket.capacity]u8 = undefined;
        defer @memset(&buffer, 0);
        const address = pair_ticket.endpoint(snap.listeningAddress(), &buffer) orelse return self.feedback("当前没有可复制的监听地址。", true);
        if (!pairing) {
            const serving_directory = self.task.request.mode == .send and self.task.request.root_service;
            if (self.task.request.mode != .receive and self.task.request.mode != .pair_host and !serving_directory) return;
            if (share_desktop_copy(address.ptr, @intCast(address.len), 0) == 0) return self.feedback("剪贴板正忙，请重试。", true);
            if (self.task.request.mode == .pair_host) {
                share_desktop_pair_copied(0);
            } else if (serving_directory) {
                self.set("copy-address-caption", "已复制服务地址");
                notice("已复制目录服务地址。", false);
            } else {
                self.set("copy-address-caption", "已复制接收地址");
                notice("已复制接收地址。", false);
            }
            return;
        }
        if (self.task.request.mode != .pair_host) return;
        const code: u32 = @truncate(self.task.decisions.display_code.load(.acquire));
        if (code == 0 or code > 100000000) return self.feedback("连接码正在更新，请稍后再试。", true);
        if (open_popup) {
            var number: [8]u8 = undefined;
            defer @memset(&number, 0);
            const digits = std.fmt.bufPrint(&number, "{d:0>8}", .{code - 1}) catch return;
            _ = share_desktop_pair_popup(address.ptr, @intCast(address.len), digits.ptr, @intCast(digits.len), 1);
            return;
        }
        const value = pair_ticket.Ticket.format(self.task.request.routed, snap.listeningAddress(), code - 1, &buffer) catch return;
        if (share_desktop_copy(value.ptr, @intCast(value.len), 1) == 0) return self.feedback("剪贴板正忙，请重试。", true);
        self.copied_code = code;
        share_desktop_pair_copied(1);
    }

    fn pastePairInfo(self: *Instance) void {
        if (self.task.occupied()) return;
        var buffer: [pair_ticket.capacity + 1]u8 = undefined;
        defer @memset(&buffer, 0);
        const len = share_desktop_paste(&buffer, buffer.len);
        if (len < 0) return self.feedback("剪贴板正忙，或内容过长。", true);
        const ticket = pair_ticket.Ticket.parse(buffer[0..@intCast(len)]) catch return self.feedback("剪贴板里没有有效的 Share 配对信息。请复制对方的地址和连接码。", true);
        var address_buffer: [pair_ticket.capacity]u8 = undefined;
        const address = pair_ticket.endpoint(ticket.endpoint, &address_buffer) orelse return;
        if (ticket.routed) {
            self.openRoutedPair(true);
            self.set("routed-pair-peer", address);
            self.set("routed-pair-input", ticket.code);
        } else {
            self.set("active-tab", "2");
            if (!self.expanded[@backingInt(Section.join)]) self.toggle(.join);
            self.set("pair-peer", address);
            self.set("pair-input", ticket.code);
        }
        self.feedback("已填入地址和连接码。请点「连接」，再核对两边指纹。", false);
    }

    fn suggestName(self: *Instance, field: []const u8) void {
        var name: [64]u8 = undefined;
        const value = randomDeviceName(&name) catch return;
        self.set(field, value);
    }

    fn loadDefaults(self: *Instance) void {
        var address: [64]u8 = undefined;
        const n = share_desktop_default_network(&address, address.len);
        if (n > 0 and n < address.len) self.default_bind.set(address[0..@intCast(n)]) catch {};
        for (&self.default_paths, 0..) |*field, i| {
            var path: [2048]u8 = undefined;
            const len = share_desktop_default_path(@intCast(i), &path, path.len);
            if (len > 0 and len < path.len) field.set(path[0..@intCast(len)]) catch {};
        }
    }

    fn applyPreferences(self: *Instance) void {
        for (prefs.indices) |index| {
            const saved = self.saved.value(index);
            if (index == 12 or index == 13) continue;
            self.set(field_names[index], if (saved.len != 0) saved else switch (index) {
                0 => self.default_bind.slice(),
                2 => self.default_paths[0].slice(),
                5 => self.default_paths[1].slice(),
                4 => self.default_paths[2].slice(),
                else => "",
            });
        }
        const kind = self.saved.value(12);
        const kind_index = if (std.mem.eql(u8, kind, "image")) "1" else if (std.mem.eql(u8, kind, "files")) "2" else "0";
        self.set("send-clipboard-kind", kind_index);
        self.set("receive-clipboard-kind", kind_index);
        self.set("clipboard-delivery", if (std.mem.eql(u8, self.saved.value(13), "clipboard")) "1" else "0");
        self.updatePathLabels();
    }

    fn readClipboardKind(self: *Instance, key: []const u8, out: *managed.Field) !void {
        var field: managed.Field = .{};
        try self.readField(key, &field);
        try out.set(try clipboardOption(field.slice(), &.{ "text", "image", "files" }));
    }

    fn readClipboardDelivery(self: *Instance, out: *managed.Field) !void {
        var field: managed.Field = .{};
        try self.readField("clipboard-delivery", &field);
        try out.set(try clipboardOption(field.slice(), &.{ "folder", "clipboard" }));
    }

    fn prepareDevice(self: *Instance) void {
        self.start(.device_prepare, false, false, false, 0, false, "") catch |err| {
            self.reportError(err);
        };
    }

    fn savePreferences(self: *Instance) void {
        if (self.session_only) return self.status("本次会话的设置仅保留在窗口中。");
        var values: prefs.Values = .{};
        for (prefs.indices, 0..) |index, n| {
            const result = switch (index) {
                12 => self.readClipboardKind("send-clipboard-kind", &values.fields[n]),
                13 => self.readClipboardDelivery(&values.fields[n]),
                else => self.readField(field_names[index], &values.fields[n]),
            };
            result catch return self.feedback("输入无效，未保存设置。", true);
        }
        var buffer: [prefs.limit]u8 = undefined;
        const encoded = values.encode(&buffer) catch return self.feedback("设置过长，未保存。", true);
        _ = prefs.Values.decode(encoded) catch return self.feedback("请检查端口和通道等设置。", true);
        if (share_desktop_preferences_write(encoded.ptr, @intCast(encoded.len)) == 0) return self.feedback("无法写入本机设置。", true);
        self.saved = values;
        const kind = self.saved.value(12);
        const kind_index = if (std.mem.eql(u8, kind, "image")) "1" else if (std.mem.eql(u8, kind, "files")) "2" else "0";
        self.set("receive-clipboard-kind", kind_index);
        self.feedback("已保存设置。", false);
    }

    fn browse(self: *Instance, parent: bool) void {
        var buffer: [2048]u8 = undefined;
        const len = share_desktop_pick(1, &buffer, buffer.len);
        if (len < 0) return self.feedback("无法读取所选目录。", true);
        if (len == 0) return;
        const path = buffer[0..@intCast(len)];
        if (parent) {
            const root = std.mem.trimEnd(u8, path, "\\/");
            var store: [2048]u8 = undefined;
            var spool: [2048]u8 = undefined;
            self.set("store", std.fmt.bufPrint(&store, "{s}\\PulseShare-identity", .{root}) catch return self.feedback("目录太长。", true));
            self.set("spool", std.fmt.bufPrint(&spool, "{s}\\PulseShare-spool", .{root}) catch return self.feedback("目录太长。", true));
            self.status("已填入两个独立目录，请确认后创建。");
        } else {
            self.set("destination", path);
            self.updatePathLabels();
        }
    }

    fn pickSource(self: *Instance, folder: bool) void {
        var buffer: [2048]u8 = undefined;
        const len = share_desktop_pick(@intFromBool(folder), &buffer, buffer.len);
        if (len < 0) return self.feedback("无法读取所选文件或文件夹。", true);
        if (len == 0) return;
        const path = buffer[0..@intCast(len)];
        self.selected_batch.set(path) catch return self.feedback("所选路径过长或无效。", true);
        self.selected = if (folder) .{} else self.selected_batch;
        self.selection_count = 1;
        self.showSelection();
    }

    fn toggle(self: *Instance, section: Section) void {
        const i = @backingInt(section);
        self.expanded[i] = !self.expanded[i];
        const expanded = self.expanded[i];
        const key: []const u8, const id: [:0]const u8 = switch (section) {
            .send => .{ "show-send-options", "send-extras" },
            .receive => .{ "show-receive-options", "receive-extras" },
            .network => .{ "show-network-options", "network-options" },
            .storage => .{ "show-storage-options", "storage-options" },
            .address => .{ "show-address-field", "send-address-field" },
            .join => .{ "show-lan-join", "lan-join-form" },
        };
        self.set(key, if (expanded) "true" else "false");
        if (expanded) share_desktop_show_section(id);
        if (section == .join and !expanded) self.set("pair-input", "");
    }

    fn updatePathLabels(self: *Instance) void {
        var value: managed.Field = .{};
        self.readField("destination", &value) catch return;
        self.set("receive-location", if (value.len == 0) "未选择保存位置" else value.slice());
        self.readField("bind", &value) catch return;
        self.set("network-location", if (value.len == 0) "还没有选定本机网络，请打开网络设置。" else value.slice());
        const current_discovery = std.mem.eql(u8, value.slice(), self.discovery_bind.slice());
        self.set("show-found-receivers", if (current_discovery and self.endpoint_choices.count > 0) "true" else "false");
        self.set("show-found-pairing", if (current_discovery and self.pair_endpoint_choices.count > 0) "true" else "false");
        self.readField("store", &value) catch return;
        const peers = std.mem.eql(u8, value.slice(), self.peer_store.slice()) and self.peer_choices.count > 0;
        self.set("show-listed-peers", if (peers) "true" else "false");
        self.readField("peer", &value) catch return;
        self.set("send-endpoint", if (value.len == 0) "还没有选择对端地址" else value.slice());
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

    fn clearSelection(self: *Instance) void {
        if (self.task.occupied() or self.selection_count == 0) return;
        self.selected = .{};
        self.selected_batch = .{};
        self.selection_count = 0;
        self.showSelection();
        self.feedback("已清空待发送内容。", false);
    }

    fn showSelection(self: *Instance) void {
        self.set("show-source-clear", if (self.selection_count == 0) "false" else "true");
        var count: [72]u8 = undefined;
        self.set("source", if (self.selection_count == 0)
            "可将文件或文件夹拖到窗口，也可以点击下方按钮选择。"
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
                    if (self.task.request.mode == .peer_revoke) {
                        self.set("paired", "");
                        self.updateAlias();
                    } else {
                        self.set("paired", self.task.request.paired.slice());
                        self.updateAlias();
                        self.suggestName(if (self.task.request.routed) "routed-alias" else "pair-alias");
                        if (self.task.request.mode == .peer_add) {
                            self.set("advanced-pair-alias", "");
                            self.set("fingerprint", "");
                        }
                    }
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
            if (state == .completed) notice(result, false);
        }
        switch (self.task.request.mode) {
            .interfaces, .discover, .peer_list, .peer_add, .peer_revoke, .pair_host, .pair_join => self.render(true) catch self.set("status", "更新选项失败，请重新打开 Share"),
            else => {},
        }
        self.updatePathLabels();
        self.set("inventory", if (self.inventory_len == 0) "" else self.inventory[0..self.inventory_len]);
        if (self.task.request.mode != .send and self.task.request.mode != .receive) return;
        var line: [256]u8 = undefined;
        const record = std.fmt.bufPrint(&line, "{s} · {s} · {s}\r\n", .{
            if (self.task.request.mode == .send) "发送" else "接收",
            self.task.request.paired.slice(),
            switch (state) {
                .completed => "完成",
                .cancelled => "已取消",
                else => "失败或结果不确定",
            },
        }) catch return;
        // Keep only a bounded, session-local history; do not persist paths.
        while (record.len + self.history_len > self.history.len and self.history_len > 0) {
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

    fn openRoutedPair(self: *Instance, visible: bool) void {
        self.set("active-tab", "2");
        self.set("show-routed-pair", if (visible) "true" else "false");
        if (visible) {
            var current: managed.Field = .{};
            self.readField("routed-bind", &current) catch return;
            if (current.len == 0) {
                self.readField("bind", &current) catch return;
                self.set("routed-bind", current.slice());
            }
            self.readField("routed-alias", &current) catch return;
            if (current.len == 0) self.suggestName("routed-alias");
        } else self.set("routed-pair-input", "");
        share_desktop_show_section(if (visible) "routed-pair-card" else "pairing-card");
    }

    fn start(self: *Instance, mode: managed.Mode, advertise: bool, use_spool: bool, routed: bool, join_code: u32, quic: bool, batch_action: []const u8) !void {
        if (!managed.configured()) return error.Unavailable;
        if (managed.pairingMode(mode) and !managed.pairingConfigured()) return error.Unavailable;
        if (mode == .pair_join and (join_code == 0 or join_code > 100000000)) return error.Argument;
        if (self.task.occupied()) return error.State;
        const next = try std.heap.page_allocator.create(managed.Request);
        defer std.heap.page_allocator.destroy(next);
        @memcpy(std.mem.asBytes(next), std.mem.asBytes(&initial_request));
        next.mode = mode;
        next.advertise = advertise;
        next.routed = routed;
        next.quic = quic;
        const routed_pair = routed and managed.pairingMode(mode);
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
            const local_queue_action = next.queue_action.len != 0 and !std.mem.eql(u8, next.queue_action, "enqueue");
            const queue_manage_only = local_queue_action and !std.mem.eql(u8, next.queue_action, "run");
            if (local_queue_action) {
                try self.readField("queue-id", &next.queue_id);
                if (std.mem.eql(u8, next.queue_action, "list")) try self.readField("browse-offset", &next.browse_offset);
                if (std.mem.eql(u8, next.queue_action, "discard") and next.queue_id.len == 0) return error.Argument;
            }
            next.sync_clipboard = std.mem.eql(u8, batch_action, "share-sync-send") or std.mem.eql(u8, batch_action, "share-sync-receive");
            next.root_service = std.mem.eql(u8, batch_action, "share-directory-service");
            next.root_connect = std.mem.eql(u8, batch_action, "share-directory-connect");
            if (!local_queue_action and !std.mem.eql(u8, batch_action, "share-send-selection") and !std.mem.eql(u8, batch_action, "share-receive-selection")) {
                var transport: managed.Field = .{};
                try self.readField("batch-mode", &transport);
                const value = transport.slice();
                next.quic = std.mem.eql(u8, value, "quic") or std.mem.eql(u8, value, "quic-routed");
                next.routed = std.mem.eql(u8, value, "tcp-routed") or std.mem.eql(u8, value, "quic-routed");
                if (value.len != 0 and !next.quic and !next.routed and !std.mem.eql(u8, value, "tcp")) return error.Argument;
                try self.readField("channels", &next.channels);
            }
            if (std.mem.eql(u8, batch_action, "share-clipboard-send") or std.mem.eql(u8, batch_action, "share-sync-send")) {
                try self.readClipboardKind("send-clipboard-kind", &next.clipboard);
                if (next.clipboard.len == 0) return error.Argument;
            } else if (mode == .send and !queue_manage_only) next.sources = self.selected_batch;
            if (std.mem.eql(u8, batch_action, "share-clipboard-receive") or std.mem.eql(u8, batch_action, "share-sync-receive")) {
                next.clipboard_receive = true;
                try self.readClipboardKind("receive-clipboard-kind", &next.clipboard);
                if (next.sync_clipboard) {
                    next.delivery.set("clipboard") catch return error.Argument;
                } else try self.readClipboardDelivery(&next.delivery);
            }
            next.browse = std.mem.eql(u8, batch_action, "share-root-offer") or std.mem.eql(u8, batch_action, "share-root-receive") or next.root_connect;
            if (next.sync_clipboard and std.mem.eql(u8, next.clipboard.slice(), "files")) return error.AutoClipboardKind;
            if (mode == .receive) {
                if (!next.sync_clipboard) try self.readField("resume", &next.resume_path);
                if (next.browse) {
                    try self.readField("remote-path", &next.remote_path);
                    try self.readField("browse-offset", &next.browse_offset);
                }
            }
        }
        const local_queue_action = next.queue_action.len != 0 and !std.mem.eql(u8, next.queue_action, "enqueue");
        switch (mode) {
            .discover, .send, .receive, .pair_host, .pair_join => {
                if (!local_queue_action) try self.readField(if (routed_pair) "routed-bind" else "bind", &next.bind);
            },
            else => {},
        }
        if (mode != .discover and mode != .interfaces) try self.readField(if (use_spool) "spool" else "store", &next.store);
        const enrolling = managed.pairingMode(mode) or mode == .peer_add;
        const alias_field = if (routed_pair) "routed-alias" else if (mode == .peer_add) "advanced-pair-alias" else if (enrolling) "pair-alias" else "paired";
        switch (mode) {
            .send, .receive, .peer_add, .peer_revoke, .pair_host, .pair_join => {
                if (!local_queue_action) {
                    try self.readField(alias_field, &next.paired);
                    if (mode == .peer_add and next.paired.len == 0) {
                        self.readField("pair-alias", &next.paired) catch {};
                    }
                }
            },
            else => {},
        }
        if (enrolling and next.paired.len == 0) {
            var name: [64]u8 = undefined;
            try next.paired.set(try randomDeviceName(&name));
            self.set(alias_field, next.paired.slice());
        }
        if (next.paired.len != 0 and !choices.validPeerName(next.paired.slice())) return error.PeerNameFormat;
        if (mode == .peer_add) try self.readField("fingerprint", &next.fingerprint);
        if (mode == .send) {
            if (!next.batch and !local_queue_action) next.source = self.selected;
            if (!next.root_service and !local_queue_action) try self.readField("peer", &next.peer);
            if (next.root_service) {
                try self.readField("port", &next.port);
                if (next.routed) try self.readField("allowed-source", &next.allowed_source);
            }
            if (local_queue_action) {
                next.batch = false;
                next.quic = false;
                next.routed = false;
            }
        }
        if (mode == .pair_host) {
            try self.readField(if (routed_pair) "routed-pair-port" else "port", &next.port);
            if (next.port.len == 0) try next.port.set("0");
            if (routed_pair) {
                try self.readField("routed-pair-source", &next.allowed_source);
                if (next.allowed_source.len == 0) return error.RoutedPairSourceRequired;
            }
        }
        if (mode == .pair_join) try self.readField(if (routed_pair) "routed-pair-peer" else "pair-peer", &next.peer);
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
        if (next.peer.len > 0) {
            var address: [pair_ticket.capacity]u8 = undefined;
            if (pair_ticket.endpoint(next.peer.slice(), &address) == null) return error.PeerAddressFormat;
        }
        if (mode == .receive and !next.sync_clipboard and (next.destination.len == 0 or next.spool.len == 0)) return error.ReceiveDirectoriesRequired;
        if (mode == .receive and !next.sync_clipboard and !self.session_only and self.default_paths[1].len > 0 and
            std.ascii.eqlIgnoreCase(self.default_paths[1].slice(), next.spool.slice()))
        {
            next.prepare_default_parent = true;
            next.prepare_spool = true;
        }
        if (mode == .device_prepare) {
            try self.readField("spool", &next.spool);
            if (next.spool.len == 0) return error.ReceiveDirectoriesRequired;
            const paths = &self.default_paths;
            next.prepare_default_parent = (paths[0].len > 0 and std.ascii.eqlIgnoreCase(paths[0].slice(), next.store.slice())) or
                (paths[1].len > 0 and std.ascii.eqlIgnoreCase(paths[1].slice(), next.spool.slice()));
            if (self.session_only and next.prepare_default_parent) return error.SessionUseTestDirectories;
        }
        next.validate() catch return error.Argument;
        try self.task.start(next, join_code);
        self.active_service = serviceFor(batch_action);
        self.service_running = false;
        self.updateServices(.running, 0);
        self.popup_shown = false;
        self.shown_prompt = 0;
        self.set("status", switch (mode) {
            .discover => "正在查找附近设备…",
            .device_prepare => "正在准备本机身份和暂存目录…",
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
        self.updatePathLabels();
        switch (kind) {
            .endpoint => self.set("active-tab", "0"),
            .pair_endpoint => {
                if (!self.expanded[@backingInt(Section.join)]) self.toggle(.join);
                self.set("pair-help", "地址已填入。输入对端显示的连接码，再点「连接」。");
            },
            else => {},
        }
        self.status("已填入所选项，请核对后继续。");
    }

    noinline fn renderDevice(self: *Instance, temporary: std.mem.Allocator, fields: []const ui.Node) ![]const ui.Node {
        const local_options = try temporary.create(choices.Options);
        const endpoint_options = try temporary.create(choices.Options);
        const pair_endpoint_options = try temporary.create(choices.Options);
        const peer_options = try temporary.create(choices.Options);
        const pair_peer = try temporary.create(view.FieldNodes);
        pair_peer.* = .{};
        const pair_alias = try temporary.create(view.FieldNodes);
        pair_alias.* = .{};
        const route_fields = try temporary.alloc(view.FieldNodes, 5);
        @memset(route_fields, .{});
        const route_labels = [_][4][]const u8{
            .{ "routed-bind-field", "routed-bind-label", "routed-bind", "本机组网 IP" },
            .{ "routed-alias-field", "routed-alias-label", "routed-alias", "组网对端名称" },
            .{ "routed-port-field", "routed-port-label", "routed-pair-port", "生成端监听端口（0 自动）" },
            .{ "routed-source-field", "routed-source-label", "routed-pair-source", "允许连接的对端来源 IP" },
            .{ "routed-peer-field", "routed-peer-label", "routed-pair-peer", "对端组网地址与端口" },
        };
        const route_nodes = try temporary.alloc(ui.Node, route_labels.len);
        for (route_labels, 0..) |keys, i|
            route_nodes[i] = route_fields[i].buildCustom(keys[0], keys[1], keys[2], keys[3]);
        var code_input = view.input("pair-input", true);
        code_input.text = .{ .present = 1, .value = abi.view("输入对端显示的 8 位连接码") };
        const network_options = try temporary.alloc(ui.Node, 4);
        network_options[0] = fields[0];
        network_options[1] = view.button("列出本机地址", "share-interfaces", "standard", "state.idle");
        network_options[2] = view.select("local-options", "local-choice", "选择本机地址", self.local_choices.options(local_options));
        network_options[3] = view.button("填入本机地址", "share-use-local", "standard", "state.idle");
        const network_actions = try temporary.alloc(ui.Node, 2);
        network_actions[0] = view.button("查找附近设备", "share-discover", "primary", "state.idle");
        network_actions[1] = view.button("更改本机网络", "share-toggle-network", "standard", "state.ui-idle");
        const found_receivers = try temporary.alloc(ui.Node, 3);
        found_receivers[0] = view.text("receiver-options-label", "可接收的附近设备", "caption");
        found_receivers[1] = view.select("endpoint-options", "endpoint-choice", "可接收的附近设备", self.endpoint_choices.options(endpoint_options));
        found_receivers[2] = view.button("使用地址并进入发送", "share-use-endpoint", "standard", "state.idle");
        const found_pairing = try temporary.alloc(ui.Node, 3);
        found_pairing[0] = view.text("pair-endpoint-label", "等待配对的附近设备", "caption");
        found_pairing[1] = view.select("pair-endpoint-options", "pair-endpoint-choice", "等待配对的附近设备", self.pair_endpoint_choices.options(pair_endpoint_options));
        found_pairing[2] = view.button("填入配对地址", "share-use-pair-endpoint", "standard", "state.idle");
        const nearby_card = try temporary.alloc(ui.Node, 6);
        nearby_card[0] = view.bound("current-network", "state.network-location");
        nearby_card[1] = view.grid("network-actions", network_actions);
        nearby_card[2] = view.container(ui.NodeKind.stack, "network-options", network_options);
        nearby_card[3] = view.bound("discovery-text", "state.discovery");
        nearby_card[4] = view.container(ui.NodeKind.stack, "found-receivers", found_receivers);
        nearby_card[5] = view.container(ui.NodeKind.stack, "found-pairing", found_pairing);
        const pair_actions = try temporary.alloc(ui.Node, 2);
        pair_actions[0] = view.button("开启连接码并允许发现", "share-pair-host-advertise", "primary", "state.idle");
        pair_actions[1] = view.button("输入连接码", "share-toggle-join", "standard", "state.ui-idle");
        const pair_peer_field = pair_peer.buildCustom("pair-peer-group", "pair-peer-label", "pair-peer", "对端配对地址");
        pair_peer.children[1].placeholder = .{ .present = 1, .value = abi.view("例如 192.168.1.21:45843") };
        route_fields[4].children[1].placeholder = .{ .present = 1, .value = abi.view("例如 100.64.1.20:45843") };
        const join_form = try temporary.alloc(ui.Node, 4);
        join_form[0] = pair_peer_field;
        join_form[1] = view.text("pair-input-label", "对端的 8 位连接码", "caption");
        join_form[2] = code_input;
        join_form[3] = view.button("连接", "share-pair-join", "primary", "state.idle");
        const pairing_card = try temporary.alloc(ui.Node, 7);
        pairing_card[0] = view.button("首次使用：初始化本机", "share-prepare-device", "standard", "state.idle");
        pairing_card[1] = pair_alias.buildCustom("pair-alias-field", "pair-alias-label", "pair-alias", "配对名称");
        pairing_card[2] = view.grid("pair-actions", pair_actions);
        pairing_card[3] = view.button("粘贴配对信息", "share-paste-pair", "standard", "state.ui-idle");
        pairing_card[4] = view.bound("pair-help", "state.pair-help");
        pairing_card[5] = view.container(ui.NodeKind.stack, "lan-join-form", join_form);
        pairing_card[6] = view.button("已组网？手动配对", "share-show-routed-pair", "standard", "state.ui-idle");
        const routed_pair_card = try temporary.alloc(ui.Node, 11);
        routed_pair_card[0] = view.text("routed-pair-note", "使用两台设备现有的私有或虚拟组网地址。手动连接后，两边都需核对并确认指纹。", "body");
        routed_pair_card[1] = route_nodes[0];
        routed_pair_card[2] = route_nodes[1];
        routed_pair_card[3] = route_nodes[2];
        routed_pair_card[4] = route_nodes[3];
        routed_pair_card[5] = view.button("生成组网连接码", "share-pair-host-routed", "primary", "state.idle");
        routed_pair_card[6] = route_nodes[4];
        routed_pair_card[7] = view.text("routed-pair-code-label", "对端显示的 8 位组网连接码", "caption");
        routed_pair_card[8] = view.input("routed-pair-input", true);
        routed_pair_card[9] = view.button("连接组网设备", "share-pair-join-routed", "primary", "state.idle");
        routed_pair_card[10] = view.button("收起组网配对", "share-close-routed-pair", "standard", "state.ui-idle");
        const listed_peers = try temporary.alloc(ui.Node, 2);
        listed_peers[0] = view.select("peer-options", "peer-choice", "选择已配对设备", self.peer_choices.options(peer_options));
        listed_peers[1] = view.button("设为当前对端", "share-use-peer", "standard", "state.idle");
        const trusted_card = try temporary.alloc(ui.Node, 3);
        trusted_card[0] = fields[3];
        trusted_card[1] = view.button("刷新已配对设备", "share-peer-list", "standard", "state.idle");
        trusted_card[2] = view.container(ui.NodeKind.stack, "listed-peers", listed_peers);
        const device_content = try temporary.alloc(ui.Node, 5);
        device_content[0] = view.text("devices-heading", "设备", "section");
        device_content[1] = view.group("nearby-card", "附近设备", nearby_card);
        device_content[2] = view.group("pairing-card", "配对新设备", pairing_card);
        device_content[3] = view.group("routed-pair-card", "组网配对", routed_pair_card);
        device_content[4] = view.group("trusted-card", "已配对的设备", trusted_card);
        return device_content;
    }

    noinline fn renderSend(temporary: std.mem.Allocator, fields: []const ui.Node) ![]const ui.Node {
        const file_actions = try temporary.alloc(ui.Node, 2);
        file_actions[0] = view.button("选择文件", "share-pick-file", "standard", "state.ui-idle");
        file_actions[1] = view.button("选择文件夹", "share-pick-folder", "standard", "state.ui-idle");
        const clear_action = try temporary.alloc(ui.Node, 1);
        clear_action[0] = view.button("清空选择", "share-clear-selection", "standard", "state.ui-idle");
        const source_card = try temporary.alloc(ui.Node, 3);
        source_card[0] = view.bound("source", "state.source");
        source_card[1] = view.grid("file-actions", file_actions);
        source_card[2] = view.container(ui.NodeKind.stack, "source-clear", clear_action);
        const send_actions = try temporary.alloc(ui.Node, 2);
        send_actions[0] = view.button("选设备", "share-open-devices", "standard", "state.ui-idle");
        send_actions[1] = view.button("发送", "share-send-selection", "primary", "state.idle");
        const address_field = try temporary.alloc(ui.Node, 1);
        address_field[0] = fields[1];
        const target_card = try temporary.alloc(ui.Node, 5);
        target_card[0] = view.bound("current-peer", "state.current-peer");
        target_card[1] = view.bound("send-endpoint-label", "state.send-endpoint");
        target_card[2] = view.button("手动输入对端地址", "share-toggle-address", "standard", "state.ui-idle");
        target_card[3] = view.container(ui.NodeKind.stack, "send-address-field", address_field);
        target_card[4] = view.grid("send-actions", send_actions);
        const send_cards = try temporary.alloc(ui.Node, 2);
        send_cards[0] = view.group("source-card", "待发送内容", source_card);
        send_cards[1] = view.group("target-card", "接收设备", target_card);
        const send_clipboard_actions = try temporary.alloc(ui.Node, 2);
        send_clipboard_actions[0] = view.button("发送剪贴板", "share-clipboard-send", "standard", "state.idle");
        send_clipboard_actions[1] = view.action("开启自动发送剪贴板", "share-sync-send", "state.sync-send-caption", "state.sync-send-enabled");
        const send_clipboard = try temporary.alloc(ui.Node, 3);
        send_clipboard[0] = view.text("send-clipboard-label", "内容类型", "caption");
        send_clipboard[1] = view.select("send-clipboard-select", "send-clipboard-kind", "内容类型", &clipboard_names);
        send_clipboard[2] = view.grid("send-clipboard-actions", send_clipboard_actions);
        const send_directory_actions = try temporary.alloc(ui.Node, 2);
        send_directory_actions[0] = view.button("提供只读目录", "share-root-offer", "standard", "state.idle");
        send_directory_actions[1] = view.action("开启只读目录服务", "share-directory-service", "state.directory-caption", "state.directory-enabled");
        const send_queue_actions = try temporary.alloc(ui.Node, 3);
        send_queue_actions[0] = view.button("将选中项目加入队列", "share-queue-add", "standard", "state.idle");
        send_queue_actions[1] = view.button("查看发送队列", "share-queue-list", "standard", "state.idle");
        send_queue_actions[2] = view.button("发送队列中的待发项目", "share-queue-run", "standard", "state.idle");
        const send_extras = try temporary.alloc(ui.Node, 4);
        send_extras[0] = view.group("send-clipboard", "剪贴板", send_clipboard);
        send_extras[1] = view.group("send-directory", "目录共享", send_directory_actions);
        send_extras[2] = view.group("send-queue", "发送队列", send_queue_actions);
        send_extras[3] = view.bound("send-inventory", "state.inventory");
        const send_content = try temporary.alloc(ui.Node, 4);
        send_content[0] = view.text("send-heading", "发送文件或文件夹", "section");
        send_content[1] = view.grid("send-cards", send_cards);
        send_content[2] = view.button("更多发送方式", "share-toggle-send", "standard", "state.ui-idle");
        send_content[3] = view.container(ui.NodeKind.stack, "send-extras", send_extras);
        return send_content;
    }

    noinline fn renderReceive(temporary: std.mem.Allocator) ![]const ui.Node {
        const alternate_receive = try temporary.alloc(ui.Node, 2);
        alternate_receive[0] = view.button("接收单文件（不广播）", "share-receive", "standard", "state.idle");
        alternate_receive[1] = view.button("接收文件夹 / 多文件", "share-receive-selection", "standard", "state.idle");
        const receive_clipboard_actions = try temporary.alloc(ui.Node, 2);
        receive_clipboard_actions[0] = view.button("接收剪贴板", "share-clipboard-receive", "standard", "state.idle");
        receive_clipboard_actions[1] = view.action("开启自动接收剪贴板", "share-sync-receive", "state.sync-receive-caption", "state.sync-receive-enabled");
        const receive_clipboard = try temporary.alloc(ui.Node, 5);
        receive_clipboard[0] = view.text("receive-clipboard-label", "内容类型", "caption");
        receive_clipboard[1] = view.select("receive-clipboard-select", "receive-clipboard-kind", "内容类型", &clipboard_names);
        receive_clipboard[2] = view.text("clipboard-delivery-label", "接收后放到", "caption");
        receive_clipboard[3] = view.select("clipboard-delivery-select", "clipboard-delivery", "接收后放到", &delivery_names);
        receive_clipboard[4] = view.grid("receive-clipboard-actions", receive_clipboard_actions);
        const receive_directory_actions = try temporary.alloc(ui.Node, 2);
        receive_directory_actions[0] = view.button("浏览或下载对端目录", "share-root-receive", "standard", "state.idle");
        receive_directory_actions[1] = view.button("连接只读目录服务", "share-directory-connect", "standard", "state.idle");
        const receive_extras = try temporary.alloc(ui.Node, 3);
        receive_extras[0] = view.group("receive-clipboard", "剪贴板", receive_clipboard);
        receive_extras[1] = view.group("receive-directory", "目录共享", receive_directory_actions);
        receive_extras[2] = view.bound("receive-inventory", "state.inventory");
        const receive_card = try temporary.alloc(ui.Node, 6);
        receive_card[0] = view.bound("save-location", "state.receive-location");
        receive_card[1] = view.button("更改保存位置", "share-browse-destination", "standard", "state.ui-idle");
        receive_card[2] = view.bound("receive-peer", "state.current-peer");
        receive_card[3] = view.button("开始接收单文件 · 允许附近发现", "share-receive-advertise", "primary", "state.idle");
        receive_card[4] = view.grid("receive-options", alternate_receive);
        receive_card[5] = view.text("receive-confirm", "发送单个文件用「单文件」接收，发送文件夹或多文件用「文件夹 / 多文件」接收；收到请求后在下方核对确认。", "caption");
        const receive_content = try temporary.alloc(ui.Node, 4);
        receive_content[0] = view.text("receive-heading", "接收文件", "section");
        receive_content[1] = view.group("receive-card", "保存位置", receive_card);
        receive_content[2] = view.button("更多接收方式", "share-toggle-receive", "standard", "state.ui-idle");
        receive_content[3] = view.container(ui.NodeKind.stack, "receive-extras", receive_extras);
        return receive_content;
    }

    noinline fn renderAdvanced(temporary: std.mem.Allocator, fields: []const ui.Node) ![]const ui.Node {
        const routed_actions = try temporary.alloc(ui.Node, 2);
        routed_actions[0] = view.button("发送（组网/转发）", "share-send-routed", "standard", "state.idle");
        routed_actions[1] = view.button("接收（组网/转发）", "share-receive-routed", "standard", "state.idle");
        const quic_actions = try temporary.alloc(ui.Node, 4);
        quic_actions[0] = view.button("QUIC 发送", "share-send-quic", "standard", "state.idle");
        quic_actions[1] = view.button("QUIC 接收", "share-receive-quic", "standard", "state.idle");
        quic_actions[2] = view.button("QUIC 组网发送", "share-send-quic-routed", "standard", "state.idle");
        quic_actions[3] = view.button("QUIC 组网接收", "share-receive-quic-routed", "standard", "state.idle");
        const batch_actions = try temporary.alloc(ui.Node, 2);
        batch_actions[0] = view.button("按批量选项发送选中项", "share-batch-send", "standard", "state.idle");
        batch_actions[1] = view.button("按批量选项接收或恢复", "share-batch-receive", "standard", "state.idle");
        const queue_actions = try temporary.alloc(ui.Node, 2);
        queue_actions[0] = view.button("放弃指定任务", "share-queue-discard", "standard", "state.idle");
        queue_actions[1] = view.button("清理终态记录", "share-queue-prune", "standard", "state.idle");
        const advanced_pair_actions = try temporary.alloc(ui.Node, 5);
        advanced_pair_actions[0] = view.button("开启连接码（不广播）", "share-pair-host", "standard", "state.idle");
        advanced_pair_actions[1] = view.button("显示本机指纹", "share-identity-show", "standard", "state.idle");
        advanced_pair_actions[2] = view.button("打开组网配对", "share-open-routed-pair", "standard", "state.ui-idle");
        advanced_pair_actions[3] = view.button("手动指纹配对", "share-peer-add", "standard", "state.idle");
        advanced_pair_actions[4] = view.button("撤销当前配对", "share-peer-revoke", "danger", "state.idle");
        const advanced_alias = try temporary.create(view.FieldNodes);
        advanced_alias.* = .{};
        const advanced_alias_field = advanced_alias.buildCustom("advanced-alias-field", "advanced-alias-label", "advanced-pair-alias", "新配对设备名称（用于手动指纹配对）");
        advanced_alias.children[1].placeholder = .{ .present = 1, .value = abi.view("留空自动生成名称") };
        const advanced_pair = try temporary.alloc(ui.Node, 5);
        advanced_pair[0] = view.bound("advanced-current-peer", "state.current-peer");
        advanced_pair[1] = advanced_alias_field;
        advanced_pair[2] = fields[7];
        advanced_pair[3] = view.text("advanced-pair-help", "手动指纹配对前，请通过另一渠道核对完整指纹；「撤销当前配对」将撤销上方显示的当前对端。", "caption");
        advanced_pair[4] = view.grid("advanced-pair-actions", advanced_pair_actions);
        const transport = try temporary.alloc(ui.Node, 5);
        transport[0] = view.text("routed-help", "高级：仅已配对设备。使用具体数字 IP 和端口；接收须填写实际 TCP 来源 IP（代理场景可为代理地址）。不自动映射端口。", "caption");
        transport[1] = fields[8];
        transport[2] = view.grid("routed-actions", routed_actions);
        transport[3] = view.text("quic-help", "QUIC：使用 UDP，双方手动选择 QUIC，不自动回退 TCP；目前仅单文件。", "caption");
        transport[4] = view.grid("quic-actions", quic_actions);
        const batch_options = try temporary.alloc(ui.Node, 7);
        batch_options[0] = view.text("batch-help", "批量使用已配对设备。选择协议、通道和接收选项；多选路径受宿主命令长度限制。恢复须手动选择原事务。", "caption");
        batch_options[1] = fields[9];
        batch_options[2] = fields[10];
        batch_options[3] = fields[11];
        batch_options[4] = fields[14];
        batch_options[5] = fields[15];
        batch_options[6] = view.grid("batch-actions", batch_actions);
        const queue_and_services = try temporary.alloc(ui.Node, 4);
        queue_and_services[0] = fields[16];
        queue_and_services[1] = view.text("queue-help", "队列保存在私有身份目录。留空 ID 分页查看或运行全部待发任务；每页 20 条，使用列表偏移。放弃需指定 ID。结果不确定时先检查接收端。", "caption");
        queue_and_services[2] = view.grid("queue-actions", queue_actions);
        queue_and_services[3] = view.bound("batch-inventory", "state.inventory");
        const advanced_content = try temporary.alloc(ui.Node, 5);
        advanced_content[0] = view.text("advanced-heading", "高级操作", "section");
        advanced_content[1] = view.group("advanced-pair-card", "高级配对", advanced_pair);
        advanced_content[2] = view.group("transport-card", "组网与 QUIC", transport);
        advanced_content[3] = view.group("batch-card", "批量与内容类型", batch_options);
        advanced_content[4] = view.group("queue-card", "队列与服务", queue_and_services);
        return advanced_content;
    }

    noinline fn renderSetup(temporary: std.mem.Allocator, fields: []const ui.Node) ![]const ui.Node {
        const setup_actions = try temporary.alloc(ui.Node, 2);
        setup_actions[0] = view.button("应用已保存设置", "share-apply-prefs", "standard", "state.ui-idle");
        setup_actions[1] = view.button("保存当前配置", "share-save-prefs", "primary", "state.ui-idle");
        const storage_options = try temporary.alloc(ui.Node, 5);
        storage_options[0] = view.button("选择身份和暂存的父文件夹", "share-browse-parent", "standard", "state.ui-idle");
        storage_options[1] = fields[2];
        storage_options[2] = fields[5];
        storage_options[3] = fields[4];
        storage_options[4] = fields[6];
        const setup_card = try temporary.alloc(ui.Node, 5);
        setup_card[0] = view.text("setup-help", "接收文件默认存到「下载」。首次使用可直接初始化本机。", "body");
        setup_card[1] = view.button("初始化本机身份和暂存", "share-prepare-from-settings", "primary", "state.idle");
        setup_card[2] = view.button("更改存储位置和端口", "share-toggle-storage", "standard", "state.ui-idle");
        setup_card[3] = view.container(ui.NodeKind.stack, "storage-options", storage_options);
        setup_card[4] = view.grid("setup-actions", setup_actions);
        const maintenance_buttons = try temporary.alloc(ui.Node, 2);
        maintenance_buttons[0] = view.button("检查暂存残留", "share-spool-recovery", "standard", "state.idle");
        maintenance_buttons[1] = view.button("检查身份目录残留", "share-recovery-list", "standard", "state.idle");
        const maintenance_card = try temporary.alloc(ui.Node, 2);
        maintenance_card[0] = view.grid("maintenance-buttons", maintenance_buttons);
        maintenance_card[1] = view.bound("setup-inventory", "state.inventory");
        const setup_content = try temporary.alloc(ui.Node, 3);
        setup_content[0] = view.text("setup-heading", "设置", "section");
        setup_content[1] = view.group("setup-card", "设备与存储", setup_card);
        setup_content[2] = view.group("maintenance-card", "维护", maintenance_card);
        return setup_content;
    }

    noinline fn renderHistory(temporary: std.mem.Allocator) ![]const ui.Node {
        const diagnostic_card = try temporary.alloc(ui.Node, 2);
        diagnostic_card[0] = view.bound("diagnostic-text", "state.diagnostic");
        diagnostic_card[1] = view.button("导出诊断…", "share-export-diagnostics", "standard", "state.ui-idle");
        const history_content = try temporary.alloc(ui.Node, 3);
        history_content[0] = view.text("history-heading", "记录", "section");
        history_content[1] = view.bound("history-text", "state.history");
        history_content[2] = view.group("diagnostic-card", "诊断", diagnostic_card);
        return history_content;
    }

    fn render(self: *Instance, update: bool) !void {
        // The native panel synchronously copies the tree. Allocate a bounded
        // per-render arena so nested node arrays never accumulate on the UI stack.
        var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
        defer arena.deinit();
        const temporary = arena.allocator();
        const storage = try temporary.alloc(view.FieldNodes, field_names.len);
        @memset(storage, .{});
        const fields = try temporary.alloc(ui.Node, field_names.len);
        for (storage, 0..) |*item, n| fields[n] = item.build(n);
        const device_content = try self.renderDevice(temporary, fields);
        const send_content = try renderSend(temporary, fields);
        const receive_content = try renderReceive(temporary);
        const advanced_content = try renderAdvanced(temporary, fields);
        const setup_content = try renderSetup(temporary, fields);
        const history_content = try renderHistory(temporary);
        const tabs_children = try temporary.alloc(ui.Node, 6);
        tabs_children[0] = view.tab("send-tab", "发送", send_content);
        tabs_children[1] = view.tab("receive-tab", "接收", receive_content);
        tabs_children[2] = view.tab("devices-tab", "设备", device_content);
        tabs_children[3] = view.tab("history-tab", "记录", history_content);
        tabs_children[4] = view.tab("setup-tab", "设置", setup_content);
        tabs_children[5] = view.tab("advanced-tab", "高级", advanced_content);
        var tabs = view.container(ui.NodeKind.tabs, "share-tabs", tabs_children);
        tabs.state = .{ .present = 1, .value = abi.view("active-tab") };
        var bar = ui.node(ui.NodeKind.progress);
        bar.id = abi.view("transfer-progress");
        bar.binding = .{ .present = 1, .value = abi.view("state.progress") };
        const controls = try temporary.alloc(ui.Node, 5);
        controls[0] = view.button("查看配对信息", "share-open-pair-popup", "standard", "state.pair-popup-ready");
        controls[1] = view.action("复制接收地址", "share-copy-address", "state.copy-address-caption", "state.copy-address-ready");
        controls[2] = view.button("取消任务", "share-cancel", "danger", "state.busy");
        controls[3] = view.button("确认请求", "share-approve", "primary", "state.confirm");
        controls[4] = view.button("拒绝请求", "share-decline", "standard", "state.confirm");
        const task_content = try temporary.alloc(ui.Node, 5);
        task_content[0] = view.bound("pair-code", "state.pair-code");
        task_content[1] = view.bound("status-line", "state.status");
        task_content[2] = bar;
        task_content[3] = view.bound("byte-count", "state.bytes");
        task_content[4] = view.grid("task-controls", controls);
        const children = try temporary.alloc(ui.Node, 2);
        children[0] = view.group("task-group", "当前任务", task_content);
        children[1] = tabs;
        const root = view.container(ui.NodeKind.stack, "share-root", children);
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
        self.set("show-routed-pair", "false");
        self.set("pair-popup-ready", "false");
        self.set("copy-address-ready", "false");
        self.set("copy-address-caption", "复制接收地址");
        self.set("routed-pair-port", "0");
        self.suggestName("pair-alias");
        self.suggestName("routed-alias");
        self.set("ui-idle", "true");
        self.set("busy", "false");
        self.set("confirm", "false");
        self.set("history", "本次会话尚无传输记录");
        self.set("diagnostic", self.diagnostics.latest);
        self.updateServices(null, 0);
        self.set("discovery", "点击「查找附近设备」查看结果。");
        self.set("pair-help", "请在两台设备上核对并确认指纹。");
        self.showSelection();
        self.updateAlias();
    }
};

fn command(self: *Instance, name: []const u8) void {
    if (std.mem.eql(u8, name, "share-export-diagnostics")) return self.exportDiagnostics();
    if (serviceFor(name)) |service| {
        if (self.active_service == service and self.task.occupied()) {
            self.task.cancel();
            self.updateServices(.cancelling, 0);
            self.set("confirm", "false");
            self.shown_prompt = 0;
            return self.status("正在停止会话…");
        }
    }
    if (std.mem.eql(u8, name, "share-paste-pair")) return self.pastePairInfo();
    if (std.mem.eql(u8, name, "share-copy-address")) return self.quickCopy(false, false);
    if (std.mem.eql(u8, name, "share-copy-pair")) return self.quickCopy(true, false);
    if (std.mem.eql(u8, name, "share-open-pair-popup")) return self.quickCopy(true, true);
    if (std.mem.eql(u8, name, "share-receive-selection")) {
        self.start(.receive, false, false, false, 0, false, name) catch |err| self.reportError(err);
        return;
    }
    if (std.mem.eql(u8, name, "share-prepare-device") or std.mem.eql(u8, name, "share-prepare-from-settings"))
        return self.prepareDevice();
    if (std.mem.eql(u8, name, "share-open-routed-pair") or std.mem.eql(u8, name, "share-show-routed-pair"))
        return self.openRoutedPair(true);
    if (std.mem.eql(u8, name, "share-close-routed-pair")) return self.openRoutedPair(false);
    if (std.mem.eql(u8, name, "share-toggle-send")) return self.toggle(.send);
    if (std.mem.eql(u8, name, "share-toggle-receive")) return self.toggle(.receive);
    if (std.mem.eql(u8, name, "share-toggle-network")) return self.toggle(.network);
    if (std.mem.eql(u8, name, "share-toggle-storage")) return self.toggle(.storage);
    if (std.mem.eql(u8, name, "share-toggle-address")) return self.toggle(.address);
    if (std.mem.eql(u8, name, "share-toggle-join")) return self.toggle(.join);
    if (std.mem.eql(u8, name, "share-open-devices")) return self.set("active-tab", "2");
    if (std.mem.eql(u8, name, "share-pick-file")) return self.pickSource(false);
    if (std.mem.eql(u8, name, "share-pick-folder")) return self.pickSource(true);
    if (std.mem.eql(u8, name, "share-clear-selection")) return self.clearSelection();
    if (std.mem.eql(u8, name, "share-send-selection")) {
        if (self.selected_batch.len == 0) return self.feedback("请先选择文件或文件夹。", true);
        self.start(.send, false, false, false, 0, false, if (self.selected.len > 0) "" else "share-send-selection") catch |err| self.reportError(err);
        return;
    }
    if (std.mem.eql(u8, name, "share-pair-host") or std.mem.eql(u8, name, "share-pair-host-routed") or std.mem.eql(u8, name, "share-pair-host-advertise")) {
        const routed = std.mem.eql(u8, name, "share-pair-host-routed");
        self.start(.pair_host, std.mem.eql(u8, name, "share-pair-host-advertise"), false, routed, 0, false, "") catch |err| return self.reportError(err);
        self.set("active-tab", "2");
        return;
    }
    if (std.mem.eql(u8, name, "share-pair-join") or std.mem.eql(u8, name, "share-pair-join-routed")) {
        const routed = std.mem.eql(u8, name, "share-pair-join-routed");
        const key = if (routed) "routed-pair-input" else "pair-input";
        var value: [24]u8 = @splat(0);
        defer @memset(&value, 0);
        const panel = self.panel orelse return;
        const input = panel.read(key, &value) catch return self.feedback("请输入完整的 8 位连接码。", true);
        const code = managed.parseCode(input) catch return self.feedback("请输入完整的 8 位连接码。", true);
        self.start(.pair_join, false, false, routed, code, false, "") catch |err| return self.reportError(err);
        self.set(key, "");
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
        self.clearPairClipboard(0);
        share_desktop_pair_clear(1);
        self.set("pair-input", "");
        self.set("routed-pair-input", "");
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
        self.start(if (sending) .send else .receive, false, false, false, 0, false, name) catch |err| self.reportError(err);
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
    self.start(mode, std.mem.eql(u8, name, "share-receive-advertise"), std.mem.eql(u8, name, "share-spool-init") or std.mem.eql(u8, name, "share-spool-recovery"), std.mem.eql(u8, name, "share-send-routed") or std.mem.eql(u8, name, "share-receive-routed") or std.mem.eql(u8, name, "share-send-quic-routed") or std.mem.eql(u8, name, "share-receive-quic-routed"), 0, std.mem.eql(u8, name, "share-send-quic") or std.mem.eql(u8, name, "share-receive-quic") or std.mem.eql(u8, name, "share-send-quic-routed") or std.mem.eql(u8, name, "share-receive-quic-routed"), "") catch |err| self.reportError(err);
}

var instance: Instance = .{};

fn formatByteSize(buffer: []u8, bytes: u64) []const u8 {
    if (bytes >= 1024 * 1024 * 1024) {
        const whole = bytes / (1024 * 1024 * 1024);
        const tenths = (bytes % (1024 * 1024 * 1024)) * 10 / (1024 * 1024 * 1024);
        return std.fmt.bufPrint(buffer, "{d}.{d} GB", .{ whole, tenths }) catch "";
    }
    if (bytes >= 1024 * 1024) {
        const whole = bytes / (1024 * 1024);
        const tenths = (bytes % (1024 * 1024)) * 10 / (1024 * 1024);
        return std.fmt.bufPrint(buffer, "{d}.{d} MB", .{ whole, tenths }) catch "";
    }
    if (bytes >= 1024) {
        const whole = bytes / 1024;
        const tenths = (bytes % 1024) * 10 / 1024;
        return std.fmt.bufPrint(buffer, "{d}.{d} KB", .{ whole, tenths }) catch "";
    }
    return std.fmt.bufPrint(buffer, "{d} B", .{bytes}) catch "";
}

fn canClassifyService(service: ?Service, snapshot: *const task_mod.Snapshot) bool {
    return switch (service orelse return false) {
        .clipboard_send, .clipboard_receive => snapshot.clipboard_sync_active,
        .directory_host => snapshot.endpoint_len > 0,
    };
}

fn randomDeviceName(buffer: []u8) ![]const u8 {
    const words = [_][]const u8{ "薄荷", "松果", "海盐", "星河", "青柠", "月光", "清风", "小舟" };
    const nonce = share_desktop_label_nonce();
    return std.fmt.bufPrint(buffer, "{s}-{x:0>6}", .{ words[nonce % words.len], (nonce >> 8) & 0xffffff });
}

fn clipboardOption(value: []const u8, options: []const []const u8) ![]const u8 {
    const i = std.fmt.parseInt(usize, value, 10) catch return error.Argument;
    if (i >= options.len) return error.Argument;
    return options[i];
}

fn errorMessage(err: anyerror) []const u8 {
    return switch (err) {
        error.LocalAddressRequired => "请在「设备」页选择本机网络地址。",
        error.IdentityRequired => "请在「设置」页选择并初始化设备身份目录。",
        error.DeviceNameRequired => "请在「设备」页选择已配对设备。",
        error.PeerNameFormat => "配对名称可用中文、英文或数字，最多 48 个字符，请去掉路径符号或控制字符。",
        error.PeerAddressFormat => "请输入数字 IP 和端口，例如 192.168.1.21:45843。IPv6 请加方括号。",
        error.PeerAddressRequired => "请填写对端配对地址和端口，或从查找结果中选择。",
        error.AutoClipboardKind => "自动同步支持文本和图片。文件请用「发送剪贴板」或「接收剪贴板」。",
        error.SessionUseTestDirectories => "会话模式下，请在设置页选择独立的测试身份和暂存目录。",
        error.RoutedPairSourceRequired => "请填写允许连接的对端来源 IP。",
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
    const key = std.mem.span(name);
    if (std.mem.eql(u8, key, "paired")) instance.updateAlias();
    if (std.mem.eql(u8, key, "bind") or std.mem.eql(u8, key, "destination") or
        std.mem.eql(u8, key, "peer") or std.mem.eql(u8, key, "store")) instance.updatePathLabels();
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
    instance.clearPairClipboard(0);
    share_desktop_pair_clear(1);
    instance.set("confirm", "false");
    instance.set("pair-code", "");
    instance.set("pair-input", "");
    instance.set("routed-pair-input", "");
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
    instance.loadDefaults();
    if (share_desktop_create() == 0) return error.WindowCreation;
    if (selection.count > 0) instance.applySelection(selection) catch {
        failure = "Pulse 选区不可用，请在此窗口重新选择文件。";
    };
    try instance.render(false);
    if (failure.len > 0) instance.status(failure);
    share_desktop_run();
}
