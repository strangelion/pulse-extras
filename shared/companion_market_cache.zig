//! Serialized Windows cache adapter. Only a dedicated approved private
//! cache root; all slots disposable, never place user files in this root.
//! Caller provides bounded allocator/buffers and current UTC epoch seconds.
const std = @import("std");
const market = @import("companion/pet_market.zig");
const codec = @import("companion/pet_market_cache.zig");

extern "c" fn pet_market_cache_read([*:0]const u16, u32, [*]u8, usize, *usize) c_int;
extern "c" fn pet_market_cache_write([*:0]const u16, u32, [*]const u8, usize) c_int;
extern "c" fn pet_catalog_store_fixture_open([*]u16, u32) c_int;
extern "c" fn pet_market_cache_fixture_close([*:0]const u16) c_int;

pub const Request = union(enum) {
    root,
    search_index: market.Index,
    search_page: struct { root: market.Index, index: market.SearchIndex, number: u32 },
    detail: struct { root: market.Index, number: u32 },

    pub fn key(self: Request) !codec.Key {
        const value: codec.Key = switch (self) {
            .root => .{ .revision = "", .url = market.index_url },
            .search_index => |index| .{ .revision = index.generatedAt, .url = index.search },
            .search_page => |page| blk: {
                if (page.number >= page.index.pages.len) return error.InvalidCatalog;
                break :blk .{ .revision = page.root.generatedAt, .url = page.index.pages[page.number] };
            },
            .detail => |page| blk: {
                if (page.number >= page.root.pages.len) return error.InvalidCatalog;
                break :blk .{ .revision = page.root.generatedAt, .url = page.root.pages[page.number] };
            },
        };
        if (!value.valid()) return error.InvalidCatalog;
        return value;
    }

    /// Cached JSON must pass the same validators as the network response.
    pub fn validate(self: Request, allocator: std.mem.Allocator, payload: []const u8) !void {
        switch (self) {
            .root => {
                const parsed = try market.parseIndex(allocator, payload);
                defer parsed.deinit();
            },
            .search_index => |root| {
                const parsed = try market.parseSearchIndex(allocator, payload, root);
                defer parsed.deinit();
            },
            .search_page => |page| {
                const parsed = try market.parseSearchPage(allocator, payload, page.root, page.index, page.number);
                defer parsed.deinit();
            },
            .detail => |page| {
                const root = page.root;
                const offset = @as(u64, page.number) * root.pageSize;
                if (root.pageSize == 0 or offset >= root.total) return error.InvalidCatalog;
                const parsed = try market.parsePage(allocator, payload, page.number, root.pageSize);
                defer parsed.deinit();
                if (parsed.value.pets.len != @min(root.pageSize, root.total - offset)) return error.InvalidCatalog;
            },
        }
    }
};

fn check(code: c_int) !void {
    return switch (code) {
        0 => {},
        2 => error.InvalidRecord,
        3 => error.Io,
        4 => error.Busy,
        5 => error.CleanupFailed,
        else => error.Io,
    };
}

const NativeAccess = struct {
    pub fn read(_: NativeAccess, root: [*:0]const u16, slot: u32, buffer: []u8) !?usize {
        var len: usize = 0;
        const code = pet_market_cache_read(root, slot, buffer.ptr, buffer.len, &len);
        if (code == 1) return null;
        try check(code);
        return len;
    }

    pub fn write(_: NativeAccess, root: [*:0]const u16, slot: u32, data: []const u8) !void {
        try check(pet_market_cache_write(root, slot, data.ptr, data.len));
    }
};

pub const Cache = CacheFor(NativeAccess);

pub fn CacheFor(comptime Access: type) type {
    return struct {
        const Self = @This();
        root: [*:0]const u16,
        access: Access = .{},

        /// Returned payload borrows the caller's buffer. Miss is explicit;
        /// malformed, IO and cleanup failures must remain visible to the owner.
        pub fn load(self: Self, allocator: std.mem.Allocator, request: Request, buffer: []u8, now: u64, offline: bool) !?codec.Entry {
            const key = try request.key();
            if (buffer.len == 0 or buffer.len > codec.max_record) return error.BufferTooSmall;
            const len = (try self.access.read(self.root, key.slot(), buffer)) orelse return null;
            if (len > buffer.len) return error.InvalidRecord;
            const entry = (try codec.decode(buffer[0..len], key, now, offline)) orelse return null;
            try request.validate(allocator, entry.payload);
            return entry;
        }

        pub fn save(self: Self, allocator: std.mem.Allocator, request: Request, payload: []const u8, now: u64) !void {
            const key = try request.key();
            try request.validate(allocator, payload);
            const buffer = try allocator.alloc(u8, codec.header_size + key.revision.len + key.url.len + payload.len);
            defer allocator.free(buffer);
            const data = try codec.encode(buffer, key, now, payload);
            try self.access.write(self.root, key.slot(), data);
        }
    };
}

test "native cache survives reopen, replaces root atomically and validates JSON" {
    const allocator = std.testing.allocator;
    var root: [1024]u16 = @splat(0);
    try std.testing.expect(pet_catalog_store_fixture_open(&root, root.len) != 0);
    const path: [*:0]const u16 = @ptrCast(&root);
    defer {
        std.testing.expect(pet_market_cache_fixture_close(path) != 0) catch @panic("cache fixture cleanup failed");
    }
    const cache: Cache = .{ .root = path };
    var bytes: [1024]u8 = undefined;
    const payload = "{\"version\":3,\"generatedAt\":\"revision-a\",\"total\":0,\"pageSize\":20,\"search\":\"https://openpets.dev/pets/catalog.v3/rev/search.json\",\"pages\":[]}";
    try std.testing.expect((try cache.load(allocator, .root, &bytes, 1000, false)) == null);
    try cache.save(allocator, .root, payload, 1000);
    const reopened: Cache = .{ .root = path };
    try std.testing.expectEqualStrings(payload, (try reopened.load(allocator, .root, &bytes, 1001, false)).?.payload);
    try std.testing.expectError(error.InvalidCatalog, cache.save(allocator, .root, "{}", 1100));
    try std.testing.expect((try reopened.load(allocator, .root, &bytes, 1900, false)) == null);
    try std.testing.expect((try reopened.load(allocator, .root, &bytes, 1900, true)).?.stale);
    try cache.save(allocator, .root, payload, 1900);
    try std.testing.expect(!(try reopened.load(allocator, .root, &bytes, 1901, false)).?.stale);
}
