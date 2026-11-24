//! Identity types shared by every VCS provider.
//!
//! No type assumes a Git-shaped hash: a revision is a tagged value with a
//! provider-specific textual id (40-hex hash, jj change id + commit id, svn
//! revision number, p4 changelist, …). Paths are fixed-capacity, validated
//! UTF-8 so a borrowed host string can never be stored beyond its lifetime.

const std = @import("std");

pub const Kind = enum(u8) {
    git,
    jj,
    svn,
    hg,
    p4,
    plastic,
    sapling,
    fossil,

    pub fn displayName(self: Kind) []const u8 {
        return switch (self) {
            .git => "Git",
            .jj => "Jujutsu",
            .svn => "Subversion",
            .hg => "Mercurial",
            .p4 => "Perforce",
            .plastic => "Unity Version Control",
            .sapling => "Sapling",
            .fossil => "Fossil",
        };
    }

    /// Distributed VCS share history between workspaces; centralised ones keep
    /// a single authoritative copy on the server. Providers use this to decide
    /// what "workspace" and "remote" mean; it is not a capability claim.
    pub fn isDistributed(self: Kind) bool {
        return switch (self) {
            .git, .jj, .hg, .sapling, .fossil => true,
            .svn, .p4, .plastic => false,
        };
    }
};

pub const max_path_bytes = 2048;
pub const max_revision_bytes = 96;

/// A validated, owned filesystem path in UTF-8. Windows long paths and
/// non-ASCII names fit; anything longer than the capacity is rejected instead
/// of silently truncated into a different path.
pub const Path = struct {
    bytes: [max_path_bytes]u8 = undefined,
    len: u16 = 0,

    pub fn init(text: []const u8) error{ EmptyPath, PathTooLong, InvalidPath }!Path {
        if (text.len == 0) return error.EmptyPath;
        if (text.len > max_path_bytes) return error.PathTooLong;
        for (text) |byte| {
            if (byte == 0) return error.InvalidPath;
        }
        if (!std.unicode.utf8ValidateSlice(text)) return error.InvalidPath;
        var path: Path = .{};
        @memcpy(path.bytes[0..text.len], text);
        path.len = @intCast(text.len);
        return path;
    }

    pub fn slice(self: *const Path) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Path, other: []const u8) bool {
        return std.mem.eql(u8, self.slice(), other);
    }
};

/// Provider-specific revision identifier. The text is validated as printable
/// ASCII without spaces so it can be passed as a single argv element.
pub const RevisionId = struct {
    kind: Kind,
    bytes: [max_revision_bytes]u8 = undefined,
    len: u8 = 0,

    pub fn init(kind: Kind, text: []const u8) error{ EmptyRevision, RevisionTooLong, InvalidRevision }!RevisionId {
        if (text.len == 0) return error.EmptyRevision;
        if (text.len > max_revision_bytes) return error.RevisionTooLong;
        for (text) |byte| {
            if (byte < 0x21 or byte > 0x7E) return error.InvalidRevision;
        }
        var revision: RevisionId = .{ .kind = kind };
        @memcpy(revision.bytes[0..text.len], text);
        revision.len = @intCast(text.len);
        return revision;
    }

    pub fn slice(self: *const RevisionId) []const u8 {
        return self.bytes[0..self.len];
    }

    /// Jujutsu exposes a change id and, once committed, a commit id. Other
    /// providers leave `commit` empty.
    pub fn eql(self: *const RevisionId, other: *const RevisionId) bool {
        return self.kind == other.kind and std.mem.eql(u8, self.slice(), other.slice());
    }
};

pub const Repository = struct {
    kind: Kind,
    root: Path,
    /// Optional remote identity. A repository is not its URL: the same clone
    /// can be fetched from mirrors, so this field never identifies a workspace.
    remote: ?Path = null,

    pub fn init(kind: Kind, root: []const u8) !Repository {
        return .{ .kind = kind, .root = try Path.init(root) };
    }
};

pub const Workspace = struct {
    kind: Kind,
    root: Path,
    repository_root: Path,
    /// True when several workspaces (git worktrees, jj workspaces, colocated
    /// git+jj) share one metadata store and therefore one write lock.
    shared_metadata: bool = false,

    pub fn init(kind: Kind, root: []const u8, repository_root: []const u8) !Workspace {
        return .{
            .kind = kind,
            .root = try Path.init(root),
            .repository_root = try Path.init(repository_root),
        };
    }
};

test "paths keep Unicode and long Windows paths" {
    const chinese = try Path.init("C:\\用户\\文档\\项目\\文件.txt");
    try std.testing.expect(chinese.eql("C:\\用户\\文档\\项目\\文件.txt"));
    const emoji = try Path.init("/tmp/目录😀/a.txt");
    try std.testing.expect(emoji.eql("/tmp/目录😀/a.txt"));
    var long: [max_path_bytes]u8 = undefined;
    @memset(&long, 'a');
    const longest = try Path.init(&long);
    try std.testing.expectEqual(@as(usize, max_path_bytes), longest.slice().len);
}

test "paths reject empty, NUL and overlong values" {
    try std.testing.expectError(error.EmptyPath, Path.init(""));
    try std.testing.expectError(error.InvalidPath, Path.init("bad\x00path"));
    try std.testing.expectError(error.InvalidPath, Path.init("bad\xFFpath"));
    var too_long: [max_path_bytes + 1]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expectError(error.PathTooLong, Path.init(&too_long));
}

test "revision ids are per-kind and argv safe" {
    const git = try RevisionId.init(.git, "9f2c0c7d1d6b0a1c2d3e4f5061728394a5b6c7d8");
    const svn = try RevisionId.init(.svn, "12345");
    const p4 = try RevisionId.init(.p4, "678901");
    try std.testing.expectEqual(Kind.git, git.kind);
    try std.testing.expect(!git.eql(&svn));
    try std.testing.expect(svn.eql(&svn));
    try std.testing.expectEqualStrings("678901", p4.slice());
    try std.testing.expectError(error.EmptyRevision, RevisionId.init(.git, ""));
    try std.testing.expectError(error.InvalidRevision, RevisionId.init(.jj, "with space"));
    var too_long: [max_revision_bytes + 1]u8 = undefined;
    @memset(&too_long, 'a');
    try std.testing.expectError(error.RevisionTooLong, RevisionId.init(.git, &too_long));
}

test "kind semantics stay honest" {
    try std.testing.expect(Kind.git.isDistributed());
    try std.testing.expect(Kind.jj.isDistributed());
    try std.testing.expect(!Kind.svn.isDistributed());
    try std.testing.expect(!Kind.p4.isDistributed());
    try std.testing.expectEqualStrings("Unity Version Control", Kind.plastic.displayName());
}

test "workspace keeps repository root separate" {
    const workspace = try Workspace.init(.git, "C:\\src\\app-worktree", "C:\\src\\app");
    try std.testing.expect(workspace.root.eql("C:\\src\\app-worktree"));
    try std.testing.expect(workspace.repository_root.eql("C:\\src\\app"));
    try std.testing.expect(!workspace.shared_metadata);
}
