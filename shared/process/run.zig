//! Bounded external-process execution for VCS providers and other backends.
//!
//! Every call passes an argv array (never a shell string), a working directory,
//! an optional environment, an output cap and a timeout. The child inherits
//! stdin from `NUL`/`/dev/null`, so a tool that unexpectedly prompts fails
//! instead of hanging on a terminal.
//!
//! Zig 0.17 moved process spawning onto `std.Io`; this module owns one
//! `std.Io.Threaded` instance so callers do not have to thread an `Io` value
//! through their APIs. The runner is not thread-safe: create one per worker.

const std = @import("std");

pub const Request = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// `null` inherits the parent environment; pass a map to restrict it.
    environ_map: ?*const std.process.Environ.Map = null,
    timeout_ns: u64 = 10 * std.time.ns_per_s,
    stdout_limit: usize = 4 * 1024 * 1024,
    stderr_limit: usize = 1024 * 1024,
};

pub const Status = enum {
    /// Process ran to completion; `exit_code` is meaningful.
    exited,
    /// Terminated by a signal (POSIX) or an unknown status (Windows).
    signalled,
    /// The timeout expired and the child was killed.
    timed_out,
};

pub const Outcome = struct {
    status: Status,
    exit_code: ?u8,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.* = undefined;
    }

    /// True only for a clean zero exit; timeouts and signals are failures even
    /// when the tool produced output.
    pub fn succeeded(self: *const Outcome) bool {
        return self.status == .exited and self.exit_code == 0;
    }
};

pub const Error = error{
    /// The executable could not be found or started.
    SpawnFailed,
    /// stdout or stderr exceeded its configured cap.
    OutputTooLong,
    /// The child did not finish within `timeout_ns`.
    TimedOut,
} || std.mem.Allocator.Error;

/// `std.Io.Threaded` keeps process-wide state (signal handlers, worker pool),
/// so the whole process shares one instance instead of creating one per call.
var shared_threaded: std.Io.Threaded = undefined;
var shared_io: ?std.Io = null;
var shared_lock: std.atomic.Mutex = .unlocked;

fn sharedIo() std.Io {
    while (!shared_lock.tryLock()) std.atomic.spinLoopHint();
    defer shared_lock.unlock();
    if (shared_io) |value| return value;
    shared_threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    shared_io = shared_threaded.io();
    return shared_io.?;
}

/// Shared `Io` for callers that need filesystem access without threading an
/// `Io` value through their APIs (for example CLI discovery).
pub fn io() std.Io {
    return sharedIo();
}

pub const Runner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) Runner {
        return .{ .allocator = allocator };
    }

    /// Kept for symmetry; the shared I/O instance lives for the whole process.
    pub fn deinit(self: *Runner) void {
        _ = self;
    }

    /// Runs `request.argv` and collects bounded output.
    pub fn run(self: *Runner, request: Request) Error!Outcome {
        const cwd: std.process.Child.Cwd = if (request.cwd) |path| .{ .path = path } else .inherit;
        const timeout: std.Io.Timeout = if (request.timeout_ns == 0)
            .none
        else
            .{ .duration = .{ .raw = .fromNanoseconds(request.timeout_ns), .clock = .boot } };

        const result = std.process.run(self.allocator, sharedIo(), .{
            .argv = request.argv,
            .cwd = cwd,
            .environ_map = request.environ_map,
            .stdout_limit = std.Io.Limit.limited(request.stdout_limit),
            .stderr_limit = std.Io.Limit.limited(request.stderr_limit),
            .timeout = timeout,
        }) catch |err| switch (err) {
            error.FileNotFound, error.AccessDenied, error.InvalidExe, error.NameTooLong => return error.SpawnFailed,
            error.StreamTooLong => return error.OutputTooLong,
            error.Timeout => return error.TimedOut,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SpawnFailed,
        };

        const status: Status = switch (result.term) {
            .exited => .exited,
            else => .signalled,
        };
        return .{
            .status = status,
            .exit_code = switch (result.term) {
                .exited => |code| code,
                else => null,
            },
            .stdout = result.stdout,
            .stderr = result.stderr,
        };
    }
};

const testing = std.testing;

test "runner reports a missing executable instead of hanging" {
    var runner = Runner.init(testing.allocator);
    defer runner.deinit();
    try testing.expectError(error.SpawnFailed, runner.run(.{
        .argv = &.{"pulse-extras-does-not-exist-9f3a"},
        .timeout_ns = 5 * std.time.ns_per_s,
    }));
}

test "runner captures output and exit status" {
    var runner = Runner.init(testing.allocator);
    defer runner.deinit();
    const command: []const u8 = if (@import("builtin").os.tag == .windows) "cmd" else "sh";
    const args: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    var outcome = runner.run(.{ .argv = args, .timeout_ns = 5 * std.time.ns_per_s }) catch |err| switch (err) {
        error.SpawnFailed => return error.SkipZigTest,
        else => return err,
    };
    defer outcome.deinit(testing.allocator);
    try testing.expect(outcome.succeeded());
    try testing.expect(std.mem.indexOf(u8, outcome.stdout, "hello") != null);
    _ = command;
}

test "runner enforces the output cap" {
    var runner = Runner.init(testing.allocator);
    defer runner.deinit();
    // Fixed-size output: the child exits on its own, so a limit hit cannot
    // deadlock on a full pipe (that only happens with unbounded writers).
    var filler: [600]u8 = undefined;
    @memset(&filler, 'x');
    var command: [720]u8 = undefined;
    const is_windows = @import("builtin").os.tag == .windows;
    const line = if (is_windows)
        try std.fmt.bufPrint(&command, "echo {s}", .{filler})
    else
        try std.fmt.bufPrint(&command, "printf '%s' {s}", .{filler});
    const argv: []const []const u8 = if (is_windows)
        &.{ "cmd", "/c", line }
    else
        &.{ "sh", "-c", line };
    const result = runner.run(.{ .argv = argv, .stdout_limit = 64, .timeout_ns = 5 * std.time.ns_per_s });
    try testing.expectError(error.OutputTooLong, result);
}
