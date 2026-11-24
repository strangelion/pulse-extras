//! Safe view over the `pulse.context` host interface.
//!
//! Every string in a snapshot is borrowed from the host and only valid for the
//! duration of the callback. Callers must copy what they need before returning.

const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");

pub const interface_name = raw.PULSE_CONTEXT_INTERFACE_NAME;
pub const version_1: u32 = @intCast(raw.PULSE_CONTEXT_VERSION_1);

pub const Change = struct {
    pub const initial: u32 = @intCast(raw.PULSE_CONTEXT_INITIAL);
    pub const navigation: u32 = @intCast(raw.PULSE_CONTEXT_NAVIGATION);
    pub const selection: u32 = @intCast(raw.PULSE_CONTEXT_SELECTION);
    pub const view: u32 = @intCast(raw.PULSE_CONTEXT_VIEW);
};

pub const EntryFlag = struct {
    pub const directory: u32 = @intCast(raw.PULSE_CONTEXT_ENTRY_DIRECTORY);
};

pub const Snapshot = raw.PulseContextSnapshot;
pub const SelectionSnapshot = raw.PulseContextSelectionSnapshot;
pub const SelectionEntry = raw.PulseContextSelectionEntry;
pub const SubscriptionId = raw.PulseContextSubscriptionId;
pub const ChangeFn = raw.PulseContextChangeFn;
pub const SelectionFn = raw.PulseContextSelectionFn;
pub const TableV1 = raw.PulseContextV1;

comptime {
    std.debug.assert(@sizeOf(TableV1) == 48);
    std.debug.assert(@offsetOf(TableV1, "get") == 16);
    std.debug.assert(@offsetOf(TableV1, "get_selection") == 40);
    std.debug.assert(@offsetOf(Snapshot, "loading") == 88);
}

pub fn query(host: *const abi.HostV1, out: *TableV1) abi.Status {
    out.* = std.mem.zeroes(TableV1);
    return host.query_interface.?(
        host.context,
        abi.view(interface_name),
        version_1,
        out,
        @sizeOf(TableV1),
    );
}

pub const Error = host_mod.Error;

pub const Table = struct {
    raw: TableV1,

    pub fn init(host: *const abi.HostV1) Error!Table {
        var table: TableV1 = undefined;
        const status = query(host, &table);
        try host_mod.mapStatus(status);
        if (table.size < @sizeOf(TableV1) or table.version < version_1) return error.Abi;
        if (table.context == null or table.get == null) return error.Unavailable;
        return .{ .raw = table };
    }

    /// Synchronous read. The callback runs before this returns and its snapshot
    /// is only valid inside it; copy strings you keep.
    pub fn get(self: *const Table, callback: ChangeFn, user: ?*anyopaque) Error!void {
        const get_fn = self.raw.get orelse return error.Unavailable;
        try host_mod.mapStatus(get_fn(self.raw.context, callback, user));
    }

    /// The host coalesces changes (about 30 ms) and allows at most 16
    /// subscriptions per attachment.
    pub fn subscribe(self: *const Table, callback: ChangeFn, user: ?*anyopaque, id: *SubscriptionId) Error!void {
        const subscribe_fn = self.raw.subscribe orelse return error.Unavailable;
        id.* = 0;
        try host_mod.mapStatus(subscribe_fn(self.raw.context, callback, user, id));
        if (id.* == 0) return error.State;
    }

    pub fn unsubscribe(self: *const Table, id: SubscriptionId) Error!void {
        const unsubscribe_fn = self.raw.unsubscribe orelse return error.Unavailable;
        if (id == 0) return;
        try host_mod.mapStatus(unsubscribe_fn(self.raw.context, id));
    }

    /// Reads the already loaded selection snapshot. Returns `error.State` while
    /// the host is still loading and `error.Unavailable` for virtual views.
    pub fn getSelection(self: *const Table, callback: SelectionFn, user: ?*anyopaque) Error!void {
        const get_selection = self.raw.get_selection orelse return error.Unavailable;
        try host_mod.mapStatus(get_selection(self.raw.context, callback, user));
    }
};

pub fn directory(snapshot: *const Snapshot) ?[]const u8 {
    return abi.slice(snapshot.directory);
}

pub fn selectionName(snapshot: *const Snapshot) ?[]const u8 {
    return abi.slice(snapshot.selection_name);
}

/// Copies a borrowed host string into `buffer`, returning the slice that was
/// written. Truncated results are still valid UTF-8 boundaries only when the
/// caller passes a generous buffer; callers that need exactness should check
/// `source.len <= buffer.len` first.
pub fn copyBorrowed(source: []const u8, buffer: []u8) []const u8 {
    const length = @min(source.len, buffer.len);
    @memcpy(buffer[0..length], source[0..length]);
    return buffer[0..length];
}

const testing = std.testing;

fn fakeContext(_: ?*anyopaque, callback: raw.PulseContextChangeFn, user: ?*anyopaque) callconv(.c) raw.PulseStatus {
    var snapshot = std.mem.zeroes(Snapshot);
    snapshot.size = @sizeOf(Snapshot);
    snapshot.changes = Change.initial | Change.navigation;
    snapshot.revision = 7;
    snapshot.directory = abi.view("C:\\work");
    snapshot.selection_name = abi.view("main.zig");
    snapshot.loading = 0;
    if (callback) |cb| cb(user, &snapshot);
    return abi.ok;
}

test "get delivers a borrowed snapshot" {
    const table = TableV1{
        .size = @sizeOf(TableV1),
        .version = version_1,
        .context = null,
        .get = &fakeContext,
    };
    const t = Table{ .raw = table };
    const Probe = struct {
        revision: u64 = 0,
        directory: [16]u8 = undefined,
        directory_len: usize = 0,
        fn onChange(user: ?*anyopaque, snapshot: [*c]const Snapshot) callconv(.c) void {
            const self: *@This() = @ptrCast(@alignCast(user.?));
            self.revision = snapshot.*.revision;
            const source = directory(&snapshot.*) orelse return;
            const copied = copyBorrowed(source, &self.directory);
            self.directory_len = copied.len;
        }
    };
    var probe = Probe{};
    try t.get(&Probe.onChange, &probe);
    try testing.expectEqual(@as(u64, 7), probe.revision);
    try testing.expectEqualStrings("C:\\work", probe.directory[0..probe.directory_len]);
}

test "subscription id must be non-zero" {
    const table = TableV1{
        .size = @sizeOf(TableV1),
        .version = version_1,
        .subscribe = struct {
            fn subscribe(_: ?*anyopaque, _: raw.PulseContextChangeFn, _: ?*anyopaque, id: [*c]SubscriptionId) callconv(.c) raw.PulseStatus {
                id.* = 0;
                return abi.ok;
            }
        }.subscribe,
    };
    const t = Table{ .raw = table };
    var id: SubscriptionId = 0;
    try testing.expectError(error.State, t.subscribe(null, null, &id));
}
