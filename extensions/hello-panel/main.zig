//! `strangelion.hello-panel` - the smallest UI-contributing extension.
//!
//! Purpose: prove the `pulse.commands` -> activation -> `pulse.ui.model` panel ->
//! `pulse.ui.mount` placement -> `pulse.context` subscription path against a real
//! host, and give P1 a shape that later extensions can copy. It intentionally
//! does no file I/O, starts no threads and owns no state beyond two panels.

const std = @import("std");
const builtin = @import("builtin");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const commands = @import("pulse_commands");
const context = @import("pulse_context");
const ui_model = @import("pulse_ui_model");
const ui_mount = @import("pulse_ui_mount");
const diag = @import("pulse_diagnostics");

const allocator = std.heap.page_allocator;

const command_open = "strangelion.hello-panel.open";
const command_close = "hello-panel.close";
const panel_title = "Pulse Hello Panel";

const Instance = struct {
    host: *const abi.HostV1,
    commands: commands.TableV1 = std.mem.zeroes(commands.TableV1),
    model: ui_model.TableV1 = std.mem.zeroes(ui_model.TableV1),
    mount: ui_mount.TableV1 = std.mem.zeroes(ui_mount.TableV1),
    context: context.TableV1 = std.mem.zeroes(context.TableV1),
    panel: ?ui_model.Panel = null,
    subscription: u64 = 0,
    context_subscription: u64 = 0,
    placement: ui_mount.Placement = .workspace,
    line_directory: [600]u8 = undefined,
    line_directory_len: usize = 0,
    line_selection: [300]u8 = undefined,
    line_selection_len: usize = 0,
    revision: u64 = 0,
    active: bool = false,
};

/// Host command entry: opening an extension from the palette or a menu item
/// activates the package first, then calls this on the UI thread.
fn commandInvoke(user: ?*anyopaque, id: commands.CommandId, _: [*c]const commands.SelectionSnapshot) callconv(.c) void {
    diag.event("invoke");
    diag.status("invoke-id", id);
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    openPanel(instance) catch |err| diag.status("open-failed", @intFromError(err));
}

/// Panel button callback. The host passes the command id declared on the node.
fn onCommand(user: ?*anyopaque, panel_id: u64, command: abi.StringView) callconv(.c) void {
    const name = abi.slice(command) orelse return;
    diag.status("panel-command", panel_id);
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    if (std.mem.eql(u8, name, command_close)) closePanel(instance);
}

/// Copies `prefix + value` into `buffer` without splitting a UTF-8 codepoint.
fn compose(buffer: []u8, prefix: []const u8, value: []const u8) []const u8 {
    const head = @min(prefix.len, buffer.len);
    @memcpy(buffer[0..head], prefix[0..head]);
    const room = buffer.len - head;
    var take = @min(value.len, room);
    // A truncated tail must not start inside a continuation byte.
    while (take > 0 and take < value.len and (value[take] & 0xC0) == 0x80) take -= 1;
    @memcpy(buffer[head .. head + take], value[0..take]);
    return buffer[0 .. head + take];
}

/// The snapshot is borrowed: everything kept here is copied into `Instance`.
fn applySnapshot(instance: *Instance, snapshot: *const context.Snapshot) void {
    if (snapshot.size < @offsetOf(context.Snapshot, "loading")) return;
    const directory = context.directory(snapshot) orelse "";
    const name = context.selectionName(snapshot) orelse "";
    const dir = compose(&instance.line_directory, "目录：", directory);
    instance.line_directory_len = dir.len;
    const selected = compose(&instance.line_selection, "选中：", name);
    instance.line_selection_len = selected.len;
    instance.revision = snapshot.revision;
}

fn onContextChange(user: ?*anyopaque, snapshot: [*c]const context.Snapshot) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    applySnapshot(instance, &snapshot.*);
    refreshPanels(instance);
}

/// Nodes and the tree must stay alive until the host copies them, so callers
/// declare `Content` next to the `create`/`update` call instead of returning a
/// tree by value.
const Content = struct {
    declared: [1]abi.StringView,
    body: ui_model.Node,
    meta: ui_model.Node,
    close: ui_model.Node,
    children: [3]ui_model.Node,
    root: ui_model.Node,
};

const SideContent = struct {
    first: ui_model.Node,
    second: ui_model.Node,
    children: [2]ui_model.Node,
    root: ui_model.Node,
};

fn directoryLine(instance: *const Instance) []const u8 {
    return if (instance.line_directory_len == 0)
        "目录：（等待宿主上下文）"
    else
        instance.line_directory[0..instance.line_directory_len];
}

fn selectionLine(instance: *const Instance) []const u8 {
    return if (instance.line_selection_len == 0)
        "选中：（无）"
    else
        instance.line_selection[0..instance.line_selection_len];
}

fn fillTree(instance: *const Instance, content: *Content, tree: *ui_model.Tree) void {
    content.declared = .{abi.view(command_close)};
    content.body = ui_model.text(directoryLine(instance));
    content.body.id = abi.view("body");
    content.meta = ui_model.text(selectionLine(instance));
    content.meta.id = abi.view("meta");
    content.close = ui_model.button("关闭面板", command_close);
    content.close.id = abi.view("close");
    content.children = .{ content.body, content.meta, content.close };
    content.root = ui_model.node(ui_model.NodeKind.stack);
    content.root.id = abi.view("root");
    content.root.gap = .{ .present = 1, .value = 8 };
    ui_model.withChildren(&content.root, &content.children);
    tree.* = std.mem.zeroes(ui_model.Tree);
    tree.size = @sizeOf(ui_model.Tree);
    tree.root = &content.root;
    tree.commands = &content.declared;
    tree.command_count = content.declared.len;
}

fn fillSideTree(instance: *const Instance, content: *SideContent, tree: *ui_model.Tree) void {
    content.first = ui_model.text(directoryLine(instance));
    content.first.id = abi.view("side.directory");
    content.first.role = .{ .present = 1, .value = abi.view("section") };
    content.second = ui_model.text(selectionLine(instance));
    content.second.id = abi.view("side.selection");
    content.children = .{ content.first, content.second };
    content.root = ui_model.node(ui_model.NodeKind.stack);
    content.root.id = abi.view("side.root");
    content.root.gap = .{ .present = 1, .value = 4 };
    ui_model.withChildren(&content.root, &content.children);
    tree.* = std.mem.zeroes(ui_model.Tree);
    tree.size = @sizeOf(ui_model.Tree);
    tree.root = &content.root;
}

fn refreshPanels(instance: *Instance) void {
    if (instance.panel) |*panel| {
        if (instance.placement == .sidebar) {
            var side: SideContent = undefined;
            var side_tree: ui_model.Tree = undefined;
            fillSideTree(instance, &side, &side_tree);
            panel.update(&side_tree) catch |err| diag.status("panel-update", @intFromError(err));
        } else {
            var content: Content = undefined;
            var tree: ui_model.Tree = undefined;
            fillTree(instance, &content, &tree);
            panel.update(&tree) catch |err| diag.status("panel-update", @intFromError(err));
        }
        diag.status("panel-refresh", instance.revision);
    }
}

fn readContext(instance: *Instance) void {
    const status = context.query(instance.host, &instance.context);
    diag.status("ui.context", status);
    if (status != abi.ok) return;
    if (instance.context.size < @sizeOf(context.TableV1) or instance.context.version < context.version_1) return;
    const get_fn = instance.context.get orelse return;
    host_mod.mapStatus(get_fn(instance.context.context, &onContextChange, instance)) catch |err|
        diag.status("context-get", @intFromError(err));
}

/// Placement is a request; the host still decides. `HELLO_PANEL_PLACEMENT=sidebar`
/// is used by the acceptance harness to exercise the secondary sidebar slot.
fn requestedPlacement() ui_mount.Placement {
    if (comptime builtin.os.tag != .windows) return .workspace;
    const environment = std.process.Environ{ .block = .global };
    const value = environment.getWindows(std.unicode.wtf8ToWtf16LeStringLiteral("HELLO_PANEL_PLACEMENT")) orelse return .workspace;
    var buffer: [32]u8 = undefined;
    const length = std.unicode.wtf16LeToWtf8(&buffer, value);
    if (std.ascii.eqlIgnoreCase(buffer[0..length], "sidebar")) return .sidebar;
    return .workspace;
}

fn openPanel(instance: *Instance) host_mod.Error!void {
    if (instance.panel != null) return;
    var table: ui_model.TableV1 = undefined;
    const status = ui_model.query(instance.host, &table);
    diag.status("ui.model", status);
    if (status != abi.ok) return host_mod.mapStatus(status);
    const create = table.create orelse return error.Unavailable;
    instance.model = table;
    var mount: ui_mount.TableV1 = undefined;
    const mount_status = ui_mount.query(instance.host, &mount);
    diag.status("ui.mount", mount_status);
    if (mount_status == abi.ok) instance.mount = mount;
    readContext(instance);

    const placement = requestedPlacement();
    instance.placement = placement;
    var panel_id: u64 = 0;
    const created = blk: {
        if (placement == .sidebar) {
            var side: SideContent = undefined;
            var side_tree: ui_model.Tree = undefined;
            fillSideTree(instance, &side, &side_tree);
            break :blk create(table.context, abi.view(panel_title), &side_tree, &panel_id);
        }
        var content: Content = undefined;
        var tree: ui_model.Tree = undefined;
        fillTree(instance, &content, &tree);
        break :blk create(table.context, abi.view(panel_title), &tree, &panel_id);
    };
    diag.status("ui.model.create", created);
    if (created != abi.ok) return host_mod.mapStatus(created);
    if (panel_id == 0) return error.State;
    var panel = ui_model.Panel{ .table = table, .id = panel_id };
    if (placement != .sidebar) {
        const subscribe = table.subscribe_command orelse return error.Unavailable;
        var subscription: u64 = 0;
        const subscribed = subscribe(table.context, panel_id, abi.view(command_close), onCommand, instance, &subscription);
        diag.status("ui.model.subscribe", subscribed);
        if (subscribed != abi.ok) {
            panel.close();
            return host_mod.mapStatus(subscribed);
        }
        instance.subscription = subscription;
    }
    instance.panel = panel;
    // Placement is a request: the host decides, and a refusal is not an error
    // for the panel itself.
    if (instance.mount.set) |set| {
        diag.status("placement-request", @backingInt(placement));
        const placed = set(instance.mount.context, panel_id, @backingInt(placement));
        diag.status("ui.mount.set", placed);
        if (placed != abi.ok) diag.status("mount-refused", placed);
    }
    if (instance.context.subscribe) |subscribe_context| {
        const status_subscribe = subscribe_context(
            instance.context.context,
            &onContextChange,
            instance,
            &instance.context_subscription,
        );
        host_mod.mapStatus(status_subscribe) catch |err| diag.status("context-subscribe", @intFromError(err));
    }
    diag.event("panel-open");
}

fn closePanel(instance: *Instance) void {
    if (instance.context_subscription != 0) {
        if (instance.context.unsubscribe) |unsubscribe| {
            host_mod.mapStatus(unsubscribe(instance.context.context, instance.context_subscription)) catch {};
        }
        instance.context_subscription = 0;
    }
    if (instance.panel) |*panel| {
        if (instance.subscription != 0) {
            panel.unsubscribe(instance.subscription) catch {};
            instance.subscription = 0;
        }
        panel.close();
        instance.panel = null;
        diag.event("panel-close");
    }
}

fn registerOpenCommand(instance: *Instance) void {
    var table: commands.TableV1 = undefined;
    const status = commands.query(instance.host, &table);
    diag.status("ui.commands", status);
    if (status != abi.ok) return;
    instance.commands = table;
    const register = table.register_command orelse return;
    var descriptor = commands.descriptor(command_open, "Pulse Hello Panel: 打开面板", commandInvoke);
    descriptor.kinds = commands.Kind.files | commands.Kind.directories | commands.Kind.background;
    descriptor.virtual_key = 0x79; // F10; letters need CTRL/ALT and collide with app shortcuts.
    descriptor.modifiers = commands.Modifier.ctrl | commands.Modifier.shift;
    descriptor.user = instance;
    var assigned: commands.CommandId = 0;
    diag.status("register", register(table.context, &descriptor, &assigned));
}

fn activate(raw: ?*anyopaque) callconv(.c) abi.Status {
    diag.event("activate");
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return abi.error_argument));
    instance.active = true;
    openPanel(instance) catch |err| {
        diag.status("activate-failed", @intFromError(err));
        return statusOf(err);
    };
    return abi.ok;
}

fn deactivate(raw: ?*anyopaque) callconv(.c) void {
    diag.event("deactivate");
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return));
    closePanel(instance);
    instance.active = false;
}

fn destroy(raw: ?*anyopaque) callconv(.c) void {
    diag.event("destroy");
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return));
    closePanel(instance);
    allocator.destroy(instance);
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

export fn PulsePluginSdkPreview() callconv(.c) u32 {
    return abi.sdk_preview;
}

export fn PulsePluginEntryV1(host_ptr: ?*const abi.HostV1, out_ptr: ?*abi.PluginV1) callconv(.c) abi.Status {
    diag.event("entry");
    const host = host_ptr orelse return abi.error_abi;
    const out = out_ptr orelse return abi.error_abi;
    if (host.size < @sizeOf(abi.HostV1) or out.size < @sizeOf(abi.PluginV1)) return abi.error_abi;
    if (host.version != abi.abi_version or out.version != abi.abi_version) return abi.error_abi;
    const instance = allocator.create(Instance) catch return abi.error_initialization;
    instance.* = .{ .host = host };
    registerOpenCommand(instance);
    out.* = .{
        .size = @sizeOf(abi.PluginV1),
        .version = abi.abi_version,
        .instance = instance,
        .activate = activate,
        .deactivate = deactivate,
        .destroy = destroy,
    };
    return abi.ok;
}

test "compose keeps UTF-8 boundaries when truncating" {
    var buffer: [8]u8 = undefined;
    // "目录：" is 9 bytes, so a 8-byte buffer must cut before the third
    // character instead of emitting a broken sequence.
    const line = compose(&buffer, "", "目录");
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
    try std.testing.expect(line.len <= buffer.len);
}

test "entry rejects short tables and never returns an instance" {
    var host = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = abi.abi_version, .context = null, .query_interface = null };
    var out = std.mem.zeroes(abi.PluginV1);
    out.size = @sizeOf(abi.PluginV1);
    out.version = abi.abi_version;
    try std.testing.expectEqual(abi.ok, PulsePluginEntryV1(&host, &out));
    try std.testing.expect(out.instance != null);
    // No interfaces are reachable, so activation must fail cleanly instead of
    // pretending a panel exists.
    try std.testing.expectEqual(abi.error_unavailable, out.activate.?(out.instance));
    out.deactivate.?(out.instance);
    out.destroy.?(out.instance);

    host.size = 8;
    var rejected = std.mem.zeroes(abi.PluginV1);
    rejected.size = @sizeOf(abi.PluginV1);
    rejected.version = abi.abi_version;
    try std.testing.expectEqual(abi.error_abi, PulsePluginEntryV1(&host, &rejected));
    try std.testing.expect(rejected.instance == null);
    try std.testing.expectEqual(@as(u32, 3), PulsePluginSdkPreview());
}
