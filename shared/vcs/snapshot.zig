//! Bounded snapshot cache with generation counters.
//!
//! The cache never hides age: `get` distinguishes `fresh`, `stale` and
//! `missing`, and every invalidation bumps a generation so results computed
//! before the invalidation can be discarded instead of published.

const std = @import("std");
const identity = @import("vcs_identity");

/// `now_ms` is injected so tests do not sleep and callers can use a monotonic
/// clock from any thread.
pub fn Cache(comptime Value: type) type {
    return struct {
        pub const max_entries = 8;

        pub const Entry = struct {
            key: identity.Path,
            value: Value,
            stored_at_ms: i64,
            generation: u64,
        };

        pub const Lookup = union(enum) {
            missing,
            /// Older than the TTL; the value is only useful as a placeholder.
            stale: *const Value,
            fresh: *const Value,
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

        /// A result tagged with an older generation must not be published.
        pub fn isCurrent(self: *const Self, generation: u64) bool {
            return generation == self.generation;
        }

        pub fn get(self: *Self, root: []const u8) Lookup {
            const entry = self.find(root) orelse return .missing;
            if (self.now() - entry.stored_at_ms > self.ttl_ms) return .{ .stale = &entry.value };
            return .{ .fresh = &entry.value };
        }

        pub fn put(self: *Self, root: []const u8, value: Value) error{InvalidKey}!u64 {
            const key = identity.Path.init(root) catch return error.InvalidKey;
            const now_ms = self.now();
            const generation = self.generation;

            if (self.find(root)) |entry| {
                entry.* = .{ .key = key, .value = value, .stored_at_ms = now_ms, .generation = generation };
                return generation;
            }
            if (self.len == max_entries) {
                const victim = self.oldest() orelse return error.InvalidKey;
                victim.* = .{ .key = key, .value = value, .stored_at_ms = now_ms, .generation = generation };
                return generation;
            }
            self.entries[self.len] = .{ .key = key, .value = value, .stored_at_ms = now_ms, .generation = generation };
            self.len += 1;
            return generation;
        }

        /// Drops one repository and invalidates in-flight results.
        pub fn invalidate(self: *Self, root: []const u8) void {
            self.generation +%= 1;
            var index: usize = 0;
            while (index < self.len) {
                if (self.entries[index].key.eql(root)) {
                    self.entries[index] = self.entries[self.len - 1];
                    self.len -= 1;
                    return;
                }
                index += 1;
            }
        }

        pub fn invalidateAll(self: *Self) void {
            self.generation +%= 1;
            self.len = 0;
        }

        /// Marks every entry stale without discarding it, for "show cached
        /// data while an external change is re-read".
        pub fn ageAll(self: *Self) void {
            self.generation +%= 1;
            for (self.entries[0..self.len]) |*entry| {
                entry.stored_at_ms -= self.ttl_ms + 1;
            }
        }

        fn find(self: *Self, root: []const u8) ?*Entry {
            for (self.entries[0..self.len]) |*entry| {
                if (entry.key.eql(root)) return entry;
            }
            return null;
        }

        fn oldest(self: *Self) ?*Entry {
            if (self.len == 0) return null;
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

test "fresh values are returned until the TTL expires" {
    fake_now_ms = 1000;
    var cache = TestCache.init(500, fakeClock);
    _ = try cache.put("C:\\repo", 7);

    switch (cache.get("C:\\repo")) {
        .fresh => |value| try std.testing.expectEqual(@as(u32, 7), value.*),
        else => return error.TestExpectedFresh,
    }
    fake_now_ms = 1600;
    switch (cache.get("C:\\repo")) {
        .stale => |value| try std.testing.expectEqual(@as(u32, 7), value.*),
        else => return error.TestExpectedStale,
    }
}

test "missing entries are not fabricated" {
    var cache = TestCache.init(500, fakeClock);
    try std.testing.expect(cache.get("C:\\repo") == .missing);
}

test "invalidation bumps the generation and drops the entry" {
    var cache = TestCache.init(500, fakeClock);
    const before = try cache.put("C:\\repo", 1);
    cache.invalidate("C:\\repo");
    try std.testing.expect(!cache.isCurrent(before));
    try std.testing.expect(cache.get("C:\\repo") == .missing);
    try std.testing.expect(cache.isCurrent(cache.currentGeneration()));
}

test "put replaces an existing entry and reuses its slot" {
    var cache = TestCache.init(500, fakeClock);
    _ = try cache.put("C:\\repo", 1);
    _ = try cache.put("C:\\repo", 2);
    try std.testing.expectEqual(@as(u8, 1), cache.len);
    switch (cache.get("C:\\repo")) {
        .fresh => |value| try std.testing.expectEqual(@as(u32, 2), value.*),
        else => return error.TestExpectedFresh,
    }
}

test "the cache stays bounded and evicts the oldest entry" {
    var cache = TestCache.init(10_000, fakeClock);
    var buffer: [64]u8 = undefined;
    var index: usize = 0;
    while (index < TestCache.max_entries) : (index += 1) {
        fake_now_ms = @intCast(index);
        const key = try std.fmt.bufPrint(&buffer, "C:\\repo{d}", .{index});
        _ = try cache.put(key, @intCast(index));
    }
    try std.testing.expectEqual(@as(u8, TestCache.max_entries), cache.len);

    fake_now_ms = 100;
    _ = try cache.put("C:\\new", 99);
    try std.testing.expectEqual(@as(u8, TestCache.max_entries), cache.len);
    try std.testing.expect(cache.get("C:\\repo0") == .missing);
    try std.testing.expect(cache.get("C:\\new") != .missing);
}

test "ageAll keeps data as stale instead of losing it" {
    fake_now_ms = 1000;
    var cache = TestCache.init(500, fakeClock);
    _ = try cache.put("C:\\repo", 3);
    cache.ageAll();
    switch (cache.get("C:\\repo")) {
        .stale => |value| try std.testing.expectEqual(@as(u32, 3), value.*),
        else => return error.TestExpectedStale,
    }
}
