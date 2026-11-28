//! Interpret exact Git index entries for a single reviewed path. The caller
//! supplies bounded NUL-delimited output from literal-path Git commands.
const std = @import("std");

const Sha256 = std.crypto.hash.sha2.Sha256;
const identity = @import("vcs_identity");

pub const Object = [40]u8;
pub const Mode = enum { regular, executable };
pub const Entry = struct {
    object: Object,
    mode: Mode,

    pub fn eql(self: Entry, other: Entry) bool {
        return self.mode == other.mode and std.mem.eql(u8, &self.object, &other.object);
    }
};

pub const State = struct {
    selected: ?Entry = null,
    other_entries: [32]u8,
};

pub const Action = enum { stage, unstage };
pub const FileStamp = struct {
    identity: [12]u8,
    contents: [32]u8,
};

/// Keep exact operation evidence in the UI owner until confirmation. Paths,
/// action and navigational generation are copied independently of CLI output.
pub const Plan = struct {
    scope: Scope,
    evidence: Evidence,

    pub const Scope = struct {
        root: identity.Path,
        tool: identity.Path,
        path: identity.Path,
        action: Action,
        generation: u64,

        fn eql(self: *const Scope, other: *const Scope) bool {
            return self.generation == other.generation and self.action == other.action and self.root.eql(other.root.slice()) and self.tool.eql(other.tool.slice()) and self.path.eql(other.path.slice());
        }
    };

    pub const Evidence = struct {
        tool: FileStamp,
        repository: [12]u8,
        metadata: [12]u8,
        config: FileStamp,
        head: Object,
        head_file: FileStamp,
        reference: ?FileStamp,
        index: FileStamp,
        working_file: ?FileStamp,
    };

    /// Consume the review on every confirmation attempt. Failure requires a
    /// new review, including when the same path was selected again later.
    pub fn consume(slot: *?Plan, scope: *const Scope) !Plan {
        const plan = slot.* orelse return error.IndexReviewMissing;
        slot.* = null;
        if (!plan.scope.eql(scope)) return error.IndexReviewChanged;
        return plan;
    }

    pub fn revalidate(self: *const Plan, current: *const Evidence) !void {
        if (!std.meta.eql(self.evidence, current.*)) return error.IndexReviewChanged;
    }
};

pub fn parseObject(value: []const u8) !Object {
    if (value.len != 40) return error.InvalidGitObject;
    for (value) |ch| {
        if (!std.ascii.isDigit(ch) and (ch < 'a' or ch > 'f')) return error.InvalidGitObject;
    }
    if (std.mem.allEqual(u8, value, '0')) return error.MissingGitObject;
    return value[0..40].*;
}

fn mode(value: []const u8) !Mode {
    if (std.mem.eql(u8, value, "100644")) return .regular;
    if (std.mem.eql(u8, value, "100755")) return .executable;
    return error.UnsupportedGitEntry;
}

pub fn index(output: []const u8, target: []const u8) !State {
    var hash = Sha256.init(.{});
    var selected: ?Entry = null;
    var rest = output;
    while (rest.len != 0) {
        const end = std.mem.indexOfScalar(u8, rest, 0) orelse return error.TruncatedGitIndex;
        const row = rest[0..end];
        const tab = std.mem.indexOfScalar(u8, row, '\t') orelse return error.InvalidGitIndex;
        if (tab != 49 or row[6] != ' ' or row[47] != ' ' or tab + 1 == row.len) return error.InvalidGitIndex;
        if (row[48] != '0') return error.ConflictedGitIndex;
        const path = row[tab + 1 ..];
        if (std.mem.eql(u8, path, target)) {
            if (selected != null) return error.InvalidGitIndex;
            selected = .{ .object = try parseObject(row[7..47]), .mode = try mode(row[0..6]) };
        } else {
            if (std.ascii.eqlIgnoreCase(path, target)) return error.AliasedGitPath;
            hash.update(rest[0 .. end + 1]);
        }
        rest = rest[end + 1 ..];
    }
    return .{ .selected = selected, .other_entries = hash.finalResult() };
}

pub fn tree(output: []const u8, target: []const u8) !?Entry {
    if (output.len == 0) return null;
    if (output.len < 55 or output[output.len - 1] != 0) return error.InvalidGitTree;
    if (!std.mem.eql(u8, output[6..12], " blob ") or output[52] != '\t') return error.UnsupportedGitEntry;
    if (!std.mem.eql(u8, output[53 .. output.len - 1], target)) return error.InvalidGitTree;
    return .{ .object = try parseObject(output[12..52]), .mode = try mode(output[0..6]) };
}

pub fn verify(before: State, after: State, expected: ?Entry) !void {
    if (!std.mem.eql(u8, &before.other_entries, &after.other_entries)) return error.UnrelatedIndexChange;
    if (expected) |entry| {
        const actual = after.selected orelse return error.UnexpectedIndexEntry;
        if (!entry.eql(actual)) return error.UnexpectedIndexEntry;
    } else if (after.selected != null) return error.UnexpectedIndexEntry;
}

test "an index proposal binds both the selected blob and unrelated entries" {
    const object = "181bdb7f7a490c783e54bdfc28ffeee011d55681";
    const changed = "6cb7ffbe54db0d007d9bd3d14eb3acb2f3b63277";
    const other = "100644 " ++ object ++ " 0\tother.txt\x00";
    const before = try index(other, "selected.txt");
    const after = try index(other ++ "100644 " ++ changed ++ " 0\tselected.txt\x00", "selected.txt");
    try verify(before, after, .{ .object = changed.*, .mode = .regular });
    try std.testing.expectError(error.UnexpectedIndexEntry, verify(before, after, null));
    try std.testing.expectError(error.UnrelatedIndexChange, verify(before, try index("100644 " ++ changed ++ " 0\tother.txt\x00", "selected.txt"), null));
    try std.testing.expectError(error.ConflictedGitIndex, index("100644 " ++ object ++ " 2\tother.txt\x00", "selected.txt"));
    try std.testing.expectError(error.AliasedGitPath, index("100644 " ++ object ++ " 0\tSelected.txt\x00", "selected.txt"));
    try std.testing.expectError(error.TruncatedGitIndex, index(other[0 .. other.len - 1], "selected.txt"));
}

test "confirmation is consumed on drift and evidence is checked again before publication" {
    const scope: Plan.Scope = .{
        .root = try identity.Path.init("/fixture"),
        .tool = try identity.Path.init("/tools/git"),
        .path = try identity.Path.init("selected.txt"),
        .action = .stage,
        .generation = 1,
    };
    const plan: Plan = .{
        .scope = scope,
        .evidence = .{
            .tool = .{ .identity = @splat(1), .contents = @splat(2) },
            .repository = @splat(3),
            .metadata = @splat(4),
            .config = .{ .identity = @splat(5), .contents = @splat(6) },
            .head = @splat('a'),
            .head_file = .{ .identity = @splat(7), .contents = @splat(8) },
            .reference = null,
            .index = .{ .identity = @splat(9), .contents = @splat(10) },
            .working_file = .{ .identity = @splat(8), .contents = @splat(9) },
        },
    };
    var slot: ?Plan = plan;
    var changed_scope = scope;
    changed_scope.generation += 1;
    try std.testing.expectError(error.IndexReviewChanged, Plan.consume(&slot, &changed_scope));
    try std.testing.expectError(error.IndexReviewMissing, Plan.consume(&slot, &scope));
    slot = plan;
    const approved = try Plan.consume(&slot, &scope);
    try approved.revalidate(&plan.evidence);
    try std.testing.expectError(error.IndexReviewMissing, Plan.consume(&slot, &scope));
    var changed_evidence = plan.evidence;
    changed_evidence.working_file.?.contents[0] = 0;
    try std.testing.expectError(error.IndexReviewChanged, approved.revalidate(&changed_evidence));
    changed_evidence = plan.evidence;
    changed_evidence.head[0] = 'b';
    try std.testing.expectError(error.IndexReviewChanged, approved.revalidate(&changed_evidence));
}
