//! Minimal hand-reviewed mirror of the pinned public C header.
//! Do not extend this without verifying the actual upstream ABI.
pub const abi_version: u32 = 1;
pub const sdk_preview: u32 = 3;
pub const Status = i32;
pub const ok: Status = 0;
pub const error_argument: Status = 1;
pub const error_abi: Status = 2;
pub const error_initialization: Status = 4;

pub const StringView = extern struct {
    data: ?[*]const u8,
    length: u32,
};

pub const QueryInterface = *const fn (?*anyopaque, StringView, u32, ?*anyopaque, u32) callconv(.c) Status;

pub const HostV1 = extern struct {
    size: u32,
    version: u32,
    context: ?*anyopaque,
    query_interface: ?QueryInterface,
};

pub const PluginV1 = extern struct {
    size: u32,
    version: u32,
    instance: ?*anyopaque,
    activate: ?*const fn (?*anyopaque) callconv(.c) Status,
    deactivate: ?*const fn (?*anyopaque) callconv(.c) void,
    destroy: ?*const fn (?*anyopaque) callconv(.c) void,
};

comptime {
    if (@sizeOf(usize) != 8) @compileError("Pulse ABI probe requires a 64-bit target");
    if (@sizeOf(StringView) != 16 or @alignOf(StringView) != 8 or
        @offsetOf(StringView, "length") != 8 or
        @sizeOf(HostV1) != 24 or @alignOf(HostV1) != 8 or
        @offsetOf(HostV1, "context") != 8 or @offsetOf(HostV1, "query_interface") != 16 or
        @sizeOf(PluginV1) != 40 or @alignOf(PluginV1) != 8 or
        @offsetOf(PluginV1, "instance") != 8 or @offsetOf(PluginV1, "activate") != 16 or
        @offsetOf(PluginV1, "deactivate") != 24 or @offsetOf(PluginV1, "destroy") != 32)
        @compileError("Pulse ABI layout mismatch");
}
