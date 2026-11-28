//! Pulse context-menu adapter. The desktop process owns UI and network tasks.
const std = @import("std");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const commands = @import("pulse_commands");
const context = @import("pulse_context");
const diag = @import("pulse_diagnostics");
const async_host = @import("pulse_async_host");
const raw = @import("pulse_raw");
const prefs = @import("preferences.zig");
const managed = @import("managed.zig");
const handoff = @import("handoff.zig");
const desktop_digest = @import("share_desktop_digest");
const allocator = std.heap.page_allocator;

const Instance = struct {
    host: host_mod.Host,
    menu: commands.Table,
    legacy: prefs.Legacy,
    task: ?async_host.Task = null,
    command_id: commands.CommandId = 0,
    payload: [handoff.capacity]u8 = undefined,
    payload_len: usize = 0,
    active: bool = false,
};

fn selected(snapshot: [*c]const commands.SelectionSnapshot, buffer: []u8) handoff.Selection {
    if (snapshot == null or !context.validSelection(snapshot) or snapshot.*.entry_count == 0 or
        snapshot.*.entry_count > 64 or snapshot.*.entries == null) return .{};
    const count = snapshot.*.entry_count;
    const entries: [*]const context.SelectionEntry = @ptrCast(snapshot.*.entries);
    var len: usize = 0;
    for (entries[0..count]) |*entry| {
        if (entry.size < @sizeOf(context.SelectionEntry)) return .{};
        const path = context.entryPath(entry) orelse return .{};
        if (std.mem.indexOfScalar(u8, path, '|') != null or path.len + len + 1 >= buffer.len) return .{};
        if (len != 0) {
            buffer[len] = '|';
            len += 1;
        }
        @memcpy(buffer[len..][0..path.len], path);
        len += path.len;
    }
    return .{ .count = count, .single_file = count == 1 and entries[0].flags & context.EntryFlag.directory == 0, .paths = buffer[0..len] };
}

fn result(ctx: *const raw.PulseTaskContext, text: []const u8) void {
    if (ctx.report) |report| {
        var progress = std.mem.zeroes(raw.PulseTaskProgress);
        progress.size = @sizeOf(raw.PulseTaskProgress);
        progress.percent = std.math.maxInt(u32);
        progress.current_item = abi.view(text);
        _ = report(ctx.context, &progress);
    }
}

fn launch(user: ?*anyopaque, value: [*c]const raw.PulseTaskContext) callconv(.c) raw.PulseTaskState {
    const self: *Instance = @ptrCast(@alignCast(user orelse return 4));
    if (value == null) return 4;
    managed.launchDesktop(desktop_digest.sha256, self.payload[0..self.payload_len], &value.*) catch |err| {
        result(&value.*, "无法打开 Share 窗口");
        diag.status("share-desktop-launch", @intFromError(err));
        return if (err == error.Cancelled) 5 else 4;
    };
    result(&value.*, "Share 窗口已启动");
    return 2;
}

fn invoke(user: ?*anyopaque, _: commands.CommandId, snapshot: [*c]const commands.SelectionSnapshot) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(user orelse return));
    if (!self.active) return;
    if (self.task == null) {
        const table = async_host.taskTable(self.host) catch |err| {
            diag.status("share-desktop-task-table", @intFromError(err));
            return;
        };
        self.task = async_host.Task.init(table) catch return;
    }
    const task = &self.task.?;
    if (task.occupied()) {
        const state = task.poll() catch return;
        if (!state.terminal()) return;
        task.releaseTerminal() catch return;
    }
    var paths: [2048]u8 = undefined;
    var selection = selected(snapshot, &paths);
    var preferences: [prefs.limit]u8 = undefined;
    if (self.legacy.loaded) selection.preferences = self.legacy.saved.encode(&preferences) catch "";
    self.payload_len = (selection.encode(&self.payload) catch blk: {
        break :blk (handoff.Selection{ .preferences = selection.preferences }).encode(&self.payload) catch return;
    }).len;
    var descriptor = std.mem.zeroes(raw.PulseTaskDescriptor);
    descriptor.size = @sizeOf(raw.PulseTaskDescriptor);
    descriptor.title = abi.view("打开 Pulse Share");
    descriptor.type = abi.view("share");
    descriptor.work = &launch;
    descriptor.user = self;
    task.start(&descriptor) catch |err| diag.status("share-desktop-start", @intFromError(err));
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

fn activate(raw_instance: ?*anyopaque) callconv(.c) abi.Status {
    const self: *Instance = @ptrCast(@alignCast(raw_instance orelse return abi.error_argument));
    self.active = true;
    self.legacy.open() catch |err| diag.status("share-legacy-preferences", @intFromError(err));
    return abi.ok;
}

fn deactivate(raw_instance: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(raw_instance orelse return));
    self.active = false;
    if (self.task) |*task| task.cancel() catch |err| diag.status("share-desktop-cancel", @intFromError(err));
    self.legacy.close() catch |err| diag.status("share-legacy-close", @intFromError(err));
}

fn destroy(raw_instance: ?*anyopaque) callconv(.c) void {
    const self: *Instance = @ptrCast(@alignCast(raw_instance orelse return));
    self.active = false;
    if (self.command_id != 0) self.menu.unregister(self.command_id) catch |err| switch (err) {
        error.State => {},
        else => diag.status("share-command-unregister", @intFromError(err)),
    };
    self.legacy.close() catch |err| diag.status("share-legacy-destroy", @intFromError(err));
    if (self.task) |*task| task.retireAtHostDestroy();
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
    const table = commands.Table.init(validated) catch |err| return statusOf(err);
    if (table.raw.unregister_command == null) return abi.error_unavailable;
    const self = allocator.create(Instance) catch return abi.error_initialization;
    self.* = .{ .host = validated, .menu = table, .legacy = .{ .host = validated } };
    var descriptor = commands.descriptor("strangelion.share.open", "Pulse Share / 文件共享", &invoke);
    descriptor.kinds = commands.Kind.files | commands.Kind.directories;
    descriptor.min_selection = 0;
    descriptor.max_selection = 4096;
    descriptor.user = self;
    self.command_id = table.register(&descriptor) catch |err| {
        allocator.destroy(self);
        return statusOf(err);
    };
    if (self.command_id == 0) {
        allocator.destroy(self);
        return abi.error_state;
    }
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

test "share adapter rejects null ABI inputs" {
    try std.testing.expectEqual(abi.error_abi, PulsePluginEntryV1(null, null));
    try std.testing.expectEqual(abi.sdk_preview, PulsePluginSdkPreview());
    std.testing.refAllDecls(@import("handoff.zig"));
    std.testing.refAllDecls(@import("presentation.zig"));
    std.testing.refAllDecls(@import("choices.zig"));
    std.testing.refAllDecls(@import("pair_ticket.zig"));
    std.testing.refAllDecls(@import("worker_messages.zig"));
    std.testing.refAllDecls(@import("diagnostic_history.zig"));
}
