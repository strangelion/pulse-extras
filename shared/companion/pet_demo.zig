//! Standalone experimental desktop companion executable, not a Pulse plugin.
const std = @import("std");
const memory = @import("pet_memory.zig");
const Group = @import("runtime_group").Group;
const async_decode = @import("pet_async_bridge.zig");
const resources = @import("pet_resources.zig");
const animation = @import("animation.zig");
const assets = @import("pet_assets.zig");
const activities = @import("pet_activities.zig");
const package = @import("pet_package.zig");
const fingerprint = @import("pet_fingerprint.zig");

const Sample = extern struct {
    row: u32,
    column: u32,
    wait_ms: u32,
};

const SampleFn = *const fn (u32, u32, u64, c_int, *Sample) callconv(.c) c_int;
const ValidateFn = *const fn (u32, [*]const u8, usize) callconv(.c) c_int;

const ActivitySampleFn = *const fn (u32, u32, u64, *Sample) callconv(.c) c_int;

const PackageParseFn = *const fn (*const memory.Bridge, [*]const u8, usize, [*]const u8, usize, *package.Package) callconv(.c) c_int;

const ScheduleFn = *const fn (*const package.Package, u32, u32, u32, u32) callconv(.c) u32;

const FingerprintFile = extern struct {
    path: [96]u8,
    size: u64,
    digest: fingerprint.Pair,
};
const HashFn = *const fn ([*]const u8, usize, *fingerprint.Pair) callconv(.c) void;
const FingerprintFn = *const fn ([*]const FingerprintFile, usize, *fingerprint.Pair) callconv(.c) c_int;

fn hashBytes(input: [*]const u8, len: usize, out: *fingerprint.Pair) callconv(.c) void {
    std.crypto.hash.sha2.Sha256.hash(input[0..len], &out.primary, .{});
    std.crypto.hash.sha2.Sha512.hash(input[0..len], &out.secondary, .{});
}

fn hashInventory(input: [*]const FingerprintFile, count: usize, out: *fingerprint.Pair) callconv(.c) c_int {
    if (count > fingerprint.max_files) return 1;
    var files: [fingerprint.max_files]fingerprint.FileDigest = undefined;
    for (input[0..count], 0..) |*file, i| {
        const path = std.mem.sliceTo(&file.path, 0);
        if (path.len == file.path.len) return 1;
        files[i] = .{ .path = path, .size = file.size, .digest = file.digest.primary, .secondary = file.digest.secondary };
    }
    out.* = fingerprint.digestPair(files[0..count]) catch return 1;
    return 0;
}

extern "c" fn pet_demo_run(*const memory.Bridge, *const async_decode.Bridge, SampleFn, ValidateFn, ActivitySampleFn, ValidateFn, PackageParseFn, ScheduleFn, HashFn, FingerprintFn) c_int;

fn layoutFor(version: u32) ?assets.Layout {
    return switch (version) {
        1 => .v1,
        2 => .v2,
        else => null,
    };
}

fn sampleFrame(version: u32, reaction: u32, elapsed: u64, reduced: c_int, output: *Sample) callconv(.c) c_int {
    const layout = layoutFor(version) orelse return 1;
    // Explicit C wire codes; never depend on Zig enum ordinal layout.
    const state: animation.State = switch (reaction) {
        0 => .idle,
        1 => .review,
        2, 3, 4 => .running,
        5, 6 => .waiting,
        7 => .waving,
        8, 10 => .jumping,
        9 => .failed,
        else => return 1,
    };
    const point = animation.sample(layout, state, elapsed, reduced != 0);
    output.* = .{
        .row = point.row,
        .column = point.column,
        .wait_ms = if (point.next_in) |wait| @intCast(wait) else 0,
    };
    return 0;
}

fn validateWebp(version: u32, bytes: [*]const u8, len: usize) callconv(.c) c_int {
    const layout = layoutFor(version) orelse return 1;
    if (len == 0 or len > assets.max_webp_bytes) return 1;
    assets.preflightWebp(layout, bytes[0..len]) catch return 1;
    return 0;
}

fn sampleActivity(frames: u32, fps: u32, elapsed: u64, output: *Sample) callconv(.c) c_int {
    if (frames > 32 or fps > 12) return -1;
    const rep: activities.Representation = .{ .frames = @intCast(frames), .fps = @intCast(fps) };
    if (!rep.valid()) return -1;
    const point = activities.sample(rep, elapsed) orelse return 1;
    output.* = .{ .row = 0, .column = point.column, .wait_ms = @intCast(point.next_in) };
    return 0;
}

fn validateActivity(frames: u32, bytes: [*]const u8, len: usize) callconv(.c) c_int {
    if (frames < 4 or frames > 32 or len == 0 or len > activities.max_file_bytes) return 1;
    // 4 fps admits every supported frame count; the actual playback fps
    // is validated separately by sampleActivity.
    const rep: activities.Representation = .{ .frames = @intCast(frames), .fps = 4 };
    assets.preflightActivity(rep, bytes[0..len]) catch return 1;
    return 0;
}

fn parsePackage(bridge: *const memory.Bridge, input: [*]const u8, len: usize, id: [*]const u8, id_len: usize, out: *package.Package) callconv(.c) c_int {
    return package.parse(bridge.allocator(), input, len, id, id_len, out);
}

export fn pet_pick_folder() callconv(.c) c_int {
    return @import("pet_folder_picker.zig").run();
}

pub fn main(init: std.process.Init) !void {
    var group = Group.init(std.heap.page_allocator, memory.limit, 1, 1);
    var resource_owner: resources.Owner = .{};
    const resource_bridge = resources.Bridge.init(&resource_owner);
    const bridge = memory.Bridge.init(&group.pool, &resource_bridge);
    var async_owner = async_decode.Owner.init(init.io, &group);
    const async_bridge = async_decode.Bridge.init(&async_owner);
    const result = pet_demo_run(&bridge, &async_bridge, sampleFrame, validateWebp, sampleActivity, validateActivity, parsePackage, package.resolveSchedule, hashBytes, hashInventory);
    // C must stop before releasing its pinned package and notification.
    // Idempotent stop is a defensive final drain, not a replacement.
    async_owner.stop();
    const group_stats = group.diagnostics();
    const stats = group_stats.memory;
    // A single bounded shutdown diagnostic; no per-frame logging.
    std.debug.print("Companion heap: live={d} allocations={d} peak={d} denied={d}\n", .{ stats.live_bytes, stats.live_allocations, stats.reserved_peak, stats.denied });
    std.debug.print("Companion resources: files={d} codec={d} dib={d} cleanup_failures={d} peaks={d}/{d}/{d}\n", .{ resource_owner.files.used, resource_owner.codecs.used, resource_owner.dib.used, resource_owner.cleanup_failures, resource_owner.files.peak, resource_owner.codecs.peak, resource_owner.dib.peak });
    std.debug.print("Companion notification: live={d} peak={d}\n", .{ resource_owner.notifications.used, resource_owner.notifications.peak });
    std.debug.print("Companion native: ipc={d} registry={d} menus={d} argv={d} peaks={d}/{d}/{d}/{d}\n", .{ resource_owner.ipc.used, resource_owner.registry.used, resource_owner.menus.used, resource_owner.argv.used, resource_owner.ipc.peak, resource_owner.registry.peak, resource_owner.menus.peak, resource_owner.argv.peak });
    std.debug.print("Companion drawing: windows={d} memory_dc={d} desktop_dc={d} peaks={d}/{d}/{d}\n", .{ resource_owner.windows.used, resource_owner.memory_dcs.used, resource_owner.desktop_dcs.used, resource_owner.windows.peak, resource_owner.memory_dcs.peak, resource_owner.desktop_dcs.peak });
    std.debug.print("Companion menu timer: live={d} peak={d}\n", .{ resource_owner.menu_timers.used, resource_owner.menu_timers.peak });
    if (stats.denied != 0) resource_owner.log.add(.{ .kind = .allocation_limit, .count = stats.denied });
    if (result != 0) resource_owner.log.add(.{ .kind = .io_failure, .count = 1 });
    resource_owner.log.add(.{ .kind = .stopped, .count = 1 });
    var log_buffer: [4096]u8 = undefined;
    const report = try resource_owner.log.encode(&log_buffer);
    std.debug.print("{s}", .{report});
    std.debug.print("Companion tasks: queued={d} running={d} peaks={d}/{d} rejected={d}\n", .{ group_stats.queued, group_stats.running, group_stats.queue_peak, group_stats.running_peak, group_stats.rejected });
    try group.checkDrained();
    try resource_owner.checkDrained();
    if (result != 0) return error.CompanionDemoFailed;
}
