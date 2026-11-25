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
const text = @import("pulse_text");

const allocator = std.heap.page_allocator;

const command_open = "strangelion.hello-panel.open";
const command_close = "hello-panel.close";
const panel_title = "Pulse Hello Panel";

const Instance = struct {
    host: host_mod.Host,
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
    if (std.mem.eql(u8, name, command_close)) {
        closePanel(instance) catch |err| diag.status("panel-command-close-failed", @intFromError(err));
    }
}

/// The snapshot is borrowed: everything kept here is copied into `Instance`.
fn applySnapshot(instance: *Instance, snapshot: *const context.Snapshot) void {
    if (!context.validSnapshot(snapshot)) return;
    const directory = context.directory(snapshot) orelse "";
    const name = context.selectionName(snapshot) orelse "";
    const dir = text.appendTruncated(&instance.line_directory, "目录：", directory);
    instance.line_directory_len = dir.len;
    const selected = text.appendTruncated(&instance.line_selection, "选中：", name);
    instance.line_selection_len = selected.len;
    instance.revision = snapshot.revision;
}

fn onContextChange(user: ?*anyopaque, snapshot: [*c]const context.Snapshot) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(user orelse return));
    const value = snapshot orelse return;
    if (!context.validSnapshot(value)) return;
    applySnapshot(instance, value);
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
    const status = context.query(instance.host.raw(), &instance.context);
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
    return placementFromValue(value);
}

/// Compares the environment value directly as UTF-16, so an arbitrarily long
/// value is simply "not sidebar" instead of being truncated into a match.
fn placementFromValue(value: []const u16) ui_mount.Placement {
    const sidebar = std.unicode.wtf8ToWtf16LeStringLiteral("sidebar");
    if (value.len != sidebar.len) return .workspace;
    for (value, sidebar) |left, right| {
        if (left > 0x7F or right > 0x7F) return .workspace;
        if (std.ascii.toLower(@intCast(left)) != std.ascii.toLower(@intCast(right))) return .workspace;
    }
    return .sidebar;
}

fn openPanel(instance: *Instance) host_mod.Error!void {
    return openPanelAt(instance, requestedPlacement());
}

fn openPanelAt(instance: *Instance, placement: ui_mount.Placement) host_mod.Error!void {
    if (instance.panel != null) return;
    var table: ui_model.TableV1 = undefined;
    const status = ui_model.query(instance.host.raw(), &table);
    diag.status("ui.model", status);
    if (status != abi.ok) return host_mod.mapStatus(status);
    if (table.size < @sizeOf(ui_model.TableV1) or table.version < ui_model.version_1) return error.Abi;
    const create = table.create orelse return error.Unavailable;
    if (table.close == null or table.update == null) return error.Unavailable;
    if (placement != .sidebar and (table.subscribe_command == null or table.unsubscribe == null)) return error.Unavailable;
    instance.model = table;
    var mount: ui_mount.TableV1 = undefined;
    const mount_status = ui_mount.query(instance.host.raw(), &mount);
    diag.status("ui.mount", mount_status);
    if (mount_status == abi.ok) instance.mount = mount;
    readContext(instance);

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
        if (subscribed != abi.ok or subscription == 0) {
            // Partial activation: the panel exists, its command subscription
            // does not. Close it; if the host refuses, keep the panel so
            // deactivate/destroy can retry instead of leaking live callbacks.
            if (panel.close()) |_| {} else |close_err| {
                diag.status("cleanup-close-failed", @intFromError(close_err));
                instance.panel = panel;
            }
            if (subscribed == abi.ok) return error.State;
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

/// Releases everything the panel owns. Every host call is checked: a failed
/// unsubscribe or close keeps the handle so a later retry can succeed, and the
/// caller learns about the failure instead of assuming cleanup happened.
fn closePanel(instance: *Instance) host_mod.Error!void {
    var failure: ?host_mod.Error = null;
    if (instance.context_subscription != 0) {
        if (instance.context.unsubscribe) |unsubscribe| {
            if (host_mod.mapStatus(unsubscribe(instance.context.context, instance.context_subscription))) |_| {
                instance.context_subscription = 0;
            } else |err| switch (err) {
                // The host already dropped the subscription with the attachment.
                error.State => instance.context_subscription = 0,
                else => {
                    diag.status("context-unsubscribe-failed", @intFromError(err));
                    failure = err;
                },
            }
        } else {
            diag.event("context-unsubscribe-missing");
            failure = error.Unavailable;
        }
    }
    if (instance.panel) |*panel| {
        if (instance.subscription != 0) {
            if (panel.unsubscribe(instance.subscription)) |_| {
                instance.subscription = 0;
            } else |err| {
                diag.status("panel-unsubscribe-failed", @intFromError(err));
                if (failure == null) failure = err;
            }
        }
        if (panel.close()) |_| {
            instance.panel = null;
            instance.subscription = 0;
            diag.event("panel-close");
        } else |err| {
            diag.status("panel-close-failed", @intFromError(err));
            if (failure == null) failure = err;
        }
    }
    if (failure) |err| return err;
}

fn registerOpenCommand(instance: *Instance) void {
    var table: commands.TableV1 = undefined;
    const status = commands.query(instance.host.raw(), &table);
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
    openPanel(instance) catch |err| {
        diag.status("activate-failed", @intFromError(err));
        return statusOf(err);
    };
    instance.active = true;
    return abi.ok;
}

fn deactivate(raw: ?*anyopaque) callconv(.c) void {
    diag.event("deactivate");
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return));
    closePanel(instance) catch |err| {
        diag.status("deactivate-close-failed", @intFromError(err));
        return; // stay active: the host may still call panel callbacks
    };
    instance.active = false;
}

fn destroy(raw: ?*anyopaque) callconv(.c) void {
    diag.event("destroy");
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return));
    closePanel(instance) catch |err| {
        // Closing failed, so the host may still call callbacks with this
        // instance as userdata. Leaking one small instance is the only safe
        // option; freeing it here would be a use-after-free.
        diag.status("destroy-close-failed", @intFromError(err));
        return;
    };
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
    const validated = host_mod.Host.init(host) catch |err| return statusOf(err);
    const instance = allocator.create(Instance) catch return abi.error_initialization;
    instance.* = .{ .host = validated };
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

test "placement parsing ignores oversized and non-ASCII values" {
    const testing = std.testing;
    try testing.expectEqual(ui_mount.Placement.sidebar, placementFromValue(std.unicode.wtf8ToWtf16LeStringLiteral("sidebar")));
    try testing.expectEqual(ui_mount.Placement.sidebar, placementFromValue(std.unicode.wtf8ToWtf16LeStringLiteral("SideBar")));
    try testing.expectEqual(ui_mount.Placement.workspace, placementFromValue(std.unicode.wtf8ToWtf16LeStringLiteral("sidebar ")));
    try testing.expectEqual(ui_mount.Placement.workspace, placementFromValue(std.unicode.wtf8ToWtf16LeStringLiteral("工作区")));

    var long: [4096]u16 = undefined;
    @memset(&long, 'a');
    try testing.expectEqual(ui_mount.Placement.workspace, placementFromValue(&long));
}

fn unavailableInterface(_: ?*anyopaque, _: abi.StringView, _: u32, _: ?*anyopaque, _: u32) callconv(.c) abi.Status {
    return abi.error_unavailable;
}

test "entry validates the host table before allocating an instance" {
    var host = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = abi.abi_version, .context = null, .query_interface = null };
    var out = std.mem.zeroes(abi.PluginV1);
    out.size = @sizeOf(abi.PluginV1);
    out.version = abi.abi_version;
    // A host without query_interface cannot provide any interface, so entry
    // refuses instead of handing out a plugin that can never activate.
    try std.testing.expectEqual(abi.error_unavailable, PulsePluginEntryV1(&host, &out));
    try std.testing.expect(out.instance == null);

    host.size = 8;
    try std.testing.expectEqual(abi.error_abi, PulsePluginEntryV1(&host, &out));
    try std.testing.expect(out.instance == null);

    host.size = @sizeOf(abi.HostV1);
    host.query_interface = &unavailableInterface;
    var accepted = std.mem.zeroes(abi.PluginV1);
    accepted.size = @sizeOf(abi.PluginV1);
    accepted.version = abi.abi_version;
    try std.testing.expectEqual(abi.ok, PulsePluginEntryV1(&host, &accepted));
    try std.testing.expect(accepted.instance != null);
    // No interfaces are reachable, so activation reports the real reason.
    try std.testing.expectEqual(abi.error_unavailable, accepted.activate.?(accepted.instance));
    accepted.deactivate.?(accepted.instance);
    accepted.destroy.?(accepted.instance);

    try std.testing.expectEqual(@as(u32, 3), PulsePluginSdkPreview());
}

const MockModel = struct {
    missing_subscribe: bool = false,
    fail_subscribe: bool = false,
    fail_close: bool = false,
    created: usize = 0,
    closed: usize = 0,
    subscribed: bool = false,

    fn query(raw: ?*anyopaque, name: abi.StringView, version: u32, output: ?*anyopaque, size: u32) callconv(.c) abi.Status {
        const self: *MockModel = @ptrCast(@alignCast(raw orelse return abi.error_argument));
        const id = abi.slice(name) orelse return abi.error_argument;
        if (!std.mem.eql(u8, id, ui_model.interface_name)) return abi.error_unavailable;
        if (version != ui_model.version_1 or size < @sizeOf(ui_model.TableV1)) return abi.error_abi;
        const table: *ui_model.TableV1 = @ptrCast(@alignCast(output orelse return abi.error_argument));
        table.* = std.mem.zeroes(ui_model.TableV1);
        table.size = @sizeOf(ui_model.TableV1);
        table.version = ui_model.version_1;
        table.context = self;
        table.create = &create;
        table.update = &update;
        table.close = &close;
        table.unsubscribe = &unsubscribe;
        if (!self.missing_subscribe) table.subscribe_command = &subscribe;
        return abi.ok;
    }

    fn create(raw: ?*anyopaque, _: abi.StringView, tree: [*c]const ui_model.Tree, out: [*c]u64) callconv(.c) abi.Status {
        const self: *MockModel = @ptrCast(@alignCast(raw orelse return abi.error_argument));
        if (tree == null or tree.*.root == null or out == null) return abi.error_argument;
        self.created += 1;
        out.* = 1;
        return abi.ok;
    }

    fn update(_: ?*anyopaque, _: u64, _: [*c]const ui_model.Tree) callconv(.c) abi.Status {
        return abi.ok;
    }

    fn subscribe(raw: ?*anyopaque, _: u64, _: abi.StringView, callback: ui_model.ClickFn, user: ?*anyopaque, out: [*c]u64) callconv(.c) abi.Status {
        const self: *MockModel = @ptrCast(@alignCast(raw orelse return abi.error_argument));
        if (self.fail_subscribe) return abi.error_permission;
        if (callback == null or user == null or out == null) return abi.error_argument;
        self.subscribed = true;
        out.* = 2;
        return abi.ok;
    }

    fn unsubscribe(raw: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *MockModel = @ptrCast(@alignCast(raw orelse return abi.error_argument));
        self.subscribed = false;
        return abi.ok;
    }

    fn close(raw: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *MockModel = @ptrCast(@alignCast(raw orelse return abi.error_argument));
        if (self.fail_close) return abi.error_permission;
        self.closed += 1;
        self.subscribed = false;
        return abi.ok;
    }

    fn instance(self: *MockModel) Instance {
        const host: abi.HostV1 = .{ .size = @sizeOf(abi.HostV1), .version = abi.abi_version, .context = self, .query_interface = &query };
        return .{ .host = host_mod.Host.init(&host) catch unreachable };
    }
};

test "mock host missing callbacks fail before panel creation" {
    var mock: MockModel = .{ .missing_subscribe = true };
    var instance = mock.instance();
    try std.testing.expectError(error.Unavailable, openPanelAt(&instance, .workspace));
    try std.testing.expectEqual(@as(usize, 0), mock.created);
    try std.testing.expect(instance.panel == null);
}

test "mock host failed subscribe rolls back and failed close stays retryable" {
    var mock: MockModel = .{ .fail_subscribe = true, .fail_close = true };
    var instance = mock.instance();
    try std.testing.expectError(error.Permission, openPanelAt(&instance, .workspace));
    try std.testing.expect(instance.panel != null);
    try std.testing.expectEqual(@as(usize, 0), mock.closed);
    mock.fail_close = false;
    try closePanel(&instance);
    try std.testing.expect(instance.panel == null);
    mock.fail_subscribe = false;
    try openPanelAt(&instance, .workspace);
    try std.testing.expect(mock.subscribed);
    try closePanel(&instance);
    try std.testing.expect(!mock.subscribed);
    try std.testing.expectEqual(mock.created, mock.closed);
}
