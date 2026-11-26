//! Optional append-only task-report ABI from the installed 1.0.61 SDK.
const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");

// Optional append-only task ABI from installed Pulse 1.0.61 tasks.h.
// The pinned 1.0.60 host accepts size >= its prefix and ignores the tail.
// Do not change the generated baseline or the version of pulse.tasks.
pub const TaskDescriptor61 = extern struct {
    base: raw.PulseTaskDescriptor,
    source: abi.StringView,
    destination: abi.StringView,
    steps: [*c]const abi.StringView,
    step_count: u32,
    on_action: ?*const fn (?*anyopaque, u64, abi.StringView) callconv(.c) void,
    action_user: ?*anyopaque,
};

pub const TaskProgress61 = extern struct {
    base: raw.PulseTaskProgress,
    step: u32,
    action_count: u32,
    linked_operation: u64,
    note: abi.StringView,
    detail: abi.StringView,
    assurance: abi.StringView,
    actions: ?*const anyopaque,
    log: abi.StringView,
    result: abi.StringView,
    result_path: abi.StringView,
};

comptime {
    if (@sizeOf(raw.PulseTaskDescriptor) != 64 or @offsetOf(TaskDescriptor61, "source") != 64 or @offsetOf(TaskDescriptor61, "steps") != 96 or @offsetOf(TaskDescriptor61, "step_count") != 104 or @sizeOf(TaskDescriptor61) != 128) @compileError("task descriptor 1.0.61 x64 ABI mismatch");
    if (@sizeOf(raw.PulseTaskProgress) != 72 or @offsetOf(TaskProgress61, "step") != 72 or @offsetOf(TaskProgress61, "linked_operation") != 80 or @sizeOf(TaskProgress61) != 192) @compileError("task progress 1.0.61 x64 ABI mismatch");
}

pub const indeterminate: u32 = std.math.maxInt(u32);

/// Steps and their strings remain caller-owned and must outlive host use.
pub fn steppedDescriptor(base: raw.PulseTaskDescriptor, steps: []const abi.StringView) error{TooManySteps}!TaskDescriptor61 {
    if (steps.len > 64) return error.TooManySteps;
    var descriptor = std.mem.zeroes(TaskDescriptor61);
    descriptor.base = base;
    descriptor.base.size = @sizeOf(TaskDescriptor61);
    descriptor.steps = steps.ptr;
    descriptor.step_count = @intCast(steps.len);
    return descriptor;
}

/// Only valid during host work callback; no UI access or product logging.
/// Preserve raw host status for the caller. Step zero uses the frozen prefix.
pub fn report(context: *const raw.PulseTaskContext, message: []const u8, step: u32, percent: u32) abi.Status {
    const send = context.report orelse return abi.error_unavailable;
    if (percent != indeterminate and percent > 100) return abi.error_argument;
    var progress = std.mem.zeroes(TaskProgress61);
    progress.base.size = if (step == 0) @sizeOf(raw.PulseTaskProgress) else @sizeOf(TaskProgress61);
    progress.base.percent = percent;
    progress.base.current_item = abi.view(message);
    progress.step = step;
    return send(context.context, &progress.base);
}

test "step descriptor preserves base and advertises additive size" {
    const base = std.mem.zeroes(raw.PulseTaskDescriptor);
    const steps = [_]abi.StringView{abi.view("read")};
    const desc = try steppedDescriptor(base, &steps);
    try std.testing.expectEqual(@as(u32, @sizeOf(TaskDescriptor61)), desc.base.size);
    try std.testing.expectEqual(@as(u32, 1), desc.step_count);
    try std.testing.expectEqual(indeterminate, std.math.maxInt(u32));
}
