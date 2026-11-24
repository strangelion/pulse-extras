//! CLI discovery and version detection.
//!
//! Providers never guess: a tool is usable only when its executable is on
//! `PATH`, it starts, and its version parses. Detection runs the tool with
//! `--version` (no repository is touched) and is meant for a worker thread.

const std = @import("std");
const builtin = @import("builtin");
const identity = @import("vcs_identity");
const run = @import("pulse_process");

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
pub fn parseVersion(text: []const u8) ?Version {
    var index: usize = 0;
    while (index < text.len and !std.ascii.isDigit(text[index])) : (index += 1) {}
    if (index == text.len) return null;

    const major = parseNumber(text, &index) orelse return null;
    if (index >= text.len or text[index] != '.') return null;
    index += 1;
    const minor = parseNumber(text, &index) orelse return null;

    var patch: u32 = 0;
    if (index < text.len and text[index] == '.') {
        const after = index + 1;
        var probe = after;
        patch = parseNumber(text, &probe) orelse 0;
        if (patch != 0) index = probe;
    }
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
    defer outcome.deinit(runner.allocator);
    if (!outcome.succeeded()) return report;

    const line_end = std.mem.indexOfScalar(u8, outcome.stdout, '\n') orelse outcome.stdout.len;
    const line = std.mem.trim(u8, outcome.stdout[0..line_end], " \r\t");
    const copied = @min(line.len, report.line.len);
    @memcpy(report.line[0..copied], line[0..copied]);
    report.line_len = @intCast(copied);
    report.version = parseVersion(line);
    return report;
}

test "git version strings" {
    const version = parseVersion("git version 2.43.0.windows.1") orelse return error.TestExpectedVersion;
    try std.testing.expectEqual(@as(u32, 2), version.major);
    try std.testing.expectEqual(@as(u32, 43), version.minor);
    try std.testing.expectEqual(@as(u32, 0), version.patch);
    try std.testing.expect(version.atLeast(.{ .major = 2, .minor = 30 }));
    try std.testing.expect(!version.atLeast(.{ .major = 2, .minor = 44 }));
}

test "jj and svn and hg version strings" {
    try std.testing.expectEqual(@as(u32, 23), (parseVersion("jj 0.23.0") orelse return error.TestExpectedVersion).minor);
    const svn = parseVersion("svn, version 1.14.2 (r1886195)") orelse return error.TestExpectedVersion;
    try std.testing.expectEqual(@as(u32, 14), svn.minor);
    try std.testing.expectEqual(@as(u32, 2), svn.patch);
    const hg = parseVersion("Mercurial Distributed SCM (version 6.7.2)") orelse return error.TestExpectedVersion;
    try std.testing.expectEqual(@as(u32, 6), hg.major);
}

test "unknown version shapes are not guessed" {
    try std.testing.expect(parseVersion("no digits here") == null);
    try std.testing.expect(parseVersion("version 12") == null);
    try std.testing.expect(parseVersion("build 7.x.y") == null);
}

test "locate finds an executable in a PATH-like value" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = run.io();
    const file = try tmp.dir.createFile(io, Tool.git.exeName(), .{});
    file.close(io);

    var path_buffer: [4096]u8 = undefined;
    const path_value = try std.fmt.bufPrint(&path_buffer, ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str ++ "{s}{c}ignored", .{
        tmp.sub_path,
        std.fs.path.delimiter,
    });
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    const found = locate(io, .git, path_value, &scratch) orelse return error.TestExpectedPath;
    try std.testing.expect(std.mem.endsWith(u8, found.slice(), Tool.git.exeName()));
}

test "locate returns null when the tool is absent" {
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    const missing = "C:\\definitely-not-a-real-dir" ++ std.fs.path.sep_str ++ "nope";
    try std.testing.expect(locate(run.io(), .jj, missing, &scratch) == null);
}
