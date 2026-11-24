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

/// A validated host table. Copyable, cheap, and safe to keep for the plugin lifetime.
pub const Host = struct {
    table: *const abi.HostV1,

    pub fn init(table: *const abi.HostV1) Error!Host {
        if (table.size < @sizeOf(abi.HostV1)) return error.Abi;
        if (table.version != abi.abi_version) return error.Abi;
        _ = table.query_interface orelse return error.Unavailable;
        return .{ .table = table };
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
