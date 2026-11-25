//! Fixed-capacity snapshot cache for one serialized owner. Values must own
//! their contents by value (no borrowed slices or independently freed handles).
//! Workers return results to the owner; they never access this cache directly.

const std = @import("std");
const identity = @import("vcs_identity");

pub fn Cache(comptime Value: type) type {
    return struct {
        pub const max_entries = 8;

        const Entry = struct {
            key: identity.Workspace,
            value: Value,
            stored_at_ms: i64,
            stale: bool = false,
        };

        pub const Lookup = union(enum) {
            missing,
            stale: Value,
            fresh: Value,
        };

        const Self = @This();

        entries: [max_entries]Entry = undefined,
        len: u8 = 0,
        generation: u64 = 0,
        ttl_ms: i64,
        now: *const fn () i64,

        pub fn init(ttl_ms: i64, now: *const fn () i64) Self {
            std.debug.assert(ttl_ms >= 0);
            return .{ .ttl_ms = ttl_ms, .now = now };
        }

        pub fn currentGeneration(self: *const Self) u64 {
            return self.generation;
        }

        pub fn isCurrent(self: *const Self, generation: u64) bool {
            return generation == self.generation;
        }

        /// Advance on a new request, even if no cache entry changes.
        pub fn beginRequest(self: *Self) u64 {
            self.generation +%= 1;
            return self.generation;
        }

        fn sameKey(a: *const identity.Workspace, b: *const identity.Workspace) bool {
            return a.kind == b.kind and a.root.eql(b.root.slice()) and a.repository_root.eql(b.repository_root.slice());
        }

        /// Returns an owned-by-value snapshot, never a mutable cache pointer.
        pub fn get(self: *Self, key: *const identity.Workspace) Lookup {
            const entry = self.find(key) orelse return .missing;
            const elapsed = @as(i128, self.now()) - @as(i128, entry.stored_at_ms);
            if (entry.stale or elapsed < 0 or elapsed > self.ttl_ms) return .{ .stale = entry.value };
            return .{ .fresh = entry.value };
        }

        /// The generation check and publication are one owner-thread operation.
        pub fn put(self: *Self, key: *const identity.Workspace, generation: u64, value: Value) error{Stale}!void {
            if (!self.isCurrent(generation)) return error.Stale;
            const entry = Entry{ .key = key.*, .value = value, .stored_at_ms = self.now() };
            if (self.find(key)) |existing| {
                existing.* = entry;
                return;
            }
            if (self.len == max_entries) {
                self.oldest().* = entry;
                return;
            }
            self.entries[self.len] = entry;
            self.len += 1;
        }

        /// Preserve a prior value as stale while its replacement is queried.
        pub fn markStale(self: *Self, key: *const identity.Workspace) void {
            if (self.find(key)) |entry| entry.stale = true;
        }

        pub fn invalidate(self: *Self, key: *const identity.Workspace) void {
            _ = self.beginRequest();
            var index: usize = 0;
            while (index < self.len) : (index += 1) {
                if (sameKey(&self.entries[index].key, key)) {
                    self.entries[index] = self.entries[self.len - 1];
                    self.len -= 1;
                    return;
                }
            }
        }

        pub fn invalidateAll(self: *Self) void {
            _ = self.beginRequest();
            self.len = 0;
        }

        pub fn ageAll(self: *Self) void {
            _ = self.beginRequest();
            for (self.entries[0..self.len]) |*entry| entry.stale = true;
        }

        fn find(self: *Self, key: *const identity.Workspace) ?*Entry {
            for (self.entries[0..self.len]) |*entry| {
                if (sameKey(&entry.key, key)) return entry;
            }
            return null;
        }

        fn oldest(self: *Self) *Entry {
            var victim: *Entry = &self.entries[0];
            for (self.entries[1..self.len]) |*entry| {
                if (entry.stored_at_ms < victim.stored_at_ms) victim = entry;
            }
            return victim;
        }
    };
}

var fake_now_ms: i64 = 0;

fn fakeClock() i64 {
    return fake_now_ms;
}

const TestCache = Cache(u32);

test "fresh values are returned by value until TTL expires" {
    fake_now_ms = 1000;
    var cache = TestCache.init(500, fakeClock);
    const key = try identity.Workspace.init(.git, "repo", "repo");
    try cache.put(&key, cache.currentGeneration(), 7);
    const held = cache.get(&key);
    try cache.put(&key, cache.currentGeneration(), 8);
    try std.testing.expectEqual(@as(u32, 7), held.fresh);
    try std.testing.expectEqual(@as(u32, 8), cache.get(&key).fresh);
    fake_now_ms = 1600;
    try std.testing.expectEqual(@as(u32, 8), cache.get(&key).stale);
}

test "different providers and workspaces do not collide" {
    var cache = TestCache.init(500, fakeClock);
    const git = try identity.Workspace.init(.git, "repo", "repo");
    const jj = try identity.Workspace.init(.jj, "repo", "repo");
    const worktree = try identity.Workspace.init(.git, "other", "repo");
    const moved_store = try identity.Workspace.init(.git, "repo", "different-store");
    try cache.put(&git, cache.currentGeneration(), 1);
    try cache.put(&jj, cache.currentGeneration(), 2);
    try cache.put(&worktree, cache.currentGeneration(), 3);
    try cache.put(&moved_store, cache.currentGeneration(), 4);
    try std.testing.expectEqual(@as(u32, 1), cache.get(&git).fresh);
    try std.testing.expectEqual(@as(u32, 2), cache.get(&jj).fresh);
    try std.testing.expectEqual(@as(u32, 3), cache.get(&worktree).fresh);
    try std.testing.expectEqual(@as(u32, 4), cache.get(&moved_store).fresh);
    cache.invalidate(&git);
    try std.testing.expect(cache.get(&git) == .missing);
    try std.testing.expectEqual(@as(u32, 2), cache.get(&jj).fresh);
}

test "older results cannot overwrite a newer request or invalidation" {
    var cache = TestCache.init(500, fakeClock);
    const key = try identity.Workspace.init(.svn, "repo", "repo");
    const old = cache.beginRequest();
    const current = cache.beginRequest();
    try cache.put(&key, current, 2);
    try std.testing.expectError(error.Stale, cache.put(&key, old, 1));
    cache.invalidateAll();
    try std.testing.expectError(error.Stale, cache.put(&key, current, 2));
    try std.testing.expect(cache.get(&key) == .missing);
}

test "the cache stays bounded and evicts the oldest entry" {
    var cache = TestCache.init(10_000, fakeClock);
    var buffer: [64]u8 = undefined;
    var index: usize = 0;
    while (index < TestCache.max_entries) : (index += 1) {
        fake_now_ms = @intCast(index);
        const path = try std.fmt.bufPrint(&buffer, "repo{d}", .{index});
        const key = try identity.Workspace.init(.git, path, path);
        try cache.put(&key, cache.currentGeneration(), @intCast(index));
    }
    fake_now_ms = 100;
    const new = try identity.Workspace.init(.git, "new", "new");
    const oldest = try identity.Workspace.init(.git, "repo0", "repo0");
    try cache.put(&new, cache.currentGeneration(), 99);
    try std.testing.expectEqual(@as(u8, TestCache.max_entries), cache.len);
    try std.testing.expect(cache.get(&oldest) == .missing);
    try std.testing.expectEqual(@as(u32, 99), cache.get(&new).fresh);
}

test "aging and clock extremes do not overflow" {
    fake_now_ms = std.math.minInt(i64);
    var cache = TestCache.init(std.math.maxInt(i64), fakeClock);
    const key = try identity.Workspace.init(.git, "repo", "repo");
    try cache.put(&key, cache.currentGeneration(), 3);
    fake_now_ms = std.math.maxInt(i64);
    try std.testing.expectEqual(@as(u32, 3), cache.get(&key).stale);
    try cache.put(&key, cache.currentGeneration(), 4);
    cache.ageAll();
    try std.testing.expectEqual(@as(u32, 4), cache.get(&key).stale);
}
