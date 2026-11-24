//! `pulse.ui.model` V1 - declarative panels rendered by the host.
//!
//! All calls are UI-thread only. Arrays and strings passed in a tree are copied
//! by the host synchronously, so the tree may live on the caller's stack.
//! Panel ids are never reused; `close` is idempotent from the plugin's side.

const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");

pub const interface_name: []const u8 = raw.PULSE_UI_MODEL_INTERFACE;
pub const version_1: u32 = @intCast(raw.PULSE_UI_MODEL_VERSION);

pub const NodeKind = struct {
    pub const stack: u32 = raw.PULSE_UI_MODEL_STACK;
    pub const grid: u32 = raw.PULSE_UI_MODEL_GRID;
    pub const group: u32 = raw.PULSE_UI_MODEL_GROUP;
    pub const scroll_view: u32 = raw.PULSE_UI_MODEL_SCROLL_VIEW;
    pub const text: u32 = raw.PULSE_UI_MODEL_TEXT;
    pub const button: u32 = raw.PULSE_UI_MODEL_BUTTON;
    pub const text_input: u32 = raw.PULSE_UI_MODEL_TEXT_INPUT;
    pub const checkbox: u32 = raw.PULSE_UI_MODEL_CHECKBOX;
    pub const select: u32 = raw.PULSE_UI_MODEL_SELECT;
    pub const progress: u32 = raw.PULSE_UI_MODEL_PROGRESS;
    pub const divider: u32 = raw.PULSE_UI_MODEL_DIVIDER;
    pub const tabs: u32 = raw.PULSE_UI_MODEL_TABS;
    pub const tab: u32 = raw.PULSE_UI_MODEL_TAB;
    pub const badge: u32 = raw.PULSE_UI_MODEL_BADGE;
    pub const tag: u32 = raw.PULSE_UI_MODEL_TAG;
    pub const info_bar: u32 = raw.PULSE_UI_MODEL_INFO_BAR;
    pub const empty_state: u32 = raw.PULSE_UI_MODEL_EMPTY_STATE;
    pub const virtual_list: u32 = raw.PULSE_UI_MODEL_VIRTUAL_LIST;
    pub const tree: u32 = raw.PULSE_UI_MODEL_TREE;
    pub const data_table: u32 = raw.PULSE_UI_MODEL_DATA_TABLE;
    pub const split_pane: u32 = raw.PULSE_UI_MODEL_SPLIT_PANE;
};

pub const Node = raw.PulseUiModelNode;
pub const Tree = raw.PulseUiModelTree;
pub const State = raw.PulseUiState;
pub const ClickFn = raw.PulseUiClickFn;
pub const TableV1 = raw.PulseUiModelV1;

/// Queries the `pulse.ui.model` V1 table. Returns the raw host status.
pub fn query(host: *const abi.HostV1, out: *TableV1) abi.Status {
    const query_interface = host.query_interface orelse return abi.error_unavailable;
    out.* = std.mem.zeroes(TableV1);
    return query_interface(host.context, abi.view(interface_name), version_1, @ptrCast(out), @intCast(@sizeOf(TableV1)));
}

/// A node with `size`/`type` set and every optional property absent.
pub fn node(kind: u32) Node {
    var value: Node = std.mem.zeroes(Node);
    value.size = @sizeOf(Node);
    value.type = kind;
    return value;
}

/// Attaches children. `children` must outlive the host call that copies the tree.
pub fn withChildren(value: *Node, children: []const Node) void {
    value.children = .{ .present = 1, .data = children.ptr, .count = @intCast(children.len) };
}

pub fn text(body: []const u8) Node {
    var value = node(NodeKind.text);
    value.text = .{ .present = 1, .value = abi.view(body) };
    return value;
}

pub fn button(label: []const u8, command: []const u8) Node {
    var value = node(NodeKind.button);
    value.text = .{ .present = 1, .value = abi.view(label) };
    value.command = .{ .present = 1, .value = abi.view(command) };
    return value;
}

pub const Panel = struct {
    table: TableV1,
    id: u64,
    closed: bool = false,

    pub fn open(host: host_mod.Host, title: []const u8, tree: *const Tree) host_mod.Error!Panel {
        const table = try host.query(TableV1, interface_name, version_1);
        const create = table.create orelse return error.Unavailable;
        var id: u64 = 0;
        try host_mod.mapStatus(create(table.context, abi.view(title), tree, &id));
        if (id == 0) return error.State;
        return .{ .table = table, .id = id };
    }

    pub fn update(self: *Panel, tree: *const Tree) host_mod.Error!void {
        if (self.closed) return error.State;
        const update_fn = self.table.update orelse return error.Unavailable;
        try host_mod.mapStatus(update_fn(self.table.context, self.id, tree));
    }

    pub fn subscribeCommand(self: *Panel, command: []const u8, callback: ClickFn, user: ?*anyopaque) host_mod.Error!u64 {
        if (self.closed) return error.State;
        const subscribe = self.table.subscribe_command orelse return error.Unavailable;
        var subscription: u64 = 0;
        try host_mod.mapStatus(subscribe(self.table.context, self.id, abi.view(command), callback, user, &subscription));
        if (subscription == 0) return error.State;
        return subscription;
    }

    pub fn setStates(self: *Panel, states: []const State) host_mod.Error!void {
        if (self.closed) return error.State;
        const set_states = self.table.set_states orelse return error.Unavailable;
        if (states.len == 0) return;
        try host_mod.mapStatus(set_states(self.table.context, self.id, states.ptr, @intCast(states.len)));
    }

    pub fn unsubscribe(self: *Panel, subscription: u64) host_mod.Error!void {
        const unsubscribe_fn = self.table.unsubscribe orelse return error.Unavailable;
        try host_mod.mapStatus(unsubscribe_fn(self.table.context, subscription));
    }

    /// Idempotent. After the host accepts `close`, no callback for this panel can run.
    pub fn close(self: *Panel) void {
        if (self.closed) return;
        self.closed = true;
        if (self.table.close) |close_fn| {
            _ = close_fn(self.table.context, self.id);
        }
    }
};

test "node helpers keep size and property flags" {
    const testing = std.testing;
    const plain = node(NodeKind.text);
    try testing.expectEqual(@as(u32, @sizeOf(Node)), plain.size);
    try testing.expectEqual(NodeKind.text, plain.type);
    try testing.expectEqual(@as(u32, 0), plain.text.present);

    const labelled = button("Ping", "ping");
    try testing.expectEqual(@as(u32, 1), labelled.command.present);
    try testing.expectEqualStrings("ping", abi.slice(labelled.command.value).?);

    var children = [_]Node{ plain, labelled };
    var stack = node(NodeKind.stack);
    withChildren(&stack, &children);
    try testing.expectEqual(@as(u32, 2), stack.children.count);
}

test "closed panels refuse further calls" {
    var panel = Panel{ .table = std.mem.zeroes(TableV1), .id = 1 };
    panel.close();
    panel.close();
    var tree: Tree = std.mem.zeroes(Tree);
    try std.testing.expectError(error.State, panel.update(&tree));
}
