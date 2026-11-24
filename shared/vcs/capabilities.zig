//! Capability vocabulary shared by every VCS provider.
//!
//! A provider advertises what it can really do for the *detected* CLI version,
//! repository state and permissions. The enum is deliberately about user-level
//! abilities ("can I show the history?"), not about command names, so a
//! centralised VCS and a distributed one can both answer it honestly.

const std = @import("std");

pub const Capability = enum(u32) {
    repository_detection,
    workspace_detection,
    status,
    history,
    file_history,
    diff,
    revision_content,
    annotate,
    branches,
    bookmarks,
    tags,
    staging,
    changelists,
    commit,
    update,
    fetch,
    push,
    merge,
    rebase,
    conflicts,
    shelves,
    file_locking,
    operation_history,
    operation_undo,
    workspaces,
    remotes,
    incoming_changes,
    outgoing_changes,
};

pub const Set = std.enums.EnumSet(Capability);

/// Everything a read-only browser may need.
pub const read_only: Set = blk: {
    var set: Set = .empty;
    for ([_]Capability{
        .repository_detection,
        .workspace_detection,
        .status,
        .history,
        .file_history,
        .diff,
        .revision_content,
        .annotate,
        .branches,
        .bookmarks,
        .tags,
        .conflicts,
        .operation_history,
        .workspaces,
        .remotes,
    }) |capability| set.insert(capability);
    break :blk set;
};

pub fn names(set: Set, buffer: []u8) []const u8 {
    var writer = std.Io.Writer.fixed(buffer);
    var first = true;
    var index: u32 = 0;
    while (index <= @backingInt(Capability.outgoing_changes)) : (index += 1) {
        const capability: Capability = @fromBackingInt(@intCast(index));
        if (!set.contains(capability)) continue;
        if (!first) writer.writeAll(",") catch return buffer[0..writer.end];
        first = false;
        writer.writeAll(@tagName(capability)) catch return buffer[0..writer.end];
    }
    return buffer[0..writer.end];
}

/// Capabilities that survive the runtime answer: declared ∩ supported by the
/// installed CLI ∩ supported by the repository state. Anything not proven is
/// dropped, so the UI degrades instead of offering a command that fails.
pub fn resolve(declared: Set, cli: Set, state: Set) Set {
    return declared.intersectWith(cli).intersectWith(state);
}

test "read-only set excludes writes" {
    const testing = std.testing;
    try testing.expect(read_only.contains(.status));
    try testing.expect(read_only.contains(.operation_history));
    try testing.expect(!read_only.contains(.commit));
    try testing.expect(!read_only.contains(.push));
    try testing.expect(!read_only.contains(.staging));
}

test "names are stable and bounded" {
    var buffer: [512]u8 = undefined;
    var set: Set = .empty;
    set.insert(.status);
    set.insert(.history);
    try std.testing.expectEqualStrings("status,history", names(set, &buffer));
    const empty = names(Set.empty, &buffer);
    try std.testing.expectEqualStrings("", empty);
}

test "resolve drops unproven capabilities" {
    var declared: Set = .empty;
    declared.insert(.status);
    declared.insert(.commit);
    var cli: Set = .empty;
    cli.insert(.status);
    cli.insert(.commit);
    var state: Set = .empty;
    state.insert(.status);
    const effective = resolve(declared, cli, state);
    try std.testing.expect(effective.contains(.status));
    try std.testing.expect(!effective.contains(.commit));
}
