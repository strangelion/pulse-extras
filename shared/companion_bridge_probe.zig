//! Isolated CI fixture, never used as a production DLL approval authority.
const std = @import("std");
const runtime = @import("companion_group.zig");

extern "kernel32" fn GetFullPathNameW([*:0]const u16, u32, [*]u16, ?*anyopaque) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?*anyopaque, u32) callconv(.winapi) usize;
extern "kernel32" fn GetProcAddress(usize, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(usize) callconv(.winapi) c_int;

const Query = *const fn (u32, u32, *runtime.NativeApi) callconv(.c) c_int;

pub fn main() !void {
    var path: [1024]u16 = undefined;
    const len = GetFullPathNameW(std.unicode.wtf8ToWtf16LeStringLiteral("zig-out\\bin\\pulse_companion_runtime.dll"), path.len, &path, null);
    if (len == 0 or len >= path.len) return error.BadFixturePath;
    const module = LoadLibraryExW(path[0..len :0], null, 0x900);
    if (module == 0) return error.LoadFailed;
    // Fixture never launches a child. A production owner must not unload
    // the module before confirmed drain/close.
    defer _ = FreeLibrary(module);
    const query: Query = @ptrCast(GetProcAddress(module, "pulse_companion_runtime_query") orelse return error.MissingQuery);
    var api: runtime.NativeApi = undefined;
    if (query(2, @sizeOf(runtime.NativeApi), &api) != 0 or
        query(1, @sizeOf(runtime.NativeApi) - 1, &api) != 0 or
        query(1, @sizeOf(runtime.NativeApi), &api) == 0 or !api.valid())
        return error.BadRuntimeAbi;
    var group: runtime.Group = .{};
    var invalid = api;
    invalid.start = null;
    if (group.openWithApi(invalid, 2, 256 * 1024 * 1024)) |_| {
        return error.AcceptedInvalidTable;
    } else |err| {
        if (err != error.Invalid) return err;
    }
    try group.openWithApi(api, 2, 256 * 1024 * 1024);
    if (try group.remaining() != 0) return error.UnexpectedChildren;
    try group.beginDrain(false);
    var rows: [runtime.max_tick_slots]runtime.TickResult = undefined;
    if (try group.tick(&rows) != 0) return error.UnexpectedTick;
    try group.close();
    try group.openWithApi(api, 1, 128 * 1024 * 1024);
    try group.close();
    std.debug.print("Companion GNU/MSVC runtime bridge ABI verified\n", .{});
}
