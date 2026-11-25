//! Classic Idle Activities contract from OpenPetsHQ/openpets
//! @2f02bb04d872dec6923a47572343305235c63482, activities.ts.
//! Owned bounded metadata; no filesystem, decoder, scripts, timers or I/O.
const std = @import("std");

pub const max_activities = 16;
pub const max_outfits = 16;
pub const max_representations = max_outfits + 1;
pub const max_file_bytes = 2 * 1024 * 1024;
pub const max_total_bytes = 16 * 1024 * 1024;
pub const Error = error{ InvalidActivity, InvalidInventory };

pub const Id = struct {
    bytes: [32]u8 = @splat(0),
    len: u8 = 0,

    pub fn parse(value: []const u8) Error!Id {
        if (value.len == 0 or value.len > 32) return error.InvalidActivity;
        for (value, 0..) |c, i| {
            if ((c >= 'a' and c <= 'z') or std.ascii.isDigit(c)) continue;
            if (i > 0 and (c == '-' or c == '_')) continue;
            return error.InvalidActivity;
        }
        var result: Id = .{};
        result.len = @intCast(value.len);
        @memcpy(result.bytes[0..value.len], value);
        return result;
    }

    pub fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }
};

/// Count UTF-16 units, as the upstream JavaScript string length does.
/// Deliberately reject control characters and trim ASCII whitespace only.
pub fn checkedText(value: std.json.Value, max_units: usize) ?[]const u8 {
    if (value != .string) return null;
    const s = std.mem.trim(u8, value.string, " \t\r\n");
    if (s.len == 0 or !std.unicode.utf8ValidateSlice(s)) return null;
    var units: usize = 0;
    for (s) |c| {
        if (c < 32 or c == 127) return null;
        if (c < 128 or c >= 192) units += if (c >= 240) @as(usize, 2) else 1;
        if (units > max_units) return null;
    }
    return s;
}

pub const Representation = struct {
    outfit: Id = .{},
    frames: u8 = 0,
    fps: u8 = 0,

    pub fn valid(self: Representation) bool {
        if (self.frames < 4 or self.frames > 32 or self.fps < 1 or self.fps > 12) return false;
        const numerator = @as(u32, self.frames) * 1000;
        return numerator >= @as(u32, self.fps) * 1000 and numerator <= @as(u32, self.fps) * 12000;
    }

    pub fn width(self: Representation) u32 {
        return @as(u32, self.frames) * 192;
    }

    pub fn rgbaBytes(self: Representation) usize {
        return @as(usize, self.width()) * 208 * 4;
    }

    pub fn path(self: *const Representation, id: *const Id, primary: bool, buffer: []u8) error{NoSpaceLeft}![]const u8 {
        return if (primary)
            std.fmt.bufPrint(buffer, "activities/{s}.webp", .{id.slice()})
        else
            std.fmt.bufPrint(buffer, "activities/{s}.{s}.webp", .{ id.slice(), self.outfit.slice() });
    }
};

pub const Activity = struct {
    id: Id = .{},
    name: [160]u8 = @splat(0),
    name_len: u8 = 0,
    representations: [max_representations]Representation = @splat(.{}),
    count: u8 = 0,

    pub fn displayName(self: *const Activity) []const u8 {
        return self.name[0..self.name_len];
    }

    /// Exact outfit match only; the primary is not a fallback.
    pub fn resolve(self: *const Activity, outfit: []const u8) ?*const Representation {
        for (self.representations[0..self.count]) |*rep| {
            if (std.mem.eql(u8, rep.outfit.slice(), outfit)) return rep;
        }
        return null;
    }
};

pub const InventoryEntry = struct { path: []const u8, bytes: usize };

pub const Catalog = struct {
    items: [max_activities]Activity = @splat(.{}),
    count: u8 = 0,

    /// Exact inventory of regular activity files, supplied by a future
    /// handle-relative package loader. No archive extraction here.
    pub fn validateInventory(self: *const Catalog, entries: []const InventoryEntry) Error!void {
        var expected: usize = 0;
        for (self.items[0..self.count]) |*item| expected += item.count;
        if (entries.len != expected) return error.InvalidInventory;
        var seen: [max_activities * max_representations]bool = @splat(false);
        var total: usize = 0;
        for (entries) |entry| {
            if (entry.bytes == 0 or entry.bytes > max_file_bytes or entry.bytes > max_total_bytes - total) return error.InvalidInventory;
            total += entry.bytes;
            var matched = false;
            var index: usize = 0;
            for (self.items[0..self.count]) |*item| {
                for (item.representations[0..item.count], 0..) |*rep, i| {
                    var buffer: [96]u8 = undefined;
                    const path = rep.path(&item.id, i == 0, &buffer) catch unreachable;
                    if (std.mem.eql(u8, entry.path, path)) {
                        if (seen[index]) return error.InvalidInventory;
                        seen[index] = true;
                        matched = true;
                    }
                    index += 1;
                }
            }
            if (!matched) return error.InvalidInventory;
        }
    }
};

fn str(value: std.json.Value) Error![]const u8 {
    return if (value == .string) value.string else error.InvalidActivity;
}

fn integer(value: std.json.Value, min: i64, max: i64) Error!u8 {
    if (value != .integer or value.integer < min or value.integer > max) return error.InvalidActivity;
    return @intCast(value.integer);
}

fn addRepresentation(item: *Activity, value: std.json.Value, primary: bool, outfits: []const Id) Error!void {
    if (value != .object or item.count >= max_representations) return error.InvalidActivity;
    const obj = value.object;
    const outfit = try Id.parse(try str(obj.get("outfitId") orelse return error.InvalidActivity));
    var known = std.mem.eql(u8, outfit.slice(), "default");
    for (outfits) |*candidate| {
        if (std.mem.eql(u8, outfit.slice(), candidate.slice())) known = true;
    }
    if (!known or item.resolve(outfit.slice()) != null) return error.InvalidActivity;
    const rep: Representation = .{
        .outfit = outfit,
        .frames = try integer(obj.get("frameCount") orelse return error.InvalidActivity, 4, 32),
        .fps = try integer(obj.get("fps") orelse return error.InvalidActivity, 1, 12),
    };
    if (!rep.valid()) return error.InvalidActivity;
    var buffer: [96]u8 = undefined;
    const expected = rep.path(&item.id, primary, &buffer) catch unreachable;
    if (!std.mem.eql(u8, expected, try str(obj.get("spritesheetPath") orelse return error.InvalidActivity))) return error.InvalidActivity;
    // Unknown fields are inert, following the upstream normalized contract.
    item.representations[item.count] = rep;
    item.count += 1;
}

/// Caller provides already validated declared wardrobe IDs, if supported.
/// No input strings or parse allocations escape.
pub fn parse(value: ?std.json.Value, outfits: []const Id) Error!Catalog {
    var result: Catalog = .{};
    if (outfits.len > max_outfits) return error.InvalidActivity;
    for (outfits, 0..) |*outfit, i| {
        _ = try Id.parse(outfit.slice());
        if (std.mem.eql(u8, outfit.slice(), "default") or std.mem.eql(u8, outfit.slice(), "auto")) return error.InvalidActivity;
        for (outfits[0..i]) |*prior| {
            if (std.mem.eql(u8, outfit.slice(), prior.slice())) return error.InvalidActivity;
        }
    }
    const data = value orelse return result;
    if (data != .array or data.array.items.len > max_activities) return error.InvalidActivity;
    for (data.array.items) |entry| {
        if (entry != .object) return error.InvalidActivity;
        const obj = entry.object;
        const id = try Id.parse(try str(obj.get("id") orelse return error.InvalidActivity));
        for (result.items[0..result.count]) |*old| {
            if (std.mem.eql(u8, id.slice(), old.id.slice())) return error.InvalidActivity;
        }
        const name = checkedText(obj.get("displayName") orelse return error.InvalidActivity, 40) orelse return error.InvalidActivity;
        var item: Activity = .{ .id = id, .name_len = @intCast(name.len) };
        @memcpy(item.name[0..name.len], name);
        try addRepresentation(&item, entry, true, outfits);
        if (obj.get("outfitVariants")) |variants| {
            if (variants != .array or variants.array.items.len > max_outfits) return error.InvalidActivity;
            for (variants.array.items) |variant| try addRepresentation(&item, variant, false, outfits);
        }
        result.items[result.count] = item;
        result.count += 1;
    }
    return result;
}

pub const Sample = struct { column: u32, next_in: u64 };

/// One-shot integer timeline. No catch-up loop, no replay on expiry.
/// Ceiling of the exact rational frame boundary avoids accumulating drift.
pub fn sample(rep: Representation, elapsed: u64) ?Sample {
    if (!rep.valid()) return null;
    const duration = (@as(u64, rep.frames) * 1000 + rep.fps - 1) / rep.fps;
    if (elapsed >= duration) return null;
    const index = elapsed * rep.fps / 1000;
    const boundary = ((index + 1) * 1000 + rep.fps - 1) / rep.fps;
    return .{ .column = @intCast(index), .next_in = boundary - elapsed };
}

const t = std.testing;
const primary = "{\"id\":\"nap\",\"displayName\":\" Nap \",\"outfitId\":\"default\",\"spritesheetPath\":\"activities/nap.webp\",\"frameCount\":12,\"fps\":7}";

fn parseFixture(input: []const u8, outfits: []const Id) !Catalog {
    const parsed = try std.json.parseFromSlice(std.json.Value, t.allocator, input, .{});
    defer parsed.deinit();
    return parse(parsed.value, outfits);
}

test "owned metadata and exact inventory" {
    const c = try parseFixture("[" ++ primary ++ "]", &.{});
    try t.expectEqual(@as(u8, 1), c.count);
    try t.expectEqualStrings("Nap", c.items[0].displayName());
    const rep = c.items[0].resolve("default").?;
    try t.expect(c.items[0].resolve("winter") == null);
    try t.expectEqual(@as(u32, 2304), rep.width());
    try c.validateInventory(&.{.{ .path = "activities/nap.webp", .bytes = max_file_bytes }});
    try t.expectError(error.InvalidInventory, c.validateInventory(&.{}));
    try t.expectError(error.InvalidInventory, c.validateInventory(&.{.{ .path = "activities/nap.webp", .bytes = max_file_bytes + 1 }}));
    try t.expectError(error.InvalidInventory, c.validateInventory(&.{.{ .path = "activities/../nap.webp", .bytes = 1 }}));
}

test "outfit variants are exact and reject undeclared or repeated IDs" {
    const data = "[{\"id\":\"nap\",\"displayName\":\"Nap\",\"outfitId\":\"winter\",\"spritesheetPath\":\"activities/nap.webp\",\"frameCount\":4,\"fps\":4,\"outfitVariants\":[{\"outfitId\":\"default\",\"spritesheetPath\":\"activities/nap.default.webp\",\"frameCount\":8,\"fps\":4}]}]";
    const winter = try Id.parse("winter");
    const c = try parseFixture(data, &.{winter});
    try t.expectEqual(@as(u8, 8), c.items[0].resolve("default").?.frames);
    try t.expectEqual(@as(u8, 4), c.items[0].resolve("winter").?.frames);
    try c.validateInventory(&.{ .{ .path = "activities/nap.default.webp", .bytes = 100 }, .{ .path = "activities/nap.webp", .bytes = 200 } });
    try t.expectError(error.InvalidInventory, c.validateInventory(&.{ .{ .path = "activities/nap.webp", .bytes = 100 }, .{ .path = "activities/nap.webp", .bytes = 200 } }));
    try t.expectError(error.InvalidActivity, parseFixture(data, &.{}));
    try t.expectError(error.InvalidActivity, parseFixture(data, &.{ winter, winter }));
    try t.expectError(error.InvalidActivity, parseFixture("[" ++ primary ++ "," ++ primary ++ "]", &.{}));
}

test "reject fractional short long and path-traversal activities" {
    try t.expectError(error.InvalidActivity, parseFixture("[{\"id\":\"../x\",\"displayName\":\"X\"}]", &.{}));
    const prefix = "[{\"id\":\"x\",\"displayName\":\"X\",\"outfitId\":\"default\",\"spritesheetPath\":\"activities/x.webp\",";
    try t.expectError(error.InvalidActivity, parseFixture(prefix ++ "\"frameCount\":4,\"fps\":12}]", &.{}));
    try t.expectError(error.InvalidActivity, parseFixture(prefix ++ "\"frameCount\":32,\"fps\":1}]", &.{}));
    try t.expectError(error.InvalidActivity, parseFixture(prefix ++ "\"frameCount\":4,\"fps\":1.5}]", &.{}));
    try t.expectError(error.InvalidActivity, parseFixture("null", &.{}));
}

test "one-shot rational timing covers each frame and expires exactly" {
    const rep: Representation = .{ .frames = 12, .fps = 7 };
    for (0..1715) |elapsed| {
        const point = sample(rep, elapsed).?;
        try t.expect(point.column < 12 and point.next_in > 0);
        if (sample(rep, elapsed + point.next_in)) |next| {
            try t.expect(next.column > point.column);
        }
    }
    try t.expect(sample(rep, 1715) == null);
    try t.expect(sample(rep, std.math.maxInt(u64)) == null);
    try t.expect(sample(.{}, 0) == null);
}

test "UTF-16 unit limits accept multilingual names without allowing oversized ASCII" {
    try t.expectEqualStrings("睡觉", checkedText(.{ .string = " 睡觉 " }, 2).?);
    try t.expect(checkedText(.{ .string = "睡觉" }, 1) == null);
    try t.expectEqualStrings("🐱", checkedText(.{ .string = "🐱" }, 2).?);
    try t.expect(checkedText(.{ .string = "🐱" }, 1) == null);
    try t.expect(checkedText(.{ .string = "abc" }, 2) == null);
    try t.expect(checkedText(.{ .string = "a\x00b" }, 40) == null);
    try t.expect(checkedText(.{ .string = "\xff" }, 40) == null);
}

test "inventory aggregate limit admits exact boundary and rejects one extra byte" {
    var c: Catalog = .{};
    const ids = [_][]const u8{ "a", "b", "c", "d", "e", "f", "g", "h", "i" };
    var paths: [ids.len][96]u8 = undefined;
    var entries: [ids.len]InventoryEntry = undefined;
    c.count = @intCast(ids.len);
    for (ids, 0..) |id, i| {
        const item = &c.items[i];
        item.id = try Id.parse(id);
        item.count = 1;
        item.representations[0] = .{ .outfit = try Id.parse("default"), .frames = 4, .fps = 4 };
        entries[i] = .{
            .path = try item.representations[0].path(&item.id, true, &paths[i]),
            .bytes = max_file_bytes,
        };
    }
    entries[7].bytes = max_file_bytes - 1;
    entries[8].bytes = 1;
    try c.validateInventory(&entries);
    entries[8].bytes = 2;
    try t.expectError(error.InvalidInventory, c.validateInventory(&entries));
    entries[8].bytes = 0;
    try t.expectError(error.InvalidInventory, c.validateInventory(&entries));
}
