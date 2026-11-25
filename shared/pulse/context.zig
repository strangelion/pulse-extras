//! Safe view over the `pulse.context` host interface.
//!
//! Every string in a snapshot is borrowed from the host and only valid for the
//! duration of the callback. Callers must copy what they need before returning.

const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");
const text = @import("pulse_text");

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
    const query_interface = host.query_interface orelse return abi.error_unavailable;
    return query_interface(
        host.context,
        abi.view(interface_name),
        version_1,
        @ptrCast(out),
        @intCast(@sizeOf(TableV1)),
    );
}

/// A host snapshot is only safe to read when it advertises at least the V1 size.
pub fn validSnapshot(snapshot: *const Snapshot) bool {
    return snapshot.size >= @sizeOf(Snapshot);
}

/// A host selection snapshot is only safe to read when it advertises at least
/// the V1 size; entry strings are borrowed for the callback duration.
pub fn validSelection(snapshot: *const SelectionSnapshot) bool {
    return snapshot.size >= @sizeOf(SelectionSnapshot);
}

pub fn entryPath(entry: *const SelectionEntry) ?[]const u8 {
    return abi.slice(entry.path);
}

pub fn entryName(entry: *const SelectionEntry) ?[]const u8 {
    return abi.slice(entry.name);
}

/// Copies a borrowed host string, stopping on a UTF-8 codepoint boundary.
pub fn copyBorrowed(source: []const u8, buffer: []u8) []const u8 {
    return text.copyTruncated(buffer, source);
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

    /// `STATE` means the host already dropped the subscription (attachment
    /// gone); treat it as released, everything else as a real failure.
    pub fn unsubscribe(self: *const Table, id: SubscriptionId) Error!void {
        const unsubscribe_fn = self.raw.unsubscribe orelse return error.Unavailable;
        if (id == 0) return;
        host_mod.mapStatus(unsubscribe_fn(self.raw.context, id)) catch |err| switch (err) {
            error.State => return,
            else => return err,
        };
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

test "query without a host query function returns unavailable" {
    const host = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = 1, .context = null, .query_interface = null };
    var table: TableV1 = undefined;
    try testing.expectEqual(abi.error_unavailable, query(&host, &table));
}

test "table init rejects short or unsupported tables" {
    const host = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = 1, .context = null, .query_interface = &shortTable };
    try testing.expectError(error.Abi, Table.init(&host));
}

fn shortTable(_: ?*anyopaque, _: abi.StringView, _: u32, out_table: ?*anyopaque, _: u32) callconv(.c) abi.Status {
    const out: *TableV1 = @ptrCast(@alignCast(out_table orelse return abi.error_argument));
    out.* = std.mem.zeroes(TableV1);
    out.size = 8;
    out.version = version_1;
    out.get = &fakeContext;
    return abi.ok;
}

test "snapshot and selection size guards" {
    var snapshot = std.mem.zeroes(Snapshot);
    try testing.expect(!validSnapshot(&snapshot));
    snapshot.size = @sizeOf(Snapshot);
    try testing.expect(validSnapshot(&snapshot));

    var selection = std.mem.zeroes(SelectionSnapshot);
    try testing.expect(!validSelection(&selection));
    selection.size = @sizeOf(SelectionSnapshot);
    try testing.expect(validSelection(&selection));
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

/// One owner-thread navigation mailbox. The capacity is a hard byte limit:
/// malformed, loading or oversized directories invalidate the previous
/// selection instead of being truncated into an unrelated filesystem path.
/// This adapter never resolves repositories, checks trust or runs a command.
/// Keep its address stable from subscription until checkDrained succeeds.
pub fn Navigation(comptime capacity: usize) type {
    return struct {
        const Self = @This();

        pub const Ticket = struct {
            generation: u64,
            bytes: [capacity]u8 = undefined,
            len: usize = 0,

            pub fn directory(self: *const Ticket) ?[]const u8 {
                if (self.len == 0 or self.len > capacity) return null;
                return self.bytes[0..self.len];
            }
        };

        table: ?Table = null,
        id: SubscriptionId = 0,
        accepting: bool = false,
        poisoned: bool = false,
        latest: ?Ticket = null,
        pending: bool = false,
        generation: u64 = 0,

        pub fn open(self: *Self, table: Table) Error!void {
            if (self.table != null or self.poisoned) return error.State;
            if (table.raw.size < @sizeOf(TableV1) or table.raw.version < version_1) return error.Abi;
            const subscribe_fn = table.raw.subscribe orelse return error.Unavailable;
            if (table.raw.get == null or table.raw.unsubscribe == null) return error.Unavailable;
            self.table = table;
            self.latest = null;
            self.pending = false;
            self.accepting = true;
            var id: SubscriptionId = 0;
            host_mod.mapStatus(subscribe_fn(table.raw.context, &receive, self, &id)) catch |err| {
                self.accepting = false;
                self.table = null;
                self.latest = null;
                self.pending = false;
                return err;
            };
            if (id == 0) {
                // Host reported success without a usable unsubscribe handle.
                self.accepting = false;
                self.poisoned = true;
                return error.State;
            }
            self.id = id;
            table.get(&receive, self) catch |err| {
                self.close() catch |cleanup_err| return cleanup_err;
                return err;
            };
            if (self.latest == null) {
                try self.close();
                return error.Abi;
            }
        }

        fn receive(user: ?*anyopaque, snapshot: [*c]const Snapshot) callconv(.c) void {
            const self: *Self = @ptrCast(@alignCast(user orelse return));
            if (!self.accepting) return;
            var source: []const u8 = "";
            if (snapshot != null and validSnapshot(&snapshot.*) and snapshot.*.loading == 0) {
                const value = abi.slice(snapshot.*.directory) orelse "";
                if (value.len <= capacity and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null) source = value;
            }
            if (self.latest) |*previous| {
                if (std.mem.eql(u8, previous.bytes[0..previous.len], source)) return;
            }
            self.generation +%= 1;
            var ticket: Ticket = .{ .generation = self.generation };
            @memcpy(ticket.bytes[0..source.len], source);
            ticket.len = source.len;
            self.latest = ticket;
            self.pending = true;
        }

        /// Consume at most one latest directory; older events are replaced.
        /// A ticket with no directory explicitly instructs the owner to clear.
        pub fn take(self: *Self) ?Ticket {
            if (!self.accepting or !self.pending) return null;
            self.pending = false;
            return self.latest;
        }

        /// Recheck on the owner thread before applying a resolution result.
        /// A ticket is not an authorization or proof of repository identity.
        pub fn isCurrent(self: *const Self, ticket: *const Ticket) bool {
            if (!self.accepting or ticket.len > capacity) return false;
            const latest = if (self.latest) |*value| value else return false;
            return latest.generation == ticket.generation and std.mem.eql(u8, latest.bytes[0..latest.len], ticket.bytes[0..ticket.len]);
        }

        pub fn close(self: *Self) Error!void {
            self.accepting = false;
            self.pending = false;
            if (self.poisoned) return error.State;
            if (self.table) |table| {
                try table.unsubscribe(self.id);
                self.id = 0;
                self.table = null;
            }
        }

        pub fn checkDrained(self: *const Self) error{Busy}!void {
            if (self.table != null or self.poisoned) return error.Busy;
        }
    };
}

const NavigationMock = struct {
    callback: ChangeFn = null,
    user: ?*anyopaque = null,
    fail_close: bool = false,
    zero_id: bool = false,

    fn get(_: ?*anyopaque, callback: ChangeFn, user: ?*anyopaque) callconv(.c) abi.Status {
        var initial: Snapshot = .{ .size = @sizeOf(Snapshot), .directory = abi.view("initial") };
        (callback orelse return abi.error_argument)(user, &initial);
        return abi.ok;
    }

    fn subscribe(user: ?*anyopaque, callback: ChangeFn, data: ?*anyopaque, out: [*c]SubscriptionId) callconv(.c) abi.Status {
        const self: *NavigationMock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.callback = callback;
        self.user = data;
        out.* = if (self.zero_id) 0 else 1;
        return abi.ok;
    }

    fn unsubscribe(user: ?*anyopaque, id: SubscriptionId) callconv(.c) abi.Status {
        const self: *NavigationMock = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (id != 1) return abi.error_argument;
        if (self.fail_close) return abi.error_permission;
        self.callback = null;
        self.user = null;
        return abi.ok;
    }

    fn table(self: *NavigationMock) Table {
        return .{ .raw = .{
            .size = @sizeOf(TableV1),
            .version = version_1,
            .context = self,
            .get = &get,
            .subscribe = &subscribe,
            .unsubscribe = &unsubscribe,
        } };
    }

    fn emit(self: *NavigationMock, path: []const u8, loading: u32) void {
        var snapshot: Snapshot = .{ .size = @sizeOf(Snapshot), .directory = abi.view(path), .loading = loading };
        if (self.callback) |callback| callback(self.user, &snapshot);
    }
};

test "navigation owns latest borrowed path and rejects stale resolution" {
    var mock: NavigationMock = .{};
    var nav: Navigation(16) = .{};
    try nav.open(mock.table());
    const initial = nav.take().?;
    try testing.expectEqualStrings("initial", initial.directory().?);
    var borrowed = [_]u8{ 'n', 'e', 'w' };
    mock.emit(&borrowed, 0);
    borrowed[0] = 'x';
    const copied = nav.take().?;
    try testing.expectEqualStrings("new", copied.directory().?);
    try testing.expect(!nav.isCurrent(&initial));
    try testing.expect(nav.isCurrent(&copied));
    mock.emit("new", 0);
    try testing.expect(nav.take() == null);
    mock.emit("another", 0);
    mock.emit("latest", 0);
    const latest = nav.take().?;
    try testing.expectEqualStrings("latest", latest.directory().?);
    mock.emit("latest", 1);
    const clear = nav.take().?;
    try testing.expect(clear.directory() == null);
    try testing.expect(!nav.isCurrent(&latest));
    mock.emit("01234567890123456", 0);
    try testing.expect(nav.take() == null);
    mock.emit("latest", 0);
    _ = nav.take().?;
    mock.emit("bad\x00path", 0);
    const invalid = nav.take().?;
    try testing.expect(invalid.directory() == null);
    try nav.close();
    try nav.checkDrained();
}

test "navigation failed unsubscribe keeps userdata alive and disables admission" {
    var mock: NavigationMock = .{};
    var nav: Navigation(16) = .{};
    try nav.open(mock.table());
    const initial = nav.take().?;
    mock.fail_close = true;
    try testing.expectError(error.Permission, nav.close());
    try testing.expectError(error.Busy, nav.checkDrained());
    mock.emit("late", 0);
    try testing.expect(nav.take() == null);
    try testing.expect(!nav.isCurrent(&initial));
    mock.fail_close = false;
    try nav.close();
    try nav.checkDrained();
    try testing.expect(mock.callback == null);
    try nav.open(mock.table());
    const reopened = nav.take().?;
    try testing.expect(!nav.isCurrent(&initial));
    try testing.expect(nav.isCurrent(&reopened));
    try nav.close();
    try nav.checkDrained();
}

test "navigation successful zero subscription id never certifies drain" {
    var mock: NavigationMock = .{ .zero_id = true };
    var nav: Navigation(16) = .{};
    try testing.expectError(error.State, nav.open(mock.table()));
    try testing.expectError(error.Busy, nav.checkDrained());
    try testing.expectError(error.State, nav.close());
}
