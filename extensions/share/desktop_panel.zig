const std = @import("std");
const abi = @import("pulse_abi");
const ui = @import("pulse_ui_model");

extern fn share_desktop_node(c_int, c_int, [*:0]const u8, [*:0]const u8, [*:0]const u8, [*]const u8, c_int, c_int) c_int;
extern fn share_desktop_options(c_int, c_int, [*]const u8, c_int) void;
extern fn share_desktop_set([*:0]const u8, [*]const u8, c_int) void;
extern fn share_desktop_get([*:0]const u8, [*]u8, c_int) c_int;
extern fn share_desktop_layout() void;

fn zero(buffer: *[64:0]u8, value: abi.StringView) ![:0]const u8 {
    const input = abi.slice(value) orelse "";
    if (input.len >= buffer.len) return error.Argument;
    @memcpy(buffer[0..input.len], input);
    buffer[input.len] = 0;
    return buffer[0..input.len :0];
}

fn string(value: abi.StringView) []const u8 {
    return abi.slice(value) orelse "";
}

fn render(node: *const ui.Node, parent: c_int) !void {
    const t = ui.NodeKind;
    const kind: c_int = switch (node.type) {
        t.stack => 0,
        t.grid => 1,
        t.group => 2,
        t.text => if (std.mem.eql(u8, string(node.role.value), "section")) 10 else 3,
        t.button => 4,
        t.text_input => 5,
        t.select => 6,
        t.progress => 7,
        t.tabs => 8,
        t.tab => 9,
        else => return error.Argument,
    };
    var id_buffer: [64:0]u8 = undefined;
    var key_buffer: [64:0]u8 = undefined;
    var enable_buffer: [64:0]u8 = undefined;
    const id = try zero(&id_buffer, node.id);
    const key = try zero(&key_buffer, if (node.state.present != 0) node.state.value else node.binding.value);
    const enabled = try zero(&enable_buffer, node.enabled_binding.value);
    const text = string(if (node.type == t.text_input) node.placeholder.value else node.text.value);
    const style = string(node.kind.value);
    const appearance: c_int = if (std.mem.eql(u8, style, "password")) 1 else if (std.mem.eql(u8, style, "primary")) 2 else 0;
    const index = share_desktop_node(parent, kind, id, key, enabled, text.ptr, @intCast(text.len), appearance);
    if (index < 0) return error.State;
    if (node.type == t.select and node.options.present != 0) {
        for (node.options.data[0..node.options.count], 0..) |item, i| {
            const option = string(item);
            share_desktop_options(index, @intFromBool(i == 0), option.ptr, @intCast(option.len));
        }
    }
    if (node.children.present != 0) for (node.children.data[0..node.children.count]) |*child| try render(child, index);
}

pub const Panel = struct {
    pub fn updateTree(_: Panel, root: *const ui.Node) !void {
        try render(root, -1);
        share_desktop_layout();
    }

    pub fn openTree(root: *const ui.Node) !Panel {
        const panel: Panel = .{};
        try panel.updateTree(root);
        return panel;
    }

    pub fn setStates(_: Panel, states: []const ui.State) !void {
        for (states) |state| {
            var buffer: [64:0]u8 = undefined;
            const key = try zero(&buffer, state.key);
            const text = string(state.value);
            share_desktop_set(key, text.ptr, @intCast(text.len));
        }
    }

    pub fn read(_: Panel, key: []const u8, out: []u8) ![]const u8 {
        var buffer: [64:0]u8 = undefined;
        const id = try zero(&buffer, abi.view(key));
        const len = share_desktop_get(id, out.ptr, @intCast(out.len));
        if (len < 0 or len >= out.len) return error.Argument;
        return out[0..@intCast(len)];
    }
};
