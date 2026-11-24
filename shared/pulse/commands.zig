//! `pulse.commands` V1 - registering plugin commands with the host.
//!
//! Only the V1 prefix is used. The host appends V2/V3 fields at the tail, so
//! descriptors are always built with `size = @sizeOf(Descriptor)` (the V1 size).

const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");
const host_mod = @import("pulse_host");

pub const interface_name: []const u8 = raw.PULSE_COMMANDS_INTERFACE_NAME;
pub const version_1: u32 = raw.PULSE_COMMANDS_VERSION_1;

pub const Kind = struct {
    pub const files: u32 = 1;
    pub const directories: u32 = 2;
    pub const background: u32 = 4;
};

pub const Modifier = struct {
    pub const ctrl: u32 = 1;
    pub const shift: u32 = 2;
    pub const alt: u32 = 4;
};

pub const Icon = struct {
    pub const default: u32 = 0;
    pub const archive: u32 = 1;
    pub const extract: u32 = 2;
};

pub const CommandId = raw.PulseCommandId;
pub const SelectionSnapshot = raw.PulseContextSelectionSnapshot;
pub const Descriptor = raw.PulseCommandDescriptor;
pub const TableV1 = raw.PulseCommandsV1;
pub const InvokeFn = raw.PulseCommandFn;

/// Queries the `pulse.commands` V1 table. Returns the raw status so callers can
/// log or degrade exactly as the host reported it.
pub fn query(host: *const abi.HostV1, out: *TableV1) abi.Status {
    const query_interface = host.query_interface orelse return abi.error_unavailable;
    out.* = std.mem.zeroes(TableV1);
    return query_interface(host.context, abi.view(interface_name), version_1, @ptrCast(out), @intCast(@sizeOf(TableV1)));
}

/// Builds a V1 descriptor with every optional list empty.
pub fn descriptor(id: []const u8, title: []const u8, invoke: InvokeFn) Descriptor {
    return .{
        .size = @sizeOf(Descriptor),
        .id = abi.view(id),
        .title = abi.view(title),
        .icon = Icon.default,
        .kinds = Kind.files | Kind.directories,
        .min_selection = 0,
        .max_selection = 4096,
        .extensions = null,
        .extension_count = 0,
        .exclude_extensions = 0,
        .virtual_key = 0,
        .modifiers = 0,
        .invoke = invoke,
        .user = null,
    };
}

fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |byte| {
        const ok = (byte >= 'A' and byte <= 'Z') or (byte >= 'a' and byte <= 'z') or
            (byte >= '0' and byte <= '9') or byte == '.' or byte == '_' or byte == '-';
        if (!ok) return false;
    }
    return true;
}

fn validTitle(title: []const u8) bool {
    if (title.len == 0 or title.len > 128) return false;
    for (title) |byte| {
        if (byte < 0x20 or byte == 0x7F) return false;
    }
    return true;
}

/// Checks everything the host would otherwise reject at registration time.
/// Doing it here keeps a bad descriptor from failing silently inside the host.
pub fn validateDescriptor(item: *const Descriptor) host_mod.Error!void {
    if (item.size != @sizeOf(Descriptor)) return error.Argument;
    const id = abi.slice(item.id) orelse return error.Argument;
    const title = abi.slice(item.title) orelse return error.Argument;
    if (!validId(id) or !validTitle(title)) return error.Argument;
    if (item.kinds == 0 or (item.kinds & ~@as(u32, 7)) != 0) return error.Argument;
    if (item.min_selection > item.max_selection or item.max_selection > 4096) return error.Argument;
    if (item.extension_count > 32) return error.Argument;
    if (item.invoke == null) return error.Argument;
}

/// Owned copy of the `pulse.commands` V1 table with the required function
/// pointers validated up front.
pub const Table = struct {
    raw: TableV1,

    pub fn init(host: host_mod.Host) host_mod.Error!Table {
        const table = try host.query(TableV1, interface_name, version_1);
        if (table.context == null) return error.Abi;
        if (table.register_command == null) return error.Unavailable;
        return .{ .raw = table };
    }

    pub fn register(self: *const Table, item: *const Descriptor) host_mod.Error!CommandId {
        try validateDescriptor(item);
        const register_fn = self.raw.register_command orelse return error.Unavailable;
        var assigned: CommandId = 0;
        try host_mod.mapStatus(register_fn(self.raw.context, item, &assigned));
        return assigned;
    }

    pub fn unregister(self: *const Table, id: CommandId) host_mod.Error!void {
        const unregister_fn = self.raw.unregister_command orelse return error.Unavailable;
        try host_mod.mapStatus(unregister_fn(self.raw.context, id));
    }
};

comptime {
    // `PULSE_COMMAND_DESCRIPTOR_SIZE_V1` ends at `detail`; the V1 prefix is 96 bytes.
    if (@sizeOf(Descriptor) != 96) @compileError("PulseCommandDescriptor V1 size must be 96 on x86_64");
    if (@sizeOf(TableV1) != 32) @compileError("PulseCommandsV1 must be 32 bytes on x86_64");
    if (@offsetOf(Descriptor, "invoke") != 80) @compileError("descriptor invoke offset");
}

test "descriptor keeps the V1 prefix" {
    const testing = std.testing;
    const item = descriptor("strangelion.test.ping", "Ping", null);
    try testing.expectEqual(@as(u32, 96), item.size);
    try testing.expectEqualStrings("strangelion.test.ping", abi.slice(item.id).?);
}

test "descriptor validation rejects host-invalid values" {
    const testing = std.testing;
    const good = descriptor("strangelion.test.ping", "Ping", struct {
        fn invoke(_: ?*anyopaque, _: CommandId, _: [*c]const SelectionSnapshot) callconv(.c) void {}
    }.invoke);
    try validateDescriptor(&good);

    var long: [65]u8 = undefined;
    @memset(&long, 'x');
    var long_id = good;
    long_id.id = abi.view(&long);
    try testing.expectError(error.Argument, validateDescriptor(&long_id));

    var bad_chars = good;
    bad_chars.id = abi.view("bad id");
    try testing.expectError(error.Argument, validateDescriptor(&bad_chars));

    var empty_title = good;
    empty_title.title = abi.view("");
    try testing.expectError(error.Argument, validateDescriptor(&empty_title));

    var control: [5]u8 = [_]u8{ 'P', 'i', 'n', 'g', 0x0A };
    var control_title = good;
    control_title.title = abi.view(&control);
    try testing.expectError(error.Argument, validateDescriptor(&control_title));

    var no_kinds = good;
    no_kinds.kinds = 0;
    try testing.expectError(error.Argument, validateDescriptor(&no_kinds));

    var inverted = good;
    inverted.min_selection = 5;
    inverted.max_selection = 1;
    try testing.expectError(error.Argument, validateDescriptor(&inverted));

    var no_invoke = good;
    no_invoke.invoke = null;
    try testing.expectError(error.Argument, validateDescriptor(&no_invoke));
}

test "query returns unavailable without a host query function" {
    const host = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = 1, .context = null, .query_interface = null };
    var table: TableV1 = undefined;
    try std.testing.expectEqual(abi.error_unavailable, query(&host, &table));
}
