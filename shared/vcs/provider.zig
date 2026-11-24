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

    pub fn init(value: []const u8) error{TooLong}!Text {
        if (value.len > capacity) return error.TooLong;
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

/// What a read-only summary can say. Absent fields carry the reason through
/// `availability` instead of pretending the repository is empty.
pub const Snapshot = struct {
    availability: Availability = .unknown,
    workspace: ?identity.Workspace = null,
    revision: ?identity.RevisionId = null,
    /// Branch, bookmark, stream or trunk-relative path, depending on the VCS.
    reference: Text = .{},
    changes: Changes = .{},
    /// Human-readable detail for errors and partial states; never parsed.
    detail: Text = .{},
};

pub const VTable = struct {
    /// Fills `out` with the workspaces this provider recognises at or above
    /// `start_directory`. Must not run the CLI or touch the network.
    detect: *const fn (ctx: *anyopaque, start_directory: []const u8, out: *detect.Result) void,
    /// Reads one bounded summary. Called off the UI thread.
    summarize: *const fn (ctx: *anyopaque, workspace: *const identity.Workspace) Error!Snapshot,
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
