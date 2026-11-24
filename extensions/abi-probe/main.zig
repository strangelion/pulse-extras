const std = @import("std");
const abi = @import("pulse_abi");

const Instance = struct { active: bool = false };
const allocator = std.heap.page_allocator;

export fn PulsePluginSdkPreview() callconv(.c) u32 {
    return abi.sdk_preview;
}

fn activate(raw: ?*anyopaque) callconv(.c) abi.Status {
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return abi.error_argument));
    instance.active = true;
    return abi.ok;
}

fn deactivate(raw: ?*anyopaque) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return));
    instance.active = false;
}

fn destroy(raw: ?*anyopaque) callconv(.c) void {
    const instance: *Instance = @ptrCast(@alignCast(raw orelse return));
    allocator.destroy(instance);
}

/// Host owns both table buffers and guarantees readable initialized headers.
/// Successful instances must be destroyed exactly once on the owning thread.
export fn PulsePluginEntryV1(host_ptr: ?*const abi.HostV1, out_ptr: ?*abi.PluginV1) callconv(.c) abi.Status {
    const host = host_ptr orelse return abi.error_abi;
    const out = out_ptr orelse return abi.error_abi;
    if (host.size < @sizeOf(abi.HostV1) or out.size < @sizeOf(abi.PluginV1)) return abi.error_abi;
    if (host.version != abi.abi_version or out.version != abi.abi_version) return abi.error_abi;
    const instance = allocator.create(Instance) catch return abi.error_initialization;
    instance.* = .{};
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
