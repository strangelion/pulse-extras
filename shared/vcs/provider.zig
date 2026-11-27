//! Provider contract.
//!
//! A provider is a value with a small vtable plus the capability set it really
//! implements. The contract is read-only on purpose: write operations are added
//! one at a time in later phases, each with a plan and confirmation.

const std = @import("std");
const capabilities = @import("vcs_capabilities");
const detect = @import("vcs_detect");
const identity = @import("vcs_identity");

pub const Error = error{
    CliMissing,
    CliTooOld,
    NotConnected,
    Unsupported,
    Stale,
    Parse,
    Timeout,
    Cancelled,
    Permission,
    Io,
    OutOfMemory,
    ResourceLimit,
};

/// Why a value is missing. `empty` is a real answer; the others are not.
pub const Availability = enum {
    ready,
    empty,
    unknown,
    unsupported,
    not_queried,
    not_connected,
    stale,
};

/// Bounded UTF-8 text for user-facing values (branch name, bookmark, reason).
pub const Text = struct {
    pub const capacity = 256;
    bytes: [capacity]u8 = undefined,
    len: u16 = 0,

    pub fn init(value: []const u8) error{ TooLong, InvalidText }!Text {
        if (value.len > capacity) return error.TooLong;
        if (!std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidText;
        var text: Text = .{};
        @memcpy(text.bytes[0..value.len], value);
        text.len = @intCast(value.len);
        return text;
    }

    pub fn slice(self: *const Text) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn eql(self: *const Text, other: []const u8) bool {
        return std.mem.eql(u8, self.slice(), other);
    }
};

/// Counts are coarse on purpose: every VCS can answer "how many changed
/// paths", while staging/changelists are provider-specific capabilities.
pub const Changes = struct {
    /// Index / staging area entries (Git) or equivalent prepared changes.
    staged: u32 = 0,
    /// Worktree modifications not yet staged (or not yet in a changelist).
    modified: u32 = 0,
    untracked: u32 = 0,
    conflicted: u32 = 0,
    /// Distance to the upstream ref, only when the provider reports it.
    ahead: u32 = 0,
    behind: u32 = 0,
};

/// Count availability is independent of the stored numeric value. Consumers
/// must not present a default zero as a measured count.
pub const CountAvailability = struct {
    staged: Availability = .not_queried,
    modified: Availability = .not_queried,
    untracked: Availability = .not_queried,
    conflicted: Availability = .not_queried,
    ahead: Availability = .not_queried,
    behind: Availability = .not_queried,
};

/// Saved-record metadata is only an observation, never executable admission.
/// A recorded path may no longer exist or match its original fingerprint.
pub const SavedHint = struct {
    pub const State = enum { not_checked, absent, recorded, unavailable };
    state: State = .not_checked,
    executable: ?identity.Path = null,
};

/// Display-only file status records. Paths are never CLI arguments.
/// Compact bounded arena avoids one 2 KiB Path per row in every cache entry.
pub const FileList = struct {
    pub const capacity = 64;
    pub const byte_capacity = 8192;
    pub const page_size = 8;
    pub const Kind = enum {
        modified,
        added,
        deleted,
        renamed,
        copied,
        conflict,
        untracked,
        ignored,
        missing,
        replaced,
        obstructed,
        incomplete,
        property,
        external,
        unknown,

        pub fn label(self: Kind) []const u8 {
            return @tagName(self);
        }
    };
    pub const Span = struct {
        offset: u16 = 0,
        len: u16 = 0,
    };
    pub const Row = struct {
        path: Span,
        original: Span = .{},
        kind: Kind,
        /// Git XY, otherwise zero. Never infer staging for JJ or SVN.
        xy: [2]u8 = .{ 0, 0 },
        property_changed: bool = false,
        tree_conflict: bool = false,
        revision: ?u64 = null,
    };
    available: bool = false,
    omitted: u32 = 0,
    count: u8 = 0,
    used: u16 = 0,
    rows: [capacity]Row = undefined,
    bytes: [byte_capacity]u8 = undefined,

    fn valid(value: []const u8) bool {
        return value.len != 0 and value.len <= identity.max_path_bytes and std.unicode.utf8ValidateSlice(value) and std.mem.indexOfScalar(u8, value, 0) == null;
    }

    fn store(self: *FileList, value: []const u8) Span {
        const offset = self.used;
        @memcpy(self.bytes[offset..][0..value.len], value);
        self.used += @intCast(value.len);
        return .{ .offset = offset, .len = @intCast(value.len) };
    }

    pub fn omit(self: *FileList) void {
        self.omitted +|= 1;
    }

    pub fn add(self: *FileList, path: []const u8, original: []const u8, row: Row) void {
        if (!valid(path) or (original.len != 0 and !valid(original)) or self.count == capacity or @as(usize, self.used) + path.len + original.len > byte_capacity) {
            self.omit();
            return;
        }
        var entry = row;
        entry.path = self.store(path);
        if (original.len != 0) entry.original = self.store(original);
        self.rows[self.count] = entry;
        self.count += 1;
    }

    pub fn slice(self: *const FileList, span: Span) []const u8 {
        return self.bytes[span.offset..][0..span.len];
    }

    pub fn matches(self: *const FileList, row: Row, filter: []const u8) bool {
        return filter.len == 0 or std.mem.indexOf(u8, self.slice(row.path), filter) != null or std.mem.indexOf(u8, self.slice(row.original), filter) != null or std.mem.indexOf(u8, row.kind.label(), filter) != null;
    }

    pub fn matchCount(self: *const FileList, filter: []const u8) usize {
        var count: usize = 0;
        for (self.rows[0..self.count]) |row| {
            if (self.matches(row, filter)) count += 1;
        }
        return count;
    }
};

/// What a read-only summary can say. Absent fields carry the reason through
/// `availability` instead of pretending the repository is empty.
pub const Snapshot = struct {
    availability: Availability = .unknown,
    workspace: ?identity.Workspace = null,
    revision: ?identity.RevisionId = null,
    operation: Text = .{},
    /// Branch, bookmark, stream or trunk-relative path, depending on the VCS.
    reference: Text = .{},
    changes: Changes = .{},
    files: FileList = .{},
    counts: CountAvailability = .{},
    /// Some providers report only whether a revision has conflicts.
    has_conflict: ?bool = null,
    /// Human-readable detail for errors and partial states; never parsed.
    detail: Text = .{},
    /// Metadata preview hints only; none is executable approval.
    remote_web: Text = .{},
    preview_kinds: u8 = 0,
    preview_tools: [3]?identity.Path = .{ null, null, null },
    preview_saved: [3]SavedHint = @splat(.{}),

    pub fn previewIndex(kind: identity.Kind) ?usize {
        return switch (kind) {
            .git => 0,
            .jj => 1,
            .svn => 2,
            else => null,
        };
    }

    pub fn previewHas(self: *const Snapshot, kind: identity.Kind) bool {
        const index = previewIndex(kind) orelse return false;
        return self.preview_kinds & (@as(u8, 1) << @as(u3, @intCast(index))) != 0;
    }

    pub fn savedHint(self: *const Snapshot, kind: identity.Kind) SavedHint {
        const index = previewIndex(kind) orelse return .{};
        return self.preview_saved[index];
    }

    pub fn previewTool(self: *const Snapshot, kind: identity.Kind) ?identity.Path {
        const index = previewIndex(kind) orelse return null;
        return self.preview_tools[index];
    }
};

/// Convert only literal, public forge repository locations to a canonical
/// HTTPS landing page. No credentials, ports, query, fragment, escaping,
/// arbitrary schemes or arbitrary hosts. Not a claim of repository existence.
pub fn repositoryWebUrl(input: []const u8) ?Text {
    if (input.len == 0 or input.len > 512) return null;
    const hosts = [_][]const u8{ "github.com", "gitlab.com", "bitbucket.org" };
    for (hosts) |name| {
        var prefix: [96]u8 = undefined;
        var body: ?[]const u8 = null;
        for ([_][]const u8{ "https://", "git@", "ssh://git@" }) |scheme| {
            const separator = if (std.mem.eql(u8, scheme, "git@")) ":" else "/";
            const start = std.fmt.bufPrint(&prefix, "{s}{s}{s}", .{ scheme, name, separator }) catch return null;
            if (std.mem.startsWith(u8, input, start)) {
                body = input[start.len..];
                break;
            }
        }
        var path = body orelse continue;
        if (std.mem.endsWith(u8, path, ".git")) path = path[0 .. path.len - 4];
        var components = std.mem.splitScalar(u8, path, '/');
        var count: usize = 0;
        while (components.next()) |component| {
            if (component.len == 0 or component.len > 100 or component[0] == '.' or component[component.len - 1] == '.') return null;
            for (component) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') return null;
            }
            count += 1;
        }
        if (count != 2 and (!std.mem.eql(u8, name, "gitlab.com") or count < 2 or count > 8)) return null;
        var buffer: [Text.capacity]u8 = undefined;
        const url = std.fmt.bufPrint(&buffer, "https://{s}/{s}", .{ name, path }) catch return null;
        return Text.init(url) catch null;
    }
    return null;
}

test "forge links reject credentials, redirects and non-repository paths" {
    const good = repositoryWebUrl("git@github.com:owner/project.git") orelse return error.TestUnexpectedResult;
    try std.testing.expect(good.eql("https://github.com/owner/project"));
    try std.testing.expect(repositoryWebUrl("https://gitlab.com/group/sub/project.git") != null);
    for ([_][]const u8{ "https://github.com.evil.test/a/b", "https://user:token@github.com/a/b", "https://github.com/a/../b", "https://github.com/a/b?x=1", "https://github.com/a/b/issues", "file:///C:/test", "https://github.com/a/%2e%2e" }) |bad| {
        try std.testing.expect(repositoryWebUrl(bad) == null);
    }
}

/// Bounded local read-only detail. The exact same command grammar is used
/// for construction and for authorization at the process admission boundary.
pub const DetailKind = enum { history, file_history, revision_info, working_diff, staged_diff, revision_diff, content, refs, workspaces, operations, local_info, properties, guard, filter_guard, jj_pin, jj_status_revision, jj_status_diff };

pub const DetailRequest = struct {
    kind: DetailKind,
    path: identity.Path = .{},
    revision: ?identity.RevisionId = null,
    offset: u16 = 0,
    operation: Text = .{},
};

pub fn safeRelativePath(value: []const u8) bool {
    if (value.len == 0 or value.len > identity.max_path_bytes or !std.unicode.utf8ValidateSlice(value)) return false;
    for (value) |byte| {
        if (byte < 0x20 or byte == 0x7f or std.mem.indexOfScalar(u8, "\\:\"*?<>|@{}[]", byte) != null) return false;
    }
    var parts = std.mem.splitScalar(u8, value, '/');
    while (parts.next()) |part| {
        if (part.len == 0 or part[0] == '-' or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
        for ([_][]const u8{ ".git", ".jj", ".svn" }) |bad| {
            if (std.ascii.eqlIgnoreCase(part, bad)) return false;
        }
        const stem = part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len];
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" }) |bad| {
            if (std.ascii.eqlIgnoreCase(stem, bad)) return false;
        }
    }
    return true;
}

pub fn safeRevision(kind: identity.Kind, value: []const u8) bool {
    if (kind != .git and kind != .jj) return false;
    if (value.len != 40 and !(kind == .git and value.len == 64)) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

pub fn safeOperation(value: []const u8) bool {
    if (value.len != 128) return false;
    for (value) |byte| {
        if (!std.ascii.isHex(byte)) return false;
    }
    return true;
}

pub const DetailText = struct {
    pub const capacity = 16384;
    pub const page_size = 8;
    pub const chunk_size = 512;
    pub const State = enum { text, binary, invalid_encoding };
    state: State = .text,
    bytes: [capacity]u8 = undefined,
    len: u16 = 0,

    pub fn init(value: []const u8) Error!DetailText {
        if (value.len > capacity) return error.ResourceLimit;
        if (std.mem.indexOfScalar(u8, value, 0) != null) return .{ .state = .binary };
        if (!std.unicode.utf8ValidateSlice(value)) return .{ .state = .invalid_encoding };
        var result: DetailText = .{};
        @memcpy(result.bytes[0..value.len], value);
        result.len = @intCast(value.len);
        return result;
    }

    pub fn slice(self: *const DetailText) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn nextChunk(self: *const DetailText, cursor: *usize) ?[]const u8 {
        if (cursor.* >= self.len) return null;
        const rest = self.slice()[cursor.*..];
        const line_len = std.mem.indexOfScalar(u8, rest, '\n') orelse rest.len;
        var n = @min(line_len, chunk_size);
        while (n != 0 and n < rest.len and (rest[n] & 0xc0) == 0x80) n -= 1;
        cursor.* += n + @as(usize, @intFromBool(n == line_len and line_len < rest.len));
        return rest[0..n];
    }

    pub fn revisionAt(self: *const DetailText, kind: identity.Kind, chunk: usize) ?identity.RevisionId {
        if (self.state != .text) return null;
        var cursor: usize = 0;
        var index: usize = 0;
        while (cursor < self.len) : (index += 1) {
            const start = cursor;
            const line = self.nextChunk(&cursor) orelse return null;
            if (index != chunk) continue;
            if (start != 0 and self.bytes[start - 1] != '\n') return null;
            const end = std.mem.indexOfAny(u8, line, " \t") orelse return null;
            if (!safeRevision(kind, line[0..end])) return null;
            return identity.RevisionId.init(kind, line[0..end]) catch null;
        }
        return null;
    }

    pub fn pages(self: *const DetailText) usize {
        var cursor: usize = 0;
        var count: usize = 0;
        while (self.nextChunk(&cursor)) |_| count += 1;
        return @max(1, (count + page_size - 1) / page_size);
    }
};

const Spec = struct { provider: identity.Kind, kind: DetailKind, args: []const []const u8 };
const detail_specs = [_]Spec{
    .{ .provider = .jj, .kind = .jj_pin, .args = &.{ "$exe", "--ignore-working-copy", "--at-op=@", "--no-pager", "--color=never", "-R", "$root", "op", "log", "--no-graph", "--limit", "1", "-T", "id" } },
    .{ .provider = .jj, .kind = .jj_status_revision, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "log", "-r", "@", "--no-graph", "-T", "change_id.short() ++ \"\\t\" ++ commit_id ++ \"\\t\" ++ bookmarks.join(\" \") ++ \"\\t\" ++ if(conflict, \"conflict\", \"ok\")" } },
    .{ .provider = .jj, .kind = .jj_status_diff, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "diff", "--summary", "-r", "$rev" } },
    .{ .provider = .git, .kind = .guard, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "config", "--get-regexp", "^(extensions\\.partialclone|remote\\..*\\.(promisor|partialclonefilter))$" } },
    .{ .provider = .git, .kind = .filter_guard, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "config", "--get-regexp", "^filter\\..*\\.(clean|process)$" } },
    .{ .provider = .git, .kind = .history, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "log", "--no-show-signature", "--max-count=32", "$skip", "--format=%H%x09%aI%x09%s", "$rev", "--" } },
    .{ .provider = .git, .kind = .file_history, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "log", "--no-show-signature", "--max-count=32", "$skip", "--format=%H%x09%aI%x09%s", "$rev", "--", "$path" } },
    .{ .provider = .git, .kind = .revision_info, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "show", "--no-patch", "--no-show-signature", "--format=fuller", "$rev", "--" } },
    .{ .provider = .git, .kind = .working_diff, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "diff", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=all", "--", "$path" } },
    .{ .provider = .git, .kind = .staged_diff, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "diff", "--cached", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=all", "$rev", "--", "$path" } },
    .{ .provider = .git, .kind = .revision_diff, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "show", "--format=", "--no-show-signature", "--no-ext-diff", "--no-textconv", "--no-renames", "--ignore-submodules=all", "$rev", "--", "$path" } },
    .{ .provider = .git, .kind = .content, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "cat-file", "blob", "$blob" } },
    .{ .provider = .git, .kind = .refs, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "for-each-ref", "--count=128", "--format=%(objectname) %(refname)", "refs/heads", "refs/tags", "refs/remotes" } },
    .{ .provider = .git, .kind = .workspaces, .args = &.{ "$exe", "--no-pager", "--no-optional-locks", "--literal-pathspecs", "--no-replace-objects", "-c", "core.fsmonitor=false", "-C", "$root", "worktree", "list", "--porcelain" } },
    .{ .provider = .jj, .kind = .history, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "log", "-r", "$ancestors", "--no-graph", "$jj_limit", "-T", "commit_id ++ \" \" ++ change_id ++ \" \" ++ description.first_line() ++ \"\\n\"" } },
    .{ .provider = .jj, .kind = .file_history, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "log", "-r", "$ancestors", "--no-graph", "$jj_limit", "-T", "commit_id ++ \" \" ++ change_id ++ \" \" ++ description.first_line() ++ \"\\n\"", "$fileset" } },
    .{ .provider = .jj, .kind = .revision_info, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "log", "-r", "$rev", "--no-graph", "-T", "commit_id ++ \"\\n\" ++ change_id ++ \"\\n\" ++ description" } },
    .{ .provider = .jj, .kind = .working_diff, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "diff", "--git", "-r", "$rev", "$fileset" } },
    .{ .provider = .jj, .kind = .revision_diff, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "diff", "--git", "-r", "$rev", "$fileset" } },
    .{ .provider = .jj, .kind = .content, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "file", "show", "-r", "$rev", "$fileset" } },
    .{ .provider = .jj, .kind = .refs, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "bookmark", "list" } },
    .{ .provider = .jj, .kind = .workspaces, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "workspace", "list" } },
    .{ .provider = .jj, .kind = .operations, .args = &.{ "$exe", "--ignore-working-copy", "$op", "--no-pager", "--color=never", "-R", "$root", "op", "log", "--no-graph", "--limit", "32" } },
    .{ .provider = .svn, .kind = .local_info, .args = &.{ "$exe", "info", "--non-interactive", "--no-auth-cache", "--xml", "--", "$target" } },
    .{ .provider = .svn, .kind = .working_diff, .args = &.{ "$exe", "diff", "--non-interactive", "--no-auth-cache", "--internal-diff", "--", "$target" } },
    .{ .provider = .svn, .kind = .content, .args = &.{ "$exe", "cat", "--non-interactive", "--no-auth-cache", "-r", "BASE", "--", "$target" } },
    .{ .provider = .svn, .kind = .properties, .args = &.{ "$exe", "proplist", "--non-interactive", "--no-auth-cache", "--xml", "--", "$target" } },
};

pub fn detailSupported(provider: identity.Kind, kind: DetailKind) bool {
    if (kind == .guard or kind == .filter_guard or kind == .jj_pin or kind == .jj_status_revision or kind == .jj_status_diff) return false;
    for (detail_specs) |spec| {
        if (spec.provider == provider and spec.kind == kind) return true;
    }
    return false;
}

fn eqArg(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

fn validSvnTarget(root: []const u8, value: []const u8) bool {
    if (!std.mem.endsWith(u8, value, "@")) return false;
    const target = value[0 .. value.len - 1];
    if (eqArg(target, root)) return true;
    if (target.len <= root.len + 1 or !std.mem.startsWith(u8, target, root) or target[root.len] != std.fs.path.sep) return false;
    const relative = target[root.len + 1 ..];
    var normalized: [identity.max_path_bytes]u8 = undefined;
    if (relative.len > normalized.len) return false;
    for (relative, 0..) |byte, i| normalized[i] = if (byte == std.fs.path.sep) '/' else byte;
    return safeRelativePath(normalized[0..relative.len]);
}

fn matchToken(kind: identity.Kind, root: []const u8, exe: []const u8, token: []const u8, actual: []const u8) bool {
    if (eqArg(token, "$exe")) return eqArg(exe, actual);
    if (eqArg(token, "$root")) return eqArg(root, actual);
    if (eqArg(token, "$rev")) return safeRevision(kind, actual);
    if (eqArg(token, "$path")) return safeRelativePath(actual);
    if (eqArg(token, "$skip")) {
        if (!std.mem.startsWith(u8, actual, "--skip=")) return false;
        const offset = std.fmt.parseInt(u16, actual[7..], 10) catch return false;
        return offset <= 4096 and offset % 32 == 0;
    }
    if (eqArg(token, "$op")) return std.mem.startsWith(u8, actual, "--at-op=") and safeOperation(actual[8..]);
    if (eqArg(token, "$jj_limit")) {
        if (!std.mem.startsWith(u8, actual, "--limit=")) return false;
        const n = std.fmt.parseInt(u16, actual[8..], 10) catch return false;
        return n >= 32 and n <= 256 and n % 32 == 0;
    }
    if (eqArg(token, "$ancestors")) return std.mem.startsWith(u8, actual, "::") and safeRevision(kind, actual[2..]);
    if (eqArg(token, "$blob")) {
        const colon = std.mem.indexOfScalar(u8, actual, ':') orelse return false;
        return safeRevision(kind, actual[0..colon]) and safeRelativePath(actual[colon + 1 ..]);
    }
    if (eqArg(token, "$fileset")) {
        const prefix = "root-file:\"";
        return actual.len > prefix.len and std.mem.startsWith(u8, actual, prefix) and actual[actual.len - 1] == '"' and safeRelativePath(actual[prefix.len .. actual.len - 1]);
    }
    if (eqArg(token, "$target")) return validSvnTarget(root, actual);
    return eqArg(token, actual);
}

pub fn detailAllowed(kind: identity.Kind, exe: []const u8, root: []const u8, argv: []const []const u8) bool {
    outer: for (detail_specs) |spec| {
        if (spec.provider != kind or spec.args.len != argv.len) continue;
        for (spec.args, argv) |token, actual| {
            if (!matchToken(kind, root, exe, token, actual)) continue :outer;
        }
        return true;
    }
    return false;
}

pub const DetailCommand = struct {
    argv: [32][]const u8 = undefined,
    scratch: [identity.max_path_bytes * 2 + 128]u8 = undefined,
    skip: [16]u8 = undefined,
    op: [136]u8 = undefined,

    pub fn build(self: *DetailCommand, kind: identity.Kind, exe: []const u8, root: []const u8, request: *const DetailRequest) Error![]const []const u8 {
        const rev = if (request.revision) |*value| value.slice() else "";
        const path = request.path.slice();
        if (request.revision) |value| {
            if (value.kind != kind) return error.Parse;
        }
        if (path.len != 0 and !safeRelativePath(path)) return error.Permission;
        for (detail_specs) |spec| {
            if (spec.provider != kind or spec.kind != request.kind) continue;
            for (spec.args, 0..) |token, i| {
                self.argv[i] = if (eqArg(token, "$exe"))
                    exe
                else if (eqArg(token, "$root"))
                    root
                else if (eqArg(token, "$rev"))
                    rev
                else if (eqArg(token, "$path"))
                    path
                else if (eqArg(token, "$skip"))
                    std.fmt.bufPrint(&self.skip, "--skip={d}", .{request.offset}) catch return error.ResourceLimit
                else if (eqArg(token, "$op"))
                    std.fmt.bufPrint(&self.op, "--at-op={s}", .{request.operation.slice()}) catch return error.ResourceLimit
                else if (eqArg(token, "$jj_limit")) blk: {
                    if (request.offset > 224 or request.offset % 32 != 0) return error.ResourceLimit;
                    break :blk std.fmt.bufPrint(&self.skip, "--limit={d}", .{request.offset + 32}) catch return error.ResourceLimit;
                } else if (eqArg(token, "$ancestors"))
                    std.fmt.bufPrint(&self.scratch, "::{s}", .{rev}) catch return error.ResourceLimit
                else if (eqArg(token, "$blob"))
                    std.fmt.bufPrint(&self.scratch, "{s}:{s}", .{ rev, path }) catch return error.ResourceLimit
                else if (eqArg(token, "$fileset"))
                    std.fmt.bufPrint(&self.scratch, "root-file:\"{s}\"", .{path}) catch return error.ResourceLimit
                else if (eqArg(token, "$target")) blk: {
                    if (path.len == 0 and request.kind != .local_info and request.kind != .properties) return error.Permission;
                    const target = if (path.len == 0)
                        std.fmt.bufPrint(&self.scratch, "{s}@", .{root}) catch return error.ResourceLimit
                    else
                        std.fmt.bufPrint(&self.scratch, "{s}" ++ std.fs.path.sep_str ++ "{s}@", .{ root, path }) catch return error.ResourceLimit;
                    for (self.scratch[root.len..target.len]) |*byte| {
                        if (byte.* == '/') byte.* = std.fs.path.sep;
                    }
                    break :blk target;
                } else token;
                if (!matchToken(kind, root, exe, token, self.argv[i])) return error.Permission;
            }
            return self.argv[0..spec.args.len];
        }
        return error.Unsupported;
    }
};

pub const VTable = struct {
    /// Fills `out` with the workspaces this provider recognises at or above
    /// `start_directory`. Must not run the CLI or touch the network.
    detect: *const fn (ctx: *anyopaque, start_directory: []const u8, out: *detect.Result) void,
    /// Reads one bounded summary. Called off the UI thread.
    summarize: *const fn (ctx: *anyopaque, workspace: *const identity.Workspace) Error!Snapshot,
    detail: ?*const fn (ctx: *anyopaque, workspace: *const identity.Workspace, request: *const DetailRequest) Error!DetailText = null,
};

pub const Provider = struct {
    kind: identity.Kind,
    display_name: []const u8,
    capabilities: capabilities.Set,
    vtable: VTable,
    ctx: *anyopaque,

    pub fn supports(self: Provider, capability: capabilities.Capability) bool {
        return self.capabilities.contains(capability);
    }

    pub fn detectInto(self: Provider, start_directory: []const u8, out: *detect.Result) void {
        self.vtable.detect(self.ctx, start_directory, out);
    }

    pub fn summarize(self: Provider, workspace: *const identity.Workspace) Error!Snapshot {
        return self.vtable.summarize(self.ctx, workspace);
    }

    pub fn detail(self: Provider, workspace: *const identity.Workspace, request: *const DetailRequest) Error!DetailText {
        if (workspace.kind != self.kind or !detailSupported(self.kind, request.kind)) return error.Unsupported;
        return (self.vtable.detail orelse return error.Unsupported)(self.ctx, workspace, request);
    }
};

/// Runtime negotiation: a capability is advertised only when the provider
/// declares it, the installed CLI supports it and the repository state allows
/// it. Callers pass `state` as the empty set when the state is not known yet,
/// which degrades the UI instead of offering a command that will fail.
pub fn effectiveCapabilities(provider: Provider, cli: capabilities.Set, state: capabilities.Set) capabilities.Set {
    return capabilities.resolve(provider.capabilities, cli, state);
}

const Fake = struct {
    var snapshot: Snapshot = .{ .availability = .empty };

    fn detectImpl(_: *anyopaque, start: []const u8, out: *detect.Result) void {
        out.* = .{};
        const root = identity.Path.init(start) catch return;
        out.add(.{ .kind = .git, .root = root });
    }

    fn summarizeImpl(_: *anyopaque, workspace: *const identity.Workspace) Error!Snapshot {
        if (workspace.kind != .git) return error.Unsupported;
        var result = snapshot;
        result.workspace = workspace.*;
        return result;
    }

    fn provider() Provider {
        var set: capabilities.Set = .empty;
        set.insert(.status);
        set.insert(.history);
        return .{
            .kind = .git,
            .display_name = "Git",
            .capabilities = set,
            .vtable = .{ .detect = detectImpl, .summarize = summarizeImpl },
            .ctx = undefined,
        };
    }
};

test "capabilities are declared, not assumed" {
    const provider = Fake.provider();
    try std.testing.expect(provider.supports(.status));
    try std.testing.expect(!provider.supports(.push));
    try std.testing.expect(!provider.supports(.staging));
}

test "detect is delegated to the provider vtable" {
    var result: detect.Result = .{};
    Fake.provider().detectInto("C:\\src\\app", &result);
    try std.testing.expectEqual(@as(u8, 1), result.len);
    try std.testing.expect(result.find(.git) != null);
}

test "summaries return typed errors for unsupported workspaces" {
    const workspace = identity.Workspace.init(.svn, "C:\\wc", "C:\\wc") catch unreachable;
    try std.testing.expectError(error.Unsupported, Fake.provider().summarize(&workspace));
}

test "effective capabilities need cli and state support" {
    const provider = Fake.provider();
    var declared_only: capabilities.Set = .empty;
    declared_only.insert(.status);
    declared_only.insert(.history);
    var cli: capabilities.Set = .empty;
    cli.insert(.status);
    const effective = effectiveCapabilities(provider, cli, declared_only);
    try std.testing.expect(effective.contains(.status));
    try std.testing.expect(!effective.contains(.history));
}

test "bounded text reports overflow instead of truncating" {
    const value = try Text.init("main");
    try std.testing.expect(value.eql("main"));
    var long: [Text.capacity + 1]u8 = undefined;
    @memset(&long, 'a');
    try std.testing.expectError(error.TooLong, Text.init(&long));
}

test "bounded text rejects invalid UTF-8 and embedded NUL" {
    try std.testing.expectError(error.InvalidText, Text.init("bad\xff"));
    try std.testing.expectError(error.InvalidText, Text.init("bad\x00"));
}

test "file arena bounds retained rows and preserves omissions and exact names" {
    var list: FileList = .{ .available = true };
    list.add("new name", "old name", .{ .path = .{}, .kind = .renamed, .xy = .{ 'R', '.' } });
    try std.testing.expectEqualStrings("old name", list.slice(list.rows[0].original));
    try std.testing.expectEqual(@as(usize, 1), list.matchCount("old"));
    list.add("bad\xff", "", .{ .path = .{}, .kind = .modified });
    for (0..FileList.capacity) |_| list.add("a", "", .{ .path = .{}, .kind = .modified });
    try std.testing.expectEqual(@as(u8, FileList.capacity), list.count);
    try std.testing.expectEqual(@as(u32, 2), list.omitted);
    var large: FileList = .{ .available = true };
    const path: [identity.max_path_bytes]u8 = @splat('x');
    for (0..5) |_| large.add(&path, "", .{ .path = .{}, .kind = .modified });
    try std.testing.expectEqual(@as(u8, 4), large.count);
    try std.testing.expectEqual(@as(u32, 1), large.omitted);
}

test "detail grammar rejects path and revision injection and other roots" {
    const rev = try identity.RevisionId.init(.git, "0123456789012345678901234567890123456789");
    var command: DetailCommand = .{};
    const request: DetailRequest = .{ .kind = .file_history, .revision = rev, .path = try identity.Path.init("src/a b.txt"), .offset = 32 };
    const argv = try command.build(.git, "git", "repo", &request);
    try std.testing.expect(detailAllowed(.git, "git", "repo", argv));
    try std.testing.expect(!detailAllowed(.git, "git", "other", argv));
    command.argv[argv.len - 1] = "../outside";
    try std.testing.expect(!detailAllowed(.git, "git", "repo", argv));
    for ([_][]const u8{ "../a", "a/../b", "a//b", "https://host/file", ".git/config", "AUX.txt", "-option", "a*.txt", "a\\b", "a@HEAD" }) |bad| {
        try std.testing.expect(!safeRelativePath(bad));
    }
    try std.testing.expect(!safeRevision(.git, "--all"));
    try std.testing.expect(!detailSupported(.svn, .history));
}

test "detail text distinguishes binary encoding and resource limit" {
    try std.testing.expectEqual(DetailText.State.binary, (try DetailText.init("a\x00b")).state);
    try std.testing.expectEqual(DetailText.State.invalid_encoding, (try DetailText.init("\xff")).state);
    const too_long: [DetailText.capacity + 1]u8 = @splat('x');
    try std.testing.expectError(error.ResourceLimit, DetailText.init(&too_long));
    const detail = try DetailText.init("a\n\n中文");
    var cursor: usize = 0;
    try std.testing.expectEqualStrings("a", detail.nextChunk(&cursor).?);
    try std.testing.expectEqualStrings("", detail.nextChunk(&cursor).?);
    try std.testing.expectEqualStrings("中文", detail.nextChunk(&cursor).?);
    try std.testing.expect(detail.nextChunk(&cursor) == null);
}
