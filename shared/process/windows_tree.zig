//! Windows x64 owned process-tree execution. Use std.process.spawn suspended,
//! assign to a private unnamed job before resume, then collect bounded output.
//! No fallback to an uncontained process on assignment failure. A job object
//! is not a filesystem/network sandbox. Only use from a non-UI worker.

const std = @import("std");
const builtin = @import("builtin");
const Handle = std.os.windows.HANDLE;

const BasicLimits = extern struct {
    per_process_time: i64 = 0,
    per_job_time: i64 = 0,
    flags: u32 = 0,
    min_working_set: usize = 0,
    max_working_set: usize = 0,
    active_process_limit: u32 = 0,
    affinity: usize = 0,
    priority_class: u32 = 0,
    scheduling_class: u32 = 0,
};

const IoCounters = extern struct {
    read_operations: u64 = 0,
    write_operations: u64 = 0,
    other_operations: u64 = 0,
    read_bytes: u64 = 0,
    write_bytes: u64 = 0,
    other_bytes: u64 = 0,
};

const ExtendedLimits = extern struct {
    basic: BasicLimits = .{},
    io: IoCounters = .{},
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};

const Accounting = extern struct {
    total_user: i64,
    total_kernel: i64,
    period_user: i64,
    period_kernel: i64,
    page_faults: u32,
    total_processes: u32,
    active_processes: u32,
    terminated_processes: u32,
};

extern "kernel32" fn CreateJobObjectW(attributes: ?*anyopaque, name: ?[*:0]const u16) callconv(.winapi) ?Handle;
extern "kernel32" fn SetInformationJobObject(job: Handle, class: i32, info: *const anyopaque, length: u32) callconv(.winapi) i32;
extern "kernel32" fn QueryInformationJobObject(job: Handle, class: i32, info: *anyopaque, length: u32, returned: ?*u32) callconv(.winapi) i32;
extern "kernel32" fn AssignProcessToJobObject(job: Handle, process: Handle) callconv(.winapi) i32;
extern "kernel32" fn TerminateJobObject(job: Handle, code: u32) callconv(.winapi) i32;
extern "kernel32" fn ResumeThread(thread: Handle) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(milliseconds: u32) callconv(.winapi) void;

const Job = struct {
    handle: Handle,

    fn init() error{ContainmentFailed}!Job {
        const handle = CreateJobObjectW(null, null) orelse return error.ContainmentFailed;
        errdefer _ = CloseHandle(handle);
        const limits: ExtendedLimits = .{ .basic = .{
            // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE | ACTIVE_PROCESS
            .flags = 0x2000 | 0x8,
            .active_process_limit = 16,
        } };
        if (SetInformationJobObject(handle, 9, &limits, @sizeOf(ExtendedLimits)) == 0) return error.ContainmentFailed;
        return .{ .handle = handle };
    }

    fn close(self: Job) void {
        _ = CloseHandle(self.handle);
    }

    fn active(self: Job) error{ContainmentFailed}!u32 {
        var info: Accounting = undefined;
        if (QueryInformationJobObject(self.handle, 1, &info, @sizeOf(Accounting), null) == 0) return error.ContainmentFailed;
        return info.active_processes;
    }

    /// Cleanup is independent of the canceled Zig task. Do not report
    /// confirmed termination unless the job's accounting reaches zero.
    fn terminateAndDrain(self: Job) error{ContainmentFailed}!void {
        if (try self.active() == 0) return;
        if (TerminateJobObject(self.handle, 1) == 0) return error.ContainmentFailed;
        const start = GetTickCount64();
        while (try self.active() != 0) {
            if (GetTickCount64() -% start >= 5000) return error.ContainmentFailed;
            Sleep(10);
        }
    }
};

fn remaining(start: u64, timeout_ms: u64) error{Timeout}!u64 {
    const elapsed = GetTickCount64() -% start;
    if (elapsed >= timeout_ms) return error.Timeout;
    return timeout_ms - elapsed;
}

pub fn run(allocator: std.mem.Allocator, io: std.Io, options: std.process.RunOptions, timeout_ns: u64) anyerror!std.process.RunResult {
    if (comptime builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.ContainmentUnavailable;
    if (timeout_ns == 0) return error.Timeout;
    const timeout_ms = (timeout_ns - 1) / std.time.ns_per_ms + 1;
    const start = GetTickCount64();
    const job = try Job.init();
    defer job.close();
    var child = try std.process.spawn(io, .{
        .argv = options.argv,
        .cwd = options.cwd,
        .environ_map = options.environ_map,
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .pipe,
        .start_suspended = true,
        .create_no_window = true,
    });
    defer child.kill(io);
    // On assignment failure the process remains suspended and child.kill
    // reaps it. Never resume or try a less restrictive launch.
    if (AssignProcessToJobObject(job.handle, child.id.?) == 0) return error.ContainmentFailed;
    const result = collect(allocator, io, &child, job, options, start, timeout_ms) catch |err| {
        try job.terminateAndDrain();
        return err;
    };
    return result;
}

fn collect(allocator: std.mem.Allocator, io: std.Io, child: *std.process.Child, job: Job, options: std.process.RunOptions, start: u64, timeout_ms: u64) !std.process.RunResult {
    _ = try remaining(start, timeout_ms);
    if (ResumeThread(child.thread_handle) != 1) return error.ContainmentFailed;
    var streams: std.Io.File.MultiReader.Buffer(2) = undefined;
    var reader: std.Io.File.MultiReader = undefined;
    reader.init(allocator, io, streams.toStreams(), &.{ child.stdout.?, child.stderr.? });
    defer reader.deinit();
    while (true) {
        const left = try remaining(start, timeout_ms);
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(@as(i96, left) * std.time.ns_per_ms), .clock = .boot } };
        reader.fill(64, timeout) catch |err| switch (err) {
            error.EndOfStream => break,
            else => return err,
        };
        if (options.stdout_limit.toInt()) |limit| {
            if (reader.reader(0).buffered().len > limit) return error.StreamTooLong;
        }
        if (options.stderr_limit.toInt()) |limit| {
            if (reader.reader(1).buffered().len > limit) return error.StreamTooLong;
        }
    }
    try reader.checkAnyError();
    if (options.stdout_limit.toInt()) |limit| {
        if (reader.reader(0).buffered().len > limit) return error.StreamTooLong;
    }
    if (options.stderr_limit.toInt()) |limit| {
        if (reader.reader(1).buffered().len > limit) return error.StreamTooLong;
    }
    // EOF does not imply the process exited. Apply the same deadline to
    // descendants even if they closed or redirected their standard streams.
    while (try job.active() != 0) {
        const left = try remaining(start, timeout_ms);
        try std.Io.sleep(io, .fromMilliseconds(@intCast(@min(left, 10))), .boot);
    }
    const term = try child.wait(io);
    const stdout = try reader.toOwnedSlice(0);
    errdefer allocator.free(stdout);
    const stderr = try reader.toOwnedSlice(1);
    errdefer allocator.free(stderr);
    return .{ .term = term, .stdout = stdout, .stderr = stderr };
}

test "Windows job ABI layout" {
    if (comptime builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 64), @sizeOf(BasicLimits));
    try std.testing.expectEqual(@as(usize, 144), @sizeOf(ExtendedLimits));
    try std.testing.expectEqual(@as(usize, 48), @sizeOf(Accounting));
}

test "Windows job captures a child and rejects a surviving descendant" {
    if (comptime builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.SkipZigTest;
    const a = std.testing.allocator;
    const io = std.testing.io;
    const result = try run(a, io, .{
        .argv = &.{ "cmd", "/d", "/c", "echo job-owned" },
        .stdout_limit = std.Io.Limit.limited(1024),
        .stderr_limit = std.Io.Limit.limited(1024),
    }, 5 * std.time.ns_per_s);
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    try std.testing.expect(result.term.success());
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "job-owned") != null);
    try std.testing.expectError(error.Timeout, run(a, io, .{
        .argv = &.{ "cmd", "/d", "/c", "start \"\" /b ping.exe -n 20 127.0.0.1 >nul" },
        .stdout_limit = std.Io.Limit.limited(1024),
        .stderr_limit = std.Io.Limit.limited(1024),
    }, 2 * std.time.ns_per_s));
}
