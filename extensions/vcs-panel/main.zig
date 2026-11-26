//! Native VCS candidate. The default source loads one explicitly reviewed
//! Windows user grant; absent grant locks execution.
//! Real-host acceptance and production auditor certification are release gates.

const std = @import("std");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const async_host = @import("pulse_async_host");
const host_query = @import("vcs_host_query");
const diag = @import("pulse_diagnostics");
const approval = @import("vcs_approval");
const source = @import("vcs_native_source");

const allocator = std.heap.page_allocator;

const Instance = struct {
    host: host_mod.Host,
    binding: ?host_query.Binding = null,
    session: ?approval.NativeSession = null,
    session_revoked: bool = false,
    active: bool = false,

    fn start(self: *Instance) host_mod.Error!void {
        if (self.active) {
            if (self.binding) |*binding| {
                if (binding.accepting) return;
            }
            return error.State;
        }
        if (self.binding != null or self.session != null) return error.State;
        self.binding = try host_query.Binding.init(try async_host.taskTable(self.host), .en);
        errdefer self.stop() catch |err| diag.status("vcs-rollback-failed", @intFromError(err));
        const binding = &self.binding.?;
        if (!self.session_revoked) {
            if (try source.acquire(allocator)) |input| {
                self.session = approval.NativeSession.init(input, allocator);
                try self.session.?.configure(binding);
                // Supported wake hints only; no polling loop. An unavailable
                // dispatcher is a visible activation failure, not fallback.
                try binding.configureDispatch(try async_host.Dispatch.init(self.host));
            }
        }
        if (self.session == null) try binding.lockExecution();
        try binding.open(self.host);
        try binding.openNavigation(self.host);
        // Start only from the owner after the borrowed initial context call
        // returned. Later navigation uses bounded dispatch/manual Check.
        if (self.session != null) try binding.pump();
        self.active = true;
    }

    fn stop(self: *Instance) host_mod.Error!void {
        self.active = false;
        if (self.session) |*session| session.stopAdmission();
        if (self.binding) |*binding| {
            try binding.requestStop();
            binding.checkDrained() catch return error.State;
            if (binding.approval_locked and self.session != null) self.session_revoked = true;
            self.binding = null;
        }
        try self.finishSession();
    }

    fn finishSession(self: *Instance) host_mod.Error!void {
        if (self.session) |*session| {
            session.finish() catch return error.State;
            self.session = null;
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
    diag.event(if (self.session == null) "vcs-activated-locked" else "vcs-activated-reviewed");
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
        // At final destroy the SDK stop boundary suppresses callbacks and
        // joins host-owned task work. The source must own no live producers.
        // Never use this retirement path for ordinary deactivate.
        if (self.binding) |*binding| {
            binding.retireAtHostDestroy() catch |retire_err| {
                diag.status("vcs-destroy-drain-failed", @intFromError(retire_err));
                return;
            };
            binding.checkDrained() catch return;
            self.binding = null;
        }
        self.finishSession() catch |finish_err| {
            diag.status("vcs-destroy-runner-failed", @intFromError(finish_err));
            return;
        };
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

/// Standalone approval-tool ABI. These calls are not host callbacks. The
/// caller loads this exact reviewed DLL and invokes them explicitly.
export fn PulseVcsInspectV1(input: ?[*]const u8, length: u32, output: ?[*]u8, capacity: u32, written: ?*u32) callconv(.c) abi.Status {
    const count = written orelse return abi.error_argument;
    count.* = 0;
    if (length == 0 or length > 128 * 1024 or capacity > approval.Review.record_max_bytes) return abi.error_argument;
    const bytes = input orelse return abi.error_argument;
    const result = output orelse return abi.error_argument;
    if (comptime @hasDecl(source, "inspect")) {
        const size = source.inspect(bytes[0..length], result[0..capacity]) catch |err| return statusOf(err);
        count.* = @intCast(size);
        return abi.ok;
    } else return abi.error_unavailable;
}

export fn PulseVcsConfirmV1(input: ?[*]const u8, length: u32, review: ?[*]const u8, review_length: u32) callconv(.c) abi.Status {
    if (length == 0 or length > 128 * 1024 or review_length == 0 or review_length > approval.Review.record_max_bytes) return abi.error_argument;
    const bytes = input orelse return abi.error_argument;
    const record = review orelse return abi.error_argument;
    if (comptime @hasDecl(source, "confirm")) {
        source.confirm(bytes[0..length], record[0..review_length]) catch |err| return statusOf(err);
        return abi.ok;
    } else return abi.error_unavailable;
}

export fn PulseVcsRevokeV1() callconv(.c) abi.Status {
    if (comptime @hasDecl(source, "revokeSaved")) {
        source.revokeSaved() catch |err| return statusOf(err);
        return abi.ok;
    } else return abi.error_unavailable;
}
