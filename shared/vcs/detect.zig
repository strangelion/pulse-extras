//! Marker-based repository detection.
//!
//! Detection is local, lazy and bounded: it walks up from one requested
//! directory (at most `max_depth` levels) and asks a caller-supplied probe
//! whether a marker exists. It never scans a tree, never runs a CLI and never
//! touches the network, so it is safe to call from a UI thread.

const std = @import("std");
const identity = @import("vcs_identity");

pub const max_depth = 64;
pub const max_candidates = 8;

pub const EntryType = enum { missing, file, directory };

/// Injected filesystem view. Implementations must be cheap and must not follow
/// reparse points into unrelated trees.
pub const Probe = struct {
    ctx: *anyopaque,
    lookup: *const fn (ctx: *anyopaque, path: []const u8) EntryType,

    pub fn at(self: Probe, path: []const u8) EntryType {
        return self.lookup(self.ctx, path);
    }
};

pub const Candidate = struct {
    kind: identity.Kind,
    root: identity.Path,
    /// Several providers share this directory (git + jj); the caller decides
    /// which one is primary and must serialise writes across both.
    colocated_with: ?identity.Kind = null,
};

pub const Result = struct {
    items: [max_candidates]Candidate = undefined,
    len: u8 = 0,

    pub fn slice(self: *const Result) []const Candidate {
        return self.items[0..self.len];
    }

    pub fn find(self: *const Result, kind: identity.Kind) ?*const Candidate {
        for (self.slice()) |*candidate| {
            if (candidate.kind == kind) return candidate;
        }
        return null;
    }

    fn findMut(self: *Result, kind: identity.Kind) ?*Candidate {
        for (self.items[0..self.len]) |*candidate| {
            if (candidate.kind == kind) return candidate;
        }
        return null;
    }

    /// Providers append candidates here from their own detection.
    pub fn add(self: *Result, candidate: Candidate) void {
        if (self.len < max_candidates) {
            self.items[self.len] = candidate;
            self.len += 1;
        }
    }
};

const Marker = struct { name: []const u8, kind: identity.Kind, wants_directory: bool };

const markers = [_]Marker{
    .{ .name = ".git", .kind = .git, .wants_directory = false },
    .{ .name = ".jj", .kind = .jj, .wants_directory = true },
    .{ .name = ".svn", .kind = .svn, .wants_directory = true },
    .{ .name = ".hg", .kind = .hg, .wants_directory = false },
    .{ .name = ".sl", .kind = .sapling, .wants_directory = true },
    .{ .name = "_FOSSIL_", .kind = .fossil, .wants_directory = false },
    .{ .name = ".fslckout", .kind = .fossil, .wants_directory = false },
};

fn joinInto(buffer: []u8, directory: []const u8, name: []const u8) ?[]const u8 {
    const separator = std.fs.path.sep_str;
    const needs_separator = directory.len != 0 and !std.mem.endsWith(u8, directory, separator);
    const total = directory.len + @intFromBool(needs_separator) + name.len;
    if (total > buffer.len) return null;
    @memcpy(buffer[0..directory.len], directory);
    var cursor = directory.len;
    if (needs_separator) {
        @memcpy(buffer[cursor..][0..separator.len], separator);
        cursor += separator.len;
    }
    @memcpy(buffer[cursor..][0..name.len], name);
    return buffer[0..total];
}

fn matches(probe: Probe, directory: []const u8, marker: Marker, buffer: []u8) bool {
    const path = joinInto(buffer, directory, marker.name) orelse return false;
    const found = probe.at(path);
    return switch (marker.wants_directory) {
        true => found == .directory,
        false => found != .missing,
    };
}

/// Detects the closest workspace of each kind at or above `start_directory`.
///
/// The returned roots are the directories that own the marker, not the
/// requested subdirectory. A `.git` *file* marks a worktree; the git provider
/// resolves its repository root, because only the file contents know it.
pub fn detect(start_directory: []const u8, probe: Probe) Result {
    var result: Result = .{};
    if (start_directory.len == 0) return result;

    var buffer: [identity.max_path_bytes + 32]u8 = undefined;
    var directory: []const u8 = start_directory;
    var depth: usize = 0;

    while (depth < max_depth) : (depth += 1) {
        for (markers) |marker| {
            if (result.find(marker.kind) != null) continue;
            if (!matches(probe, directory, marker, &buffer)) continue;
            const root = identity.Path.init(directory) catch return result;
            result.add(.{ .kind = marker.kind, .root = root });
        }

        const parent = std.fs.path.dirname(directory) orelse break;
        if (parent.len == 0 or std.mem.eql(u8, parent, directory)) break;
        directory = parent;
    }

    // Matching roots are only a colocated candidate, not proof of shared
    // metadata. Different ancestor roots must never be grouped this way.
    if (result.findMut(.git)) |git| {
        if (result.findMut(.jj)) |jj| {
            if (git.root.eql(jj.root.slice())) {
                git.colocated_with = .jj;
                jj.colocated_with = .git;
            }
        }
    }
    return result;
}

fn join(comptime parts: []const []const u8) []const u8 {
    comptime var out: []const u8 = parts[0];
    comptime var index: usize = 1;
    inline while (index < parts.len) : (index += 1) {
        out = out ++ std.fs.path.sep_str ++ parts[index];
    }
    return out;
}

fn FakeProbe(comptime entries: anytype) type {
    return struct {
        fn lookup(_: *anyopaque, path: []const u8) EntryType {
            inline for (entries) |entry| {
                if (std.mem.eql(u8, path, entry.path)) return entry.kind;
            }
            return .missing;
        }
    };
}

fn fakeProbe(comptime entries: anytype) Probe {
    return .{ .ctx = undefined, .lookup = FakeProbe(entries).lookup };
}

test "detects git from a subdirectory" {
    const probe = fakeProbe(&.{.{ .path = join(&.{ "C:", "src", "app", ".git" }), .kind = .directory }});
    const result = detect(join(&.{ "C:", "src", "app", "src", "ui" }), probe);
    const git = result.find(.git) orelse return error.TestExpectedGit;
    try std.testing.expect(git.root.eql(join(&.{ "C:", "src", "app" })));
}

test "detects colocated git and jj" {
    const probe = fakeProbe(&.{
        .{ .path = join(&.{ "work", "repo", ".git" }), .kind = .directory },
        .{ .path = join(&.{ "work", "repo", ".jj" }), .kind = .directory },
    });
    const result = detect(join(&.{ "work", "repo", "src" }), probe);
    const git = result.find(.git) orelse return error.TestExpectedGit;
    const jj = result.find(.jj) orelse return error.TestExpectedJj;
    try std.testing.expectEqual(identity.Kind.jj, git.colocated_with.?);
    try std.testing.expectEqual(identity.Kind.git, jj.colocated_with.?);
}

test "detects a git worktree marker file" {
    const probe = fakeProbe(&.{.{ .path = join(&.{ "src", "worktree", ".git" }), .kind = .file }});
    const result = detect(join(&.{ "src", "worktree", "sub" }), probe);
    const git = result.find(.git) orelse return error.TestExpectedGit;
    try std.testing.expect(git.root.eql(join(&.{ "src", "worktree" })));
}

test "detects the closest svn working copy" {
    const probe = fakeProbe(&.{
        .{ .path = join(&.{ "old", ".svn" }), .kind = .directory },
        .{ .path = join(&.{ "old", "inner", ".svn" }), .kind = .directory },
    });
    const result = detect(join(&.{ "old", "inner", "deep" }), probe);
    const svn = result.find(.svn) orelse return error.TestExpectedSvn;
    try std.testing.expect(svn.root.eql(join(&.{ "old", "inner" })));
    try std.testing.expectEqual(@as(u8, 1), result.len);
}

test "detects Mercurial shared repository file and fossil checkout" {
    const probe = fakeProbe(&.{
        .{ .path = join(&.{ "repo", ".hg" }), .kind = .file },
        .{ .path = join(&.{ "repo", "_FOSSIL_" }), .kind = .file },
    });
    const result = detect(join(&.{ "repo", "a", "b" }), probe);
    if (result.find(.hg) == null) return error.TestExpectedHg;
    if (result.find(.fossil) == null) return error.TestExpectedFossil;
}

test "reports nothing instead of guessing" {
    const probe = fakeProbe(&.{});
    const result = detect(join(&.{ "plain", "folder" }), probe);
    try std.testing.expectEqual(@as(u8, 0), result.len);
}

test "empty start path is a no-op" {
    const probe = fakeProbe(&.{});
    try std.testing.expectEqual(@as(u8, 0), detect("", probe).len);
}

test "nested git and jj roots are not colocated candidates" {
    const probe = fakeProbe(&.{
        .{ .path = join(&.{ "repo", ".git" }), .kind = .directory },
        .{ .path = join(&.{ "repo", "nested", ".jj" }), .kind = .directory },
    });
    const result = detect(join(&.{ "repo", "nested", "src" }), probe);
    try std.testing.expect((result.find(.git) orelse return error.TestExpectedGit).colocated_with == null);
    try std.testing.expect((result.find(.jj) orelse return error.TestExpectedJj).colocated_with == null);
}
