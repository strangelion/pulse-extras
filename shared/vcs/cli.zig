//! CLI discovery and version detection.
//!
//! Compatibility discovery for fixtures is not an approval boundary.
//! Legacy helpers consider a tool usable when its executable is on
//! `PATH`, it starts, and its version parses. Detection runs the tool with
//! `--version` (no repository is touched) and is meant for a worker thread.

const std = @import("std");
const builtin = @import("builtin");
const identity = @import("vcs_identity");
const run = @import("pulse_process");
const test_config = @import("vcs_test_config");

pub const Tool = enum {
    git,
    jj,
    svn,
    hg,
    p4,
    plastic,
    sapling,
    fossil,

    /// The executable name for this platform. Compile-time, so callers cannot
    /// pass an arbitrary string to the process runner through this path.
    pub fn exeName(self: Tool) []const u8 {
        const windows = builtin.os.tag == .windows;
        return switch (self) {
            .git => if (windows) "git.exe" else "git",
            .jj => if (windows) "jj.exe" else "jj",
            .svn => if (windows) "svn.exe" else "svn",
            .hg => if (windows) "hg.exe" else "hg",
            .p4 => if (windows) "p4.exe" else "p4",
            .plastic => if (windows) "cm.exe" else "cm",
            .sapling => if (windows) "sl.exe" else "sl",
            .fossil => if (windows) "fossil.exe" else "fossil",
        };
    }
};

/// Independent command admission before process spawn. Keep context stable
/// through worker terminal release.
pub const Gate = struct {
    ctx: *anyopaque,
    check: *const fn (*anyopaque, *run.Runner, run.Request) run.Error!void,
};

/// Borrowed profile, alive until session joins. Never downgrade approval.
pub const Execution = union(enum) {
    compatibility,
    approved: struct {
        cwd: identity.Path,
        environment: *const std.process.Environ.Map,
        gate: ?Gate = null,
    },

    pub fn execute(self: *const Execution, runner: *run.Runner, request: run.Request) run.Error!run.Outcome {
        switch (self.*) {
            .compatibility => return runner.run(request),
            .approved => |*profile| {
                if (runner.policy != .approved_local) return error.UnapprovedExecutable;
                if (builtin.os.tag == .windows and runner.tree_policy != .windows_job) return error.ContainmentUnavailable;
                var controlled = request;
                controlled.cwd = profile.cwd.slice();
                controlled.environ_map = profile.environment;
                if (profile.gate) |gate| try gate.check(gate.ctx, runner, controlled);
                return runner.run(controlled);
            },
        }
    }
};

/// Lexical check only, not ACL or canonical identity verification.
pub fn candidatePath(path: []const u8) bool {
    if (path.len == 0 or path.len > identity.max_path_bytes or std.mem.indexOfScalar(u8, path, 0) != null) return false;
    if (builtin.os.tag == .windows) {
        if (path.len < 3 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or (path[2] != '\\' and path[2] != '/')) return false;
        if (std.mem.indexOfScalar(u8, path[2..], ':') != null) return false;
    } else if (path[0] != '/') return false;
    var components = std.mem.tokenizeAny(u8, path, if (builtin.os.tag == .windows) "/\\" else "/");
    while (components.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return false;
    }
    return true;
}

/// Candidate discovery is non-executing and never grants approval.
pub fn locateCandidate(io: std.Io, tool: Tool, path_value: []const u8, scratch: []u8) ?identity.Path {
    if (path_value.len > 64 * 1024) return null;
    var entries = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    for (0..128) |_| {
        const raw = entries.next() orelse return null;
        const directory = std.mem.trim(u8, raw, " \t\"");
        if (!candidatePath(directory)) continue;
        const candidate = std.fmt.bufPrint(scratch, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{
            std.mem.trimEnd(u8, directory, std.fs.path.sep_str),
            tool.exeName(),
        }) catch continue;
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return identity.Path.init(candidate) catch continue;
    }
    return null;
}

pub fn minimumVersion(tool: Tool) ?Version {
    return switch (tool) {
        .git => .{ .major = 2, .minor = 31 },
        .jj => .{ .major = 0, .minor = 46 },
        .svn => .{ .major = 1, .minor = 14 },
        .hg => .{ .major = 7, .minor = 2, .patch = 4 },
        else => null,
    };
}

pub const ProbeError = run.Error || error{ UnsupportedTool, UnsupportedVersion, InvalidVersion };

/// Require an independently approved executable and controlled environment.
/// Caller must establish installation trust before configuring the Runner.
pub fn probeApproved(tool: Tool, path: *const identity.Path, execution: *const Execution, runner: *run.Runner) ProbeError!Report {
    const minimum = minimumVersion(tool) orelse return error.UnsupportedTool;
    if (execution.* != .approved or !candidatePath(path.slice())) return error.UnapprovedExecutable;
    var outcome = try execution.execute(runner, .{
        .argv = &.{ path.slice(), "--version" },
        .timeout_ns = 3 * std.time.ns_per_s,
        .stdout_limit = 4096,
        .stderr_limit = 4096,
    });
    defer outcome.deinit();
    if (!outcome.succeeded()) return error.InvalidVersion;
    const line_end = std.mem.indexOfScalar(u8, outcome.stdout, '\n') orelse outcome.stdout.len;
    const line = std.mem.trim(u8, outcome.stdout[0..line_end], " \r\t");
    const version = parseVersion(tool, line) orelse return error.InvalidVersion;
    if (!version.atLeast(minimum)) return error.UnsupportedVersion;
    var report: Report = .{ .tool = tool, .path = path.*, .version = version };
    if (line.len <= report.line.len and std.unicode.utf8ValidateSlice(line) and std.mem.indexOfScalar(u8, line, 0) == null) {
        @memcpy(report.line[0..line.len], line);
        report.line_len = @intCast(line.len);
    }
    return report;
}

pub const Version = struct {
    major: u32,
    minor: u32,
    patch: u32 = 0,

    pub fn atLeast(self: Version, other: Version) bool {
        if (self.major != other.major) return self.major > other.major;
        if (self.minor != other.minor) return self.minor > other.minor;
        return self.patch >= other.patch;
    }
};

pub const Report = struct {
    tool: Tool,
    path: identity.Path,
    version: ?Version = null,
    /// First line of `--version`, bounded; for diagnostics only, never parsed
    /// again by business logic.
    line: [96]u8 = undefined,
    line_len: u8 = 0,

    pub fn lineSlice(self: *const Report) []const u8 {
        return self.line[0..self.line_len];
    }

    pub fn usable(self: *const Report) bool {
        return self.version != null;
    }
};

/// Parses `git version 2.43.0.windows.1`, `jj 0.23.0`, `svn, version 1.14.2`,
/// `Mercurial Distributed SCM (version 6.7.2)`. Returns `null` instead of a
/// guessed version when the shape is unknown.
pub fn parseVersion(tool: Tool, text: []const u8) ?Version {
    const prefix: []const u8 = switch (tool) {
        .git => "git version ",
        .jj => "jj ",
        .svn => "svn, version ",
        .hg => "Mercurial Distributed SCM (version ",
        else => return null,
    };
    if (!std.mem.startsWith(u8, text, prefix)) return null;
    var index = prefix.len;
    const major = parseNumber(text, &index) orelse return null;
    if (index >= text.len or text[index] != '.') return null;
    index += 1;
    const minor = parseNumber(text, &index) orelse return null;
    if (index >= text.len or text[index] != '.') return null;
    index += 1;
    const patch = parseNumber(text, &index) orelse return null;
    if (index < text.len and std.mem.indexOfScalar(u8, ".-+ )", text[index]) == null) return null;
    return .{ .major = major, .minor = minor, .patch = patch };
}

fn parseNumber(text: []const u8, index: *usize) ?u32 {
    const start = index.*;
    var end = start;
    while (end < text.len and std.ascii.isDigit(text[end])) : (end += 1) {}
    if (end == start) return null;
    const value = std.fmt.parseInt(u32, text[start..end], 10) catch return null;
    index.* = end;
    return value;
}

/// Searches `PATH` for the tool. `scratch` holds one candidate path at a time;
/// the returned `identity.Path` owns its bytes.
pub fn locate(io: std.Io, tool: Tool, path_value: []const u8, scratch: []u8) ?identity.Path {
    var entries = std.mem.splitScalar(u8, path_value, std.fs.path.delimiter);
    while (entries.next()) |raw| {
        const directory = std.mem.trim(u8, raw, " \t\"");
        if (directory.len == 0) continue;
        const candidate = std.fmt.bufPrint(scratch, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{
            std.mem.trimEnd(u8, directory, std.fs.path.sep_str),
            tool.exeName(),
        }) catch continue;
        std.Io.Dir.cwd().access(io, candidate, .{ .execute = true }) catch continue;
        return identity.Path.init(candidate) catch continue;
    }
    return null;
}

/// Locates the tool and parses its version. Returns `null` when the tool is
/// absent; returns a `Report` with `version = null` when it is present but its
/// version line is unrecognised, which callers must treat as unsupported.
pub fn detect(io: std.Io, tool: Tool, path_value: []const u8, scratch: []u8, runner: *run.Runner) ?Report {
    const path = locate(io, tool, path_value, scratch) orelse return null;
    var report = Report{ .tool = tool, .path = path };
    var outcome = runner.run(.{
        .argv = &.{ path.slice(), "--version" },
        .timeout_ns = 3 * std.time.ns_per_s,
        .stdout_limit = 4096,
        .stderr_limit = 4096,
    }) catch return report;
    defer outcome.deinit();
    if (!outcome.succeeded()) return report;

    const line_end = std.mem.indexOfScalar(u8, outcome.stdout, '\n') orelse outcome.stdout.len;
    const line = std.mem.trim(u8, outcome.stdout[0..line_end], " \r\t");
    const copied = @min(line.len, report.line.len);
    @memcpy(report.line[0..copied], line[0..copied]);
    report.line_len = @intCast(copied);
    report.version = parseVersion(tool, line);
    return report;
}

test "git version strings" {
    const version = parseVersion(.git, "git version 2.43.0.windows.1") orelse return error.TestExpectedVersion;
    try std.testing.expectEqual(@as(u32, 2), version.major);
    try std.testing.expectEqual(@as(u32, 43), version.minor);
    try std.testing.expectEqual(@as(u32, 0), version.patch);
    try std.testing.expect(version.atLeast(.{ .major = 2, .minor = 30 }));
    try std.testing.expect(!version.atLeast(.{ .major = 2, .minor = 44 }));
}

test "jj and svn and hg version strings" {
    try std.testing.expectEqual(@as(u32, 23), (parseVersion(.jj, "jj 0.23.0") orelse return error.TestExpectedVersion).minor);
    const svn = parseVersion(.svn, "svn, version 1.14.2 (r1886195)") orelse return error.TestExpectedVersion;
    try std.testing.expectEqual(@as(u32, 14), svn.minor);
    try std.testing.expectEqual(@as(u32, 2), svn.patch);
    const hg = parseVersion(.hg, "Mercurial Distributed SCM (version 6.7.2)") orelse return error.TestExpectedVersion;
    try std.testing.expectEqual(@as(u32, 6), hg.major);
}

test "unknown version shapes are not guessed" {
    try std.testing.expect(parseVersion(.git, "no digits here") == null);
    try std.testing.expect(parseVersion(.git, "version 12") == null);
    try std.testing.expect(parseVersion(.git, "build 7.x.y") == null);
    try std.testing.expect(parseVersion(.git, "jj 0.46.0") == null);
    try std.testing.expect(parseVersion(.git, "git version 2.43.x") == null);
    try std.testing.expectEqual(@as(u32, 46), (parseVersion(.jj, "jj 0.46.0-abcdef0") orelse return error.TestExpectedVersion).minor);
}

test "locate finds an executable in a PATH-like value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, Tool.git.exeName(), .{});
    file.close(io);

    var directory_buffer: [4096]u8 = undefined;
    const directory = try std.fmt.bufPrint(&directory_buffer, ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str ++ "{s}", .{tmp.sub_path});
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    if (builtin.os.tag != .windows) {
        // A regular file is not executable on POSIX. Do not weaken locate().
        try std.testing.expect(locate(io, .git, directory, &scratch) == null);
        var fixture_buffer: [4096]u8 = undefined;
        const fixture = try std.fmt.bufPrint(&fixture_buffer, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ directory, Tool.git.exeName() });
        var runner = run.Runner.init(std.testing.allocator, std.testing.io);
        var outcome = try runner.run(.{ .argv = &.{ "chmod", "700", fixture } });
        defer outcome.deinit();
        try std.testing.expect(outcome.succeeded());
    }
    var path_buffer: [4096]u8 = undefined;
    const path_value = try std.fmt.bufPrint(&path_buffer, "{s}{c}ignored", .{ directory, std.fs.path.delimiter });
    const found = locate(io, .git, path_value, &scratch) orelse return error.TestExpectedPath;
    try std.testing.expect(std.mem.endsWith(u8, found.slice(), Tool.git.exeName()));
}

test "locate returns null when the tool is absent" {
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    const missing = "C:\\definitely-not-a-real-dir" ++ std.fs.path.sep_str ++ "nope";
    try std.testing.expect(locate(std.testing.io, .jj, missing, &scratch) == null);
}

/// Optional developer integrations must become mandatory when CI installs tools.
pub fn integrationUnavailable(tool: Tool) error{ SkipZigTest, RequiredVcsUnavailable } {
    const required = switch (tool) {
        .git => test_config.require_git,
        .jj => test_config.require_jj,
        .svn => test_config.require_svn,
        .hg => test_config.require_hg,
        else => false,
    };
    return if (required) error.RequiredVcsUnavailable else error.SkipZigTest;
}

test "candidate discovery rejects relative paths and traversal" {
    try std.testing.expect(!candidatePath("."));
    try std.testing.expect(!candidatePath("relative"));
    if (builtin.os.tag == .windows) {
        try std.testing.expect(candidatePath("C:\\Program Files\\Git\\bin"));
        try std.testing.expect(!candidatePath("C:relative"));
        try std.testing.expect(!candidatePath("\\\\server\\share"));
        try std.testing.expect(!candidatePath("C:\\tools\\..\\bin"));
        try std.testing.expect(!candidatePath("C:\\tools:stream"));
    } else {
        try std.testing.expect(candidatePath("/usr/bin"));
        try std.testing.expect(!candidatePath("/tmp/../usr/bin"));
    }
    var scratch: [4096]u8 = undefined;
    try std.testing.expect(locateCandidate(std.testing.io, .git, ".", &scratch) == null);
}

test "approved probe refuses compatibility runner and unsupported tools" {
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const cwd = try identity.Path.init(if (builtin.os.tag == .windows) "C:\\trusted" else "/trusted");
    const path = try identity.Path.init(if (builtin.os.tag == .windows) "C:\\trusted\\git.exe" else "/trusted/git");
    const execution: Execution = .{ .approved = .{ .cwd = cwd, .environment = &environment } };
    try std.testing.expectError(error.UnapprovedExecutable, probeApproved(.git, &path, &execution, &runner));
    const compatibility: Execution = .compatibility;
    try std.testing.expectError(error.UnapprovedExecutable, probeApproved(.git, &path, &compatibility, &runner));
    try std.testing.expectError(error.UnsupportedTool, probeApproved(.p4, &path, &execution, &runner));
    try runner.checkDrained();
}
