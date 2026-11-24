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

    /// `PULSE_ERROR_STATE` means the host no longer knows this subscription
    /// (already removed, or the panel was closed by the host). That is the same
    /// outcome as a successful release; every other status is a real failure.
    pub fn unsubscribe(self: *Panel, subscription: u64) host_mod.Error!void {
        const unsubscribe_fn = self.table.unsubscribe orelse return error.Unavailable;
        host_mod.mapStatus(unsubscribe_fn(self.table.context, subscription)) catch |err| switch (err) {
            error.State => return,
            else => return err,
        };
    }

    pub fn isOpen(self: *const Panel) bool {
        return !self.closed;
    }

    /// Idempotent. `STATE` means the host already closed the panel (user hit
    /// the close affordance, or the session was stopped), so the end state is
    /// the same. Any other status leaves `closed` unset and is retryable: the
    /// host may still hold callbacks that point at our userdata.
    pub fn close(self: *Panel) host_mod.Error!void {
        if (self.closed) return;
        const close_fn = self.table.close orelse return error.Unavailable;
        host_mod.mapStatus(close_fn(self.table.context, self.id)) catch |err| switch (err) {
            error.State => {
                self.closed = true;
                return;
            },
            else => return err,
        };
        self.closed = true;
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

test "close failures stay retryable and never mark the panel closed" {
    const testing = std.testing;
    var state = CloseState{};
    var table = std.mem.zeroes(TableV1);
    table.size = @sizeOf(TableV1);
    table.version = version_1;
    table.context = &state;
    table.close = &CloseState.close;
    var panel = Panel{ .table = table, .id = 1 };

    // STATE means "the host already closed it": same end state, no retry.
    try panel.close();
    try testing.expect(!panel.isOpen());
    try testing.expectEqual(@as(u32, 1), state.calls);

    var tree: Tree = std.mem.zeroes(Tree);
    try testing.expectError(error.State, panel.update(&tree));
}

const CloseState = struct {
    calls: u32 = 0,

    fn close(context: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *CloseState = @ptrCast(@alignCast(context orelse return abi.error_argument));
        self.calls += 1;
        return abi.error_state;
    }
};

test "close without a host function is unavailable, not a silent success" {
    var table = std.mem.zeroes(TableV1);
    table.size = @sizeOf(TableV1);
    table.version = version_1;
    var panel = Panel{ .table = table, .id = 1 };
    try std.testing.expectError(error.Unavailable, panel.close());
    try std.testing.expect(panel.isOpen());
}
