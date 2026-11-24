//! Validated access to the host function table and its queryable interfaces.
//!
//! Rules encoded here (from `pulse/abi.h`):
//! * the plugin never stores pointers handed out by host callbacks;
//! * every interface table is copied by value and must satisfy `size`/`version`;
//! * an unknown or too-small table is a hard failure, never a silent fallback.

const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");

pub const Error = error{
    Argument,
    Abi,
    Unavailable,
    Initialization,
    State,
    Load,
    Entry,
    Permission,
    SdkPreview,
    Unknown,
};

pub fn mapStatus(status: abi.Status) Error!void {
    return switch (status) {
        abi.ok => {},
        abi.error_argument => error.Argument,
        abi.error_abi => error.Abi,
        abi.error_unavailable => error.Unavailable,
        abi.error_initialization => error.Initialization,
        abi.error_state => error.State,
        abi.error_load => error.Load,
        abi.error_entry => error.Entry,
        abi.error_permission => error.Permission,
        abi.error_sdk_preview => error.SdkPreview,
        else => error.Unknown,
    };
}

fn validateTable(comptime T: type) void {
    comptime {
        if (!@hasField(T, "size")) @compileError("interface table needs a `size` field");
        if (!@hasField(T, "version")) @compileError("interface table needs a `version` field");
        if (!@hasField(T, "context")) @compileError("interface table needs a `context` field");
        if (@FieldType(T, "size") != u32) @compileError("interface table `size` must be u32");
        if (@FieldType(T, "version") != u32) @compileError("interface table `version` must be u32");
    }
}

/// A validated host table, held **by value**.
///
/// The ABI only promises that the pointer passed to `PulsePluginEntryV1` stays
/// valid until `destroy`; keeping a copy means a host that reuses or mutates
/// that memory cannot change the function pointers we call. Only the opaque
/// `context` value is shared, and the host owns it for the plugin lifetime.
pub const Host = struct {
    table: abi.HostV1,

    pub fn init(source: *const abi.HostV1) Error!Host {
        if (source.size < @sizeOf(abi.HostV1)) return error.Abi;
        if (source.version != abi.abi_version) return error.Abi;
        if (source.query_interface == null) return error.Unavailable;
        return .{ .table = source.* };
    }

    /// Raw pointer to the copied table, for wrappers that take `*const HostV1`.
    pub fn raw(self: *const Host) *const abi.HostV1 {
        return &self.table;
    }

    /// Requests an interface table by name and version. The returned table is a
    /// by-value copy; the host validates and fills it synchronously.
    pub fn query(self: Host, comptime T: type, name: []const u8, version: u32) Error!T {
        comptime validateTable(T);
        const query_interface = self.table.query_interface orelse return error.Unavailable;
        var out: T = std.mem.zeroes(T);
        try mapStatus(query_interface(
            self.table.context,
            abi.view(name),
            version,
            @ptrCast(&out),
            @intCast(@sizeOf(T)),
        ));
        if (out.size < @sizeOf(T)) return error.Abi;
        if (out.version < version) return error.Abi;
        return out;
    }

    pub fn queryOptional(self: Host, comptime T: type, name: []const u8, version: u32) Error!?T {
        return self.query(T, name, version) catch |err| switch (err) {
            error.Unavailable => null,
            error.Abi => null,
            else => err,
        };
    }
};

test "host keeps a by-value copy of the table" {
    const testing = std.testing;
    var table = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = 1, .context = null, .query_interface = &fakeQuery };
    const host = try Host.init(&table);
    // Mutating the caller's copy must not change what the wrapper calls.
    table.query_interface = null;
    table.version = 99;
    try testing.expect(host.raw().query_interface != null);
    try testing.expectEqual(@as(u32, 1), host.raw().version);
    const fake = try host.query(FakeTable, "pulse.fake", 1);
    try testing.expectEqual(@as(u32, 7), fake.marker);
}

test "query rejects short tables and lower versions" {
    const testing = std.testing;
    var table = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = 1, .context = null, .query_interface = &shortQuery };
    const host = try Host.init(&table);
    try testing.expectError(error.Abi, host.query(FakeTable, "pulse.fake", 1));

    table.query_interface = &oldVersionQuery;
    const host2 = try Host.init(&table);
    try testing.expectError(error.Abi, host2.query(FakeTable, "pulse.fake", 2));
    try testing.expectEqual(@as(?FakeTable, null), try host2.queryOptional(FakeTable, "pulse.fake", 2));
}

test "queryOptional maps an unavailable interface to null" {
    const testing = std.testing;
    var table = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = 1, .context = null, .query_interface = &fakeQuery };
    const host = try Host.init(&table);
    try testing.expectEqual(@as(?FakeTable, null), try host.queryOptional(FakeTable, "pulse.missing", 1));
}

fn shortQuery(_: ?*anyopaque, _: abi.StringView, _: u32, out_table: ?*anyopaque, _: u32) callconv(.c) abi.Status {
    const out: *FakeTable = @ptrCast(@alignCast(out_table orelse return abi.error_argument));
    out.* = .{ .size = 8, .version = 1, .context = null, .marker = 0 };
    return abi.ok;
}

fn oldVersionQuery(_: ?*anyopaque, _: abi.StringView, _: u32, out_table: ?*anyopaque, out_size: u32) callconv(.c) abi.Status {
    if (out_size < @sizeOf(FakeTable)) return abi.error_argument;
    const out: *FakeTable = @ptrCast(@alignCast(out_table orelse return abi.error_argument));
    out.* = .{ .size = @sizeOf(FakeTable), .version = 1, .context = null, .marker = 0 };
    return abi.ok;
}

test "host validation rejects short and mismatched tables" {
    const testing = std.testing;
    var table = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = 1, .context = null, .query_interface = null };
    try testing.expectError(error.Unavailable, Host.init(&table));

    table.query_interface = &fakeQuery;
    try testing.expectError(error.Abi, Host.init(&abi.HostV1{ .size = 4, .version = 1, .context = null, .query_interface = &fakeQuery }));
    try testing.expectError(error.Abi, Host.init(&abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = 2, .context = null, .query_interface = &fakeQuery }));

    const host = try Host.init(&table);
    const fake = try host.query(FakeTable, "pulse.fake", 1);
    try testing.expectEqual(@as(u32, 7), fake.marker);
}

const FakeTable = extern struct {
    size: u32,
    version: u32,
    context: ?*anyopaque,
    marker: u32,
};

fn fakeQuery(_: ?*anyopaque, name: abi.StringView, version: u32, out_table: ?*anyopaque, out_size: u32) callconv(.c) abi.Status {
    const text = abi.slice(name) orelse return abi.error_argument;
    if (!std.mem.eql(u8, text, "pulse.fake") or version != 1) return abi.error_unavailable;
    if (out_size < @sizeOf(FakeTable)) return abi.error_argument;
    const out: *FakeTable = @ptrCast(@alignCast(out_table orelse return abi.error_argument));
    out.* = .{ .size = @sizeOf(FakeTable), .version = 1, .context = null, .marker = 7 };
    return abi.ok;
}
