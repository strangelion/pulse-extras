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

const XmlError = error{Malformed};

fn space(byte: u8) bool {
    return std.mem.indexOfScalar(u8, " \t\r\n", byte) != null;
}

fn nameByte(byte: u8) bool {
    return std.ascii.isAlphanumeric(byte) or byte == '-' or byte == '_' or byte == ':' or byte == '.';
}

fn skipSpace(xml: []const u8, index: *usize) void {
    while (index.* < xml.len and space(xml[index.*])) : (index.* += 1) {}
}

fn readName(xml: []const u8, index: *usize) XmlError![]const u8 {
    const start = index.*;
    while (index.* < xml.len and nameByte(xml[index.*])) : (index.* += 1) {}
    if (index.* == start) return error.Malformed;
    return xml[start..index.*];
}

fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Local svn status XML only. Bound depth and bytes, match start/end tags,
/// inspect attributes only on entry/wc-status, reject declarations/entities
/// other than the optional initial XML declaration. Never resolve entities.
/// Commit/author and unrelated attributes are not interpreted. Transactional:
/// malformed output leaves the caller's counts unchanged.
pub fn countStatus(xml: []const u8, changes: *contract.Changes) XmlError!void {
    var files: contract.FileList = .{};
    try parseStatus(xml, changes, &files);
}

/// Decode XML's five built-in entities only. Numeric/custom entities or
/// oversized paths are omitted rather than shown as a different filename.
fn displayPath(raw_path: []const u8, buffer: []u8) ?[]const u8 {
    var input = raw_path;
    var used: usize = 0;
    while (input.len != 0) {
        if (used == buffer.len) return null;
        if (input[0] != '&') {
            buffer[used] = input[0];
            input = input[1..];
        } else {
            const end = std.mem.indexOfScalar(u8, input, ';') orelse return null;
            const entity = input[1..end];
            buffer[used] = if (eq(entity, "amp")) '&' else if (eq(entity, "lt")) '<' else if (eq(entity, "gt")) '>' else if (eq(entity, "quot")) '"' else if (eq(entity, "apos")) '\'' else return null;
            input = input[end + 1 ..];
        }
        used += 1;
    }
    return buffer[0..used];
}

pub fn parseStatus(xml: []const u8, changes: *contract.Changes, files: *contract.FileList) XmlError!void {
    if (xml.len > limit or !std.unicode.utf8ValidateSlice(xml) or std.mem.indexOfScalar(u8, xml, 0) != null) return error.Malformed;
    var parsed: contract.Changes = .{};
    var listed: contract.FileList = .{ .available = true };
    var entry_path: ?[]const u8 = null;
    var stack: [16][]const u8 = undefined;
    var depth: usize = 0;
    var seen_root = false;
    var seen_entry_status = false;
    var index: usize = 0;
    skipSpace(xml, &index);
    if (std.mem.startsWith(u8, xml[index..], "<?xml ")) {
        const end = std.mem.indexOf(u8, xml[index..], "?>") orelse return error.Malformed;
        index += end + 2;
    }
    while (index < xml.len) {
        if (xml[index] != '<') {
            if (depth == 0 and !space(xml[index])) return error.Malformed;
            index += 1;
            continue;
        }
        index += 1;
        if (index >= xml.len) return error.Malformed;
        if (xml[index] == '/') {
            index += 1;
            const tag = try readName(xml, &index);
            skipSpace(xml, &index);
            if (depth == 0 or !eq(stack[depth - 1], tag) or index >= xml.len or xml[index] != '>') return error.Malformed;
            if (eq(tag, "entry") and !seen_entry_status) return error.Malformed;
            depth -= 1;
            index += 1;
            continue;
        }
        const tag = try readName(xml, &index);
        if (depth == 0) {
            if (seen_root or !eq(tag, "status")) return error.Malformed;
            seen_root = true;
        }
        const entry = eq(tag, "entry");
        const wc_status = eq(tag, "wc-status");
        if (entry) {
            if (depth == 0 or (!eq(stack[depth - 1], "target") and !eq(stack[depth - 1], "changelist"))) return error.Malformed;
            seen_entry_status = false;
            entry_path = null;
        }
        if (wc_status and (depth == 0 or !eq(stack[depth - 1], "entry") or seen_entry_status)) return error.Malformed;
        var item: ?[]const u8 = null;
        var props: ?[]const u8 = null;
        var tree_conflict: ?[]const u8 = null;
        var revision: ?[]const u8 = null;
        var closed = false;
        while (true) {
            skipSpace(xml, &index);
            if (index >= xml.len) return error.Malformed;
            if (xml[index] == '>') {
                index += 1;
                break;
            }
            if (xml[index] == '/') {
                index += 1;
                if (index >= xml.len or xml[index] != '>') return error.Malformed;
                index += 1;
                closed = true;
                break;
            }
            const key = try readName(xml, &index);
            skipSpace(xml, &index);
            if (index >= xml.len or xml[index] != '=') return error.Malformed;
            index += 1;
            skipSpace(xml, &index);
            if (index >= xml.len or (xml[index] != '"' and xml[index] != '\'')) return error.Malformed;
            const quote = xml[index];
            index += 1;
            const start = index;
            while (index < xml.len and xml[index] != quote) : (index += 1) {
                if (xml[index] == '<') return error.Malformed;
            }
            if (index >= xml.len) return error.Malformed;
            const value = xml[start..index];
            index += 1;
            if (entry and eq(key, "path")) {
                if (entry_path != null) return error.Malformed;
                entry_path = value;
            }
            if (!wc_status) continue;
            const slot = if (eq(key, "item")) &item else if (eq(key, "props")) &props else if (eq(key, "tree-conflicted")) &tree_conflict else if (eq(key, "revision")) &revision else continue;
            if (slot.* != null) return error.Malformed;
            slot.* = value;
        }
        if (wc_status) {
            const state = item orelse return error.Malformed;
            const property = props orelse return error.Malformed;
            const tree = tree_conflict orelse "false";
            if (!eq(tree, "true") and !eq(tree, "false")) return error.Malformed;
            const conflict = eq(state, "conflicted") or eq(property, "conflicted") or eq(tree, "true");
            if (!eq(property, "none") and !eq(property, "normal") and !eq(property, "modified") and !eq(property, "conflicted")) return error.Malformed;
            const changed = eq(state, "modified") or eq(state, "added") or eq(state, "replaced") or eq(state, "deleted") or eq(state, "missing") or eq(state, "obstructed") or eq(state, "incomplete");
            if (!changed and !eq(state, "conflicted") and !eq(state, "unversioned") and !eq(state, "ignored") and !eq(state, "external") and !eq(state, "normal") and !eq(state, "none")) return error.Malformed;
            if (conflict) {
                parsed.conflicted += 1;
            } else if (eq(state, "unversioned")) {
                parsed.untracked += 1;
            } else if (changed or eq(property, "modified")) {
                parsed.modified += 1;
            }
            const kind: ?contract.FileList.Kind = if (conflict)
                .conflict
            else if (eq(state, "unversioned"))
                .untracked
            else if (eq(state, "ignored"))
                .ignored
            else if (eq(state, "added"))
                .added
            else if (eq(state, "deleted"))
                .deleted
            else if (eq(state, "replaced"))
                .replaced
            else if (eq(state, "missing"))
                .missing
            else if (eq(state, "obstructed"))
                .obstructed
            else if (eq(state, "incomplete"))
                .incomplete
            else if (eq(state, "external"))
                .external
            else if (eq(state, "modified"))
                .modified
            else if (eq(property, "modified"))
                .property
            else
                null;
            if (kind) |value| {
                var buffer: [identity.max_path_bytes]u8 = undefined;
                if (displayPath(entry_path orelse "", &buffer)) |path| {
                    listed.add(path, "", .{ .path = .{}, .kind = value, .property_changed = eq(property, "modified") or eq(property, "conflicted"), .tree_conflict = eq(tree, "true"), .revision = if (revision) |r| std.fmt.parseInt(u64, r, 10) catch null else null });
                } else listed.omit();
            }
            seen_entry_status = true;
        }
        if (closed) {
            if (entry) return error.Malformed;
        } else {
            if (depth == stack.len) return error.Malformed;
            stack[depth] = tag;
            depth += 1;
        }
    }
    if (!seen_root or depth != 0) return error.Malformed;
    changes.* = parsed;
    files.* = listed;
}

pub const Svn = struct {
    runner: *run.Runner,
    executable: identity.Path,
    probe: detect.Probe,
    execution: cli.Execution = .compatibility,

    pub fn init(runner: *run.Runner, executable: identity.Path, probe: detect.Probe) Svn {
        return .{ .runner = runner, .executable = executable, .probe = probe };
    }

    /// Caller keeps approved Runner and environment alive through session join.
    pub fn initApproved(runner: *run.Runner, executable: identity.Path, probe: detect.Probe, execution: cli.Execution) error{UnapprovedExecutable}!Svn {
        if (execution != .approved or runner.policy != .approved_local) return error.UnapprovedExecutable;
        return .{ .runner = runner, .executable = executable, .probe = probe, .execution = execution };
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
                self.executable.slice(), "info", "--non-interactive", "--no-auth-cache", "--show-item", "revision", workspace.root.slice(),
            });
            defer revision_outcome.deinit();
            if (!revision_outcome.succeeded()) return mapFailure(revision_outcome.stderr);
            snapshot.revision = parseRevision(revision_outcome.stdout) orelse return error.Parse;
        }
        {
            var url_outcome = try self.query(&.{
                self.executable.slice(), "info", "--non-interactive", "--no-auth-cache", "--show-item", "relative-url", workspace.root.slice(),
            });
            defer url_outcome.deinit();
            if (!url_outcome.succeeded()) return mapFailure(url_outcome.stderr);
            snapshot.reference = contract.Text.init(std.mem.trim(u8, url_outcome.stdout, " \r\n\t")) catch return error.Parse;
        }
        {
            var status_outcome = try self.query(&.{
                self.executable.slice(), "status", "--non-interactive", "--no-auth-cache", "--ignore-externals", "--xml", "--no-ignore", workspace.root.slice(),
            });
            defer status_outcome.deinit();
            if (!status_outcome.succeeded()) return mapFailure(status_outcome.stderr);
            parseStatus(status_outcome.stdout, &snapshot.changes, &snapshot.files) catch return error.Parse;
        }
        snapshot.counts = .{
            .staged = .unsupported,
            .modified = .ready,
            .untracked = .ready,
            .conflicted = .ready,
            .ahead = .unsupported,
            .behind = .unsupported,
        };
        snapshot.has_conflict = snapshot.changes.conflicted != 0;
        return snapshot;
    }

    fn query(self: *Svn, argv: []const []const u8) contract.Error!run.Outcome {
        return self.execution.execute(self.runner, .{
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
        error.InvalidRequest, error.Io, error.ContainmentFailed, error.ContainmentUnavailable => error.Io,
        error.UnapprovedExecutable, error.UnapprovedEnvironment => error.Permission,
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
    try countStatus(xml, &changes);
    try std.testing.expectEqual(@as(u32, 0), changes.staged);
    try std.testing.expectEqual(@as(u32, 3), changes.modified);
    try std.testing.expectEqual(@as(u32, 1), changes.untracked);
    try std.testing.expectEqual(@as(u32, 1), changes.conflicted);
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
    try std.testing.expect(snapshot.files.available);
    try std.testing.expect(snapshot.files.count >= 2);
}

fn testSessionClock() i64 {
    return 1000;
}

test "SVN counts property changes and ignores misleading attributes" {
    var changes: contract.Changes = .{};
    try countStatus("<status><target path='item=&quot;modified&quot;'><entry path='a'><wc-status item='normal' props='modified'/></entry><entry path='b'><wc-status item='conflicted' props='conflicted' tree-conflicted='true'/></entry></target></status>", &changes);
    try std.testing.expectEqual(@as(u32, 1), changes.modified);
    try std.testing.expectEqual(@as(u32, 1), changes.conflicted);
}

test "malformed SVN output is rejected without publishing partial counts" {
    var changes: contract.Changes = .{ .modified = 17 };
    for ([_][]const u8{
        "<!DOCTYPE status SYSTEM 'file:///not-read'><status/>",
        "<status><target><entry><wc-status item='modified' props='none'/></entry></target>",
        "<status><target><entry><wc-status item='unknown' props='none'/></entry></target></status>",
        "<status><target><entry><wc-status item='normal' item='modified' props='none'/></entry></target></status>",
        "<status><wc-status item='modified' props='none'/></status>",
    }) |fixture| {
        try std.testing.expectError(error.Malformed, countStatus(fixture, &changes));
        try std.testing.expectEqual(@as(u32, 17), changes.modified);
    }
}

test "SVN file details decode entities and retain tree and property conflict metadata" {
    var changes: contract.Changes = .{};
    var files: contract.FileList = .{};
    try parseStatus("<status><target><entry path='a&amp;b'><wc-status item='normal' props='modified' revision='12'/></entry><entry path='old'><wc-status item='missing' props='none' tree-conflicted='true' revision='9'/></entry><entry path='bad&#10;name'><wc-status item='unversioned' props='none'/></entry></target></status>", &changes, &files);
    try std.testing.expectEqual(@as(u8, 2), files.count);
    try std.testing.expectEqualStrings("a&b", files.slice(files.rows[0].path));
    try std.testing.expectEqual(contract.FileList.Kind.property, files.rows[0].kind);
    try std.testing.expectEqual(@as(u64, 12), files.rows[0].revision.?);
    try std.testing.expect(files.rows[1].tree_conflict);
    try std.testing.expectEqual(@as(u32, 1), files.omitted);
    try std.testing.expectError(error.Malformed, parseStatus("<status><target><entry path='a'><wc-status item='modified' props='none'/></entry></target>", &changes, &files));
    try std.testing.expectEqual(@as(u8, 2), files.count);
}
