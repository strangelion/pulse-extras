//! Host-rendered native controls only. Every editable field has a separate
//! visible label because some host renderers do not draw textInput.text.
const std = @import("std");
const abi = @import("pulse_abi");
const ui = @import("pulse_ui_model");

pub const fields = [_][]const u8{ "bind", "peer", "store", "paired", "destination", "spool", "port", "fingerprint", "allowed-source", "batch-mode", "channels", "resume", "clipboard-kind", "delivery", "remote-path", "browse-offset", "queue-id" };
pub const labels = [_][]const u8{ "本机网络地址", "对端地址与端口", "设备身份目录", "已配对设备名称", "接收目录", "私有暂存目录", "监听端口", "对端 SHA-256 指纹", "远程接收来源 IP（高级）", "批量协议模式", "并行通道", "恢复事务路径", "剪贴板类型", "剪贴板接收去向", "远程相对路径", "目录 / 队列列表偏移", "队列任务 ID" };
pub const hints = [_][]const u8{ "例如 192.168.1.20 或 ::1", "例如 192.168.1.21:45843", "例如 C:\\ShareTest\\identity", "例如 laptop", "例如 D:\\Received", "例如 C:\\ShareTest\\spool", "0 = 自动分配", "64 位十六进制指纹", "例如 100.64.1.2 或 127.0.0.1", "tcp / quic / tcp-routed / quic-routed", "0 自适应；1–32 固定", "留空新建；或私有暂存目录中的事务路径", "text / image / files", "folder / clipboard", "留空列目录；. 全部；或准确相对路径", "0、20、40…", "留空查看全部；放弃需指定 ID" };
const label_ids = [_][]const u8{ "label-bind", "label-peer", "label-store", "label-paired", "label-destination", "label-spool", "label-port", "label-fingerprint", "label-allowed-source", "label-batch-mode", "label-channels", "label-resume", "label-clipboard-kind", "label-delivery", "label-remote-path", "label-browse-offset", "label-queue-id" };
const group_ids = [_][]const u8{ "field-bind", "field-peer", "field-store", "field-paired", "field-destination", "field-spool", "field-port", "field-fingerprint", "field-allowed-source", "field-batch-mode", "field-channels", "field-resume", "field-clipboard-kind", "field-delivery", "field-remote-path", "field-browse-offset", "field-queue-id" };

pub fn text(id: []const u8, value: []const u8, role: []const u8) ui.Node {
    var n = ui.text(value);
    n.id = abi.view(id);
    n.role = .{ .present = 1, .value = abi.view(role) };
    return n;
}

pub fn bound(id: []const u8, key: []const u8) ui.Node {
    var n = ui.node(ui.NodeKind.text);
    n.id = abi.view(id);
    n.binding = .{ .present = 1, .value = abi.view(key) };
    return n;
}

pub fn container(kind: u32, id: []const u8, children: []const ui.Node) ui.Node {
    var n = ui.node(kind);
    n.id = abi.view(id);
    n.gap = .{ .present = 1, .value = 8 };
    ui.withChildren(&n, children);
    return n;
}

pub fn group(id: []const u8, title: []const u8, children: []const ui.Node) ui.Node {
    var n = container(ui.NodeKind.group, id, children);
    n.text = .{ .present = 1, .value = abi.view(title) };
    n.bordered = .{ .present = 1, .value = 1 };
    return n;
}

pub fn grid(id: []const u8, children: []const ui.Node) ui.Node {
    var n = container(ui.NodeKind.grid, id, children);
    n.columns = .{ .present = 1, .value = 2 };
    return n;
}

pub fn tab(id: []const u8, title: []const u8, children: []const ui.Node) ui.Node {
    var n = container(ui.NodeKind.tab, id, children);
    n.text = .{ .present = 1, .value = abi.view(title) };
    return n;
}

pub fn button(label: []const u8, command: []const u8, kind: []const u8, enabled: ?[]const u8) ui.Node {
    var n = ui.button(label, command);
    n.id = abi.view(command);
    n.kind = .{ .present = 1, .value = abi.view(kind) };
    if (enabled) |key| n.enabled_binding = .{ .present = 1, .value = abi.view(key) };
    return n;
}

pub fn select(id: []const u8, state: []const u8, label: []const u8, options: []const abi.StringView) ui.Node {
    var n = ui.node(ui.NodeKind.select);
    n.id = abi.view(id);
    n.text = .{ .present = 1, .value = abi.view(label) };
    n.state = .{ .present = 1, .value = abi.view(state) };
    n.options = .{ .present = 1, .data = options.ptr, .count = @intCast(options.len) };
    n.enabled_binding = .{ .present = 1, .value = abi.view("state.idle") };
    return n;
}

pub const FieldNodes = struct {
    children: [2]ui.Node = undefined,

    pub fn build(self: *FieldNodes, i: usize) ui.Node {
        self.children[0] = text(label_ids[i], labels[i], "caption");
        var input = ui.node(ui.NodeKind.text_input);
        input.id = abi.view(fields[i]);
        input.text = .{ .present = 1, .value = abi.view(labels[i]) };
        input.placeholder = .{ .present = 1, .value = abi.view(hints[i]) };
        input.state = .{ .present = 1, .value = abi.view(fields[i]) };
        self.children[1] = input;
        return container(ui.NodeKind.stack, group_ids[i], &self.children);
    }
};

test "all fields have visible labels and placeholder and distinct IDs" {
    var nodes: [fields.len]FieldNodes = @splat(.{});
    for (&nodes, 0..) |*storage, i| {
        const field = storage.build(i);
        try std.testing.expectEqual(@as(u32, 2), field.children.count);
        try std.testing.expectEqualStrings(labels[i], abi.slice(storage.children[0].text.value).?);
        try std.testing.expectEqualStrings(fields[i], abi.slice(storage.children[1].state.value).?);
        try std.testing.expectEqualStrings(hints[i], abi.slice(storage.children[1].placeholder.value).?);
        try std.testing.expect(!std.mem.eql(u8, abi.slice(storage.children[0].id).?, abi.slice(storage.children[1].id).?));
    }
}
