//! Bounded transfer and admission contracts. Each worker owns its own
//! private scratch Store; the serialized dispatcher owns the Pool. No
//! shared mutable file table, no network or thread creation in Pool.
const std = @import("std");
const market = @import("pet_market.zig");
const zip = @import("pet_zip.zig");
const Store = @import("runtime_temp_store").Store;
const Budget = @import("runtime_budget").Budget;

pub const Kind = enum(c_uint) { index, catalog, preview, zip };

pub fn limit(kind: Kind) usize {
    return switch (kind) {
        .index, .catalog => market.max_response_bytes,
        .preview => 4 * 1024 * 1024,
        .zip => zip.max_archive_bytes,
    };
}

pub fn validUrl(kind: Kind, url: []const u8) bool {
    return switch (kind) {
        .index => std.mem.eql(u8, url, market.index_url),
        .catalog => market.validUrl(url, .catalog),
        .zip => market.validUrl(url, .zip),
        .preview => market.validUrl(url, .preview) and !std.mem.endsWith(u8, url, ".svg"),
    };
}

pub const Control = struct {
    canceled: std.atomic.Value(bool) = .init(false),
    received: std.atomic.Value(usize) = .init(0),
    expected: std.atomic.Value(usize) = .init(0), // zero means unknown

    pub fn cancel(self: *Control) void {
        self.canceled.store(true, .release);
    }

    pub fn check(self: *const Control) !void {
        if (self.canceled.load(.acquire)) return error.Canceled;
    }
};

pub const Pool = struct {
    const Slot = struct { id: u64, kind: Kind };
    disk: Budget = Budget.init(2 * 1024 * 1024 * 1024),
    downloads: usize = 4,
    previews: usize = 4,
    next_id: u64 = 1,
    slots: [17]?Slot = @splat(null),

    pub fn acquire(self: *Pool, kind: Kind) !u64 {
        if (self.downloads == 0 or self.downloads > 8 or self.previews == 0 or self.previews > 8) return error.InvalidLimit;
        var count: usize = 0;
        for (self.slots) |slot| {
            if (slot) |entry| {
                const same = if (kind == .index or kind == .catalog) entry.kind == .index or entry.kind == .catalog else entry.kind == kind;
                if (same) count += 1;
            }
        }
        const cap = switch (kind) {
            .index, .catalog => 1,
            .preview => self.previews,
            .zip => self.downloads,
        };
        if (count >= cap or self.next_id == std.math.maxInt(u64)) return error.ResourceLimit;
        for (&self.slots) |*slot| {
            if (slot.* != null) continue;
            try self.disk.reserve(limit(kind));
            const id = self.next_id;
            self.next_id += 1;
            slot.* = .{ .id = id, .kind = kind };
            return id;
        }
        return error.ResourceLimit;
    }

    /// Call only after the worker has joined AND all temporary files covered
    /// by this lease are removed. Extraction requires a separate reservation.
    pub fn release(self: *Pool, id: u64) !void {
        for (&self.slots) |*slot| {
            if (slot.*) |entry| {
                if (entry.id != id) continue;
                self.disk.release(limit(entry.kind));
                slot.* = null;
                return;
            }
        }
        return error.NotOwned;
    }
};

pub const Result = struct { id: u64, bytes: usize, file: std.Io.File };

pub const Sink = struct {
    store: *Store,
    control: *Control,
    id: u64,
    cap: usize,
    expected: ?usize = null,
    bytes: usize = 0,
    started: bool = false,

    pub fn headers(self: *Sink, length: ?usize) !void {
        try self.control.check();
        if (self.started) return error.InvalidResponse;
        if (length) |n| {
            if (n == 0 or n > self.cap) return error.ResourceLimit;
            self.control.expected.store(n, .release);
        }
        self.expected = length;
        self.started = true;
    }

    pub fn append(self: *Sink, data: []const u8) !void {
        try self.control.check();
        if (!self.started or data.len == 0) return error.InvalidResponse;
        if (data.len > self.cap - self.bytes) return error.ResourceLimit;
        if (self.expected) |n| {
            if (data.len > n - self.bytes) return error.InvalidResponse;
        }
        try self.store.append(self.id, data);
        self.bytes += data.len;
        self.control.received.store(self.bytes, .release);
    }

    fn finish(self: *Sink) !Result {
        try self.control.check();
        if (!self.started or self.bytes == 0) return error.InvalidResponse;
        if (self.expected) |n| {
            if (n != self.bytes) return error.InvalidResponse;
        }
        return .{ .id = self.id, .bytes = self.bytes, .file = try self.store.seal(self.id) };
    }
};

/// The worker owns store/control; a fresh Control is used per request.
/// The transport must enforce authenticated TLS and HTTP response policy
/// before calling headers, and return only after all callbacks have stopped.
pub fn fetch(store: *Store, transport: anytype, kind: Kind, url: []const u8, control: *Control) !Result {
    if (!validUrl(kind, url)) return error.InvalidUrl;
    try control.check();
    const id = try store.create();
    var sink: Sink = .{ .store = store, .control = control, .id = id, .cap = limit(kind) };
    transport.get(kind, url, &sink) catch |err| {
        store.remove(id) catch {
            if (err == error.TransportCleanupFailed) return err;
            return error.CleanupFailed;
        };
        return err;
    };
    return sink.finish() catch |err| {
        store.remove(id) catch return error.CleanupFailed;
        return err;
    };
}

const Mock = struct {
    mode: enum { normal, short, oversized, canceled } = .normal,

    fn get(self: Mock, _: Kind, _: []const u8, sink: *Sink) !void {
        try sink.headers(if (self.mode == .oversized) sink.cap + 1 else 4);
        try sink.append("ab");
        if (self.mode == .short) return;
        if (self.mode == .canceled) sink.control.cancel();
        try sink.append("cd");
    }
};

test "bounded transfer seals readable file and cleans failed or canceled requests" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.io, tmp.dir, 32);
    defer store.cleanup() catch {};
    var control: Control = .{};
    const url = market.index_url;
    const result = try fetch(&store, Mock{}, .index, url, &control);
    try std.testing.expectEqual(@as(usize, 4), result.bytes);
    try std.testing.expectError(error.Closed, store.append(result.id, "x"));
    var bytes: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try result.file.readPositionalAll(std.testing.io, &bytes, 0));
    try std.testing.expectEqualStrings("abcd", &bytes);
    try store.remove(result.id);
    control = .{};
    try std.testing.expectError(error.InvalidResponse, fetch(&store, Mock{ .mode = .short }, .index, url, &control));
    control = .{};
    try std.testing.expectError(error.ResourceLimit, fetch(&store, Mock{ .mode = .oversized }, .index, url, &control));
    control = .{};
    try std.testing.expectError(error.Canceled, fetch(&store, Mock{ .mode = .canceled }, .index, url, &control));
    try store.checkDrained();
}

test "parallel admission reserves worst case and rejects stale releases" {
    var pool: Pool = .{};
    var ids: [4]u64 = undefined;
    for (&ids) |*id| id.* = try pool.acquire(.zip);
    try std.testing.expectError(error.ResourceLimit, pool.acquire(.zip));
    const preview = try pool.acquire(.preview);
    const index = try pool.acquire(.index);
    try std.testing.expectError(error.ResourceLimit, pool.acquire(.catalog));
    try pool.release(preview);
    try pool.release(index);
    for (ids) |id| try pool.release(id);
    try std.testing.expectError(error.NotOwned, pool.release(ids[0]));
    try std.testing.expectEqual(@as(usize, 0), pool.disk.used);
    pool.disk = Budget.init(limit(.zip));
    const one = try pool.acquire(.zip);
    try std.testing.expectError(error.BudgetExceeded, pool.acquire(.preview));
    try pool.release(one);
}
