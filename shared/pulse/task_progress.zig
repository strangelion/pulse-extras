//! Task ABI prefixes and optional phase reporting across Pulse 1.0.60-62.
const std = @import("std");
const raw = @import("pulse_raw");
const abi = @import("pulse_abi");

pub const descriptor_v1_size: u32 = 64;
pub const progress_v1_size: u32 = 72;
pub const indeterminate: u32 = std.math.maxInt(u32);

// Only synthesize the extension for SDKs that do not declare it yet.
// New SDKs must use their official complete layout, never append it again.
pub const TaskDescriptor61 = if (@hasField(raw.PulseTaskDescriptor, "source")) raw.PulseTaskDescriptor else extern struct {
    base: raw.PulseTaskDescriptor,
    source: abi.StringView,
    destination: abi.StringView,
    steps: [*c]const abi.StringView,
    step_count: u32,
    on_action: ?*const fn (?*anyopaque, u64, abi.StringView) callconv(.c) void,
    action_user: ?*anyopaque,
};

pub const TaskProgress61 = if (@hasField(raw.PulseTaskProgress, "step")) raw.PulseTaskProgress else extern struct {
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
    const descriptor_prefix = if (@hasField(raw.PulseTaskDescriptor, "source")) @offsetOf(raw.PulseTaskDescriptor, "source") else @sizeOf(raw.PulseTaskDescriptor);
    const progress_prefix = if (@hasField(raw.PulseTaskProgress, "step")) @offsetOf(raw.PulseTaskProgress, "step") else @sizeOf(raw.PulseTaskProgress);
    if (descriptor_prefix != descriptor_v1_size or @offsetOf(raw.PulseTaskDescriptor, "work") != 40 or @offsetOf(raw.PulseTaskDescriptor, "on_cancel") != 56 or @offsetOf(TaskDescriptor61, "source") != 64 or @offsetOf(TaskDescriptor61, "steps") != 96 or @offsetOf(TaskDescriptor61, "step_count") != 104 or @sizeOf(TaskDescriptor61) != 128) @compileError("task descriptor x64 ABI mismatch");
    if (progress_prefix != progress_v1_size or @offsetOf(raw.PulseTaskProgress, "current_item") != 56 or @offsetOf(TaskProgress61, "step") != 72 or @offsetOf(TaskProgress61, "linked_operation") != 80 or @sizeOf(TaskProgress61) != 192) @compileError("task progress x64 ABI mismatch");
}

pub fn descriptorPtr(value: *const TaskDescriptor61) *const raw.PulseTaskDescriptor {
    return @ptrCast(value);
}

/// Steps and their strings remain caller-owned and must outlive host use.
pub fn steppedDescriptor(base: raw.PulseTaskDescriptor, steps: []const abi.StringView) error{TooManySteps}!TaskDescriptor61 {
    if (steps.len > 64) return error.TooManySteps;
    var descriptor = std.mem.zeroes(TaskDescriptor61);
    if (comptime @hasField(raw.PulseTaskDescriptor, "source")) {
        // Only the original prefix belongs to the base request.
        @memcpy(std.mem.asBytes(&descriptor)[0..descriptor_v1_size], std.mem.asBytes(&base)[0..descriptor_v1_size]);
        descriptor.size = @sizeOf(TaskDescriptor61);
    } else {
        descriptor.base = base;
        descriptor.base.size = @sizeOf(TaskDescriptor61);
    }
    descriptor.steps = if (steps.len == 0) null else steps.ptr;
    descriptor.step_count = @intCast(steps.len);
    return descriptor;
}

/// Only valid during host work callback; no UI access or product logging.
/// Step zero always advertises the original prefix, even on newer SDKs.
pub fn report(context: *const raw.PulseTaskContext, message: []const u8, step: u32, percent: u32) abi.Status {
    const send = context.report orelse return abi.error_unavailable;
    if (percent != indeterminate and percent > 100) return abi.error_argument;
    var progress = std.mem.zeroes(TaskProgress61);
    const prefix: *raw.PulseTaskProgress = @ptrCast(&progress);
    prefix.size = if (step == 0) progress_v1_size else @sizeOf(TaskProgress61);
    prefix.percent = percent;
    prefix.current_item = abi.view(message);
    progress.step = step;
    return send(context.context, prefix);
}

test "step descriptor preserves prefix and advertises additive size" {
    var base = std.mem.zeroes(raw.PulseTaskDescriptor);
    base.title = abi.view("task");
    const steps = [_]abi.StringView{abi.view("read")};
    const desc = try steppedDescriptor(base, &steps);
    try std.testing.expectEqual(@as(u32, 128), descriptorPtr(&desc).size);
    try std.testing.expectEqualStrings("task", abi.slice(descriptorPtr(&desc).title).?);
    try std.testing.expectEqual(@as(u32, 1), desc.step_count);
    try std.testing.expectEqualStrings("read", abi.slice(desc.steps[0]).?);
    try std.testing.expectEqual(indeterminate, std.math.maxInt(u32));
}

test "report advertises exactly the basic or stepped size" {
    const Fixture = struct {
        fn receive(user: ?*anyopaque, progress: [*c]const raw.PulseTaskProgress) callconv(.c) abi.Status {
            const expected: *const u32 = @ptrCast(@alignCast(user orelse return abi.error_argument));
            if (progress == null or progress[0].size != expected.* or progress[0].percent != indeterminate) return abi.error_argument;
            if (expected.* == 192) {
                const extended: *const TaskProgress61 = @ptrCast(progress);
                if (extended.step != 2) return abi.error_argument;
            }
            return abi.ok;
        }
    };
    var expected: u32 = progress_v1_size;
    var context = std.mem.zeroes(raw.PulseTaskContext);
    context.context = &expected;
    context.report = Fixture.receive;
    try std.testing.expectEqual(abi.ok, report(&context, "basic", 0, indeterminate));
    expected = 192;
    try std.testing.expectEqual(abi.ok, report(&context, "step", 2, indeterminate));
    try std.testing.expectEqual(abi.error_argument, report(&context, "invalid", 2, 101));
}
