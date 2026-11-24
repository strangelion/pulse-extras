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
const detect = @import("vcs_detect");
const identity = @import("vcs_identity");
const contract = @import("vcs_provider");
const run = @import("pulse_process");

pub const limit = 2 * 1024 * 1024;

/// Tab-separated template; `\t` is inside the template string, not the argv
/// separator, so paths with spaces stay unambiguous.
const revision_template =
    "change_id.short() ++ \"\\t\" ++ commit_id ++ \"\\t\" ++ bookmarks.join(\" \") ++ \"\\t\" ++ if(conflict, \"conflict\", \"ok\")";

pub const Revision = struct {
    change_id: contract.Text = .{},
    commit_id: ?identity.RevisionId = null,
    bookmarks: contract.Text = .{},
    conflicted: bool = false,
};

pub fn parseRevision(text: []const u8) Revision {
    var revision = Revision{};
    var fields = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\r\n"), '\t');
    if (fields.next()) |change| revision.change_id = contract.Text.init(change) catch .{};
    if (fields.next()) |commit| revision.commit_id = identity.RevisionId.init(.jj, commit) catch null;
    if (fields.next()) |bookmarks| revision.bookmarks = contract.Text.init(bookmarks) catch .{};
    if (fields.next()) |conflict| revision.conflicted = std.mem.eql(u8, conflict, "conflict");
    return revision;
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

pub const Jj = struct {
    runner: *run.Runner,
    executable: identity.Path,
    probe: detect.Probe,

    pub fn init(runner: *run.Runner, executable: identity.Path, probe: detect.Probe) Jj {
        return .{ .runner = runner, .executable = executable, .probe = probe };
    }

    pub fn provider(self: *Jj) contract.Provider {
        return .{
            .kind = .jj,
            .display_name = "Jujutsu",
            .capabilities = declaredCapabilities(),
            .vtable = .{ .detect = detectImpl, .summarize = summarizeImpl },
            .ctx = self,
        };
    }

    pub fn summarize(self: *Jj, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        if (workspace.kind != .jj) return error.Unsupported;

        var revision_out = try self.query(&.{
            self.executable.slice(), "--ignore-working-copy", "--no-pager", "--color=never",
            "-R",                    workspace.root.slice(),  "log",        "-r",
            "@",                     "--no-graph",            "-T",         revision_template,
        });
        defer revision_out.deinit(self.runner.allocator);
        if (!revision_out.succeeded()) return mapFailure(revision_out.stderr);

        var diff_out = try self.query(&.{
            self.executable.slice(), "--ignore-working-copy", "--no-pager", "--color=never",
            "-R",                    workspace.root.slice(),  "diff",       "--summary",
        });
        defer diff_out.deinit(self.runner.allocator);

        const revision = parseRevision(revision_out.stdout);
        var snapshot = contract.Snapshot{
            .availability = .ready,
            .workspace = workspace.*,
            .revision = revision.commit_id,
            .detail = contract.Text.init("working copy not snapshotted (read-only query)") catch .{},
        };
        snapshot.reference = if (revision.bookmarks.slice().len != 0) revision.bookmarks else revision.change_id;
        if (revision.conflicted) snapshot.changes.conflicted = 1;
        if (!diff_out.succeeded()) return mapFailure(diff_out.stderr);
        countDiff(diff_out.stdout, &snapshot.changes);
        return snapshot;
    }

    fn query(self: *Jj, argv: []const []const u8) contract.Error!run.Outcome {
        return self.runner.run(.{
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
    return set;
}

fn mapRunError(err: run.Error) contract.Error {
    return switch (err) {
        error.SpawnFailed => error.CliMissing,
        error.TimedOut => error.Timeout,
        error.OutputTooLong => error.Parse,
        error.OutOfMemory => error.OutOfMemory,
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
    const revision = parseRevision("qpvuntsm\t8f3a1c9e2b7d4a6f0c5e8d1b3a7f2c4e9d6b0a1f\tmain feature\tconflict\n");
    try std.testing.expect(revision.change_id.eql("qpvuntsm"));
    try std.testing.expect(revision.bookmarks.eql("main feature"));
    try std.testing.expect(revision.conflicted);
    try std.testing.expect(revision.commit_id != null);
}

test "missing bookmark leaves an empty reference" {
    const revision = parseRevision("abc\tdef\t\tok\n");
    try std.testing.expectEqual(@as(usize, 0), revision.bookmarks.slice().len);
    try std.testing.expect(!revision.conflicted);
}

test "counts diff summary lines and ignores headers" {
    var changes = contract.Changes{};
    countDiff("M src/main.zig\nA new.txt\nD gone.txt\nR old -> new\nC copy\n", &changes);
    try std.testing.expectEqual(@as(u32, 5), changes.modified);
}

test "provider declares only read capabilities" {
    var runner = run.Runner.init(std.testing.allocator);
    var jj = Jj.init(&runner, identity.Path.init("jj") catch unreachable, .{ .ctx = undefined, .lookup = fakeLookup });
    const api = jj.provider();
    try std.testing.expect(api.supports(.status));
    try std.testing.expect(!api.supports(.commit));
    try std.testing.expect(!api.supports(.operation_undo));
}

test "reads a real jj repository without creating snapshots" {
    const io = run.io();
    const environ: std.process.Environ = .{ .block = .global };
    const path_value = environ.getAlloc(std.testing.allocator, "PATH") catch return cli.integrationUnavailable(.jj);
    defer std.testing.allocator.free(path_value);

    var runner = run.Runner.init(std.testing.allocator);
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
    defer init_outcome.deinit(runner.allocator);
    if (!init_outcome.succeeded()) return error.TestCommandFailed;

    const workspace = try identity.Workspace.init(.jj, root, root);
    var jj = Jj.init(&runner, report.path, .{ .ctx = undefined, .lookup = fakeLookup });
    const op_args = &.{ report.path.slice(), "--ignore-working-copy", "--no-pager", "--color=never", "-R", root, "op", "log", "--no-graph", "-T", "id ++ \"\\n\"" };
    var before = try jj.query(op_args);
    defer before.deinit(runner.allocator);
    try std.testing.expect(before.succeeded());
    const dirty = try tmp.dir.createFile(io, "unsnapshotted.txt", .{});
    try dirty.writeStreamingAll(io, "not yet snapshotted\n");
    dirty.close(io);
    const snapshot = try jj.summarize(&workspace);
    var after = try jj.query(op_args);
    defer after.deinit(runner.allocator);
    try std.testing.expect(after.succeeded());
    try std.testing.expectEqualStrings(before.stdout, after.stdout);
    try std.testing.expectEqual(contract.Availability.ready, snapshot.availability);
    try std.testing.expect(snapshot.detail.eql("working copy not snapshotted (read-only query)"));
}
