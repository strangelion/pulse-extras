//! Standalone experimental desktop companion executable, not a Pulse plugin.
const animation = @import("animation.zig");
const assets = @import("pet_assets.zig");

const Sample = extern struct {
    row: u32,
    column: u32,
    wait_ms: u32,
};

const SampleFn = *const fn (u32, u32, u64, c_int, *Sample) callconv(.c) c_int;
const ValidateFn = *const fn (u32, [*]const u8, usize) callconv(.c) c_int;

extern "c" fn pet_demo_run(SampleFn, ValidateFn) c_int;

fn layoutFor(version: u32) ?assets.Layout {
    return switch (version) {
        1 => .v1,
        2 => .v2,
        else => null,
    };
}

fn sampleFrame(version: u32, waving: u32, elapsed: u64, reduced: c_int, output: *Sample) callconv(.c) c_int {
    const layout = layoutFor(version) orelse return 1;
    const point = animation.sample(layout, if (waving != 0) .waving else .idle, elapsed, reduced != 0);
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

pub fn main() !void {
    if (pet_demo_run(sampleFrame, validateWebp) != 0) return error.CompanionDemoFailed;
}
