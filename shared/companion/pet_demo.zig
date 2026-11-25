//! Standalone experimental desktop companion executable, not a Pulse plugin.
const std = @import("std");
const memory = @import("pet_memory.zig");
const resources = @import("pet_resources.zig");
const animation = @import("animation.zig");
const assets = @import("pet_assets.zig");
const activities = @import("pet_activities.zig");
const package = @import("pet_package.zig");

const Sample = extern struct {
    row: u32,
    column: u32,
    wait_ms: u32,
};

const SampleFn = *const fn (u32, u32, u64, c_int, *Sample) callconv(.c) c_int;
const ValidateFn = *const fn (u32, [*]const u8, usize) callconv(.c) c_int;

const ActivitySampleFn = *const fn (u32, u32, u64, *Sample) callconv(.c) c_int;

const PackageParseFn = *const fn (*const memory.Bridge, [*]const u8, usize, [*]const u8, usize, *package.Package) callconv(.c) c_int;

extern "c" fn pet_demo_run(*const memory.Bridge, SampleFn, ValidateFn, ActivitySampleFn, ValidateFn, PackageParseFn) c_int;

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

pub fn main() !void {
    var owner = memory.BoundedAllocator.init(std.heap.page_allocator, memory.limit);
    var resource_owner: resources.Owner = .{};
    const resource_bridge = resources.Bridge.init(&resource_owner);
    const bridge = memory.Bridge.init(&owner, &resource_bridge);
    const result = pet_demo_run(&bridge, sampleFrame, validateWebp, sampleActivity, validateActivity, parsePackage);
    const stats = owner.stats();
    // A single bounded shutdown diagnostic; no per-frame logging.
    std.debug.print("Companion heap: live={d} allocations={d} peak={d} denied={d}\n", .{ stats.live_bytes, stats.live_allocations, stats.reserved_peak, stats.denied });
    std.debug.print("Companion resources: files={d} codec={d} dib={d} cleanup_failures={d} peaks={d}/{d}/{d}\n", .{ resource_owner.files.used, resource_owner.codecs.used, resource_owner.dib.used, resource_owner.cleanup_failures, resource_owner.files.peak, resource_owner.codecs.peak, resource_owner.dib.peak });
    if (stats.denied != 0) resource_owner.log.add(.{ .kind = .allocation_limit, .count = stats.denied });
    if (result != 0) resource_owner.log.add(.{ .kind = .io_failure, .count = 1 });
    resource_owner.log.add(.{ .kind = .stopped, .count = 1 });
    var log_buffer: [4096]u8 = undefined;
    const report = try resource_owner.log.encode(&log_buffer);
    std.debug.print("{s}", .{report});
    try owner.checkDrained();
    try resource_owner.checkDrained();
    if (result != 0) return error.CompanionDemoFailed;
}
