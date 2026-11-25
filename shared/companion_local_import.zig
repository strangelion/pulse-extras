//! Typed local-directory import for a verified runtime owner.
//! The caller must hold the approved private-root lease and the approved
//! installation directory. No shell or inherited environment.
const std = @import("std");
const runtime = @import("companion_runtime_owner.zig");
const store = @import("companion_runtime_store.zig");
const importing = @import("companion/pet_import.zig");
const helper_mod = @import("companion/pet_import_helper.zig");
const inventory = @import("companion/pet_inventory.zig");
const process = @import("pulse_process");

extern "kernel32" fn GetWindowsDirectoryW([*]u16, u32) callconv(.winapi) u32;

pub const Result = importing.Result;

pub fn run(io: std.Io, owner: *runtime.Owner, private: [:0]const u16, exe: [:0]const u16, digest: [32]u8, source: []const u8, source_id: []const u8) !Result {
    if (!owner.opened or !owner.lease_opened or !inventory.validSource(source_id)) return error.Invalid;
    if (source.len < 4 or source.len > 4096 or !std.ascii.isAlphabetic(source[0]) or source[1] != ':' or source[2] != '\\' or
        std.mem.indexOfScalar(u8, source, 0) != null or !std.unicode.utf8ValidateSlice(source)) return error.InvalidSource;
    var exe_buf: [4096]u8 = undefined;
    const exe_len = try std.unicode.utf16LeToUtf8(&exe_buf, exe);
    var root_buf: [4096]u8 = undefined;
    const root_len = try std.unicode.utf16LeToUtf8(&root_buf, private);
    const root = root_buf[0..root_len];
    var system_wide: [1024]u16 = undefined;
    const n = GetWindowsDirectoryW(&system_wide, system_wide.len);
    if (n == 0 or n >= system_wide.len) return error.InvalidSystemDirectory;
    var system_buf: [4096]u8 = undefined;
    const system_len = try std.unicode.utf16LeToUtf8(&system_buf, system_wide[0..n]);
    var environ = std.process.Environ.Map.init(std.heap.page_allocator);
    defer environ.deinit();
    try environ.put("SystemRoot", system_buf[0..system_len]);
    try environ.put("TEMP", root);
    try environ.put("TMP", root);
    var runner = process.Runner.init(std.heap.page_allocator, io);
    try runner.configureApproved(.{ .path = exe_buf[0..exe_len], .digest = digest }, 60 * std.time.ns_per_s);
    try runner.configureTree(.windows_job);
    var helper: helper_mod.Helper = .{
        .runner = &runner,
        .exe = exe_buf[0..exe_len],
        .cwd = root,
        .asset_root = root,
        .environ = &environ,
    };
    const coordinator = try std.heap.page_allocator.create(importing.Coordinator);
    defer std.heap.page_allocator.destroy(coordinator);
    coordinator.* = .{};
    _ = try store.loadInventory(owner, &coordinator.index);
    const outcome = store.importPackage(owner, coordinator, &helper, source, source_id);
    try runner.checkDrained();
    if (coordinator.fault != null) return error.RecoveryRequired;
    return outcome;
}
