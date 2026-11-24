//! Read-only Subversion provider.
//!
//! Subversion is centralised: the workspace root is a working copy, the
//! revision is the working copy revision, and the reference is the URL path
//! relative to the repository root (`^/trunk/...`). Nothing here contacts the
//! server; `svn status` and `svn info` read local metadata only.

const std = @import("std");
const capabilities = @import("vcs_capabilities");
const cli = @import("vcs_cli");
const test_config = @import("vcs_test_config");
const detect = @import("vcs_detect");
const identity = @import("vcs_identity");
const contract = @import("vcs_provider");
const run = @import("pulse_process");

pub const limit = 8 * 1024 * 1024;

pub const Info = struct {
    revision: ?identity.RevisionId = null,
    relative_url: contract.Text = .{},
};

pub fn parseRevision(text: []const u8) ?identity.RevisionId {
    const trimmed = std.mem.trim(u8, text, " \r\n\t");
    if (trimmed.len == 0 or trimmed.len > 20) return null;
    for (trimmed) |byte| {
        if (!std.ascii.isDigit(byte)) return null;
    }
    return identity.RevisionId.init(.svn, trimmed) catch null;
}

/// Counts `wc-status` items. Subversion's XML is the machine format; only the
/// attribute values this provider reports are inspected, so no general XML
/// parser (and no external entity handling) is involved.
pub fn countStatus(xml: []const u8, changes: *contract.Changes) void {
    changes.modified += countItem(xml, "modified");
    // SVN schedules changes in its working copy; it has no Git staging index.
    changes.modified += countItem(xml, "added") + countItem(xml, "replaced");
    changes.untracked += countItem(xml, "unversioned");
    changes.conflicted += countItem(xml, "conflicted") + @as(u32, @intCast(std.mem.count(u8, xml, "tree-conflicted=\"true\"")));
    changes.modified += countItem(xml, "deleted") + countItem(xml, "missing");
}

fn countItem(xml: []const u8, item: []const u8) u32 {
    var needle_buffer: [64]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buffer, "item=\"{s}\"", .{item}) catch return 0;
    return @intCast(std.mem.count(u8, xml, needle));
}

pub const Svn = struct {
    runner: *run.Runner,
    executable: identity.Path,
    probe: detect.Probe,

    pub fn init(runner: *run.Runner, executable: identity.Path, probe: detect.Probe) Svn {
        return .{ .runner = runner, .executable = executable, .probe = probe };
    }

    pub fn provider(self: *Svn) contract.Provider {
        return .{
            .kind = .svn,
            .display_name = "Subversion",
            .capabilities = declaredCapabilities(),
            .vtable = .{ .detect = detectImpl, .summarize = summarizeImpl },
            .ctx = self,
        };
    }

    pub fn summarize(self: *Svn, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        if (workspace.kind != .svn) return error.Unsupported;

        var snapshot = contract.Snapshot{ .availability = .ready, .workspace = workspace.* };
        {
            var revision_outcome = try self.query(&.{
                self.executable.slice(), "info", "--show-item", "revision", workspace.root.slice(),
            });
            defer revision_outcome.deinit();
            if (!revision_outcome.succeeded()) return mapFailure(revision_outcome.stderr);
            snapshot.revision = parseRevision(revision_outcome.stdout) orelse return error.Parse;
        }
        {
            var url_outcome = try self.query(&.{
                self.executable.slice(), "info", "--show-item", "relative-url", workspace.root.slice(),
            });
            defer url_outcome.deinit();
            if (!url_outcome.succeeded()) return mapFailure(url_outcome.stderr);
            snapshot.reference = contract.Text.init(std.mem.trim(u8, url_outcome.stdout, " \r\n\t")) catch return error.Parse;
        }
        {
            var status_outcome = try self.query(&.{
                self.executable.slice(), "status", "--xml", "--no-ignore", workspace.root.slice(),
            });
            defer status_outcome.deinit();
            if (!status_outcome.succeeded()) return mapFailure(status_outcome.stderr);
            countStatus(status_outcome.stdout, &snapshot.changes);
        }
        return snapshot;
    }

    fn query(self: *Svn, argv: []const []const u8) contract.Error!run.Outcome {
        return self.runner.run(.{
            .argv = argv,
            .timeout_ns = 15 * std.time.ns_per_s,
            .stdout_limit = limit,
            .stderr_limit = 64 * 1024,
        }) catch |err| return mapRunError(err);
    }

    fn detectImpl(ctx: *anyopaque, start_directory: []const u8, out: *detect.Result) void {
        const self: *Svn = @ptrCast(@alignCast(ctx));
        const all = detect.detect(start_directory, self.probe);
        for (all.slice()) |candidate| {
            if (candidate.kind == .svn) out.add(candidate);
        }
    }

    fn summarizeImpl(ctx: *anyopaque, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        const self: *Svn = @ptrCast(@alignCast(ctx));
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
        error.OutputTooLong => error.ResourceLimit,
        error.OutOfMemory => error.OutOfMemory,
        error.PermissionDenied => error.Permission,
        error.InvalidRequest, error.Io => error.Io,
        error.Stopped, error.Cancelled => error.Cancelled,
        error.Busy, error.ConcurrencyUnavailable, error.NoPendingTask => error.Io,
        error.OutputBudgetExceeded => error.ResourceLimit,
    };
}

fn mapFailure(stderr: []const u8) contract.Error {
    if (std.mem.indexOf(u8, stderr, "is not a working copy") != null) return error.NotConnected;
    if (std.mem.indexOf(u8, stderr, "E155007") != null) return error.NotConnected;
    if (std.mem.indexOf(u8, stderr, "E170001") != null) return error.Permission;
    if (std.mem.indexOf(u8, stderr, "E215004") != null) return error.Permission;
    return error.Parse;
}

fn fakeLookup(_: *anyopaque, _: []const u8) detect.EntryType {
    return .missing;
}

test "counts status items from svn xml" {
    const xml =
        "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" ++
        "<status>\n" ++
        "<target path=\".\">\n" ++
        "<entry path=\"src/main.c\"><wc-status item=\"modified\" props=\"none\" revision=\"12\"/></entry>\n" ++
        "<entry path=\"new.txt\"><wc-status item=\"added\" props=\"none\" revision=\"-1\"/></entry>\n" ++
        "<entry path=\"gone.txt\"><wc-status item=\"deleted\" props=\"none\" revision=\"12\"/></entry>\n" ++
        "<entry path=\"other.txt\"><wc-status item=\"unversioned\" props=\"none\"/></entry>\n" ++
        "<entry path=\"conflict.txt\"><wc-status item=\"conflicted\" props=\"none\" tree-conflicted=\"true\" revision=\"12\"/></entry>\n" ++
        "</target>\n</status>\n";

    var changes = contract.Changes{};
    countStatus(xml, &changes);
    try std.testing.expectEqual(@as(u32, 0), changes.staged);
    try std.testing.expectEqual(@as(u32, 3), changes.modified);
    try std.testing.expectEqual(@as(u32, 1), changes.untracked);
    try std.testing.expectEqual(@as(u32, 2), changes.conflicted);
}

test "revision text is normalised and validated" {
    const revision = parseRevision("  4211\n") orelse return error.TestExpectedRevision;
    try std.testing.expectEqualStrings("4211", revision.slice());
    try std.testing.expect(parseRevision("not-a-number") == null);
}

test "provider declares only read capabilities" {
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var svn = Svn.init(&runner, identity.Path.init("svn") catch unreachable, .{ .ctx = undefined, .lookup = fakeLookup });
    const api = svn.provider();
    try std.testing.expect(api.supports(.status));
    try std.testing.expect(!api.supports(.commit));
    try std.testing.expect(api.kind == .svn);
}

test "a plain directory is reported as not a working copy" {
    const io = std.testing.io;
    const path_value = test_config.path;
    if (path_value.len == 0) return cli.integrationUnavailable(.svn);

    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    const report = cli.detect(io, .svn, path_value, &scratch, &runner) orelse return cli.integrationUnavailable(.svn);
    if (report.version == null) return cli.integrationUnavailable(.svn);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buffer: [identity.max_path_bytes]u8 = undefined;
    const root = try std.fmt.bufPrint(&root_buffer, ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str ++ "{s}", .{tmp.sub_path});

    const workspace = try identity.Workspace.init(.svn, root, root);
    var svn = Svn.init(&runner, report.path, .{ .ctx = undefined, .lookup = fakeLookup });
    try std.testing.expectError(error.NotConnected, svn.summarize(&workspace));
}

test "reads a real local SVN working copy prepared by integration CI" {
    const root = test_config.svn_working_copy;
    if (root.len == 0) return cli.integrationUnavailable(.svn);
    const path_value = test_config.path;
    if (path_value.len == 0) return cli.integrationUnavailable(.svn);
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    const report = cli.detect(std.testing.io, .svn, path_value, &scratch, &runner) orelse return cli.integrationUnavailable(.svn);
    if (report.version == null) return cli.integrationUnavailable(.svn);
    const workspace = try identity.Workspace.init(.svn, root, root);
    var svn = Svn.init(&runner, report.path, .{ .ctx = undefined, .lookup = fakeLookup });
    var session = @import("vcs_session").Session.init(std.testing.io, 1000, testSessionClock);
    defer session.shutdown();
    _ = try session.request(svn.provider(), &workspace);
    try std.testing.expect(try session.startNext());
    const publication = try session.awaitActive();
    if (publication == .failed) return publication.failed;
    try std.testing.expect(publication == .published);
    const snapshot = session.lookup(&workspace).fresh;
    try std.testing.expectEqual(contract.Availability.ready, snapshot.availability);
    try std.testing.expect(snapshot.revision != null);
    try std.testing.expectEqual(@as(u32, 1), snapshot.changes.modified);
    try std.testing.expectEqual(@as(u32, 1), snapshot.changes.untracked);
}

fn testSessionClock() i64 {
    return 1000;
}
