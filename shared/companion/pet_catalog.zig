//! Worker-owned catalog records; independent of source files and UI.
//! Caller owns bounded storage and serialization. No decoding or I/O here.
const std = @import("std");
const assets = @import("pet_assets.zig");

pub const max_tags = 16;
pub const max_tag_bytes = 64;
pub const max_query_bytes = 256;
pub const Error = error{ Invalid, TagCapacity, DuplicateAsset, CatalogFull, UnknownAsset };

fn Text(comptime cap: usize) type {
    return struct {
        bytes: [cap]u8 = @splat(0),
        len: usize = 0,

        const Self = @This();
        fn init(raw: []const u8) Error!Self {
            const value = std.mem.trim(u8, raw, " \t");
            if (value.len == 0 or value.len > cap or !std.unicode.utf8ValidateSlice(value)) return error.Invalid;
            for (value) |byte| {
                if (byte < 32 or byte == 127) return error.Invalid;
            }
            var out: Self = .{};
            @memcpy(out.bytes[0..value.len], value);
            out.len = value.len;
            return out;
        }

        fn slice(self: *const Self) []const u8 {
            return self.bytes[0..self.len];
        }
    };
}

const Tag = Text(max_tag_bytes);
const Name = Text(320);
const Source = Text(64);

fn contains(haystack: []const u8, needle: []const u8) bool {
    if (needle.len > haystack.len) return false;
    for (0..haystack.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

pub const Entry = struct {
    id: u64,
    source_id: Source,
    name: Name,
    layout: assets.Layout,
    favorite: bool = false,
    tags: [max_tags]Tag = @splat(.{}),
    tag_count: usize = 0,

    pub fn init(id: u64, source_id: []const u8, name: []const u8, layout: assets.Layout) Error!Entry {
        if (id == 0) return error.Invalid;
        return .{ .id = id, .source_id = try Source.init(source_id), .name = try Name.init(name), .layout = layout };
    }

    // Only validated package metadata should reach this boundary.
    pub fn fromMetadata(id: u64, source_id: []const u8, meta: *const assets.Metadata) Error!Entry {
        return init(id, source_id, meta.display_name[0..meta.display_name_len], meta.layout);
    }

    pub fn displayName(self: *const Entry) []const u8 {
        return self.name.slice();
    }

    pub fn tagAt(self: *const Entry, index: usize) ?[]const u8 {
        return if (index < self.tag_count) self.tags[index].slice() else null;
    }

    pub fn hasTag(self: *const Entry, raw: []const u8) bool {
        const value = std.mem.trim(u8, raw, " \t");
        for (self.tags[0..self.tag_count]) |*tag| {
            if (std.ascii.eqlIgnoreCase(tag.slice(), value)) return true;
        }
        return false;
    }

    // Duplicate adds are idempotent. Preserve first user spelling.
    pub fn addTag(self: *Entry, raw: []const u8) Error!bool {
        const tag = try Tag.init(raw);
        if (self.hasTag(tag.slice())) return false;
        if (self.tag_count == max_tags) return error.TagCapacity;
        self.tags[self.tag_count] = tag;
        self.tag_count += 1;
        return true;
    }

    pub fn removeTag(self: *Entry, raw: []const u8) bool {
        const value = std.mem.trim(u8, raw, " \t");
        for (self.tags[0..self.tag_count], 0..) |*tag, i| {
            if (!std.ascii.eqlIgnoreCase(tag.slice(), value)) continue;
            var j = i;
            while (j + 1 < self.tag_count) : (j += 1) self.tags[j] = self.tags[j + 1];
            self.tag_count -= 1;
            self.tags[self.tag_count] = .{};
            return true;
        }
        return false;
    }

    fn matchesToken(self: *const Entry, token: []const u8) bool {
        if (contains(self.name.slice(), token) or contains(self.source_id.slice(), token)) return true;
        for (self.tags[0..self.tag_count]) |*tag| {
            if (contains(tag.slice(), token)) return true;
        }
        return false;
    }
};

pub const Mode = enum { all, any };
pub const Filter = struct {
    query: []const u8 = "",
    tags: []const []const u8 = &.{},
    mode: Mode = .all,
    favorites_only: bool = false,
    layout: ?assets.Layout = null,

    pub fn validate(self: Filter) Error!void {
        if (self.query.len > max_query_bytes or !std.unicode.utf8ValidateSlice(self.query) or self.tags.len > max_tags) return error.Invalid;
        for (self.query) |byte| {
            if (byte < 32 and byte != '\t' or byte == 127) return error.Invalid;
        }
        for (self.tags) |tag| _ = try Tag.init(tag);
    }

    fn matches(self: Filter, entry: *const Entry) bool {
        if (self.favorites_only and !entry.favorite) return false;
        if (self.layout) |layout| {
            if (entry.layout != layout) return false;
        }
        var words = std.mem.tokenizeAny(u8, self.query, " \t");
        while (words.next()) |word| {
            if (!entry.matchesToken(word)) return false;
        }
        if (self.tags.len == 0) return true;
        var n: usize = 0;
        for (self.tags) |tag| {
            if (entry.hasTag(tag)) n += 1;
        }
        return if (self.mode == .all) n == self.tags.len else n != 0;
    }
};

// A bounded mutable catalog over caller-owned storage. No borrowed pointers
// in results: return IDs. Filtered pagination counts matching records only.
pub const Catalog = struct {
    storage: []Entry,
    len: usize = 0,

    pub fn insert(self: *Catalog, entry: Entry) Error!void {
        for (self.storage[0..self.len]) |*existing| {
            if (existing.id == entry.id) return error.DuplicateAsset;
        }
        if (self.len == self.storage.len) return error.CatalogFull;
        self.storage[self.len] = entry;
        self.len += 1;
    }

    pub fn get(self: *Catalog, id: u64) Error!*Entry {
        for (self.storage[0..self.len]) |*entry| {
            if (entry.id == id) return entry;
        }
        return error.UnknownAsset;
    }

    pub const Page = struct { written: usize, total: usize };

    pub fn search(self: *const Catalog, filter: Filter, offset: usize, ids: []u64) Error!Page {
        try filter.validate();
        var page: Page = .{ .written = 0, .total = 0 };
        for (self.storage[0..self.len]) |*entry| {
            if (!filter.matches(entry)) continue;
            if (page.total >= offset and page.written < ids.len) {
                ids[page.written] = entry.id;
                page.written += 1;
            }
            page.total += 1;
        }
        return page;
    }
};

test "Chinese tags, ASCII case folding, combined filters and pagination" {
    var storage: [3]Entry = undefined;
    var catalog: Catalog = .{ .storage = &storage };
    try catalog.insert(try Entry.init(1, "cat", "猫咪 Cat", .v2));
    try catalog.insert(try Entry.init(2, "dog", "小狗", .v1));
    try catalog.insert(try Entry.init(3, "fox", "狐狸", .v2));
    const cat = try catalog.get(1);
    cat.favorite = true;
    try std.testing.expect(try cat.addTag(" 可爱 "));
    try std.testing.expect(try cat.addTag("Pixel"));
    try std.testing.expect(!try cat.addTag("pixel"));
    try std.testing.expect(try (try catalog.get(3)).addTag("可爱"));
    var ids: [1]u64 = undefined;
    const result = try catalog.search(.{ .query = "CAT 可爱", .tags = &.{"PIXEL"}, .favorites_only = true }, 0, &ids);
    try std.testing.expectEqual(@as(usize, 1), result.total);
    try std.testing.expectEqual(@as(u64, 1), ids[0]);
    const next = try catalog.search(.{ .tags = &.{ "可爱", "Pixel" }, .mode = .any }, 1, &ids);
    try std.testing.expectEqual(@as(usize, 2), next.total);
    try std.testing.expectEqual(@as(u64, 3), ids[0]);
    try std.testing.expect(cat.removeTag("PIXEL"));
    try std.testing.expect(!cat.hasTag("Pixel"));
    try std.testing.expectError(error.Invalid, cat.addTag("\x00bad"));
    try std.testing.expectError(error.DuplicateAsset, catalog.insert(cat.*));
}

test "validated metadata owns display name and tags remain local" {
    const meta = try assets.parseMetadata(std.testing.allocator, "{\"id\":\"cat\",\"displayName\":\"猫咪\",\"description\":\"Fixture\",\"spritesheetPath\":\"spritesheet.webp\"}", "cat");
    var entry = try Entry.fromMetadata(1, "cat", &meta);
    try std.testing.expectEqualStrings("猫咪", entry.displayName());
    try std.testing.expect(try entry.addTag("工作"));
    try std.testing.expectEqualStrings("工作", entry.tagAt(0).?);
    try std.testing.expect(entry.tagAt(1) == null);
}

test "tag storage and search input are bounded" {
    var entry = try Entry.init(1, "cat", "Cat", .v1);
    for (0..max_tags) |i| {
        var buffer: [16]u8 = undefined;
        const tag = try std.fmt.bufPrint(&buffer, "tag-{d}", .{i});
        try std.testing.expect(try entry.addTag(tag));
    }
    try std.testing.expectError(error.TagCapacity, entry.addTag("overflow"));
    try std.testing.expect(!try entry.addTag("TAG-0"));
    try std.testing.expect(entry.removeTag("tag-0"));
    try std.testing.expect(try entry.addTag("replacement"));
    try std.testing.expectError(error.Invalid, (Filter{ .query = &([_]u8{'a'} ** (max_query_bytes + 1)) }).validate());
}
