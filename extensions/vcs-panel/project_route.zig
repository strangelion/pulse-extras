//! Explicit project navigation via the public pulse.directories snapshot API.
//! No filesystem operations or CLI execution on the owner thread. The host
//! owns enumeration and normal navigation. Never open a reparse/file entry.
const std = @import("std");
const abi = @import("pulse_abi");
const raw = @import("pulse_raw");
const host_mod = @import("pulse_host");
const identity = @import("vcs_identity");
const approval = @import("vcs_approval");

pub const Route = struct {
    table: ?raw.PulseDirectoriesV1 = null,
    pending: u64 = 0,
    operation: u32 = 0,
    directory: u64 = 0,
    snapshot: u64 = 0,
    offset: u32 = 0,
    total: u64 = 0,
    poisoned: bool = false,
    parent: identity.Path = .{},
    leaf: identity.Path = .{},
    user: ?*anyopaque = null,
    callback: ?*const fn (*anyopaque, bool) void = null,

    pub fn configure(self: *Route, host: host_mod.Host) void {
        if (self.busy()) return;
        self.table = null;
        const table = (host.queryOptional(raw.PulseDirectoriesV1, raw.PULSE_DIRECTORIES_INTERFACE_NAME, raw.PULSE_DIRECTORIES_VERSION_1) catch return) orelse return;
        if (table.open == null or table.list == null or table.open_entry == null or table.cancel == null or table.close == null) return;
        self.table = table;
    }

    pub fn busy(self: *const Route) bool {
        return self.pending != 0 or self.directory != 0 or self.poisoned;
    }

    pub fn begin(self: *Route, path: []const u8, user: *anyopaque, callback: *const fn (*anyopaque, bool) void) host_mod.Error!void {
        if (self.busy()) return error.State;
        const table = self.table orelse return error.Unavailable;
        if (!approval.strictPath(path)) return error.Argument;
        const parent = std.fs.path.dirname(path) orelse return error.Argument;
        const leaf = std.fs.path.basename(path);
        if (leaf.len == 0 or leaf.len > 255) return error.Argument;
        self.parent = identity.Path.init(parent) catch return error.Argument;
        self.leaf = identity.Path.init(leaf) catch return error.Argument;
        self.user = user;
        self.callback = callback;
        self.offset = 0;
        self.snapshot = 0;
        self.total = 0;
        var request: u64 = 0;
        try host_mod.mapStatus(table.open.?(table.context, abi.view(self.parent.slice()), completed, self, &request));
        try self.admit(request, raw.PULSE_DIRECTORY_OPEN);
    }

    fn admit(self: *Route, request: u64, operation: u32) host_mod.Error!void {
        if (request == 0) {
            self.poisoned = true;
            return error.State;
        }
        self.pending = request;
        self.operation = operation;
    }

    fn list(self: *Route) host_mod.Error!void {
        const table = self.table orelse return error.State;
        var request: u64 = 0;
        try host_mod.mapStatus(table.list.?(table.context, self.directory, self.snapshot, self.offset, 256, completed, self, &request));
        try self.admit(request, raw.PULSE_DIRECTORY_LIST);
    }

    fn openEntry(self: *Route, entry: u64) host_mod.Error!void {
        const table = self.table orelse return error.State;
        if (entry == 0) return error.State;
        var request: u64 = 0;
        try host_mod.mapStatus(table.open_entry.?(table.context, self.directory, self.snapshot, entry, completed, self, &request));
        try self.admit(request, raw.PULSE_DIRECTORY_OPEN_ENTRY);
    }

    fn finished(self: *Route, accepted: bool) void {
        const callback = self.callback;
        const user = self.user;
        self.callback = null;
        self.user = null;
        // A failed close retains the directory for retry/teardown. Do not
        // certify the navigation as clean in that case.
        self.stop() catch {
            if (callback) |cb| cb(user orelse return, false);
            return;
        };
        if (callback) |cb| cb(user orelse return, accepted);
    }

    fn matchingEntry(self: *const Route, row: raw.PulseDirectoryRow) bool {
        if (row.entry_id == 0 or row.flags & raw.PULSE_DIRECTORY_ENTRY_FOLDER == 0 or row.flags & raw.PULSE_DIRECTORY_ENTRY_REPARSE != 0) return false;
        const name = abi.slice(row.name) orelse return false;
        return self.leaf.eql(name);
    }

    fn completed(user: ?*anyopaque, reply: [*c]const raw.PulseDirectoryReply) callconv(.c) void {
        const self: *Route = @ptrCast(@alignCast(user orelse return));
        if (reply == null or reply.*.size < @sizeOf(raw.PulseDirectoryReply) or self.pending == 0 or reply.*.request_id != self.pending) return;
        const operation = self.operation;
        self.pending = 0;
        self.operation = 0;
        if (operation == raw.PULSE_DIRECTORY_OPEN and reply.*.status == abi.ok) self.directory = reply.*.directory_id;
        if (reply.*.operation != operation or reply.*.status != abi.ok) {
            self.finished(false);
            return;
        }
        if (self.directory == 0 or reply.*.directory_id != self.directory or reply.*.snapshot_id == 0 or reply.*.total > 65536) {
            self.finished(false);
            return;
        }
        if (operation == raw.PULSE_DIRECTORY_OPEN) {
            const path = abi.slice(reply.*.path) orelse {
                self.finished(false);
                return;
            };
            // The public adapter may normalize case/separators. Refuse an
            // ambiguous spelling rather than navigate a different root.
            if (!self.parent.eql(path) or reply.*.total == 0) {
                self.finished(false);
                return;
            }
            self.snapshot = reply.*.snapshot_id;
            self.total = reply.*.total;
            self.list() catch self.finished(false);
            return;
        }
        if (reply.*.snapshot_id != self.snapshot or reply.*.total != self.total) {
            self.finished(false);
            return;
        }
        if (operation == raw.PULSE_DIRECTORY_OPEN_ENTRY) {
            self.finished(true);
            return;
        }
        if (operation != raw.PULSE_DIRECTORY_LIST or reply.*.count > 256 or (reply.*.count != 0 and reply.*.rows == null) or @as(u64, self.offset) + reply.*.count > self.total) {
            self.finished(false);
            return;
        }
        var entry: u64 = 0;
        for (0..reply.*.count) |i| {
            const row = reply.*.rows[i];
            if (!self.matchingEntry(row)) continue;
            if (entry != 0) {
                self.finished(false);
                return;
            }
            entry = row.entry_id;
        }
        if (entry != 0) {
            self.openEntry(entry) catch self.finished(false);
            return;
        }
        if (reply.*.next_offset == std.math.maxInt(u32) or reply.*.count == 0 or reply.*.next_offset != self.offset + reply.*.count or reply.*.next_offset >= self.total) {
            self.finished(false);
            return;
        }
        self.offset = reply.*.next_offset;
        self.list() catch self.finished(false);
    }

    pub fn stop(self: *Route) host_mod.Error!void {
        self.callback = null;
        self.user = null;
        if (self.poisoned) return error.State;
        if (!self.busy()) return;
        const table = self.table orelse return error.State;
        if (self.pending != 0) {
            host_mod.mapStatus(table.cancel.?(table.context, self.pending)) catch |err| if (err != error.State) return err;
            self.pending = 0;
            self.operation = 0;
        }
        if (self.directory != 0) {
            host_mod.mapStatus(table.close.?(table.context, self.directory)) catch |err| if (err != error.State) return err;
            self.directory = 0;
        }
        self.snapshot = 0;
    }

    pub fn retire(self: *Route) void {
        // Final host destroy boundary suppresses all outstanding callbacks.
        self.* = .{};
    }
};

const Fixture = struct {
    open_calls: usize = 0,
    list_calls: usize = 0,
    entry_calls: usize = 0,
    closed: usize = 0,
    cancelled: usize = 0,
    completed_calls: usize = 0,
    success: bool = false,

    fn open(user: ?*anyopaque, _: abi.StringView, _: raw.PulseDirectoryCompletionFn, _: ?*anyopaque, request: [*c]u64) callconv(.c) abi.Status {
        const self: *Fixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.open_calls += 1;
        request.* = 11;
        return abi.ok;
    }

    fn list(user: ?*anyopaque, directory: u64, snapshot: u64, offset: u32, limit: u32, _: raw.PulseDirectoryCompletionFn, _: ?*anyopaque, request: [*c]u64) callconv(.c) abi.Status {
        const self: *Fixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (directory != 21 or snapshot != 31 or offset != 0 or limit != 256) return abi.error_argument;
        self.list_calls += 1;
        request.* = 12;
        return abi.ok;
    }

    fn openEntry(user: ?*anyopaque, directory: u64, snapshot: u64, entry: u64, _: raw.PulseDirectoryCompletionFn, _: ?*anyopaque, request: [*c]u64) callconv(.c) abi.Status {
        const self: *Fixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (directory != 21 or snapshot != 31 or entry != 41) return abi.error_argument;
        self.entry_calls += 1;
        request.* = 13;
        return abi.ok;
    }

    fn close(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *Fixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.closed += 1;
        return abi.ok;
    }

    fn cancel(user: ?*anyopaque, _: u64) callconv(.c) abi.Status {
        const self: *Fixture = @ptrCast(@alignCast(user orelse return abi.error_argument));
        self.cancelled += 1;
        return abi.ok;
    }

    fn done(user: *anyopaque, accepted: bool) void {
        const self: *Fixture = @ptrCast(@alignCast(user));
        self.completed_calls += 1;
        self.success = accepted;
    }

    fn table(self: *Fixture) raw.PulseDirectoriesV1 {
        return .{ .context = self, .open = &open, .list = &list, .open_entry = &openEntry, .close = &close, .cancel = &cancel };
    }
};

test "project navigation only opens an exact folder snapshot entry and drains" {
    var mock: Fixture = .{};
    var route: Route = .{ .table = mock.table() };
    const root = if (@import("builtin").os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    const parent = std.fs.path.dirname(root).?;
    try route.begin(root, &mock, &Fixture.done);
    var reply: raw.PulseDirectoryReply = .{ .size = @sizeOf(raw.PulseDirectoryReply), .status = abi.ok, .operation = raw.PULSE_DIRECTORY_OPEN, .request_id = 11, .directory_id = 21, .snapshot_id = 31, .total = 1, .path = abi.view(parent) };
    Route.completed(&route, &reply);
    try std.testing.expectEqual(@as(usize, 1), mock.list_calls);
    const rows = [_]raw.PulseDirectoryRow{.{ .entry_id = 41, .name = abi.view("repo"), .flags = raw.PULSE_DIRECTORY_ENTRY_FOLDER }};
    reply.operation = raw.PULSE_DIRECTORY_LIST;
    reply.request_id = 12;
    reply.rows = &rows;
    reply.count = 1;
    reply.next_offset = std.math.maxInt(u32);
    Route.completed(&route, &reply);
    try std.testing.expectEqual(@as(usize, 1), mock.entry_calls);
    reply.operation = raw.PULSE_DIRECTORY_OPEN_ENTRY;
    reply.request_id = 13;
    Route.completed(&route, &reply);
    try std.testing.expect(mock.success and !route.busy());
    try std.testing.expectEqual(@as(usize, 1), mock.closed);
    try route.begin(root, &mock, &Fixture.done);
    try route.stop();
    try std.testing.expectEqual(@as(usize, 1), mock.cancelled);
    Route.completed(&route, &reply);
    try std.testing.expectEqual(@as(usize, 1), mock.completed_calls);
}

test "project navigation refuses a reparse entry and a stale snapshot" {
    var mock: Fixture = .{};
    var route: Route = .{ .table = mock.table() };
    const root = if (@import("builtin").os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    const parent = std.fs.path.dirname(root).?;
    try route.begin(root, &mock, &Fixture.done);
    var reply: raw.PulseDirectoryReply = .{ .size = @sizeOf(raw.PulseDirectoryReply), .status = abi.ok, .operation = raw.PULSE_DIRECTORY_OPEN, .request_id = 11, .directory_id = 21, .snapshot_id = 31, .total = 1, .path = abi.view(parent) };
    Route.completed(&route, &reply);
    const rows = [_]raw.PulseDirectoryRow{.{ .entry_id = 41, .name = abi.view("repo"), .flags = raw.PULSE_DIRECTORY_ENTRY_FOLDER | raw.PULSE_DIRECTORY_ENTRY_REPARSE }};
    reply.operation = raw.PULSE_DIRECTORY_LIST;
    reply.request_id = 12;
    reply.rows = &rows;
    reply.count = 1;
    reply.next_offset = std.math.maxInt(u32);
    Route.completed(&route, &reply);
    try std.testing.expectEqual(@as(usize, 0), mock.entry_calls);
    try std.testing.expect(!mock.success and !route.busy());
    try route.begin(root, &mock, &Fixture.done);
    reply.operation = raw.PULSE_DIRECTORY_OPEN;
    reply.request_id = 11;
    reply.snapshot_id = 31;
    Route.completed(&route, &reply);
    reply.operation = raw.PULSE_DIRECTORY_LIST;
    reply.request_id = 12;
    reply.snapshot_id = 32;
    Route.completed(&route, &reply);
    try std.testing.expectEqual(@as(usize, 0), mock.entry_calls);
    try std.testing.expectEqual(@as(usize, 2), mock.closed);
}
