const std = @import("std");
const abi = @import("pulse_abi");
const commands = @import("pulse_commands");

const Instance = struct { active: bool = false };
const allocator = std.heap.page_allocator;

/// Test-only instrumentation: see `shared/diagnostics/probe_log.zig`. Set
/// `ABI_PROBE_LOG` to a file path to record every ABI callback.
const diag = @import("pulse_diagnostics");

fn logEvent(event: []const u8) void {
    diag.event(event);
}

fn logStatus(interface: []const u8, status: abi.Status) void {
    diag.status(interface, status);
}

export fn PulsePluginSdkPreview() callconv(.c) u32 {
    return abi.sdk_preview;
}

fn commandInvoke(user: ?*anyopaque, id: commands.CommandId, _: [*c]const commands.SelectionSnapshot) callconv(.c) void {
    _ = user;
    diag.event("invoke");
    diag.status("invoke-id", id);
}

/// Registers one do-nothing command so the host has a discoverable contribution
/// whose invocation must activate this package. Returns the host status.
fn registerProbeCommand(host: *const abi.HostV1) abi.Status {
    var table: commands.TableV1 = undefined;
    const status = commands.query(host, &table);
    logStatus(commands.interface_name, status);
    if (status != abi.ok) return status;
    if (table.size < @sizeOf(commands.TableV1) or table.version < commands.version_1) return abi.error_abi;
    const register = table.register_command orelse return abi.error_unavailable;
    const id = "strangelion.abi-probe.ping";
    const title = "Pulse ABI Probe: Ping";
    var descriptor = commands.Descriptor{
        .size = @sizeOf(commands.Descriptor),
        .id = .{ .data = id.ptr, .length = id.len },
        .title = .{ .data = title.ptr, .length = title.len },
        .icon = commands.Icon.default,
        .kinds = commands.Kind.files | commands.Kind.directories | commands.Kind.background,
        .min_selection = 0,
        .max_selection = 4096,
        .extensions = null,
        .extension_count = 0,
        .exclude_extensions = 0,
        .virtual_key = 0x78, // F9; the host rejects letters/digits without CTRL or ALT.
        .modifiers = commands.Modifier.ctrl | commands.Modifier.shift,
        .invoke = commandInvoke,
        .user = null,
    };
    var command_id: commands.CommandId = 0;
    const result = register(table.context, &descriptor, &command_id);
    logStatus("register", result);
    return result;
}

fn activate(raw: ?*anyopaque) callconv(.c) abi.Status {
    logEvent("activate");
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return abi.error_argument));
    instance.active = true;
    return abi.ok;
}

fn deactivate(raw: ?*anyopaque) callconv(.c) void {
    logEvent("deactivate");
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return));
    instance.active = false;
}

fn destroy(raw: ?*anyopaque) callconv(.c) void {
    logEvent("destroy");
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return));
    allocator.destroy(instance);
}

/// Host owns both table buffers and guarantees readable initialized headers.
/// Successful instances must be destroyed exactly once on the owning thread.
export fn PulsePluginEntryV1(host_ptr: ?*const abi.HostV1, out_ptr: ?*abi.PluginV1) callconv(.c) abi.Status {
    logEvent("entry");
    const host = host_ptr orelse return abi.error_abi;
    const out = out_ptr orelse return abi.error_abi;
    if (host.size < @sizeOf(abi.HostV1) or out.size < @sizeOf(abi.PluginV1)) return abi.error_abi;
    if (host.version != abi.abi_version or out.version != abi.abi_version) return abi.error_abi;
    const instance = allocator.create(Instance) catch return abi.error_initialization;
    instance.* = .{};
    // Best effort: a host without pulse.commands still gets a valid plugin table.
    _ = registerProbeCommand(host);
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

fn newHost() abi.HostV1 {
    return .{ .size = @sizeOf(abi.HostV1), .version = abi.abi_version, .context = null, .query_interface = null };
}

fn newOutput() abi.PluginV1 {
    return .{
        .size = @sizeOf(abi.PluginV1),
        .version = abi.abi_version,
        .instance = null,
        .activate = null,
        .deactivate = null,
        .destroy = null,
    };
}

test "matching ABI and repeated lifecycle" {
    const host = newHost();
    for (0..32) |_| {
        var out = newOutput();
        try std.testing.expectEqual(abi.ok, PulsePluginEntryV1(&host, &out));
        defer out.destroy.?(out.instance);
        try std.testing.expect(out.instance != null);
        try std.testing.expectEqual(abi.ok, out.activate.?(out.instance));
        out.deactivate.?(out.instance);
        try std.testing.expectEqual(abi.ok, out.activate.?(out.instance));
        out.deactivate.?(out.instance);
    }
}

test "reject null short and incompatible tables" {
    var host = newHost();
    var out = newOutput();
    try std.testing.expectEqual(abi.error_abi, PulsePluginEntryV1(null, &out));
    try std.testing.expectEqual(abi.error_abi, PulsePluginEntryV1(&host, null));
    host.size = 8;
    try std.testing.expectEqual(abi.error_abi, PulsePluginEntryV1(&host, &out));
    host = newHost();
    out.size = 8;
    try std.testing.expectEqual(abi.error_abi, PulsePluginEntryV1(&host, &out));
    out = newOutput();
    out.version = 99;
    try std.testing.expectEqual(abi.error_abi, PulsePluginEntryV1(&host, &out));
    try std.testing.expect(out.instance == null);
    try std.testing.expectEqual(@as(u32, 3), PulsePluginSdkPreview());
}
