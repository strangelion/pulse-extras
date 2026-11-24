//! ABI surface used by the hand-written wrappers.
//!
//! The only source of truth is `raw/pulse_all.zig`, generated from the pinned
//! SDK headers by `scripts/generate_bindings.py`. This module keeps the short
//! names the wrappers and tests use and pins the numeric guarantees we rely on.

const raw = @import("pulse_raw");

pub const Status = raw.PulseStatus;
pub const ok: Status = raw.PULSE_OK;
pub const error_argument: Status = raw.PULSE_ERROR_ARGUMENT;
pub const error_abi: Status = raw.PULSE_ERROR_ABI;
pub const error_unavailable: Status = raw.PULSE_ERROR_UNAVAILABLE;
pub const error_initialization: Status = raw.PULSE_ERROR_INITIALIZATION;
pub const error_state: Status = raw.PULSE_ERROR_STATE;
pub const error_load: Status = raw.PULSE_ERROR_LOAD;
pub const error_entry: Status = raw.PULSE_ERROR_ENTRY;
pub const error_permission: Status = raw.PULSE_ERROR_PERMISSION;
pub const error_sdk_preview: Status = raw.PULSE_ERROR_SDK_PREVIEW;

pub const abi_version: u32 = raw.PULSE_ABI_VERSION_1;
pub const sdk_preview: u32 = raw.PULSE_SDK_PREVIEW;

pub const StringView = raw.PulseStringView;
pub const HostV1 = raw.PulseHostV1;
pub const PluginV1 = raw.PulsePluginV1;
pub const EntryFn = raw.PulsePluginEntryV1Fn;
pub const SdkPreviewFn = raw.PulsePluginSdkPreviewFn;

/// Borrowed UTF-8 view. The caller keeps the bytes alive for the duration of the call.
pub inline fn view(bytes: []const u8) StringView {
    if (bytes.len == 0) return .{ .data = null, .length = 0 };
    return .{ .data = bytes.ptr, .length = @intCast(bytes.len) };
}

/// Returns the borrowed bytes, or `null` for an empty view.
pub inline fn slice(value: StringView) ?[]const u8 {
    const data = value.data orelse return null;
    return data[0..value.length];
}

comptime {
    if (@sizeOf(StringView) != 16) @compileError("PulseStringView must be 16 bytes on x86_64");
    if (@sizeOf(HostV1) != 24) @compileError("PulseHostV1 must be 24 bytes on x86_64");
    if (@sizeOf(PluginV1) != 40) @compileError("PulsePluginV1 must be 40 bytes on x86_64");
    if (@offsetOf(HostV1, "query_interface") != 16) @compileError("host query_interface offset");
    if (@offsetOf(PluginV1, "destroy") != 32) @compileError("plugin destroy offset");
    if (abi_version != 1) @compileError("unexpected ABI version");
    if (sdk_preview != 3) @compileError("unexpected SDK preview");
}

test "string views round-trip and reject overflow" {
    const text = "pulse";
    const value = view(text);
    try @import("std").testing.expectEqual(@as(u32, 5), value.length);
    try @import("std").testing.expectEqualStrings(text, slice(value).?);
    try @import("std").testing.expectEqual(@as(?[]const u8, null), slice(.{ .data = null, .length = 0 }));
}
