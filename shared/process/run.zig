//! Bounded external-process execution for VCS providers and other backends.
//!
//! Every call passes an argv array (never a shell string), a working directory,
//! an optional environment, an output cap and a timeout. The child inherits
//! stdin from `NUL`/`/dev/null`, so a tool that unexpectedly prompts fails
//! instead of hanging on a terminal.
//!
//! The caller owns the I/O runtime and must keep it alive until all work
//! and results have drained. Runner is serialized, not thread-safe. It must
//! remain at a stable address while an Outcome or pending task is alive.
//! A single owner controls admission, await, cancel and stop; it must not
//! access worker-owned fields while pending. No global I/O state.

const std = @import("std");
const Budget = @import("runtime_budget").Budget;
const runtime_allocator = @import("runtime_allocator");
const BoundedAllocator = runtime_allocator.BoundedAllocator;
const windows_tree = @import("process_windows_tree");
const trust = @import("process_trust");
const event_log = @import("runtime_event_log");

pub const default_output_budget: usize = 16 * 1024 * 1024;
pub const default_memory_budget: usize = 32 * 1024 * 1024;
pub const max_live_outcomes: usize = 8;
pub const max_async_arguments: usize = 128;
pub const max_async_argument_bytes: usize = 64 * 1024;
pub const max_environment_entries: usize = 256;
pub const max_environment_bytes: usize = 128 * 1024;
pub const default_max_timeout_ns: u64 = 5 * 60 * std.time.ns_per_s;

/// Explicit-path mode is an admission constraint, not a trust verdict.
/// Callers must still verify the executable and control its configuration.
pub const ExecutionPolicy = enum { compatibility, explicit_local, approved_local };
pub const TreePolicy = enum { direct_child, windows_job };

pub const Request = struct {
    argv: []const []const u8,
    cwd: ?[]const u8 = null,
    /// `null` inherits the parent environment. Explicit maps are validated;
    /// start copies them. Choosing trusted variables remains caller policy.
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
    ContainmentFailed,
    ContainmentUnavailable,
    UnapprovedExecutable,
    UnapprovedEnvironment,
    Stopped,
    Busy,
    Cancelled,
    ConcurrencyUnavailable,
    NoPendingTask,
    OutputBudgetExceeded,
    PermissionDenied,
    Io,
} || std.mem.Allocator.Error;

pub const Runner = struct {
    pub const State = enum { active, stopping, stopped };

    pub const OutputStats = struct {
        reserved_bytes: usize,
        peak_reserved_bytes: usize,
        live_outcomes: usize,
        completed: usize,
        failed: usize,
    };

    pub const Diagnostics = struct {
        state: State,
        pending: bool,
        memory: runtime_allocator.Stats,
        // Worker-owned counters must not be read before join.
        output: ?OutputStats,
    };

    const Pending = struct {
        future: std.Io.Future(Error!Outcome),
        arguments: std.heap.ArenaAllocator,
        environment: ?*std.process.Environ.Map,
    };

    pub const CancelResult = union(enum) {
        cancelled,
        completed_discarded,
        failed: Error,
    };

    memory: BoundedAllocator,
    io: std.Io,
    output_budget: Budget,
    live_outcomes: usize = 0,
    state: State = .active,
    pending: ?Pending = null,
    policy: ExecutionPolicy = .compatibility,
    tree_policy: TreePolicy = .direct_child,
    approval: ?trust.Approval = null,
    log: event_log.Log = .{},
    max_timeout_ns: u64 = default_max_timeout_ns,
    completed: usize = 0,
    failed: usize = 0,

    pub fn init(allocator: std.mem.Allocator, io: std.Io) Runner {
        return initWithBudget(allocator, io, default_output_budget);
    }

    pub fn initWithBudget(allocator: std.mem.Allocator, io: std.Io, output_limit: usize) Runner {
        return initWithLimits(allocator, io, output_limit, default_memory_budget);
    }

    pub fn initWithLimits(allocator: std.mem.Allocator, io: std.Io, output_limit: usize, memory_limit: usize) Runner {
        return .{ .memory = BoundedAllocator.init(allocator, memory_limit), .io = io, .output_budget = Budget.init(output_limit) };
    }

    /// Configure only while idle; no background mutation of admission rules.
    pub fn configure(self: *Runner, policy: ExecutionPolicy, max_timeout_ns: u64) Error!void {
        if (self.state != .active) return error.Stopped;
        if (self.pending != null or self.live_outcomes != 0) return error.Busy;
        if (max_timeout_ns == 0 or policy == .approved_local) return error.InvalidRequest;
        self.approval = null;
        self.policy = policy;
        self.max_timeout_ns = max_timeout_ns;
    }

    /// Approval is an explicit caller decision; never auto-approve PATH.
    pub fn configureApproved(self: *Runner, approval: trust.Approval, max_timeout_ns: u64) Error!void {
        try self.configure(.explicit_local, max_timeout_ns);
        self.approval = approval;
        self.policy = .approved_local;
    }

    pub fn configureTree(self: *Runner, policy: TreePolicy) Error!void {
        if (self.state != .active) return error.Stopped;
        if (self.pending != null or self.live_outcomes != 0) return error.Busy;
        if (policy == .windows_job and (@import("builtin").os.tag != .windows or @import("builtin").cpu.arch != .x86_64)) return error.ContainmentUnavailable;
        self.tree_policy = policy;
    }

    /// Copy a redacted event only when worker-owned log state is available.
    pub fn diagnosticEvent(self: *Runner, index: usize) error{Busy}!?event_log.Record {
        if (self.pending != null) return error.Busy;
        return self.log.get(index);
    }

    /// Owner-thread diagnostic snapshot, without paths, output or credentials.
    /// While a future is outstanding only lock-protected memory stats are read.
    /// No allocation, polling timer or wait for a running command.
    pub fn diagnostics(self: *Runner) Diagnostics {
        return .{
            .state = self.state,
            .pending = self.pending != null,
            .memory = self.memory.stats(),
            .output = if (self.pending != null) null else .{
                .reserved_bytes = self.output_budget.used,
                .peak_reserved_bytes = self.output_budget.peak,
                .live_outcomes = self.live_outcomes,
                .completed = self.completed,
                .failed = self.failed,
            },
        };
    }

    /// All results must be freed before the runner or its I/O owner goes away.
    /// This does not stop external workers: the caller owns their lifecycle.
    pub fn checkDrained(self: *Runner) error{ Busy, OutstandingOutputs, OutstandingAllocations }!void {
        if (self.pending != null) return error.Busy;
        if (self.live_outcomes != 0 or self.output_budget.used != 0) return error.OutstandingOutputs;
        try self.memory.checkDrained();
    }

    /// Owner-thread admission stop. Call cancelPending separately to request
    /// interruption and join a pending task. Outstanding outcomes remain valid.
    pub fn requestStop(self: *Runner) void {
        if (self.state == .active) self.state = .stopping;
    }

    /// Call after any externally owned workers have joined. Refuse to declare
    /// shutdown complete while results or allocator reservations remain.
    pub fn finishStop(self: *Runner) error{ NotStopping, Busy, OutstandingOutputs, OutstandingAllocations }!void {
        if (self.state == .active) return error.NotStopping;
        try self.checkDrained();
        self.state = .stopped;
    }

    /// Synchronous owner-thread entry; never run on a Pulse UI callback.
    pub fn run(self: *Runner, request: Request) Error!Outcome {
        if (self.state != .active) return error.Stopped;
        if (self.pending != null) return error.Busy;
        return self.runInternal(request);
    }

    /// Validate before copying inputs or starting a child. Both entry paths
    /// enforce identical limits. No unbounded argv/environment traversal.
    fn validateRequest(self: *Runner, request: Request) Error!usize {
        if (request.argv.len == 0 or request.argv.len > max_async_arguments or request.argv[0].len == 0 or request.timeout_ns == 0 or request.timeout_ns > self.max_timeout_ns) return error.InvalidRequest;
        if (self.policy != .compatibility) {
            if (!isLocalAbsolute(request.argv[0])) return error.InvalidRequest;
            if (!isLocalAbsolute(request.cwd orelse return error.InvalidRequest)) return error.InvalidRequest;
            if (request.environ_map == null) return error.InvalidRequest;
        }
        if (self.policy == .approved_local) {
            const approval = self.approval orelse return error.UnapprovedExecutable;
            if (!std.mem.eql(u8, approval.path, request.argv[0])) return error.UnapprovedExecutable;
            try trust.validateEnvironment(request.environ_map.?);
        }
        var total: usize = 0;
        for (request.argv) |arg| {
            if (arg.len > max_async_argument_bytes - total or std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidRequest;
            total += arg.len;
        }
        if (request.cwd) |cwd| {
            if (cwd.len == 0 or cwd.len > max_async_argument_bytes - total or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidRequest;
        }
        if (request.environ_map) |environment| try validateEnvironment(environment);
        if (self.live_outcomes >= max_live_outcomes) return error.OutputBudgetExceeded;
        const reservation = std.math.add(usize, request.stdout_limit, request.stderr_limit) catch return error.OutputBudgetExceeded;
        if (reservation > self.output_budget.limit - self.output_budget.used) return error.OutputBudgetExceeded;
        return reservation;
    }

    /// Reserve both output caps during execution, then retain only actual
    /// output bytes until the result is released. The allocator independently
    /// accounts for requested memory, including temporary buffers.
    fn runInternal(self: *Runner, request: Request) Error!Outcome {
        const reservation = try self.validateRequest(request);
        self.output_budget.reserve(reservation) catch return error.OutputBudgetExceeded;
        errdefer self.output_budget.release(reservation);
        errdefer {
            self.failed +|= 1;
        }
        const cwd: std.process.Child.Cwd = if (request.cwd) |path| .{ .path = path } else .inherit;
        const timeout: std.Io.Timeout = .{ .duration = .{ .raw = .fromNanoseconds(request.timeout_ns), .clock = .boot } };

        const options: std.process.RunOptions = .{
            .argv = request.argv,
            .cwd = cwd,
            .environ_map = request.environ_map,
            .stdout_limit = std.Io.Limit.limited(request.stdout_limit),
            .stderr_limit = std.Io.Limit.limited(request.stderr_limit),
            .timeout = timeout,
        };
        if (self.approval) |approval| {
            approval.verify(self.io, request.argv[0]) catch |err| switch (err) {
                error.Canceled => return error.Cancelled,
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.UnapprovedExecutable,
            };
        }
        const result = (if (self.tree_policy == .windows_job)
            windows_tree.run(self.memory.allocator(), self.io, options, request.timeout_ns)
        else
            std.process.run(self.memory.allocator(), self.io, options)) catch |err| switch (err) {
            error.FileNotFound, error.InvalidExe, error.NameTooLong => return error.SpawnFailed,
            error.AccessDenied => return error.PermissionDenied,
            error.StreamTooLong => return error.OutputTooLong,
            error.ContainmentFailed => {
                self.log.add(.{ .kind = .cleanup_failure, .count = 1 });
                return error.ContainmentFailed;
            },
            error.ContainmentUnavailable => return error.ContainmentUnavailable,
            error.Timeout => {
                self.log.add(.{ .kind = .timeout, .count = 1 });
                return error.TimedOut;
            },
            error.Canceled => {
                self.log.add(.{ .kind = .cancelled, .count = 1 });
                return error.Cancelled;
            },
            error.OutOfMemory => {
                self.log.add(.{ .kind = .allocation_limit, .count = 1 });
                return error.OutOfMemory;
            },
            else => return error.Io,
        };

        // Defense in depth: the stdlib should already enforce these caps.
        if (result.stdout.len > request.stdout_limit or result.stderr.len > request.stderr_limit) {
            const allocator = self.memory.allocator();
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return error.OutputTooLong;
        }
        const retained = result.stdout.len + result.stderr.len;
        self.output_budget.release(reservation - retained);
        self.live_outcomes += 1;
        self.completed +|= 1;
        self.log.add(.{ .kind = .admitted, .count = retained });
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
            .reservation = retained,
        };
    }

    /// Exactly one pending job per Runner. The caller-provided I/O runtime
    /// supplies concurrency; no private pool/thread is created here.
    /// Copy argv, cwd and explicit environment before submitting. No outcome
    /// may be live across a pending job, since the worker owns output counters.
    pub fn start(self: *Runner, request: Request) Error!void {
        if (self.state != .active) return error.Stopped;
        if (self.pending != null) return error.Busy;
        if (self.live_outcomes != 0) return error.Busy;
        _ = try self.validateRequest(request);
        var arguments = std.heap.ArenaAllocator.init(self.memory.allocator());
        errdefer arguments.deinit();
        const allocator = arguments.allocator();
        const argv = try allocator.alloc([]const u8, request.argv.len);
        for (request.argv, argv) |arg, *owned| owned.* = try allocator.dupe(u8, arg);
        var owned = request;
        owned.argv = argv;
        if (request.cwd) |cwd| owned.cwd = try allocator.dupe(u8, cwd);
        const environment = if (request.environ_map) |source| try self.copyEnvironment(source) else null;
        errdefer self.freeEnvironment(environment);
        owned.environ_map = environment;

        // After submission the owner must not read/write worker-owned fields.
        // The copied Request points only to this arena; its lifetime extends
        // until the future is joined, including all error/cancel paths.
        const future = try self.io.concurrent(runInternal, .{ self, owned });
        self.pending = .{ .future = future, .arguments = arguments, .environment = environment };
    }

    fn copyEnvironment(self: *Runner, source: *const std.process.Environ.Map) error{OutOfMemory}!*std.process.Environ.Map {
        const allocator = self.memory.allocator();
        const copy = try allocator.create(std.process.Environ.Map);
        errdefer allocator.destroy(copy);
        copy.* = std.process.Environ.Map.init(allocator);
        errdefer copy.deinit();
        try copy.putAll(source);
        return copy;
    }

    fn freeEnvironment(self: *Runner, environment: ?*std.process.Environ.Map) void {
        if (environment) |owned| {
            owned.deinit();
            self.memory.allocator().destroy(owned);
        }
    }

    fn releasePendingInputs(self: *Runner) void {
        const pending = if (self.pending) |*value| value else unreachable;
        self.freeEnvironment(pending.environment);
        pending.arguments.deinit();
        self.pending = null;
    }

    /// Join the task, transfer the owned result once, and release input copies.
    /// Never call this blocking operation from the Pulse UI thread.
    pub fn awaitPending(self: *Runner) Error!Outcome {
        const pending = if (self.pending) |*value| value else return error.NoPendingTask;
        const result = pending.future.await(self.io);
        self.releasePendingInputs();
        if (self.state != .active) {
            if (result) |value| {
                var outcome = value;
                outcome.deinit();
            } else |_| {}
            return error.Stopped;
        }
        return result;
    }

    /// Request cancellation and join. Cancellation is cooperative: a raced
    /// completion still owns a result, so release it rather than leak it.
    /// Return actual completion/failure rather than inventing a cancellation.
    /// This joins one stdlib task, not a Windows Job Object/process tree.
    pub fn cancelPending(self: *Runner) Error!CancelResult {
        const pending = if (self.pending) |*value| value else return error.NoPendingTask;
        const result = pending.future.cancel(self.io);
        self.releasePendingInputs();
        if (result) |value| {
            var outcome = value;
            outcome.deinit();
            return .completed_discarded;
        } else |err| {
            return if (err == error.Cancelled) .cancelled else .{ .failed = err };
        }
    }
};

/// Intentionally reject drive-relative/root-relative and device/UNC paths
/// in strict Windows mode. This is lexical validation, not ACL/reparse proof.
fn isLocalAbsolute(path: []const u8) bool {
    if (@import("builtin").os.tag == .windows) {
        return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
    }
    return path.len != 0 and path[0] == '/';
}

fn validateEnvironment(environment: *const std.process.Environ.Map) error{InvalidRequest}!void {
    var entries = environment.iterator();
    var count: usize = 0;
    var bytes: usize = 0;
    while (entries.next()) |entry| {
        if (count >= max_environment_entries) return error.InvalidRequest;
        count += 1;
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        if (key.len == 0 or key.len > max_environment_bytes - bytes) return error.InvalidRequest;
        bytes += key.len;
        if (value.len > max_environment_bytes - bytes) return error.InvalidRequest;
        bytes += value.len;
        if (std.mem.indexOfScalar(u8, key, 0) != null or std.mem.indexOfScalar(u8, key, '=') != null or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidRequest;
    }
}

const testing = std.testing;

fn cleanupPendingForTest(runner: *Runner) void {
    if (runner.pending != null) _ = runner.cancelPending() catch unreachable;
}

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

test "owned output retains actual bytes and releases the unused capacity" {
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
        const stats = runner.diagnostics().output.?;
        try testing.expectEqual(outcome.stdout.len + outcome.stderr.len, stats.reserved_bytes);
        try testing.expect(stats.reserved_bytes < 2048);
        try testing.expectEqual(@as(usize, 1), stats.live_outcomes);
        // A second request can use capacity returned by the first completion.
        var next = try runner.run(.{ .argv = args, .stdout_limit = 1024, .stderr_limit = 512 });
        defer next.deinit();
        try testing.expect(next.succeeded());
    }
    try runner.checkDrained();
    const stats = runner.diagnostics().output.?;
    try testing.expectEqual(@as(usize, 2048), stats.peak_reserved_bytes);
    try testing.expectEqual(@as(usize, 0), stats.reserved_bytes);
    try testing.expectEqual(@as(usize, 2), stats.completed);
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

test "async task owns input and transfers output only once" {
    var runner = Runner.init(testing.allocator, testing.io);
    var message: [32]u8 = undefined;
    const original = try std.fmt.bufPrint(&message, "echo owned-input", .{});
    const argv: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/d", "/c", original }
    else
        &.{ "sh", "-c", original };
    try runner.start(.{ .argv = argv });
    defer cleanupPendingForTest(&runner);
    // No lifetime dependency on the caller's stack-backed argument.
    @memset(&message, 'x');
    try testing.expectError(error.Busy, runner.start(.{ .argv = argv }));
    try testing.expectError(error.Busy, runner.run(.{ .argv = argv }));
    try testing.expectError(error.Busy, runner.checkDrained());
    const pending_stats = runner.diagnostics();
    try testing.expect(pending_stats.pending);
    try testing.expect(pending_stats.output == null);
    try testing.expectError(error.Busy, runner.configure(.explicit_local, default_max_timeout_ns));
    {
        var outcome = try runner.awaitPending();
        defer outcome.deinit();
        try testing.expect(outcome.succeeded());
        try testing.expect(std.mem.indexOf(u8, outcome.stdout, "owned-input") != null);
        try testing.expectError(error.NoPendingTask, runner.awaitPending());
        try testing.expectError(error.Busy, runner.start(.{ .argv = argv }));
    }
    try runner.checkDrained();
}

test "async admission failure releases input arena and permits retry" {
    var runner = Runner.initWithLimits(testing.allocator, testing.io, 2048, 0);
    try testing.expectError(error.OutOfMemory, runner.start(.{ .argv = &.{"never-start"}, .stdout_limit = 1024, .stderr_limit = 1024 }));
    try runner.checkDrained();
    try testing.expectError(error.NoPendingTask, runner.cancelPending());
    try testing.expectError(error.InvalidRequest, runner.start(.{ .argv = &.{"bad\x00arg"} }));
}

test "async cancellation joins and releases resources; stop is owner-local" {
    var first = Runner.init(testing.allocator, testing.io);
    var second = Runner.init(testing.allocator, testing.io);
    const slow: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "ping.exe", "-n", "5", "127.0.0.1" }
    else
        &.{ "sleep", "4" };
    try first.start(.{ .argv = slow });
    defer cleanupPendingForTest(&first);
    // Allow the finite single-child fixture to enter blocking I/O.
    try std.Io.sleep(testing.io, .fromMilliseconds(100), .boot);
    first.requestStop();
    try testing.expectError(error.Busy, first.finishStop());
    const cancellation = try first.cancelPending();
    try testing.expect(cancellation == .cancelled);
    try first.finishStop();
    try testing.expectError(error.Stopped, first.start(.{ .argv = slow }));
    const quick: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/d", "/c", "echo independent" }
    else
        &.{ "sh", "-c", "echo independent" };
    {
        var outcome = try second.run(.{ .argv = quick });
        defer outcome.deinit();
        try testing.expect(outcome.succeeded());
    }
    try second.checkDrained();
}

test "pending stop discards even a successful raced result" {
    var runner = Runner.init(testing.allocator, testing.io);
    const args: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/d", "/c", "echo hello" }
    else
        &.{ "sh", "-c", "echo hello" };
    try runner.start(.{ .argv = args });
    defer cleanupPendingForTest(&runner);
    runner.requestStop();
    try testing.expectError(error.Stopped, runner.awaitPending());
    try runner.finishStop();
}

test "synchronous and async admission reject invalid input before spawning" {
    var runner = Runner.init(testing.allocator, testing.io);
    try testing.expectError(error.InvalidRequest, runner.run(.{ .argv = &.{"never-start\x00"} }));
    try testing.expectError(error.InvalidRequest, runner.start(.{ .argv = &.{"never-start"}, .cwd = "" }));
    try testing.expectError(error.OutputBudgetExceeded, runner.start(.{ .argv = &.{"never-start"}, .stdout_limit = std.math.maxInt(usize), .stderr_limit = 1 }));
    try runner.checkDrained();
}

test "async environment copy survives source mutation and frees on join" {
    var runner = Runner.init(testing.allocator, testing.io);
    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    try environment.put("PULSE_RUNTIME_TEST", "owned-env");
    const args: []const []const u8 = if (@import("builtin").os.tag == .windows)
        &.{ "cmd", "/d", "/c", "echo %PULSE_RUNTIME_TEST%" }
    else
        &.{ "sh", "-c", "printf '%s' \"$PULSE_RUNTIME_TEST\"" };
    try runner.start(.{ .argv = args, .environ_map = &environment });
    defer cleanupPendingForTest(&runner);
    try environment.put("PULSE_RUNTIME_TEST", "changed");
    {
        var outcome = try runner.awaitPending();
        defer outcome.deinit();
        try testing.expect(outcome.succeeded());
        try testing.expect(std.mem.indexOf(u8, outcome.stdout, "owned-env") != null);
        try testing.expect(std.mem.indexOf(u8, outcome.stdout, "changed") == null);
    }
    try runner.checkDrained();
}

test "oversized and malformed explicit environments are rejected before copy" {
    var runner = Runner.init(testing.allocator, testing.io);
    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    const oversized = try testing.allocator.alloc(u8, max_environment_bytes);
    defer testing.allocator.free(oversized);
    @memset(oversized, 'x');
    try environment.put("PULSE_RUNTIME_TEST", oversized);
    try testing.expectError(error.InvalidRequest, runner.start(.{ .argv = &.{"never-start"}, .environ_map = &environment }));
    try runner.checkDrained();
}

test "execution policy rejects inherited environment and relative paths before spawn" {
    var runner = Runner.init(testing.allocator, testing.io);
    try testing.expectError(error.InvalidRequest, runner.configure(.explicit_local, 0));
    try runner.configure(.explicit_local, std.time.ns_per_s);
    const exe = if (@import("builtin").os.tag == .windows) "C:\\never-start.exe" else "/never-start";
    const cwd = if (@import("builtin").os.tag == .windows) "C:\\workspace" else "/workspace";
    var environment = std.process.Environ.Map.init(testing.allocator);
    defer environment.deinit();
    try testing.expectError(error.InvalidRequest, runner.run(.{ .argv = &.{"never-start"}, .cwd = cwd, .environ_map = &environment, .timeout_ns = 1 }));
    try testing.expectError(error.InvalidRequest, runner.start(.{ .argv = &.{exe}, .cwd = ".", .environ_map = &environment, .timeout_ns = 1 }));
    try testing.expectError(error.InvalidRequest, runner.start(.{ .argv = &.{exe}, .cwd = cwd, .timeout_ns = 1 }));
    try testing.expectError(error.InvalidRequest, runner.run(.{ .argv = &.{exe}, .cwd = cwd, .environ_map = &environment, .timeout_ns = 2 * std.time.ns_per_s }));
    try testing.expectEqual(@as(usize, 5 * 1024 * 1024), try runner.validateRequest(.{ .argv = &.{exe}, .cwd = cwd, .environ_map = &environment, .timeout_ns = 1 }));
    try runner.checkDrained();
    try testing.expectEqual(@as(usize, 0), runner.diagnostics().output.?.completed);
}

test "local absolute path validation does not accept Windows drive-relative or device paths" {
    if (@import("builtin").os.tag == .windows) {
        try testing.expect(isLocalAbsolute("C:\\tool.exe"));
        try testing.expect(!isLocalAbsolute("C:tool.exe"));
        try testing.expect(!isLocalAbsolute("\\tool.exe"));
        try testing.expect(!isLocalAbsolute("\\\\server\\share\\tool.exe"));
        try testing.expect(!isLocalAbsolute("\\\\?\\C:\\tool.exe"));
    } else {
        try testing.expect(isLocalAbsolute("/usr/bin/tool"));
        try testing.expect(!isLocalAbsolute("./tool"));
    }
    try testing.expect(!isLocalAbsolute(""));
}

test "diagnostics distinguish execution failures from rejected admissions" {
    var runner = Runner.init(testing.allocator, testing.io);
    try testing.expectError(error.InvalidRequest, runner.run(.{ .argv = &.{} }));
    try testing.expectError(error.SpawnFailed, runner.run(.{ .argv = &.{"pulse-extras-does-not-exist-9f3a"} }));
    try runner.checkDrained();
    const stats = runner.diagnostics();
    try testing.expectEqual(@as(usize, 1), stats.output.?.failed);
    try testing.expectEqual(@as(usize, 0), stats.output.?.completed);
    try testing.expectEqual(@as(usize, 0), stats.memory.live_bytes);
    try testing.expect(!stats.pending);
}

test "Windows job policy is explicit and uses the real Runner path" {
    var runner = Runner.init(testing.allocator, testing.io);
    if (@import("builtin").os.tag != .windows or @import("builtin").cpu.arch != .x86_64) {
        try testing.expectError(error.ContainmentUnavailable, runner.configureTree(.windows_job));
        return;
    }
    try runner.configureTree(.windows_job);
    {
        var outcome = try runner.run(.{ .argv = &.{ "cmd", "/d", "/c", "echo owned-tree" } });
        defer outcome.deinit();
        try testing.expect(outcome.succeeded());
        try testing.expect(std.mem.indexOf(u8, outcome.stdout, "owned-tree") != null);
        try testing.expectError(error.Busy, runner.configureTree(.direct_child));
    }
    try runner.checkDrained();
    try testing.expectEqual(event_log.Kind.admitted, (try runner.diagnosticEvent(0)).?.kind);
}

test "approved policy rejects unapproved path and environment before launch" {
    var runner = Runner.init(testing.allocator, testing.io);
    const exe = if (@import("builtin").os.tag == .windows) "C:\\approved.exe" else "/approved";
    const cwd = if (@import("builtin").os.tag == .windows) "C:\\workspace" else "/workspace";
    try runner.configureApproved(.{ .path = exe, .digest = @splat(0) }, std.time.ns_per_s);
    var map = std.process.Environ.Map.init(testing.allocator);
    defer map.deinit();
    try map.put("LD_PRELOAD", "not-allowed");
    try testing.expectError(error.UnapprovedEnvironment, runner.run(.{ .argv = &.{exe}, .cwd = cwd, .environ_map = &map, .timeout_ns = 1 }));
    try runner.checkDrained();
}
