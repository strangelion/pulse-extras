//! Experimental native VCS lifecycle candidate. No production approval
//! source yet: no resolver, tool discovery, task admission or CLI execution.
//! The host must prove callback drain before any distributable package ships.

const std = @import("std");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const async_host = @import("pulse_async_host");
const host_query = @import("vcs_host_query");
const diag = @import("pulse_diagnostics");

const allocator = std.heap.page_allocator;

const Instance = struct {
    host: host_mod.Host,
    binding: ?host_query.Binding = null,
    active: bool = false,

    fn start(self: *Instance) host_mod.Error!void {
        if (self.active) {
            if (self.binding) |*binding| {
                if (binding.accepting) return;
            }
            return error.State;
        }
        if (self.binding != null) return error.State;
        self.binding = try host_query.Binding.init(try async_host.taskTable(self.host), .en);
        errdefer self.stop() catch |err| diag.status("vcs-rollback-failed", @intFromError(err));
        const binding = &self.binding.?;
        try binding.lockExecution();
        // No dispatch or worker while the real host drain gate is unverified.
        // Navigation is a copied mailbox; explicit Check result repaints it.
        try binding.open(self.host);
        try binding.openNavigation(self.host);
        self.active = true;
    }

    fn stop(self: *Instance) host_mod.Error!void {
        self.active = false;
        if (self.binding) |*binding| {
            try binding.requestStop();
            binding.checkDrained() catch return error.State;
            self.binding = null;
        }
    }
};

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

fn activate(raw: ?*anyopaque) callconv(.c) abi.Status {
    const self: *Instance = @ptrCast(@alignCast(raw orelse return abi.error_argument));
    self.start() catch |err| {
        diag.status("vcs-activate-failed", @intFromError(err));
        return statusOf(err);
    };
    diag.event("vcs-activated-locked");
    return abi.ok;
}

fn deactivate(raw: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(raw orelse return));
    self.stop() catch |err| {
        diag.status("vcs-deactivate-failed", @intFromError(err));
        return;
    };
    diag.event("vcs-deactivated");
}

fn destroy(raw: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(raw orelse return));
    self.stop() catch |err| {
        diag.status("vcs-destroy-stop-failed", @intFromError(err));
        // The locked candidate owns no tasks, dispatch or plugin threads.
        // At final destroy the SDK stop boundary suppresses host callbacks.
        // Never use this retirement path for ordinary deactivate.
        if (self.binding) |*binding| {
            binding.retireAtHostDestroy() catch |retire_err| {
                diag.status("vcs-destroy-drain-failed", @intFromError(retire_err));
                return;
            };
            binding.checkDrained() catch return;
            self.binding = null;
        }
    };
    allocator.destroy(self);
}

export fn PulsePluginSdkPreview() callconv(.c) u32 {
    return abi.sdk_preview;
}

export fn PulsePluginEntryV1(host_ptr: ?*const abi.HostV1, out_ptr: ?*abi.PluginV1) callconv(.c) abi.Status {
    const host = host_ptr orelse return abi.error_abi;
    const out = out_ptr orelse return abi.error_abi;
    if (host.size < @sizeOf(abi.HostV1) or out.size < @sizeOf(abi.PluginV1)) return abi.error_abi;
    if (host.version != abi.abi_version or out.version != abi.abi_version) return abi.error_abi;
    const validated = host_mod.Host.init(host) catch |err| return statusOf(err);
    const self = allocator.create(Instance) catch return abi.error_initialization;
    self.* = .{ .host = validated };
    out.* = .{
        .size = @sizeOf(abi.PluginV1),
        .version = abi.abi_version,
        .instance = self,
        .activate = activate,
        .deactivate = deactivate,
        .destroy = destroy,
    };
    return abi.ok;
}

fn unavailable(_: ?*anyopaque, _: abi.StringView, _: u32, _: ?*anyopaque, _: u32) callconv(.c) abi.Status {
    return abi.error_unavailable;
}

test "native entry refuses incompatible host and missing task interface without retaining state" {
    var host: abi.HostV1 = .{ .size = @sizeOf(abi.HostV1), .version = abi.abi_version, .context = null, .query_interface = null };
    var out = std.mem.zeroes(abi.PluginV1);
    out.size = @sizeOf(abi.PluginV1);
    out.version = abi.abi_version;
    try std.testing.expectEqual(abi.error_unavailable, PulsePluginEntryV1(&host, &out));
    try std.testing.expect(out.instance == null);
    host.query_interface = &unavailable;
    try std.testing.expectEqual(abi.ok, PulsePluginEntryV1(&host, &out));
    defer out.destroy.?(out.instance);
    try std.testing.expectEqual(abi.error_unavailable, out.activate.?(out.instance));
    const self: *Instance = @ptrCast(@alignCast(out.instance.?));
    try std.testing.expect(self.binding == null and !self.active);
    out.deactivate.?(out.instance);
    try std.testing.expectEqual(abi.error_unavailable, out.activate.?(out.instance));
    try std.testing.expect(self.binding == null and !self.active);
}
