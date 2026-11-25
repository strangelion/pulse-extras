//! Standalone experimental desktop companion executable, not a Pulse plugin.
const animation = @import("animation.zig");
const assets = @import("pet_assets.zig");
const activities = @import("pet_activities.zig");

const Sample = extern struct {
    row: u32,
    column: u32,
    wait_ms: u32,
};

const SampleFn = *const fn (u32, u32, u64, c_int, *Sample) callconv(.c) c_int;
const ValidateFn = *const fn (u32, [*]const u8, usize) callconv(.c) c_int;

const ActivitySampleFn = *const fn (u32, u32, u64, *Sample) callconv(.c) c_int;

extern "c" fn pet_demo_run(SampleFn, ValidateFn, ActivitySampleFn, ValidateFn) c_int;

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

pub fn main() !void {
    if (pet_demo_run(sampleFrame, validateWebp, sampleActivity, validateActivity) != 0) return error.CompanionDemoFailed;
}
