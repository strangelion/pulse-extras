//! Bounded external-process execution for VCS providers and other backends.
//!
//! Every call passes an argv array (never a shell string), a working directory,
//! an optional environment, an output cap and a timeout. The child inherits
//! stdin from `NUL`/`/dev/null`, so a tool that unexpectedly prompts fails
//! instead of hanging on a terminal.
//!
//! The caller owns the I/O runtime and must keep it alive until all work
//! and results have drained. Runner is serialized, not thread-safe. It must
//! remain at a stable address while an Outcome is alive. No global I/O state.

const std = @import("std");
const Budget = @import("runtime_budget").Budget;
const BoundedAllocator = @import("runtime_allocator").BoundedAllocator;

pub const default_output_budget: usize = 16 * 1024 * 1024;
pub const default_memory_budget: usize = 32 * 1024 * 1024;
pub const max_live_outcomes: usize = 8;

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
};

pub const Outcome = struct {
    status: Status,
    exit_code: ?u8,
    stdout: []u8,
    stderr: []u8,

    owner: *Runner,
    reservation: usize,

    /// Owned value: do not copy or deinit twice. Owner must outlive it.
    pub fn deinit(self: *Outcome) void {
        const allocator = self.owner.memory.allocator();
        allocator.free(self.stdout);
        allocator.free(self.stderr);
        self.owner.output_budget.release(self.reservation);
        self.owner.live_outcomes -= 1;
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
    InvalidRequest,
    Stopped,
    OutputBudgetExceeded,
    PermissionDenied,
    Io,
} || std.mem.Allocator.Error;

pub const Runner = struct {
    pub const State = enum { active, stopping, stopped };

    memory: BoundedAllocator,
    io: std.Io,
    output_budget: Budget,
    live_outcomes: usize = 0,
    state: State = .active,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Runner {
        return initWithBudget(allocator, io, default_output_budget);
    }

    pub fn initWithBudget(allocator: std.mem.Allocator, io: std.Io, output_limit: usize) Runner {
        return initWithLimits(allocator, io, output_limit, default_memory_budget);
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, io: std.Io, output_limit: usize, memory_limit: usize) Runner {
        return .{ .memory = BoundedAllocator.init(allocator, memory_limit), .io = io, .output_budget = Budget.init(output_limit) };
    }

    /// All results must be freed before the runner or its I/O owner goes away.
    /// This does not stop external workers: the caller owns their lifecycle.
    pub fn checkDrained(self: *Runner) error{ OutstandingOutputs, OutstandingAllocations }!void {
        if (self.live_outcomes != 0 or self.output_budget.used != 0) return error.OutstandingOutputs;
        try self.memory.checkDrained();
    }

    /// Owner-thread admission stop. Not interruption of an active run.
    /// No further requests may start; outstanding outcomes remain valid.
    pub fn requestStop(self: *Runner) void {
        if (self.state == .active) self.state = .stopping;
    }

    /// Call after any externally owned workers have joined. Refuse to declare
    /// shutdown complete while results or allocator reservations remain.
    pub fn finishStop(self: *Runner) error{ NotStopping, OutstandingOutputs, OutstandingAllocations }!void {
        if (self.state == .active) return error.NotStopping;
        try self.checkDrained();
        self.state = .stopped;
    }

    /// Reserve both output caps until the owned outcome is released.
    /// This bounds logical output capacity, not total child/allocator memory.
    pub fn run(self: *Runner, request: Request) Error!Outcome {
        if (self.state != .active) return error.Stopped;
        if (request.argv.len == 0 or request.argv[0].len == 0 or request.timeout_ns == 0) return error.InvalidRequest;
        if (self.live_outcomes >= max_live_outcomes) return error.OutputBudgetExceeded;
        const reservation = std.math.add(usize, request.stdout_limit, request.stderr_limit) catch return error.OutputBudgetExceeded;
        self.output_budget.reserve(reservation) catch return error.OutputBudgetExceeded;
        errdefer self.output_budget.release(reservation);
        const cwd: std.process.Child.Cwd = if (request.cwd) |path| .{ .path = path } else .inherit;
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(request.timeout_ns), .clock = .boot } };

        const result = std.process.run(self.memory.allocator(), self.io, .{
            .argv = request.argv,
            .cwd = cwd,
            .environ_map = request.environ_map,
            .stdout_limit = std.Io.Limit.limited(request.stdout_limit),
            .stderr_limit = std.Io.Limit.limited(request.stderr_limit),
            .timeout = timeout,
        }) catch |err| switch (err) {
            error.FileNotFound, error.InvalidExe, error.NameTooLong => return error.SpawnFailed,
            error.AccessDenied => return error.PermissionDenied,
            error.StreamTooLong => return error.OutputTooLong,
            error.Timeout => return error.TimedOut,
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.Io,
        };

        self.live_outcomes += 1;
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
            .owner = self,
            .reservation = reservation,
        };
    }
};

const testing = std.testing;

test "runner reports a missing executable instead of hanging" {
    var runner = Runner.init(testing.allocator, testing.io);
    try testing.expectError(error.SpawnFailed, runner.run(.{
        .argv = &.{"pulse-extras-does-not-exist-9f3a"},
        .timeout_ns = 5 * std.time.ns_per_s,
    }));
    try runner.checkDrained();
}

test "runner captures output and exit status" {
    var runner = Runner.init(testing.allocator, testing.io);
    const command: []const u8 = if (@import("builtin").os.tag == .windows) "cmd" else "sh";
    const args: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    var outcome = runner.run(.{ .argv = args, .timeout_ns = 5 * std.time.ns_per_s }) catch |err| switch (err) {
        error.SpawnFailed => return error.SkipZigTest,
        else => return err,
    };
    defer outcome.deinit();
    try testing.expect(outcome.succeeded());
    try testing.expect(std.mem.indexOf(u8, outcome.stdout, "hello") != null);
    _ = command;
}

test "runner enforces the output cap" {
    var runner = Runner.init(testing.allocator, testing.io);
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
    try runner.checkDrained();
}

test "runner rejects unbounded deadline and overbudget requests before spawn" {
    var runner = Runner.initWithBudget(testing.allocator, testing.io, 1024);
    try testing.expectError(error.InvalidRequest, runner.run(.{ .argv = &.{}, .timeout_ns = 1 }));
    try testing.expectError(error.InvalidRequest, runner.run(.{ .argv = &.{"never-start"}, .timeout_ns = 0 }));
    try testing.expectError(error.OutputBudgetExceeded, runner.run(.{ .argv = &.{"never-start"}, .stdout_limit = 1024, .stderr_limit = 1 }));
    try testing.expectError(error.OutputBudgetExceeded, runner.run(.{ .argv = &.{"never-start"}, .stdout_limit = std.math.maxInt(usize), .stderr_limit = 1 }));
    try runner.checkDrained();
}

test "owned output holds and releases a reservation" {
    var runner = Runner.initWithBudget(testing.allocator, testing.io, 2048);
    const args: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    {
        var outcome = try runner.run(.{ .argv = args, .stdout_limit = 1024, .stderr_limit = 1024 });
        defer outcome.deinit();
        try testing.expect(outcome.succeeded());
        try testing.expectError(error.OutstandingOutputs, runner.checkDrained());
        try testing.expectError(error.OutputBudgetExceeded, runner.run(.{ .argv = args, .stdout_limit = 1, .stderr_limit = 0 }));
    }
    try runner.checkDrained();
    try testing.expectEqual(@as(usize, 2048), runner.output_budget.peak);
}

test "stop rejects admissions without invalidating outstanding results" {
    var runner = Runner.init(testing.allocator, testing.io);
    const args: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/d", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    try testing.expectError(error.NotStopping, runner.finishStop());
    {
        var outcome = try runner.run(.{ .argv = args });
        defer outcome.deinit();
        runner.requestStop();
        runner.requestStop();
        try testing.expectError(error.Stopped, runner.run(.{ .argv = args }));
        try testing.expectError(error.OutstandingOutputs, runner.finishStop());
        try testing.expect(outcome.succeeded());
    }
    try runner.finishStop();
    try runner.finishStop();
    try testing.expectEqual(Runner.State.stopped, runner.state);
    try testing.expectError(error.Stopped, runner.run(.{ .argv = args }));
}

test "allocation budget failure returns without retaining output reservations" {
    var runner = Runner.initWithLimits(testing.allocator, testing.io, 2048, 0);
    const args: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/d", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    try testing.expectError(error.OutOfMemory, runner.run(.{ .argv = args, .stdout_limit = 1024, .stderr_limit = 1024 }));
    try runner.checkDrained();
    try testing.expect(runner.memory.stats().denied > 0);
}

test "finite deadline on a single child returns and releases reservations" {
    var runner = Runner.init(testing.allocator, testing.io);
    // No shell-created descendant; the fixture exits on its own even if
    // deadline handling regresses. Windows uses only the loopback address.
    const args: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "ping.exe", "-n", "4", "127.0.0.1" }
    else
        &.{ "sleep", "3" };
    try testing.expectError(error.TimedOut, runner.run(.{ .argv = args, .timeout_ns = 100 * std.time.ns_per_ms }));
    try runner.checkDrained();
}

test "repeated runs return tracked allocation and reservation counts to zero" {
    var first = Runner.init(testing.allocator, testing.io);
    var second = Runner.init(testing.allocator, testing.io);
    const args: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/d", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    for (0..12) |_| {
        {
            var outcome = try first.run(.{ .argv = args });
            defer outcome.deinit();
            try testing.expect(outcome.succeeded());
            try second.checkDrained();
        }
        try first.checkDrained();
    }
    first.requestStop();
    try first.finishStop();
    {
        var outcome = try second.run(.{ .argv = args });
        defer outcome.deinit();
        try testing.expect(outcome.succeeded());
    }
    try second.checkDrained();
}
