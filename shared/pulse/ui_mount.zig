//! `pulse.ui.mount` V1 - asking the host where a panel should live.
//!
//! The host owns placement policy; the plugin can request a placement, read the
//! granted placement, and subscribe to changes (window resize, sidebar toggle,
//! user moving the panel). Subscriptions are per panel and must be released.

const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");

pub const interface_name: []const u8 = raw.PULSE_UI_MOUNT_INTERFACE;
pub const version_1: u32 = raw.PULSE_UI_MOUNT_VERSION_1;

pub const Placement = enum(u32) {
    window = 0,
    sidebar = 1,
    workspace = 2,
    _,
};

pub const Info = raw.PulseUiMountInfo;
pub const ChangedFn = raw.PulseUiMountChangedFn;
pub const TableV1 = raw.PulseUiMountV1;

pub fn query(host: *const abi.HostV1, out: *TableV1) abi.Status {
    const query_interface = host.query_interface orelse return abi.error_unavailable;
    out.* = std.mem.zeroes(TableV1);
    return query_interface(host.context, abi.view(interface_name), version_1, @ptrCast(out), @intCast(@sizeOf(TableV1)));
}

pub const Mount = struct {
    table: TableV1,

    pub fn init(host: host_mod.Host) host_mod.Error!Mount {
        return .{ .table = try host.query(TableV1, interface_name, version_1) };
    }

    /// Requests a placement. The host may refuse (`Argument`/`State`) when the
    /// requested slot does not accept this panel kind.
    pub fn request(self: Mount, panel: u64, placement: Placement) host_mod.Error!void {
        const set = self.table.set orelse return error.Unavailable;
        try host_mod.mapStatus(set(self.table.context, panel, @backingInt(placement)));
    }

    pub fn get(self: Mount, panel: u64) host_mod.Error!Info {
        const get_fn = self.table.get orelse return error.Unavailable;
        var info: Info = std.mem.zeroes(Info);
        try host_mod.mapStatus(get_fn(self.table.context, panel, &info));
        if (info.size < @sizeOf(Info)) return error.Abi;
        return info;
    }

    pub fn subscribe(self: Mount, panel: u64, callback: ChangedFn, user: ?*anyopaque) host_mod.Error!u64 {
        const subscribe_fn = self.table.subscribe orelse return error.Unavailable;
        var subscription: u64 = 0;
        try host_mod.mapStatus(subscribe_fn(self.table.context, panel, callback, user, &subscription));
        if (subscription == 0) return error.State;
        return subscription;
    }

    pub fn unsubscribe(self: Mount, subscription: u64) host_mod.Error!void {
        const unsubscribe_fn = self.table.unsubscribe orelse return error.Unavailable;
        try host_mod.mapStatus(unsubscribe_fn(self.table.context, subscription));
    }
};

comptime {
    if (@sizeOf(TableV1) != 48) @compileError("PulseUiMountV1 must be 48 bytes on x86_64");
}

test "query without a host query function is unavailable" {
    const host = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = 1, .context = null, .query_interface = null };
    var table: TableV1 = undefined;
    try std.testing.expectEqual(abi.error_unavailable, query(&host, &table));
}
