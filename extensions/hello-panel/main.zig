//! `strangelion.hello-panel` - the smallest UI-contributing extension.
//!
//! Purpose: prove the `pulse.commands` -> activation -> `pulse.ui.model` panel ->
//! `pulse.ui.mount` placement path against a real host, and give P1 a shape that
//! later extensions can copy. It intentionally does no file I/O, starts no
//! threads and owns no state beyond one panel handle.

const std = @import("std");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const commands = @import("pulse_commands");
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
    panel: ?ui_model.Panel = null,
    subscription: u64 = 0,
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

fn openPanel(instance: *Instance) host_mod.Error!void {
    if (instance.panel != null) return;
    var table: ui_model.TableV1 = undefined;
    const status = ui_model.query(instance.host, &table);
    diag.status("ui.model", status);
    if (status != abi.ok) return host_mod.mapStatus(status);
    instance.model = table;
    const create = table.create orelse return error.Unavailable;
    var declared = [_]abi.StringView{abi.view(command_close)};
    // Every node needs a unique identifier; the host rejects the whole tree
    // otherwise. The nodes live in this frame so `create` can copy them.
    var body = ui_model.text("Zig 原生面板已由宿主渲染。");
    body.id = abi.view("body");
    var meta = ui_model.text("Pulse SDK preview 3 · ABI v1 · pulse.ui.model + pulse.ui.mount");
    meta.id = abi.view("meta");
    var close = ui_model.button("关闭面板", command_close);
    close.id = abi.view("close");
    var children = [_]ui_model.Node{ body, meta, close };
    var root = ui_model.node(ui_model.NodeKind.stack);
    root.id = abi.view("root");
    root.gap = .{ .present = 1, .value = 8 };
    ui_model.withChildren(&root, &children);
    var tree = std.mem.zeroes(ui_model.Tree);
    tree.size = @sizeOf(ui_model.Tree);
    tree.root = &root;
    tree.commands = &declared;
    tree.command_count = declared.len;
    var panel_id: u64 = 0;
    const created = create(table.context, abi.view(panel_title), &tree, &panel_id);
    diag.status("ui.model.create", created);
    if (created != abi.ok) return host_mod.mapStatus(created);
    if (panel_id == 0) return error.State;
    var panel = ui_model.Panel{ .table = table, .id = panel_id };
    const subscribe = table.subscribe_command orelse return error.Unavailable;
    var subscription: u64 = 0;
    const subscribed = subscribe(table.context, panel_id, abi.view(command_close), onCommand, instance, &subscription);
    diag.status("ui.model.subscribe", subscribed);
    if (subscribed != abi.ok) {
        panel.close();
        return host_mod.mapStatus(subscribed);
    }
    instance.panel = panel;
    instance.subscription = subscription;
    // Placement is a request: the host decides, and a refusal is not an error
    // for the panel itself.
    mountRequest(instance, panel_id) catch |err| diag.status("mount-failed", @intFromError(err));
    diag.event("panel-open");
}

fn mountRequest(instance: *Instance, panel_id: u64) host_mod.Error!void {
    var mount: ui_mount.TableV1 = undefined;
    const status = ui_mount.query(instance.host, &mount);
    diag.status("ui.mount", status);
    if (status != abi.ok) return error.Unavailable;
    instance.mount = mount;
    const request = mount.set orelse return error.Unavailable;
    try host_mod.mapStatus(request(mount.context, panel_id, @backingInt(ui_mount.Placement.workspace)));
}

fn closePanel(instance: *Instance) void {
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
