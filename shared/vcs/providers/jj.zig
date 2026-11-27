//! Read-only Jujutsu provider.
//!
//! Jujutsu snapshots the working copy on most commands, and every snapshot is
//! a new operation. A status panel must never create operations just by being
//! open, so every query here passes `--ignore-working-copy` and the summary is
//! explicitly labelled as not having a fresh working-copy snapshot.
//!
//! Consequence: un-snapshotted edits are invisible to this provider. That is a
//! documented degradation, not a silent "clean" answer.

const std = @import("std");
const capabilities = @import("vcs_capabilities");
const cli = @import("vcs_cli");
const test_config = @import("vcs_test_config");
const detect = @import("vcs_detect");
const identity = @import("vcs_identity");
const contract = @import("vcs_provider");
const run = @import("pulse_process");

pub const limit = 2 * 1024 * 1024;

/// Tab-separated template; `\t` is inside the template string, not the argv
/// separator, so paths with spaces stay unambiguous.
pub const revision_template =
    "change_id.short() ++ \"\\t\" ++ commit_id ++ \"\\t\" ++ bookmarks.join(\" \") ++ \"\\t\" ++ if(conflict, \"conflict\", \"ok\")";

pub const Revision = struct {
    change_id: contract.Text = .{},
    commit_id: ?identity.RevisionId = null,
    bookmarks: contract.Text = .{},
    conflicted: bool = false,
};

pub fn parseRevision(text: []const u8) error{Malformed}!Revision {
    var fields = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\r\n"), '\t');
    const change = fields.next() orelse return error.Malformed;
    const commit = fields.next() orelse return error.Malformed;
    const bookmarks = fields.next() orelse return error.Malformed;
    const conflict = fields.next() orelse return error.Malformed;
    if (fields.next() != null or change.len == 0 or commit.len != 40) return error.Malformed;
    for (commit) |byte| {
        if (!std.ascii.isDigit(byte) and !(byte >= 'a' and byte <= 'f')) return error.Malformed;
    }
    if (!std.mem.eql(u8, conflict, "ok") and !std.mem.eql(u8, conflict, "conflict")) return error.Malformed;
    for (change) |byte| {
        if (byte < 'a' or byte > 'z') return error.Malformed;
    }
    if (std.mem.indexOfAny(u8, bookmarks, "\r\n") != null) return error.Malformed;
    return .{
        .change_id = contract.Text.init(change) catch return error.Malformed,
        .commit_id = identity.RevisionId.init(.jj, commit) catch return error.Malformed,
        .bookmarks = contract.Text.init(bookmarks) catch return error.Malformed,
        .conflicted = std.mem.eql(u8, conflict, "conflict"),
    };
}

/// `jj diff --summary` lines are `<letter> <path>`; letters are M/A/D/R/C.
pub fn countDiff(text: []const u8, changes: *contract.Changes) void {
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (line.len < 2) continue;
        switch (line[0]) {
            'M', 'A', 'D', 'R', 'C' => changes.modified += 1,
            else => {},
        }
    }
}

/// JJ summary is display-only, especially compact rename expressions.
pub fn listDiff(text: []const u8, files: *contract.FileList) void {
    files.* = .{ .available = true };
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        if (line.len == 0) continue;
        if (line.len < 3 or line[1] != ' ') {
            files.omit();
            continue;
        }
        const kind: contract.FileList.Kind = switch (line[0]) {
            'M' => .modified,
            'A' => .added,
            'D' => .deleted,
            'R' => .renamed,
            'C' => .copied,
            else => .unknown,
        };
        files.add(line[2..], "", .{ .path = .{}, .kind = kind });
    }
}

pub const Jj = struct {
    runner: *run.Runner,
    executable: identity.Path,
    probe: detect.Probe,
    execution: cli.Execution = .compatibility,
    operation: contract.Text = .{},

    pub fn init(runner: *run.Runner, executable: identity.Path, probe: detect.Probe) Jj {
        return .{ .runner = runner, .executable = executable, .probe = probe };
    }

    /// Caller keeps approved Runner and environment alive through session join.
    pub fn initApproved(runner: *run.Runner, executable: identity.Path, probe: detect.Probe, execution: cli.Execution) error{UnapprovedExecutable}!Jj {
        if (execution != .approved or runner.policy != .approved_local) return error.UnapprovedExecutable;
        return .{ .runner = runner, .executable = executable, .probe = probe, .execution = execution };
    }

    pub fn provider(self: *Jj) contract.Provider {
        return .{
            .kind = .jj,
            .display_name = "Jujutsu",
            .capabilities = declaredCapabilities(),
            .vtable = .{ .detect = detectImpl, .summarize = summarizeImpl, .detail = detailImpl },
            .ctx = self,
        };
    }

    pub fn summarize(self: *Jj, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        if (workspace.kind != .jj) return error.Unsupported;

        self.operation = .{};
        var pin_command: contract.DetailCommand = .{};
        const pin = blk: {
            var outcome = try self.query(try pin_command.build(.jj, self.executable.slice(), workspace.root.slice(), &.{ .kind = .jj_pin }));
            defer outcome.deinit();
            if (!outcome.succeeded()) return mapFailure(outcome.stderr);
            const text = std.mem.trim(u8, outcome.stdout, " \r\n\t");
            if (!contract.safeOperation(text)) return error.Parse;
            break :blk contract.Text.init(text) catch return error.Parse;
        };
        const revision = blk: {
            var command: contract.DetailCommand = .{};
            var outcome = try self.query(try command.build(.jj, self.executable.slice(), workspace.root.slice(), &.{ .kind = .jj_status_revision, .operation = pin }));
            defer outcome.deinit();
            if (!outcome.succeeded()) return mapFailure(outcome.stderr);
            const parsed = parseRevision(outcome.stdout) catch return error.Parse;
            if (parsed.commit_id == null or parsed.change_id.slice().len == 0) return error.Parse;
            break :blk parsed;
        };
        var diff_command: contract.DetailCommand = .{};
        var diff_out = try self.query(try diff_command.build(.jj, self.executable.slice(), workspace.root.slice(), &.{ .kind = .jj_status_diff, .operation = pin, .revision = revision.commit_id }));
        defer diff_out.deinit();

        var snapshot = contract.Snapshot{
            .availability = .ready,
            .workspace = workspace.*,
            .revision = revision.commit_id,
            .operation = pin,
            .detail = contract.Text.init("working copy not snapshotted (read-only query)") catch .{},
        };
        snapshot.reference = if (revision.bookmarks.slice().len != 0) revision.bookmarks else revision.change_id;
        snapshot.has_conflict = revision.conflicted;
        snapshot.counts = .{
            .staged = .unsupported,
            .modified = .ready,
            .untracked = .not_queried,
            .conflicted = .unknown,
            .ahead = .not_queried,
            .behind = .not_queried,
        };
        if (!diff_out.succeeded()) return mapFailure(diff_out.stderr);
        countDiff(diff_out.stdout, &snapshot.changes);
        listDiff(diff_out.stdout, &snapshot.files);
        self.operation = pin;
        return snapshot;
    }

    fn query(self: *Jj, argv: []const []const u8) contract.Error!run.Outcome {
        return self.execution.execute(self.runner, .{
            .argv = argv,
            .timeout_ns = 10 * std.time.ns_per_s,
            .stdout_limit = limit,
            .stderr_limit = 64 * 1024,
        }) catch |err| return mapRunError(err);
    }

    fn detectImpl(ctx: *anyopaque, start_directory: []const u8, out: *detect.Result) void {
        const self: *Jj = @ptrCast(@alignCast(ctx));
        const all = detect.detect(start_directory, self.probe);
        for (all.slice()) |candidate| {
            if (candidate.kind == .jj) out.add(candidate);
        }
    }

    fn detailImpl(ctx: *anyopaque, workspace: *const identity.Workspace, request: *const contract.DetailRequest) contract.Error!contract.DetailText {
        const self: *Jj = @ptrCast(@alignCast(ctx));
        if (workspace.kind != .jj or !contract.detailSupported(.jj, request.kind)) return error.Unsupported;
        var command: contract.DetailCommand = .{};
        if (!contract.safeOperation(self.operation.slice())) return error.Stale;
        var pinned = request.*;
        pinned.operation = self.operation;
        const argv = try command.build(.jj, self.executable.slice(), workspace.root.slice(), &pinned);
        const history = request.kind == .history or request.kind == .file_history;
        var outcome = self.execution.execute(self.runner, .{ .argv = argv, .timeout_ns = 10 * std.time.ns_per_s, .stdout_limit = if (history) 128 * 1024 else contract.DetailText.capacity, .stderr_limit = 64 * 1024 }) catch |err| return mapRunError(err);
        defer outcome.deinit();
        if (!outcome.succeeded()) {
            if (@import("builtin").is_test and self.execution == .compatibility) std.debug.print("VCS fixture detail {s}: exit={any}, stderr={s}\n", .{ @tagName(request.kind), outcome.exit_code, outcome.stderr[0..@min(outcome.stderr.len, 1024)] });
            return mapFailure(outcome.stderr);
        }
        var remaining: []const u8 = outcome.stdout;
        if (history) {
            for (0..request.offset) |_| {
                const end = std.mem.indexOfScalar(u8, remaining, '\n') orelse {
                    remaining = "";
                    break;
                };
                remaining = remaining[end + 1 ..];
            }
        }
        return contract.DetailText.init(remaining);
    }

    fn summarizeImpl(ctx: *anyopaque, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        const self: *Jj = @ptrCast(@alignCast(ctx));
        return self.summarize(workspace);
    }
};

fn declaredCapabilities() capabilities.Set {
    var set: capabilities.Set = .empty;
    set.insert(.repository_detection);
    set.insert(.workspace_detection);
    set.insert(.status);
    set.insert(.history);
    set.insert(.file_history);
    set.insert(.diff);
    set.insert(.revision_content);
    set.insert(.bookmarks);
    set.insert(.workspaces);
    set.insert(.operation_history);
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
    if (std.mem.indexOf(u8, stderr, "There is no jj repo") != null) return error.NotConnected;
    if (std.mem.indexOf(u8, stderr, "Permission denied") != null) return error.Permission;
    if (std.mem.indexOf(u8, stderr, "not found") != null) return error.NotConnected;
    return error.Parse;
}

fn fakeLookup(_: *anyopaque, _: []const u8) detect.EntryType {
    return .missing;
}

test "parses revision fields with bookmarks and conflict" {
    const revision = try parseRevision("qpvuntsm\t8f3a1c9e2b7d4a6f0c5e8d1b3a7f2c4e9d6b0a1f\tmain feature\tconflict\n");
    try std.testing.expect(revision.change_id.eql("qpvuntsm"));
    try std.testing.expect(revision.bookmarks.eql("main feature"));
    try std.testing.expect(revision.conflicted);
    try std.testing.expect(revision.commit_id != null);
}

test "missing bookmark leaves an empty reference" {
    const revision = try parseRevision("abc\t1111111111111111111111111111111111111111\t\tok\n");
    try std.testing.expectEqual(@as(usize, 0), revision.bookmarks.slice().len);
    try std.testing.expect(!revision.conflicted);
}

test "counts diff summary lines and ignores headers" {
    var changes = contract.Changes{};
    countDiff("M src/main.zig\nA new.txt\nD gone.txt\nR old -> new\nC copy\n", &changes);
    try std.testing.expectEqual(@as(u32, 5), changes.modified);
}

test "provider declares only read capabilities" {
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var jj = Jj.init(&runner, identity.Path.init("jj") catch unreachable, .{ .ctx = undefined, .lookup = fakeLookup });
    const api = jj.provider();
    try std.testing.expect(api.supports(.status));
    try std.testing.expect(!api.supports(.commit));
    try std.testing.expect(!api.supports(.operation_undo));
}

test "reads a real jj repository without creating snapshots" {
    const io = std.testing.io;
    const path_value = test_config.path;
    if (path_value.len == 0) return cli.integrationUnavailable(.jj);

    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    const report = cli.detect(io, .jj, path_value, &scratch, &runner) orelse return cli.integrationUnavailable(.jj);
    if (report.version == null) return cli.integrationUnavailable(.jj);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [identity.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str ++ "{s}", .{tmp.sub_path});

    var init_outcome = try runner.run(.{
        .argv = &.{ report.path.slice(), "git", "init", root },
        .timeout_ns = 20 * std.time.ns_per_s,
    });
    defer init_outcome.deinit();
    if (!init_outcome.succeeded()) return error.TestCommandFailed;

    const workspace = try identity.Workspace.init(.jj, root, root);
    var jj = Jj.init(&runner, report.path, .{ .ctx = undefined, .lookup = fakeLookup });
    const tracked = try tmp.dir.createFile(io, "tracked.txt", .{});
    try tracked.writeStreamingAll(io, "recorded\n");
    tracked.close(io);
    {
        var record = try runner.run(.{ .argv = &.{ report.path.slice(), "-R", root, "describe", "-m", "recorded fixture" }, .timeout_ns = 20 * std.time.ns_per_s });
        defer record.deinit();
        if (!record.succeeded()) return error.TestCommandFailed;
    }
    const op_args: []const []const u8 = &.{ report.path.slice(), "--ignore-working-copy", "--no-pager", "--color=never", "-R", root, "op", "log", "--no-graph", "-T", "id ++ \"\\n\"" };
    var before = try jj.query(op_args);
    defer before.deinit();
    try std.testing.expect(before.succeeded());
    const dirty = try tmp.dir.createFile(io, "unsnapshotted.txt", .{});
    try dirty.writeStreamingAll(io, "not yet snapshotted\n");
    dirty.close(io);
    var session = @import("vcs_session").Session.init(std.testing.io, 1000, testSessionClock);
    defer session.shutdown();
    _ = try session.request(jj.provider(), &workspace);
    try std.testing.expect(try session.startNext());
    const publication = try session.awaitActive();
    if (publication == .failed) return publication.failed;
    try std.testing.expect(publication == .published);
    const snapshot = session.lookup(&workspace).fresh;
    const revision = snapshot.revision orelse return error.TestExpectedRevision;
    try std.testing.expect(contract.safeOperation(snapshot.operation.slice()));
    const path = try identity.Path.init("tracked.txt");
    const file_history = try jj.provider().detail(&workspace, &.{ .kind = .file_history, .revision = revision, .path = path });
    try std.testing.expect(std.mem.indexOf(u8, file_history.slice(), revision.slice()) != null);
    const content = try jj.provider().detail(&workspace, &.{ .kind = .content, .revision = revision, .path = path });
    try std.testing.expectEqualStrings("recorded\n", content.slice());
    const diff = try jj.provider().detail(&workspace, &.{ .kind = .revision_diff, .revision = revision, .path = path });
    try std.testing.expect(std.mem.indexOf(u8, diff.slice(), "+recorded") != null);
    _ = try jj.provider().detail(&workspace, &.{ .kind = .revision_info, .revision = revision });
    const history = try jj.provider().detail(&workspace, &.{ .kind = .history, .revision = revision });
    try std.testing.expect(std.mem.indexOf(u8, history.slice(), revision.slice()) != null);
    _ = try jj.provider().detail(&workspace, &.{ .kind = .refs });
    _ = try jj.provider().detail(&workspace, &.{ .kind = .workspaces });
    _ = try jj.provider().detail(&workspace, &.{ .kind = .operations });
    var after = try jj.query(op_args);
    defer after.deinit();
    try std.testing.expect(after.succeeded());
    try std.testing.expectEqualStrings(before.stdout, after.stdout);
    try std.testing.expectEqual(contract.Availability.ready, snapshot.availability);
    try std.testing.expect(snapshot.detail.eql("working copy not snapshotted (read-only query)"));
    try std.testing.expect(snapshot.files.available);
    try std.testing.expect(snapshot.files.count >= 1);
}

fn testSessionClock() i64 {
    return 1000;
}

test "revision parser rejects missing unknown or extra fields" {
    try std.testing.expectError(error.Malformed, parseRevision("abc\tdef\t\tok"));
    try std.testing.expectError(error.Malformed, parseRevision("abc\t1111111111111111111111111111111111111111\t\tmaybe"));
    try std.testing.expectError(error.Malformed, parseRevision("abc\t1111111111111111111111111111111111111111\t\tok\textra"));
}

test "JJ recorded summary preserves rename expression and reports unknown records" {
    var files: contract.FileList = .{};
    listDiff("M src/main.zig\nR {old => new}.txt\nX unusual\nheader\n", &files);
    try std.testing.expectEqual(@as(u8, 3), files.count);
    try std.testing.expectEqualStrings("{old => new}.txt", files.slice(files.rows[1].path));
    try std.testing.expectEqual(contract.FileList.Kind.unknown, files.rows[2].kind);
    try std.testing.expectEqual(@as(u32, 1), files.omitted);
}
