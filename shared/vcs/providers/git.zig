//! Read-only Git contract.
//!
//! Queries suppress optional index writes. This is not a sandbox for Git
//! configuration, filters, or other external helpers. Write operations are added
//! separately, behind the risk model and an explicit plan.

const std = @import("std");
const capabilities = @import("vcs_capabilities");
const cli = @import("vcs_cli");
const test_config = @import("vcs_test_config");
const detect = @import("vcs_detect");
const identity = @import("vcs_identity");
const contract = @import("vcs_provider");
const run = @import("pulse_process");

pub const parse_limit = 4 * 1024 * 1024;

pub const Changes = contract.Changes;

pub const Status = struct {
    branch: contract.Text = .{},
    upstream: contract.Text = .{},
    oid: ?identity.RevisionId = null,
    detached: bool = false,
    seen_oid: bool = false,
    seen_head: bool = false,
    seen_upstream: bool = false,
    seen_ab: bool = false,
    distance_known: bool = false,
    changes: Changes = .{},
};

const ParseError = error{ Malformed, TooManyFields };

/// Parses `git status --porcelain=v2 --branch -z`. Records are NUL separated;
/// a rename record carries its original path as the next record, which this
/// parser skips because only counts and branch data are needed.
pub fn parseStatus(text: []const u8) ParseError!Status {
    if (text.len > parse_limit or (text.len != 0 and text[text.len - 1] != 0)) return error.Malformed;
    var status = Status{};
    var records = std.mem.splitScalar(u8, text, 0);
    while (records.next()) |record| {
        if (record.len == 0) continue;
        switch (record[0]) {
            '#' => try parseHeader(record, &status),
            '1', '2' => {
                const xy = firstField(record, 1) orelse return error.Malformed;
                if (xy.len != 2 or std.mem.indexOfScalar(u8, ".MADRCUT", xy[0]) == null or std.mem.indexOfScalar(u8, ".MADRCUT", xy[1]) == null) return error.Malformed;
                if (record[0] == '2') {
                    const original = records.next() orelse return error.Malformed;
                    if (original.len == 0) return error.Malformed;
                }
                countWorktree(xy, &status.changes);
            },
            'u' => status.changes.conflicted += 1,
            '?' => status.changes.untracked += 1,
            '!' => {},
            else => {},
        }
    }
    return status;
}

fn parseHeader(record: []const u8, status: *Status) ParseError!void {
    const body = std.mem.trimStart(u8, record[1..], " ");
    const split = std.mem.indexOfScalar(u8, body, ' ') orelse return error.Malformed;
    const key = body[0..split];
    const value = body[split + 1 ..];
    if (std.mem.eql(u8, key, "branch.oid")) {
        if (status.seen_oid) return error.Malformed;
        status.seen_oid = true;
        if (std.mem.eql(u8, value, "(initial)")) return;
        if (value.len != 40 and value.len != 64) return error.Malformed;
        for (value) |byte| {
            if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f') and !(byte >= 'A' and byte <= 'F')) return error.Malformed;
        }
        status.oid = identity.RevisionId.init(.git, value) catch return error.Malformed;
    } else if (std.mem.eql(u8, key, "branch.head")) {
        if (status.seen_head) return error.Malformed;
        status.seen_head = true;
        if (std.mem.eql(u8, value, "(detached)")) {
            status.detached = true;
            return;
        }
        if (value.len == 0) return error.Malformed;
        status.branch = contract.Text.init(value) catch return error.Malformed;
    } else if (std.mem.eql(u8, key, "branch.upstream")) {
        if (status.seen_upstream) return error.Malformed;
        status.seen_upstream = true;
        if (value.len == 0) return error.Malformed;
        status.upstream = contract.Text.init(value) catch return error.Malformed;
    } else if (std.mem.eql(u8, key, "branch.ab")) {
        if (status.seen_ab) return error.Malformed;
        status.seen_ab = true;
        status.distance_known = try parseAheadBehind(value, &status.changes);
    }
}

fn parseAheadBehind(value: []const u8, changes: *Changes) ParseError!bool {
    var tokens = std.mem.splitScalar(u8, value, ' ');
    const ahead = tokens.next() orelse return error.Malformed;
    const behind = tokens.next() orelse return error.Malformed;
    if (tokens.next() != null or ahead.len < 2 or behind.len < 2 or ahead[0] != '+' or behind[0] != '-') return error.Malformed;
    if (std.mem.eql(u8, ahead, "+?") and std.mem.eql(u8, behind, "-?")) return false;
    for (ahead[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return error.Malformed;
    }
    for (behind[1..]) |byte| {
        if (!std.ascii.isDigit(byte)) return error.Malformed;
    }
    const a = std.fmt.parseInt(u32, ahead[1..], 10) catch return error.Malformed;
    const b = std.fmt.parseInt(u32, behind[1..], 10) catch return error.Malformed;
    changes.ahead = a;
    changes.behind = b;
    return true;
}

fn firstField(record: []const u8, index: usize) ?[]const u8 {
    var tokens = std.mem.splitScalar(u8, record, ' ');
    var current: usize = 0;
    while (tokens.next()) |token| {
        if (current == index) return token;
        current += 1;
    }
    return null;
}

/// XY: X is the index state, Y the worktree state. `.` means unchanged.
fn countWorktree(xy: []const u8, changes: *Changes) void {
    const index_state = xy[0];
    const worktree_state = xy[1];
    if (index_state != '.') changes.staged += 1;
    if (worktree_state != '.') changes.modified += 1;
}

pub const Git = struct {
    runner: *run.Runner,
    executable: identity.Path,
    probe: detect.Probe,
    execution: cli.Execution = .compatibility,

    pub fn init(runner: *run.Runner, executable: identity.Path, probe: detect.Probe) Git {
        return .{ .runner = runner, .executable = executable, .probe = probe };
    }

    /// Caller keeps approved Runner and environment alive through session join.
    pub fn initApproved(runner: *run.Runner, executable: identity.Path, probe: detect.Probe, execution: cli.Execution) error{UnapprovedExecutable}!Git {
        if (execution != .approved or runner.policy != .approved_local) return error.UnapprovedExecutable;
        return .{ .runner = runner, .executable = executable, .probe = probe, .execution = execution };
    }

    pub fn provider(self: *Git) contract.Provider {
        return .{
            .kind = .git,
            .display_name = "Git",
            .capabilities = declaredCapabilities(),
            .vtable = .{ .detect = detectImpl, .summarize = summarizeImpl },
            .ctx = self,
        };
    }

    /// CLI-reported worktree and common metadata identity, not an OS file ID.
    pub fn resolveWorkspace(self: *Git, directory: []const u8) contract.Error!identity.Workspace {
        var outcome = self.execution.execute(self.runner, .{
            .argv = &.{
                self.executable.slice(),
                "--no-optional-locks",
                "-C",
                directory,
                "rev-parse",
                "--path-format=absolute",
                "--show-toplevel",
                "--git-common-dir",
                "--absolute-git-dir",
            },
            .timeout_ns = 5 * std.time.ns_per_s,
            .stdout_limit = 3 * (identity.max_path_bytes + 2),
            .stderr_limit = 64 * 1024,
        }) catch |err| return mapRunError(err);
        defer outcome.deinit();
        if (!outcome.succeeded()) return mapFailure(outcome.stderr);
        return parseWorkspace(outcome.stdout);
    }

    pub fn summarize(self: *Git, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        if (workspace.kind != .git) return error.Unsupported;
        var outcome = self.execution.execute(self.runner, .{
            .argv = &.{
                self.executable.slice(),
                "--no-optional-locks",
                "-C",
                workspace.root.slice(),
                "status",
                "--porcelain=v2",
                "--branch",
                "-z",
                "--untracked-files=normal",
                "--ignore-submodules=none",
            },
            .timeout_ns = 10 * std.time.ns_per_s,
            .stdout_limit = parse_limit,
            .stderr_limit = 64 * 1024,
        }) catch |err| return mapRunError(err);
        defer outcome.deinit();

        if (!outcome.succeeded()) return mapFailure(outcome.stderr);

        const status = parseStatus(outcome.stdout) catch return error.Parse;
        if (!status.seen_oid or !status.seen_head or (status.detached and status.oid == null)) return error.Parse;
        var snapshot = contract.Snapshot{
            .availability = .ready,
            .workspace = workspace.*,
            .revision = status.oid,
            .changes = status.changes,
            .counts = .{
                .staged = .ready,
                .modified = .ready,
                .untracked = .ready,
                .conflicted = .ready,
                .ahead = if (status.distance_known) .ready else .unknown,
                .behind = if (status.distance_known) .ready else .unknown,
            },
            .has_conflict = status.changes.conflicted != 0,
        };
        snapshot.reference = status.branch;
        if (status.detached) {
            snapshot.detail = contract.Text.init("detached HEAD") catch .{};
        }
        return snapshot;
    }

    fn detectImpl(ctx: *anyopaque, start_directory: []const u8, out: *detect.Result) void {
        const self: *Git = @ptrCast(@alignCast(ctx));
        var all: detect.Result = .{};
        all = detect.detect(start_directory, self.probe);
        for (all.slice()) |candidate| {
            if (candidate.kind == .git) out.add(candidate);
        }
    }

    fn summarizeImpl(ctx: *anyopaque, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        const self: *Git = @ptrCast(@alignCast(ctx));
        return self.summarize(workspace);
    }
};

/// Three absolute paths, no ambiguous extra records.
fn parseWorkspace(output: []const u8) contract.Error!identity.Workspace {
    var lines = std.mem.splitScalar(u8, output, '\n');
    const root = std.mem.trimEnd(u8, lines.next() orelse return error.Parse, "\r");
    const common = std.mem.trimEnd(u8, lines.next() orelse return error.Parse, "\r");
    const metadata = std.mem.trimEnd(u8, lines.next() orelse return error.Parse, "\r");
    if (lines.next()) |tail| {
        if (tail.len != 0 or lines.next() != null) return error.Parse;
    }
    for ([_][]const u8{ root, common, metadata }) |path| {
        if (!std.fs.path.isAbsolute(path) or std.mem.indexOfScalar(u8, path, '\r') != null) return error.Parse;
        _ = identity.Path.init(path) catch return error.Parse;
    }
    var workspace = identity.Workspace.init(.git, root, common) catch return error.Parse;
    workspace.shared_metadata = !std.mem.eql(u8, common, metadata);
    return workspace;
}

fn declaredCapabilities() capabilities.Set {
    var set: capabilities.Set = .empty;
    set.insert(.repository_detection);
    set.insert(.workspace_detection);
    set.insert(.status);
    return set;
}

fn mapRunError(err: run.Error) contract.Error {
    return switch (err) {
        error.SpawnFailed => error.CliMissing,
        error.TimedOut => error.Timeout,
        error.OutputTooLong => error.ResourceLimit,
        error.OutOfMemory => error.OutOfMemory,
        error.PermissionDenied => error.Permission,
        error.InvalidRequest, error.Io, error.ContainmentFailed, error.ContainmentUnavailable => error.Io,
        error.UnapprovedExecutable, error.UnapprovedEnvironment => error.Permission,
        error.Stopped, error.Cancelled => error.Cancelled,
        error.Busy, error.ConcurrencyUnavailable, error.NoPendingTask => error.Io,
        error.OutputBudgetExceeded => error.ResourceLimit,
    };
}

fn mapFailure(stderr: []const u8) contract.Error {
    if (std.mem.indexOf(u8, stderr, "not a git repository") != null) return error.NotConnected;
    if (std.mem.indexOf(u8, stderr, "Permission denied") != null) return error.Permission;
    if (std.mem.indexOf(u8, stderr, "dubious ownership") != null) return error.Permission;
    return error.Parse;
}

test "parses branch, ahead/behind and change counts" {
    const fixture =
        "# branch.oid 7f3a9d2c8e1b6a5f4d3c2b1a0f9e8d7c6b5a4938\x00" ++
        "# branch.head main\x00" ++
        "# branch.upstream origin/main\x00" ++
        "# branch.ab +2 -1\x00" ++
        "1 M. N... 100644 100644 100644 aaaaaaa bbbbbbb src/main.zig\x00" ++
        "1 .M N... 100644 100644 100644 aaaaaaa bbbbbbb docs/notes.md\x00" ++
        "2 R. N... 100644 100644 100644 aaaaaaa bbbbbbb R100 new name.txt\x00old name.txt\x00" ++
        "? untracked file.txt\x00" ++
        "u UU N... 100644 100644 100644 100644 aaaaaaa bbbbbbb ccccccc conflict.txt\x00";

    const status = try parseStatus(fixture);
    try std.testing.expect(status.branch.eql("main"));
    try std.testing.expect(status.upstream.eql("origin/main"));
    try std.testing.expectEqual(@as(u32, 2), status.changes.ahead);
    try std.testing.expectEqual(@as(u32, 1), status.changes.behind);
    try std.testing.expectEqual(@as(u32, 2), status.changes.staged);
    try std.testing.expectEqual(@as(u32, 1), status.changes.modified);
    try std.testing.expectEqual(@as(u32, 1), status.changes.untracked);
    try std.testing.expectEqual(@as(u32, 1), status.changes.conflicted);
    try std.testing.expect(status.oid != null);
}

test "detached head is reported instead of a branch name" {
    const fixture = "# branch.oid 1111111111111111111111111111111111111111\x00# branch.head (detached)\x00";
    const status = try parseStatus(fixture);
    try std.testing.expect(status.detached);
    try std.testing.expect(status.branch.slice().len == 0);
}

test "initial repository has no oid and no changes" {
    const status = try parseStatus("# branch.oid (initial)\x00# branch.head main\x00");
    try std.testing.expect(status.oid == null);
    try std.testing.expectEqual(@as(u32, 0), status.changes.modified);
}

test "records without a known type are ignored, not counted" {
    const status = try parseStatus("# branch.head dev\x00old name.txt\x00# branch.ab +0 -0\x00");
    try std.testing.expectEqual(@as(u32, 0), status.changes.modified + status.changes.untracked + status.changes.conflicted);
}

test "provider declares only implemented capabilities" {
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var git = Git.init(&runner, identity.Path.init("git") catch unreachable, .{ .ctx = undefined, .lookup = fakeLookup });
    const api = git.provider();
    try std.testing.expect(api.supports(.status));
    try std.testing.expect(api.supports(.repository_detection));
    try std.testing.expect(!api.supports(.commit));
    try std.testing.expect(!api.supports(.push));
}

fn fakeLookup(_: *anyopaque, _: []const u8) detect.EntryType {
    return .missing;
}

test "reads a real repository end to end when git is installed" {
    const io = std.testing.io;
    const path_value = test_config.path;
    if (path_value.len == 0) return cli.integrationUnavailable(.git);

    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    const report = cli.detect(io, .git, path_value, &scratch, &runner) orelse return cli.integrationUnavailable(.git);
    if (report.version == null) return cli.integrationUnavailable(.git);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [identity.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&path_buffer, ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str ++ "{s}", .{tmp.sub_path});

    try expectSuccess(&runner, &.{ report.path.slice(), "-C", root, "init", "--quiet" });
    const file = try tmp.dir.createFile(io, "work.txt", .{});
    try file.writeStreamingAll(io, "hello\n");
    file.close(io);
    try expectSuccess(&runner, &.{ report.path.slice(), "-C", root, "add", "work.txt" });
    try expectSuccess(&runner, &.{
        report.path.slice(),               "-C",                   root,
        "-c",                              "user.name=Pulse Test", "-c",
        "user.email=test@example.invalid", "commit",               "--quiet",
        "-m",                              "init",
    });

    var git = Git.init(&runner, report.path, .{ .ctx = undefined, .lookup = fakeLookup });
    const workspace = try git.resolveWorkspace(root);
    try std.testing.expect(std.fs.path.isAbsolute(workspace.root.slice()));
    try std.testing.expect(!workspace.shared_metadata);
    const clean = try git.summarize(&workspace);
    try std.testing.expectEqual(contract.Availability.ready, clean.availability);
    try std.testing.expect(clean.revision != null);
    try std.testing.expectEqual(@as(u32, 0), clean.changes.modified);

    const edited = try tmp.dir.createFile(io, "work.txt", .{});
    try edited.writeStreamingAll(io, "changed\n");
    edited.close(io);

    var session = @import("vcs_session").Session.init(std.testing.io, 1000, testSessionClock);
    defer session.shutdown();
    _ = try session.request(git.provider(), &workspace);
    try std.testing.expect(try session.startNext());
    const publication = try session.awaitActive();
    if (publication == .failed) return publication.failed;
    try std.testing.expect(publication == .published);
    const dirty = session.lookup(&workspace).fresh;
    try std.testing.expectEqual(@as(u32, 1), dirty.changes.modified);

    try expectSuccess(&runner, &.{ report.path.slice(), "-C", root, "worktree", "add", "--detach", "linked", "HEAD" });
    var linked_buffer: [identity.max_path_bytes]u8 = undefined;
    const linked_path = try std.fmt.bufPrint(&linked_buffer, "{s}" ++ std.fs.path.sep_str ++ "linked", .{workspace.root.slice()});
    const linked = try git.resolveWorkspace(linked_path);
    try std.testing.expect(linked.shared_metadata);
    try std.testing.expect(!linked.root.eql(workspace.root.slice()));
    try std.testing.expect(linked.repository_root.eql(workspace.repository_root.slice()));
    const linked_status = try git.summarize(&linked);
    try std.testing.expect(linked_status.revision != null);
}

fn expectSuccess(runner: *run.Runner, argv: []const []const u8) !void {
    var outcome = try runner.run(.{ .argv = argv, .timeout_ns = 20 * std.time.ns_per_s });
    defer outcome.deinit();
    if (!outcome.succeeded()) {
        std.debug.print("command failed: {s}\n{s}\n", .{ argv[0], outcome.stderr });
        return error.TestCommandFailed;
    }
}

test "rename source is a filename, not a status record" {
    const prefix = "2 R. N... 100644 100644 100644 a b R100 new.txt\x00";
    const cases = [_][]const u8{ "? old.txt\x00", "u old.txt\x00", "1 M. old.txt\x00", "2 R. old.txt\x00" };
    for (cases) |original| {
        var buffer: [128]u8 = undefined;
        const fixture = try std.fmt.bufPrint(&buffer, "{s}{s}", .{ prefix, original });
        const result = try parseStatus(fixture);
        try std.testing.expectEqual(@as(u32, 1), result.changes.staged);
        try std.testing.expectEqual(@as(u32, 0), result.changes.untracked + result.changes.conflicted + result.changes.modified);
    }
    try std.testing.expectError(error.Malformed, parseStatus(prefix));
    try std.testing.expectError(error.Malformed, parseStatus("? truncated"));
}

test "malformed known git fields are not silently accepted" {
    try std.testing.expectError(error.Malformed, parseStatus("# branch.oid not-an-oid\x00"));
    try std.testing.expectError(error.Malformed, parseStatus("# branch.head \x00"));
    try std.testing.expectError(error.Malformed, parseStatus("# branch.head bad\xff\x00"));
    try std.testing.expectError(error.Malformed, parseStatus("1 Z. ignored\x00"));
}

fn testSessionClock() i64 {
    return 1000;
}

test "ahead behind counts distinguish zero unknown and malformed" {
    const zero = try parseStatus("# branch.ab +0 -0\x00");
    try std.testing.expect(zero.distance_known);
    const unknown = try parseStatus("# branch.ab +? -?\x00");
    try std.testing.expect(!unknown.distance_known);
    for ([_][]const u8{
        "# branch.ab +1\x00",
        "# branch.ab +1 +2\x00",
        "# branch.ab +4294967296 -0\x00",
        "# branch.ab +0 -0 extra\x00",
        "# branch.ab +? -0\x00",
        "# branch.ab +0 -0\x00# branch.ab +1 -1\x00",
        "# branch.head main\x00# branch.head other\x00",
    }) |fixture| {
        try std.testing.expectError(error.Malformed, parseStatus(fixture));
    }
}

test "workspace identity rejects ambiguous path output" {
    try std.testing.expectError(error.Parse, parseWorkspace("relative\nrelative\nrelative\n"));
    try std.testing.expectError(error.Parse, parseWorkspace("one\ntwo\n"));
    const valid = if (@import("builtin").os.tag == .windows)
        "C:/work\nC:/repo/.git\nC:/repo/.git/worktrees/work\n"
    else
        "/work\n/repo/.git\n/repo/.git/worktrees/work\n";
    const workspace = try parseWorkspace(valid);
    try std.testing.expect(workspace.shared_metadata);
    var buffer: [256]u8 = undefined;
    const extra = try std.fmt.bufPrint(&buffer, "{s}unexpected\n", .{valid});
    try std.testing.expectError(error.Parse, parseWorkspace(extra));
}
