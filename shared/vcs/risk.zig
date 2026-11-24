//! Risk classification for VCS operations.
//!
//! Safety is a property of what a command really does for the detected CLI
//! version, not of its name. Providers declare the level; the policy decides
//! what a read-only browser may run.

const std = @import("std");

pub const Level = enum(u8) {
    /// Reads repository state without writing anything anywhere.
    passive_read,
    /// May write VCS metadata (for example a snapshot taken by a query).
    refresh,
    /// Reads from a server; needs timeout, cancellation and no credential prompt.
    network_read,
    /// Writes local metadata (update, pull into a store).
    local_metadata_write,
    /// Changes files in the working tree (checkout, merge, revert).
    working_tree_write,
    /// Writes to a remote (push, submit).
    remote_write,
    /// Rewrites history (rebase, squash, abandon).
    history_rewrite,
    /// Data loss is expected (reset --hard, clean, force push).
    destructive,

    pub fn requiresPlan(self: Level) bool {
        return switch (self) {
            .passive_read, .refresh, .network_read => false,
            else => true,
        };
    }

    pub fn requiresConfirmation(self: Level) bool {
        return switch (self) {
            .working_tree_write, .remote_write, .history_rewrite, .destructive => true,
            else => false,
        };
    }

    /// Human-readable label for logs and error details; never used to decide
    /// policy (that would make the policy language-dependent).
    pub fn label(self: Level) []const u8 {
        return switch (self) {
            .passive_read => "passive-read",
            .refresh => "refresh",
            .network_read => "network-read",
            .local_metadata_write => "local-metadata-write",
            .working_tree_write => "working-tree-write",
            .remote_write => "remote-write",
            .history_rewrite => "history-rewrite",
            .destructive => "destructive",
        };
    }
};

pub const Policy = struct {
    /// Read-only browsing is the default for the first VCS release.
    read_only: bool = true,
    /// `refresh` is only allowed when the provider proved the command is
    /// side-effect free for the detected version.
    allow_refresh: bool = false,
    allow_network_read: bool = true,
    allow_destructive: bool = false,

    pub fn allows(self: Policy, level: Level) bool {
        if (level == .destructive and !self.allow_destructive) return false;
        if (!self.read_only) return true;
        return switch (level) {
            .passive_read => true,
            .refresh => self.allow_refresh,
            .network_read => self.allow_network_read,
            else => false,
        };
    }

    /// Every level a policy rejects, so the UI can explain the gap instead of
    /// silently hiding features.
    pub fn denied(self: Policy, out: []Level) []const Level {
        var count: usize = 0;
        inline for (std.meta.tags(Level)) |level| {
            if (!self.allows(level) and count < out.len) {
                out[count] = level;
                count += 1;
            }
        }
        return out[0..count];
    }
};

test "default policy is a read-only browser" {
    const policy: Policy = .{};
    try std.testing.expect(policy.allows(.passive_read));
    try std.testing.expect(!policy.allows(.refresh));
    try std.testing.expect(policy.allows(.network_read));
    try std.testing.expect(!policy.allows(.local_metadata_write));
    try std.testing.expect(!policy.allows(.working_tree_write));
    try std.testing.expect(!policy.allows(.remote_write));
    try std.testing.expect(!policy.allows(.history_rewrite));
    try std.testing.expect(!policy.allows(.destructive));
}

test "refresh needs an explicit proof override" {
    var policy: Policy = .{};
    policy.allow_refresh = true;
    try std.testing.expect(policy.allows(.refresh));
    try std.testing.expect(!policy.allows(.working_tree_write));
}

test "write policy still never allows destructive by accident" {
    var policy: Policy = .{};
    policy.read_only = false;
    try std.testing.expect(policy.allows(.working_tree_write));
    try std.testing.expect(policy.allows(.history_rewrite));
    try std.testing.expect(!policy.allows(.destructive));
    policy.allow_destructive = true;
    try std.testing.expect(policy.allows(.destructive));
}

test "plan and confirmation requirements" {
    try std.testing.expect(!Level.passive_read.requiresPlan());
    try std.testing.expect(!Level.network_read.requiresPlan());
    try std.testing.expect(Level.local_metadata_write.requiresPlan());
    try std.testing.expect(Level.remote_write.requiresConfirmation());
    try std.testing.expect(!Level.local_metadata_write.requiresConfirmation());
    try std.testing.expect(Level.destructive.requiresConfirmation());
}

test "denied list reports every blocked level" {
    var buffer: [8]Level = undefined;
    const policy: Policy = .{};
    const blocked = policy.denied(&buffer);
    try std.testing.expect(blocked.len >= 6);
    for (blocked) |level| try std.testing.expect(!policy.allows(level));
}
