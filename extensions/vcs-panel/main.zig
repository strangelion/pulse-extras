//! Native VCS candidate. The default source loads one explicitly reviewed
//! Windows user grant; absent grant permits only non-executing metadata preview.
//! Real-host acceptance and production auditor certification are release gates.

const std = @import("std");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const async_host = @import("pulse_async_host");
const host_query = @import("vcs_host_query");
const diag = @import("pulse_diagnostics");
const approval = @import("vcs_approval");
const source = @import("vcs_native_source");
const commands = @import("pulse_commands");
const context = @import("pulse_context");
const mount = @import("pulse_ui_mount");
const settings_mod = @import("settings.zig");
const vcs_panel = @import("vcs_panel");

const allocator = std.heap.page_allocator;

const Instance = struct {
    host: host_mod.Host,
    settings: ?settings_mod.Settings = null,
    binding: ?host_query.Binding = null,
    session: ?approval.NativeSession = null,
    session_revoked: bool = false,
    active: bool = false,
    menu_table: ?commands.Table = null,
    menu_id: commands.CommandId = 0,
    menu_accepting: bool = false,
    menu_invoking: bool = false,

    // Entry-time registration is required by commands.h: discovering a menu
    // must not open the panel or acquire the protected Git grant.
    fn registerMenu(self: *Instance) void {
        const table = commands.Table.init(self.host) catch |err| {
            diag.status("vcs-menu-unavailable", @intFromError(err));
            return;
        };
        if (table.raw.unregister_command == null) return;
        var item = commands.descriptor("vcs.open-current", "VCS: Current directory / 查看当前目录", &invokeMenu);
        item.kinds = commands.Kind.files | commands.Kind.directories;
        item.min_selection = 0;
        item.max_selection = 4096;
        item.user = self;
        self.menu_table = table;
        self.menu_id = table.register(&item) catch |err| {
            diag.status("vcs-menu-register-failed", @intFromError(err));
            return;
        };
        // A successful zero ID is unusable; never admit its callbacks.
        self.menu_accepting = self.menu_id != 0;
        diag.status("vcs-menu-registered", @intFromBool(self.menu_accepting));
    }

    fn openFromMenu(self: *Instance) host_mod.Error!void {
        if (self.active) {
            if (self.binding) |*binding| {
                if (binding.accepting) {
                    // Refresh the owner context synchronously, without using
                    // selected filenames as an authorization or tool argument.
                    try binding.navigation.refreshCurrent();
                    binding.pump() catch |err| {
                        if (err != error.State or binding.accepting) return err;
                        // A closed host panel is not proof of drain. Reopen
                        // only after the existing stop path confirms cleanup.
                        try self.stop();
                    };
                } else try self.stop();
            } else return error.State;
        } else if (self.binding != null or self.session != null) {
            try self.stop();
        }
        try self.start();
        const binding = if (self.binding) |*value| value else return error.State;
        const model = binding.model orelse return error.State;
        // Best effort only: the host can refuse an occupied sidebar. The
        // existing panel remains the fallback and retains its ownership.
        if (mount.Mount.init(self.host)) |placement| {
            placement.request(model.id, .sidebar) catch |err| diag.status("vcs-menu-mount-refused", @intFromError(err));
        } else |err| diag.status("vcs-menu-mount-unavailable", @intFromError(err));
    }

    fn openSettings(self: *Instance) void {
        if (self.settings == null) self.settings = .{ .host = self.host, .user = self, .current = &currentProject, .updated = &settingsUpdated };
        if (self.settings) |*settings| settings.open() catch |err| diag.status("vcs-settings-open", @intFromError(err));
    }

    fn settingsUpdated(user: *anyopaque, tools: settings_mod.Tools, language: vcs_panel.Language) void {
        const self: *Instance = @ptrCast(@alignCast(user));
        if (self.binding) |*binding| {
            binding.configured_tools = tools;
            binding.language = language;
            binding.local_review = null;
            if (binding.accepting) binding.render() catch |err| diag.status("vcs-settings-view", @intFromError(err));
        }
    }

    fn currentProject(user: *anyopaque) ?settings_mod.Current {
        const self: *Instance = @ptrCast(@alignCast(user));
        const binding = if (self.binding) |*value| value else return null;
        if (!binding.accepting) return null;
        binding.navigation.refreshCurrent() catch return null;
        binding.render() catch return null;
        if (binding.navigation.pending or binding.controller.current.phase != .ready or binding.controller.current.stale) return null;
        const workspace = binding.controller.current.workspace orelse return null;
        const snapshot = binding.controller.current.snapshot orelse return null;
        return .{ .root = workspace.root, .remote = snapshot.remote_web, .kind = workspace.kind };
    }

    fn start(self: *Instance) host_mod.Error!void {
        self.openSettings();
        if (self.active) {
            if (self.binding) |*binding| {
                if (binding.accepting) return;
            }
            return error.State;
        }
        if (self.binding != null or self.session != null) return error.State;
        self.binding = try host_query.Binding.init(try async_host.taskTable(self.host), settings_mod.Locale.auto.language());
        errdefer self.stop() catch |err| diag.status("vcs-rollback-failed", @intFromError(err));
        const binding = &self.binding.?;
        if (self.settings) |*settings| {
            if (settings.loaded) {
                binding.configured_tools = settings.stored.tools;
                binding.language = settings.stored.locale.language();
            }
        }
        if (!self.session_revoked) {
            const input_value = source.acquire(allocator) catch |err| blk: {
                if (comptime @hasDecl(source, "configurePreview")) {
                    diag.status("vcs-approval-unavailable", @intFromError(err));
                    break :blk null;
                } else return err;
            };
            if (input_value) |input| {
                self.session = approval.NativeSession.init(input, allocator);
                try self.session.?.configure(binding);
                // Supported wake hints only; no polling loop. An unavailable
                // dispatcher is a visible activation failure, not fallback.
                try binding.configureDispatch(try async_host.Dispatch.init(self.host));
            }
        }
        if (self.session == null) {
            if (comptime @hasDecl(source, "configurePreview")) {
                // The actual host has dispatch; an older/mock host without
                // it keeps the existing locked, non-executing model.
                if (async_host.Dispatch.init(self.host)) |dispatch| {
                    try source.configurePreview(binding);
                    try binding.configureDispatch(dispatch);
                } else |_| try binding.lockExecution();
            } else try binding.lockExecution();
        }
        try binding.open(self.host);
        try binding.openNavigation(self.host);
        // Start only from the owner after the borrowed initial context call
        // returned. Later navigation uses bounded dispatch/manual Check.
        if (self.session != null or binding.metadata_only) try binding.pump();
        self.active = true;
    }

    fn stop(self: *Instance) host_mod.Error!void {
        self.active = false;
        if (self.session) |*session| session.stopAdmission();
        if (self.binding) |*binding| {
            try binding.requestStop();
            binding.checkDrained() catch return error.State;
            try binding.finishLocalAccess();
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

fn invokeMenu(user: ?*anyopaque, id: commands.CommandId, snapshot: [*c]const commands.SelectionSnapshot) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!self.menu_accepting or self.menu_invoking or id == 0 or id != self.menu_id) return;
    if (snapshot == null or !context.validSelection(&snapshot.*)) return;
    if (snapshot.*.entry_count > 4096 or (snapshot.*.entry_count != 0 and snapshot.*.entries == null)) return;
    const directory = abi.slice(snapshot.*.directory) orelse return;
    if (directory.len == 0 or directory.len > 32768 or !std.unicode.utf8ValidateSlice(directory) or std.mem.indexOfScalar(u8, directory, 0) != null) return;
    // Intentionally follow the current loaded directory, not a selected
    // child or arbitrary path. No borrowed snapshot survives this call.
    self.menu_invoking = true;
    defer self.menu_invoking = false;
    self.openFromMenu() catch |err| {
        diag.status("vcs-menu-open-failed", @intFromError(err));
        return;
    };
    diag.event("vcs-menu-open");
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

fn activate(raw: ?*anyopaque) callconv(.c) abi.Status {
    const self: *Instance = @ptrCast(@alignCast(raw orelse return abi.error_argument));
    self.start() catch |err| {
        diag.status("vcs-activate-failed", @intFromError(err));
        return statusOf(err);
    };
    diag.event(if (self.session != null) "vcs-activated-reviewed" else if (self.binding != null and self.binding.?.metadata_only) "vcs-activated-preview" else "vcs-activated-locked");
    return abi.ok;
}

fn deactivate(raw: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(raw orelse return));
    if (self.settings) |*settings| settings.close() catch |err| diag.status("vcs-settings-deactivate", @intFromError(err));
    self.stop() catch |err| {
        diag.status("vcs-deactivate-failed", @intFromError(err));
        return;
    };
    diag.event("vcs-deactivated");
}

fn destroy(raw: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(raw orelse return));
    self.menu_accepting = false;
    if (self.settings) |*settings| settings.retireAtHostDestroy();
    if (self.menu_id != 0) {
        if (self.menu_table) |table| {
            table.unregister(self.menu_id) catch |err| {
                // Final destroy only: commands.h guarantees host stop
                // invalidates menu callbacks. STATE is expected host-first.
                if (err != error.State) diag.status("vcs-menu-unregister-failed", @intFromError(err));
            };
        }
        self.menu_id = 0;
    }
    self.menu_table = null;
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
            binding.finishLocalAccess() catch |finish_err| {
                diag.status("vcs-local-session-finish-failed", @intFromError(finish_err));
                return;
            };
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
    self.registerMenu();
    self.openSettings();
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
