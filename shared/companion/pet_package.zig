//! Owned C-ABI projection of validated Classic WebP metadata.
const std = @import("std");
const assets = @import("pet_assets.zig");
const wardrobe = @import("pet_wardrobe.zig");

pub const Representation = extern struct {
    frames: u32 = 0,
    fps: u32 = 0,
    leaf: [80]u8 = @splat(0),
};

pub const Item = extern struct {
    name: [161]u8 = @splat(0),
    reps: [17]Representation = @splat(.{}),
};

pub const Outfit = extern struct {
    name: [161]u8 = @splat(0),
    leaf: [80]u8 = @splat(0),
};

pub const ScheduleRule = extern struct {
    outfit: u32 = 0,
    flags: u32 = 0, // enabled=1, time=2, days=4, dates=8
    time_from: u32 = 0,
    time_to: u32 = 0,
    days: u32 = 0,
    date_from: u32 = 0,
    date_to: u32 = 0,
};

pub const Package = extern struct {
    version: u32 = 0,
    count: u32 = 0,
    outfit_count: u32 = 0,
    items: [16]Item = @splat(.{}),
    outfits: [16]Outfit = @splat(.{}),
    rule_count: u32 = 0,
    rules: [32]ScheduleRule = @splat(.{}),
    pet_id: [65]u8 = @splat(0),
    outfit_ids: [16][33]u8 = @splat(@splat(0)),
    activity_ids: [16][33]u8 = @splat(@splat(0)),
};

comptime {
    if (@sizeOf(Representation) != 88 or @sizeOf(Item) != 1660 or @sizeOf(Outfit) != 241 or @sizeOf(ScheduleRule) != 28 or @sizeOf(Package) != 32452) @compileError("Classic package ABI mismatch");
}

pub fn project(allocator: std.mem.Allocator, input: []const u8, id: []const u8) !Package {
    const meta = try assets.parseMetadata(allocator, input, id);
    var result: Package = .{ .version = if (meta.layout == .v1) 1 else 2 };
    @memcpy(result.pet_id[0..id.len], id);
    for (meta.wardrobe.outfits[0..meta.wardrobe.count], 0..) |*outfit, i| {
        if (outfit.format != .webp) return error.UnsupportedFormat;
        const name = outfit.displayName();
        @memcpy(result.outfits[i].name[0..name.len], name);
        var buffer: [64]u8 = undefined;
        const path = try outfit.path(&buffer);
        const leaf = path["outfits/".len..];
        @memcpy(result.outfits[i].leaf[0..leaf.len], leaf);
        const outfit_id = outfit.id.slice();
        @memcpy(result.outfit_ids[i][0..outfit_id.len], outfit_id);
        result.outfit_count += 1;
    }
    for (meta.wardrobe.rules[0..meta.wardrobe.rule_count]) |rule| {
        var projected: ScheduleRule = .{ .outfit = rule.outfit, .flags = if (rule.enabled) 1 else 0 };
        if (rule.time) |range| {
            projected.flags |= 2;
            projected.time_from = range.from;
            projected.time_to = range.to;
        }
        if (rule.days) |days| {
            projected.flags |= 4;
            projected.days = days;
        }
        if (rule.dates) |range| {
            projected.flags |= 8;
            projected.date_from = range.from;
            projected.date_to = range.to;
        }
        result.rules[result.rule_count] = projected;
        result.rule_count += 1;
    }
    for (meta.activities.items[0..meta.activities.count]) |*activity| {
        const item = &result.items[result.count];
        const name = activity.displayName();
        @memcpy(item.name[0..name.len], name);
        for (activity.representations[0..activity.count], 0..) |*repr, i| {
            const index = meta.wardrobe.indexOf(repr.outfit.slice()) orelse return error.InvalidMetadata;
            const entry = &item.reps[index];
            entry.frames = repr.frames;
            entry.fps = repr.fps;
            var buffer: [96]u8 = undefined;
            const path = try repr.path(&activity.id, i == 0, &buffer);
            const leaf = path["activities/".len..];
            @memcpy(entry.leaf[0..leaf.len], leaf);
        }
        const activity_id = activity.id.slice();
        @memcpy(result.activity_ids[result.count][0..activity_id.len], activity_id);
        result.count += 1;
    }
    return result;
}

/// Native schedule selection over owned validated metadata. Keep matching
/// semantics in the original pure wardrobe Rule, not a second C parser.
pub fn resolveSchedule(meta: *const Package, minute: u32, weekday: u32, month: u32, day: u32) callconv(.c) u32 {
    if (meta.rule_count > 32 or meta.outfit_count > 16 or minute >= 1440 or weekday >= 7 or
        month < 1 or month > 12 or day < 1 or day > 31) return 0;
    const moment: wardrobe.Moment = .{
        .minute = @intCast(minute),
        .weekday = @intCast(weekday),
        .month = @intCast(month),
        .day = @intCast(day),
    };
    for (meta.rules[0..meta.rule_count]) |rule| {
        if (rule.outfit > meta.outfit_count or rule.flags & ~@as(u32, 15) != 0 or
            rule.time_from >= 1440 or rule.time_to >= 1440 or rule.days > 127 or
            rule.date_from > 1231 or rule.date_to > 1231) continue;
        const match: wardrobe.Rule = .{
            .outfit = @intCast(rule.outfit),
            .enabled = rule.flags & 1 != 0,
            .time = if (rule.flags & 2 != 0) .{ .from = @intCast(rule.time_from), .to = @intCast(rule.time_to) } else null,
            .days = if (rule.flags & 4 != 0) @intCast(rule.days) else null,
            .dates = if (rule.flags & 8 != 0) .{ .from = @intCast(rule.date_from), .to = @intCast(rule.date_to) } else null,
        };
        if (match.matches(moment)) return rule.outfit;
    }
    return 0;
}

pub fn parse(allocator: std.mem.Allocator, input: [*]const u8, len: usize, id: [*]const u8, id_len: usize, out: *Package) c_int {
    out.* = .{};
    if (len == 0 or len > assets.max_metadata_bytes or id_len == 0 or id_len > 64) return 1;
    const scratch = allocator.alloc(u8, 2 * 1024 * 1024) catch return 1;
    defer allocator.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    out.* = project(fixed.allocator(), input[0..len], id[0..id_len]) catch return 1;
    return 0;
}

test "bounded parser accepts the Windows smoke metadata" {
    const input = "{\"id\": \"cat\", \"displayName\": \"Cat\", \"description\": \"Fixture\", \"spritesheetPath\": \"spritesheet.webp\", \"activities\": [{\"id\": \"nap\", \"displayName\": \"Nap\", \"outfitId\": \"default\", \"spritesheetPath\": \"activities/nap.webp\", \"frameCount\": 4, \"fps\": 4}]}";
    var out: Package = .{};
    try std.testing.expectEqual(@as(c_int, 0), parse(std.testing.allocator, input.ptr, input.len, "cat", 3, &out));
    try std.testing.expectEqual(@as(u32, 1), out.version);
    try std.testing.expectEqual(@as(u32, 1), out.count);
    try std.testing.expectEqualStrings("nap.webp", std.mem.sliceTo(&out.items[0].reps[0].leaf, 0));
    try std.testing.expectEqual(@as(c_int, 1), parse(std.testing.allocator, input.ptr, input.len, "other", 5, &out));
    try std.testing.expectEqual(@as(u32, 0), out.count);
}

test "project owned names and canonical activity leaves" {
    const input = "{\"id\":\"cat\",\"displayName\":\"Cat\",\"description\":\"Test\",\"spritesheetPath\":\"spritesheet.webp\",\"spriteVersionNumber\":2,\"activities\":[{\"id\":\"nap\",\"displayName\":\"睡觉\",\"outfitId\":\"default\",\"spritesheetPath\":\"activities/nap.webp\",\"frameCount\":8,\"fps\":4}]}";
    const result = try project(std.testing.allocator, input, "cat");
    try std.testing.expectEqual(@as(u32, 2), result.version);
    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expectEqualStrings("睡觉", std.mem.sliceTo(&result.items[0].name, 0));
    try std.testing.expectEqualStrings("nap.webp", std.mem.sliceTo(&result.items[0].reps[0].leaf, 0));
    try std.testing.expectEqual(@as(u32, 8), result.items[0].reps[0].frames);
    try std.testing.expectError(error.InvalidMetadata, project(std.testing.allocator, input, "other"));
}

test "outfit-specific representations retain exact primary and variant leaves" {
    const input = "{\"id\":\"a\",\"displayName\":\"A\",\"description\":\"A\",\"spritesheetPath\":\"spritesheet.webp\",\"wardrobe\":{\"outfits\":[{\"id\":\"night\",\"displayName\":\"Night\",\"spritesheetPath\":\"outfits/night.webp\"}]},\"activities\":[{\"id\":\"nap\",\"displayName\":\"Nap\",\"outfitId\":\"night\",\"spritesheetPath\":\"activities/nap.webp\",\"frameCount\":4,\"fps\":4,\"outfitVariants\":[{\"outfitId\":\"default\",\"spritesheetPath\":\"activities/nap.default.webp\",\"frameCount\":8,\"fps\":4}]}]}";
    const result = try project(std.testing.allocator, input, "a");
    try std.testing.expectEqual(@as(u32, 1), result.outfit_count);
    try std.testing.expectEqualStrings("night.webp", std.mem.sliceTo(&result.outfits[0].leaf, 0));
    try std.testing.expectEqualStrings("a", std.mem.sliceTo(&result.pet_id, 0));
    try std.testing.expectEqualStrings("night", std.mem.sliceTo(&result.outfit_ids[0], 0));
    try std.testing.expectEqualStrings("nap", std.mem.sliceTo(&result.activity_ids[0], 0));
    try std.testing.expectEqualStrings("nap.webp", std.mem.sliceTo(&result.items[0].reps[1].leaf, 0));
    try std.testing.expectEqualStrings("nap.default.webp", std.mem.sliceTo(&result.items[0].reps[0].leaf, 0));
    try std.testing.expectEqual(@as(u32, 8), result.items[0].reps[0].frames);
    try std.testing.expectEqual(@as(u32, 0), result.items[0].reps[2].frames);
}

test "SVG outfit is not silently discarded" {
    const input = "{\"id\":\"a\",\"displayName\":\"A\",\"description\":\"A\",\"spritesheetPath\":\"spritesheet.webp\",\"wardrobe\":{\"outfits\":[{\"id\":\"night\",\"displayName\":\"Night\",\"spritesheetPath\":\"outfits/night.svg\"}]}}";
    try std.testing.expectError(error.UnsupportedFormat, project(std.testing.allocator, input, "a"));
}

test "native schedule projection preserves ordered local civil time semantics" {
    const input = "{\"id\":\"a\",\"displayName\":\"A\",\"description\":\"A\",\"spritesheetPath\":\"spritesheet.webp\",\"wardrobe\":{\"outfits\":[{\"id\":\"night\",\"displayName\":\"Night\",\"spritesheetPath\":\"outfits/night.webp\"},{\"id\":\"winter\",\"displayName\":\"Winter\",\"spritesheetPath\":\"outfits/winter.webp\"}],\"schedule\":[{\"outfit\":\"default\",\"enabled\":false,\"when\":{\"days\":[\"fri\"]}},{\"outfit\":\"winter\",\"when\":{\"dates\":{\"from\":\"12-20\",\"to\":\"01-02\"}}},{\"outfit\":\"night\",\"when\":{\"days\":[\"fri\"],\"time\":{\"from\":\"22:00\",\"to\":\"07:00\"}}}]}}";
    const meta = try project(std.testing.allocator, input, "a");
    try std.testing.expectEqual(@as(u32, 3), meta.rule_count);
    try std.testing.expectEqual(@as(u32, 2), resolveSchedule(&meta, 1380, 5, 12, 25));
    try std.testing.expectEqual(@as(u32, 1), resolveSchedule(&meta, 1320, 5, 11, 20));
    try std.testing.expectEqual(@as(u32, 0), resolveSchedule(&meta, 420, 5, 11, 20));
    try std.testing.expectEqual(@as(u32, 0), resolveSchedule(&meta, 120, 6, 11, 21));
    try std.testing.expectEqual(@as(u32, 2), resolveSchedule(&meta, 0, 0, 1, 2));
    try std.testing.expectEqual(@as(u32, 0), resolveSchedule(&meta, 1440, 5, 12, 25));
    try std.testing.expectEqual(@as(u32, 0), resolveSchedule(&meta, 0, 0, 2, 30));
}
