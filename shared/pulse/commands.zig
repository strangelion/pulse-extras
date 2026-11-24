//! `pulse.commands` V1 - registering plugin commands with the host.
//!
//! Only the V1 prefix is used. The host appends V2/V3 fields at the tail, so
//! descriptors are always built with `size = @sizeOf(Descriptor)` (the V1 size).

const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");

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

test "query returns unavailable without a host query function" {
    const host = abi.HostV1{ .size = @sizeOf(abi.HostV1), .version = 1, .context = null, .query_interface = null };
    var table: TableV1 = undefined;
    try std.testing.expectEqual(abi.error_unavailable, query(&host, &table));
}
