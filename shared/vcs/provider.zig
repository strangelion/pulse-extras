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

/// What a read-only summary can say. Absent fields carry the reason through
/// `availability` instead of pretending the repository is empty.
pub const Snapshot = struct {
    availability: Availability = .unknown,
    workspace: ?identity.Workspace = null,
    revision: ?identity.RevisionId = null,
    /// Branch, bookmark, stream or trunk-relative path, depending on the VCS.
    reference: Text = .{},
    changes: Changes = .{},
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

test "bounded text rejects invalid UTF-8 and embedded NUL" {
    try std.testing.expectError(error.InvalidText, Text.init("bad\xff"));
    try std.testing.expectError(error.InvalidText, Text.init("bad\x00"));
}
