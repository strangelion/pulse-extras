//! Worker-owned catalog records; independent of source files and UI.
//! Caller owns bounded storage and serialization. No decoding or I/O here.
const std = @import("std");
const assets = @import("pet_assets.zig");
const manager = @import("pet_manager.zig");

pub const max_tags = 16;
pub const max_tag_bytes = 64;
pub const max_query_bytes = 256;
pub const Error = error{ Invalid, TagCapacity, DuplicateAsset, CatalogFull, UnknownAsset, AssetInUse, InvalidRecord, BufferTooSmall };

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

pub const Feature = enum { activities, outfits, scheduled_outfits, gaze_layout };

pub const Features = struct {
    activities: bool = false,
    outfits: bool = false,
    scheduled_outfits: bool = false,
    gaze_layout: bool = false,

    pub fn has(self: Features, feature: Feature) bool {
        return switch (feature) {
            .activities => self.activities,
            .outfits => self.outfits,
            .scheduled_outfits => self.scheduled_outfits,
            .gaze_layout => self.gaze_layout,
        };
    }
};

pub const Entry = struct {
    id: u64,
    source_id: Source,
    name: Name,
    layout: assets.Layout,
    favorite: bool = false,
    features: Features = .{},
    tags: [max_tags]Tag = @splat(.{}),
    tag_count: usize = 0,

    pub fn init(id: u64, source_id: []const u8, name: []const u8, layout: assets.Layout) Error!Entry {
        if (id == 0) return error.Invalid;
        return .{ .id = id, .source_id = try Source.init(source_id), .name = try Name.init(name), .layout = layout };
    }

    // Only validated package metadata should reach this boundary.
    pub fn fromMetadata(id: u64, source_id: []const u8, meta: *const assets.Metadata) Error!Entry {
        var entry = try init(id, source_id, meta.display_name[0..meta.display_name_len], meta.layout);
        entry.features = .{
            .activities = meta.activities.count != 0,
            .outfits = meta.wardrobe.count != 0,
            .scheduled_outfits = meta.wardrobe.rule_count != 0,
            .gaze_layout = meta.layout == .v2,
        };
        return entry;
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
    features: []const Feature = &.{},

    pub fn validate(self: Filter) Error!void {
        if (self.query.len > max_query_bytes or !std.unicode.utf8ValidateSlice(self.query) or self.tags.len > max_tags or self.features.len > 4) return error.Invalid;
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
        for (self.features) |feature| {
            if (!entry.features.has(feature)) return false;
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

    // Remove only the catalog record, never a source directory. The
    // same serialized worker must own both manager and catalog mutations.
    pub fn remove(self: *Catalog, instances: *const manager.Manager, id: u64) Error!void {
        for (self.storage[0..self.len], 0..) |*entry, i| {
            if (entry.id != id) continue;
            if (!instances.canRemoveAsset(id)) return error.AssetInUse;
            var j = i;
            while (j + 1 < self.len) : (j += 1) self.storage[j] = self.storage[j + 1];
            self.len -= 1;
            self.storage[self.len] = undefined;
            return;
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
    const oversized: [max_query_bytes + 1]u8 = @splat('a');
    try std.testing.expectError(error.Invalid, (Filter{ .query = &oversized }).validate());
}

// Versioned local preferences record, separate from source metadata.
// Format: magic[4], stable asset ID LE[8], source length[1], source bytes,
// favorite[1], tag count[1], repeated length[1] + UTF-8 tag. Exact end required.
// The durable catalog must authenticate the ID/source binding against its
// validated inventory; this record is not authorization to launch a path.
pub const max_preferences_bytes = 4 + 8 + 1 + 64 + 2 + max_tags * (1 + max_tag_bytes);

pub fn encodePreferences(entry: *const Entry, out: []u8) Error![]const u8 {
    const source = entry.source_id.slice();
    var needed: usize = 15 + source.len;
    for (entry.tags[0..entry.tag_count]) |*tag| needed += 1 + tag.len;
    if (out.len < needed) return error.BufferTooSmall;
    @memcpy(out[0..4], "PCT1");
    for (0..8) |i| out[4 + i] = @truncate(entry.id >> @as(u6, @intCast(i * 8)));
    out[12] = @intCast(source.len);
    @memcpy(out[13 .. 13 + source.len], source);
    var pos = 13 + source.len;
    out[pos] = @intFromBool(entry.favorite);
    out[pos + 1] = @intCast(entry.tag_count);
    pos += 2;
    for (entry.tags[0..entry.tag_count]) |*tag| {
        out[pos] = @intCast(tag.len);
        pos += 1;
        @memcpy(out[pos .. pos + tag.len], tag.slice());
        pos += tag.len;
    }
    return out[0..pos];
}

pub fn decodePreferences(entry: *Entry, input: []const u8) Error!void {
    if (input.len < 15 or input.len > max_preferences_bytes or !std.mem.eql(u8, input[0..4], "PCT1")) return error.InvalidRecord;
    var id: u64 = 0;
    for (0..8) |i| id |= @as(u64, input[4 + i]) << @as(u6, @intCast(i * 8));
    if (id != entry.id) return error.InvalidRecord;
    const source_len: usize = input[12];
    if (source_len > input.len - 15 or !std.mem.eql(u8, entry.source_id.slice(), input[13 .. 13 + source_len])) return error.InvalidRecord;
    var pos = 13 + source_len;
    const favorite = input[pos];
    const count: usize = input[pos + 1];
    pos += 2;
    if (favorite > 1 or count > max_tags) return error.InvalidRecord;
    // Stage the entire record before publishing, preserving existing prefs
    // on truncation, invalid UTF-8, duplicate tags or unknown version.
    var candidate = entry.*;
    candidate.favorite = favorite == 1;
    candidate.tags = @splat(.{});
    candidate.tag_count = 0;
    for (0..count) |_| {
        if (pos == input.len) return error.InvalidRecord;
        const len: usize = input[pos];
        pos += 1;
        if (len > input.len - pos) return error.InvalidRecord;
        const added = candidate.addTag(input[pos .. pos + len]) catch return error.InvalidRecord;
        if (!added) return error.InvalidRecord;
        pos += len;
    }
    if (pos != input.len) return error.InvalidRecord;
    entry.* = candidate;
}

test "preference record round trip rejects truncation and wrong asset without mutation" {
    var original = try Entry.init(77, "cat", "猫咪", .v2);
    original.favorite = true;
    _ = try original.addTag("像素风");
    _ = try original.addTag("Work");
    var buffer: [max_preferences_bytes]u8 = undefined;
    const bytes = try encodePreferences(&original, &buffer);
    var restored = try Entry.init(77, "cat", "新名称", .v1);
    try decodePreferences(&restored, bytes);
    try std.testing.expect(restored.favorite and restored.hasTag("work"));
    try std.testing.expectEqualStrings("新名称", restored.displayName());
    try std.testing.expectEqual(assets.Layout.v1, restored.layout);
    for (0..bytes.len) |len| {
        try std.testing.expectError(error.InvalidRecord, decodePreferences(&restored, bytes[0..len]));
        try std.testing.expect(restored.hasTag("像素风"));
    }
    var other = try Entry.init(78, "cat", "Other", .v2);
    try std.testing.expectError(error.InvalidRecord, decodePreferences(&other, bytes));
    try std.testing.expect(!other.favorite);
    try std.testing.expectError(error.BufferTooSmall, encodePreferences(&original, buffer[0..4]));
}

test "automatic features and confirmed instance exit protect catalog removal" {
    const meta = try assets.parseMetadata(std.testing.allocator, "{\"id\":\"cat\",\"displayName\":\"Cat\",\"description\":\"Fixture\",\"spritesheetPath\":\"spritesheet.webp\",\"spriteVersionNumber\":2}", "cat");
    var storage: [2]Entry = undefined;
    var catalog: Catalog = .{ .storage = &storage };
    try catalog.insert(try Entry.fromMetadata(1, "cat", &meta));
    try catalog.insert(try Entry.init(2, "dog", "Dog", .v1));
    var ids: [2]u64 = undefined;
    const result = try catalog.search(.{ .features = &.{.gaze_layout} }, 0, &ids);
    try std.testing.expectEqual(@as(usize, 1), result.total);
    try std.testing.expectEqual(@as(u64, 1), ids[0]);
    var instances = try manager.Manager.init(2, manager.child_commit_ceiling * 2);
    const id = try instances.reserveStart(1);
    try std.testing.expectError(error.AssetInUse, catalog.remove(&instances, 1));
    try instances.requestStop(id);
    try std.testing.expectError(error.AssetInUse, catalog.remove(&instances, 1));
    try instances.confirmGone(id);
    try catalog.remove(&instances, 1);
    try std.testing.expectEqual(@as(usize, 1), catalog.len);
    try std.testing.expectError(error.UnknownAsset, catalog.get(1));
    try std.testing.expectEqualStrings("Dog", (try catalog.get(2)).displayName());
}
