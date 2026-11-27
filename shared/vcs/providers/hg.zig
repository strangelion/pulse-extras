//! Mercurial ordinary local repository provider. The production gate
//! independently checks the approved installation, root/store and environment.
const std = @import("std");
const builtin = @import("builtin");
const identity = @import("vcs_identity");
const detect = @import("vcs_detect");
const contract = @import("vcs_provider");
const capabilities = @import("vcs_capabilities");
const cli = @import("vcs_cli");
const run = @import("pulse_process");
const test_config = @import("vcs_test_config");

fn record(bytes: []const u8, cursor: *usize) contract.Error!?[]const u8 {
    if (cursor.* == bytes.len) return null;
    const tail = bytes[cursor.*..];
    const end = std.mem.indexOfScalar(u8, tail, 0) orelse return error.Parse;
    cursor.* += end + 1;
    if (end == 0) return error.Parse;
    return tail[0..end];
}

fn normalized(path: []const u8, buffer: []u8) ?[]const u8 {
    if (path.len == 0 or path.len > buffer.len or !std.unicode.utf8ValidateSlice(path)) return null;
    for (path, 0..) |c, i| buffer[i] = if (builtin.os.tag == .windows and c == '\\') '/' else c;
    return buffer[0..path.len];
}

/// Native status print0 preserves whitespace and copy sources. Counts are
/// independent of retained rows; copies are not asserted to be renames.
pub fn parseStatus(bytes: []const u8, snapshot: *contract.Snapshot) contract.Error!void {
    var files: contract.FileList = .{ .available = true };
    var changes: contract.Changes = .{};
    var cursor: usize = 0;
    var next = try record(bytes, &cursor);
    while (next) |line| {
        if (line.len < 3 or line[1] != ' ' or line[0] == ' ') return error.Parse;
        var kind: contract.FileList.Kind = switch (line[0]) {
            'M' => .modified,
            'A' => .added,
            'R' => .deleted,
            '!' => .missing,
            '?' => .untracked,
            'I' => .ignored,
            else => return error.Parse,
        };
        switch (kind) {
            .modified, .added, .deleted, .missing => changes.modified +|= 1,
            .untracked => changes.untracked +|= 1,
            else => {},
        }
        next = try record(bytes, &cursor);
        var source: []const u8 = "";
        var source_buffer: [identity.max_path_bytes]u8 = undefined;
        if (next) |copy| {
            if (std.mem.startsWith(u8, copy, "  ")) {
                if (kind != .added or copy.len <= 2) return error.Parse;
                kind = .copied;
                source = normalized(copy[2..], &source_buffer) orelse "";
                next = try record(bytes, &cursor);
            }
        }
        var path_buffer: [identity.max_path_bytes]u8 = undefined;
        if (normalized(line[2..], &path_buffer)) |path| {
            files.add(path, source, .{ .path = .{}, .kind = kind });
        } else files.omit();
    }
    snapshot.files = files;
    snapshot.changes = changes;
}

pub fn parseConflicts(bytes: []const u8, snapshot: *contract.Snapshot) contract.Error!void {
    var cursor: usize = 0;
    var count: u32 = 0;
    while (try record(bytes, &cursor)) |line| {
        if (line.len < 3 or line[1] != ' ' or (line[0] != 'R' and line[0] != 'U')) return error.Parse;
        if (line[0] == 'R') continue;
        count +|= 1;
        var buffer: [identity.max_path_bytes]u8 = undefined;
        const path = normalized(line[2..], &buffer) orelse {
            snapshot.files.omit();
            continue;
        };
        var found = false;
        for (snapshot.files.rows[0..snapshot.files.count]) |*row| {
            const span = row.path;
            if (std.mem.eql(u8, snapshot.files.bytes[span.offset..][0..span.len], path)) {
                row.kind = .conflict;
                found = true;
                break;
            }
        }
        if (!found) snapshot.files.add(path, "", .{ .path = .{}, .kind = .conflict });
    }
    snapshot.changes.conflicted = count;
    snapshot.has_conflict = count != 0;
}

fn mapError(err: run.Error) contract.Error {
    return switch (err) {
        error.SpawnFailed => error.CliMissing,
        error.TimedOut => error.Timeout,
        error.OutputTooLong, error.OutputBudgetExceeded => error.ResourceLimit,
        error.OutOfMemory => error.OutOfMemory,
        error.PermissionDenied, error.UnapprovedExecutable, error.UnapprovedEnvironment => error.Permission,
        error.Stopped, error.Cancelled => error.Cancelled,
        else => error.Io,
    };
}

pub const Hg = struct {
    runner: *run.Runner,
    executable: identity.Path,
    probe: detect.Probe,
    execution: cli.Execution = .compatibility,

    pub fn init(runner: *run.Runner, executable: identity.Path, probe: detect.Probe) Hg {
        return .{ .runner = runner, .executable = executable, .probe = probe };
    }

    pub fn initApproved(runner: *run.Runner, executable: identity.Path, probe: detect.Probe, execution: cli.Execution) !Hg {
        if (execution != .approved or runner.policy != .approved_local) return error.UnapprovedExecutable;
        return .{ .runner = runner, .executable = executable, .probe = probe, .execution = execution };
    }

    fn query(self: *Hg, workspace: *const identity.Workspace, request: *const contract.DetailRequest, limit: usize) contract.Error!run.Outcome {
        var command: contract.DetailCommand = .{};
        const args = try command.build(.hg, self.executable.slice(), workspace.root.slice(), request);
        var outcome = self.execution.execute(self.runner, .{ .argv = args, .timeout_ns = 10 * std.time.ns_per_s, .stdout_limit = limit, .stderr_limit = 4096 }) catch |err| return mapError(err);
        if (!outcome.succeeded()) {
            if (builtin.is_test and self.execution == .compatibility) std.debug.print("Hg fixture {s}: {s}\n", .{ @tagName(request.kind), outcome.stderr[0..@min(outcome.stderr.len, 1024)] });
            outcome.deinit();
            return error.Parse;
        }
        return outcome;
    }

    pub fn verifyRoot(self: *Hg, workspace: *const identity.Workspace) contract.Error!void {
        var result = try self.query(workspace, &.{ .kind = .hg_root }, identity.max_path_bytes + 2);
        defer result.deinit();
        const root = std.mem.trimEnd(u8, result.stdout, "\r\n");
        const expected = workspace.root.slice();
        if (root.len != expected.len) return error.Permission;
        for (root, expected) |a, b| {
            if (a != b and !(builtin.os.tag == .windows and a == '/' and b == '\\')) return error.Permission;
        }
    }

    pub fn summarize(self: *Hg, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        if (workspace.kind != .hg) return error.Unsupported;
        var snapshot: contract.Snapshot = .{ .workspace = workspace.*, .availability = .ready };
        {
            var result = try self.query(workspace, &.{ .kind = .hg_parents }, 256);
            defer result.deinit();
            var lines = std.mem.tokenizeAny(u8, result.stdout, "\r\n");
            if (lines.next()) |node| {
                if (!contract.safeRevision(.hg, node)) return error.Parse;
                if (!std.mem.eql(u8, node, "0000000000000000000000000000000000000000")) snapshot.revision = identity.RevisionId.init(.hg, node) catch return error.Parse;
            }
            if (lines.next()) |parent| {
                if (!contract.safeRevision(.hg, parent) or lines.next() != null) return error.Parse;
                snapshot.detail = contract.Text.init("Merge working copy; history anchor is first parent") catch unreachable;
            }
        }
        {
            var result = try self.query(workspace, &.{ .kind = .hg_branch }, contract.Text.capacity + 2);
            defer result.deinit();
            snapshot.reference = contract.Text.init(std.mem.trimEnd(u8, result.stdout, "\r\n")) catch return error.Parse;
        }
        {
            var result = try self.query(workspace, &.{ .kind = .hg_status }, 256 * 1024);
            defer result.deinit();
            try parseStatus(result.stdout, &snapshot);
        }
        {
            var result = try self.query(workspace, &.{ .kind = .hg_conflicts }, 64 * 1024);
            defer result.deinit();
            try parseConflicts(result.stdout, &snapshot);
        }
        snapshot.counts = .{ .staged = .unsupported, .modified = .ready, .untracked = .ready, .conflicted = .ready, .ahead = .not_queried, .behind = .not_queried };
        return snapshot;
    }

    fn detailImpl(ctx: *anyopaque, workspace: *const identity.Workspace, request: *const contract.DetailRequest) contract.Error!contract.DetailText {
        const self: *Hg = @ptrCast(@alignCast(ctx));
        if (workspace.kind != .hg or !contract.detailSupported(.hg, request.kind)) return error.Unsupported;
        if (request.kind == .refs) {
            var buffer: [contract.DetailText.capacity]u8 = undefined;
            var used: usize = 0;
            for ([_]contract.DetailKind{ .refs, .hg_tags, .hg_bookmarks }) |kind| {
                var result = try self.query(workspace, &.{ .kind = kind }, contract.DetailText.capacity);
                defer result.deinit();
                if (result.stdout.len > buffer.len - used) return error.ResourceLimit;
                @memcpy(buffer[used..][0..result.stdout.len], result.stdout);
                used += result.stdout.len;
            }
            return contract.DetailText.init(buffer[0..used]);
        }
        var result = try self.query(workspace, request, contract.DetailText.capacity);
        defer result.deinit();
        return contract.DetailText.init(result.stdout);
    }

    fn detectImpl(ctx: *anyopaque, directory: []const u8, out: *detect.Result) void {
        const self: *Hg = @ptrCast(@alignCast(ctx));
        const all = detect.detect(directory, self.probe);
        for (all.slice()) |candidate| {
            if (candidate.kind == .hg) out.add(candidate);
        }
    }

    fn summarizeImpl(ctx: *anyopaque, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        const self: *Hg = @ptrCast(@alignCast(ctx));
        return self.summarize(workspace);
    }

    pub fn provider(self: *Hg) contract.Provider {
        var set: capabilities.Set = .empty;
        for ([_]capabilities.Capability{ .repository_detection, .workspace_detection, .status, .history, .file_history, .diff, .revision_content, .branches, .tags, .bookmarks, .conflicts }) |capability| set.insert(capability);
        return .{ .kind = .hg, .display_name = "Mercurial", .capabilities = set, .ctx = self, .vtable = .{ .detect = detectImpl, .summarize = summarizeImpl, .detail = detailImpl } };
    }
};

fn fakeLookup(_: *anyopaque, _: []const u8) detect.EntryType {
    return .missing;
}

test "Mercurial native status retains copy source, missing, ignored and conflicts" {
    var snapshot: contract.Snapshot = .{};
    try parseStatus("M a.txt\x00A copy.txt\x00  a.txt\x00! gone\x00? new name\x00I ignored\x00", &snapshot);
    try std.testing.expectEqual(@as(u32, 3), snapshot.changes.modified);
    try std.testing.expectEqual(@as(u32, 1), snapshot.changes.untracked);
    try std.testing.expectEqual(contract.FileList.Kind.copied, snapshot.files.rows[1].kind);
    try std.testing.expectEqualStrings("a.txt", snapshot.files.slice(snapshot.files.rows[1].original));
    try parseConflicts("U a.txt\x00R old.txt\x00", &snapshot);
    try std.testing.expectEqual(@as(u32, 1), snapshot.changes.conflicted);
    try std.testing.expectEqual(contract.FileList.Kind.conflict, snapshot.files.rows[0].kind);
    try std.testing.expectError(error.Parse, parseStatus("M unterminated", &snapshot));
    try std.testing.expectError(error.Parse, parseStatus("  orphan\x00", &snapshot));
}

test "real Mercurial fixture exposes status history content diff and refs" {
    if (test_config.hg_working_copy.len == 0) return cli.integrationUnavailable(.hg);
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    const report = cli.detect(std.testing.io, .hg, test_config.path, &scratch, &runner) orelse return cli.integrationUnavailable(.hg);
    const version = report.version orelse return cli.integrationUnavailable(.hg);
    if (!version.atLeast(cli.minimumVersion(.hg).?)) return cli.integrationUnavailable(.hg);
    const workspace = try identity.Workspace.init(.hg, test_config.hg_working_copy, test_config.hg_working_copy);
    var hg = Hg.init(&runner, report.path, .{ .ctx = undefined, .lookup = fakeLookup });
    try hg.verifyRoot(&workspace);
    const snapshot = try hg.summarize(&workspace);
    const revision = snapshot.revision orelse return error.TestExpectedRevision;
    try std.testing.expect(snapshot.changes.modified >= 2);
    try std.testing.expectEqual(@as(u32, 1), snapshot.changes.untracked);
    try std.testing.expectEqual(contract.Availability.unsupported, snapshot.counts.staged);
    const api = hg.provider();
    const path = try identity.Path.init("tracked.txt");
    const history = try api.detail(&workspace, &.{ .kind = .history, .revision = revision });
    try std.testing.expect(std.mem.indexOf(u8, history.slice(), revision.slice()) != null);
    const file_history = try api.detail(&workspace, &.{ .kind = .file_history, .revision = revision, .path = path });
    try std.testing.expect(std.mem.indexOf(u8, file_history.slice(), revision.slice()) != null);
    const content = try api.detail(&workspace, &.{ .kind = .content, .revision = revision, .path = path });
    try std.testing.expectEqualStrings("original\n", content.slice());
    const diff = try api.detail(&workspace, &.{ .kind = .working_diff, .path = path });
    try std.testing.expect(std.mem.indexOf(u8, diff.slice(), "+changed") != null);
    const revision_diff = try api.detail(&workspace, &.{ .kind = .revision_diff, .revision = revision, .path = path });
    try std.testing.expect(std.mem.indexOf(u8, revision_diff.slice(), "+original") != null);
    _ = try api.detail(&workspace, &.{ .kind = .revision_info, .revision = revision });
    const refs = try api.detail(&workspace, &.{ .kind = .refs });
    try std.testing.expect(std.mem.indexOf(u8, refs.slice(), "branch default") != null);
    try std.testing.expect(std.mem.indexOf(u8, refs.slice(), "bookmark fixture") != null);
    const empty_page = try api.detail(&workspace, &.{ .kind = .history, .revision = revision, .offset = 32 });
    try std.testing.expectEqual(@as(usize, 0), empty_page.slice().len);
    try runner.checkDrained();
}
