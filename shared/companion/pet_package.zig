//! Owned C-ABI projection of validated Classic WebP metadata.
const std = @import("std");
const assets = @import("pet_assets.zig");

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

pub const Package = extern struct {
    version: u32 = 0,
    count: u32 = 0,
    outfit_count: u32 = 0,
    items: [16]Item = @splat(.{}),
    outfits: [16]Outfit = @splat(.{}),
};

comptime {
    if (@sizeOf(Representation) != 88 or @sizeOf(Item) != 1660 or @sizeOf(Outfit) != 241 or @sizeOf(Package) != 30428) @compileError("Classic package ABI mismatch");
}

pub fn project(allocator: std.mem.Allocator, input: []const u8, id: []const u8) !Package {
    const meta = try assets.parseMetadata(allocator, input, id);
    var result: Package = .{ .version = if (meta.layout == .v1) 1 else 2 };
    for (meta.wardrobe.outfits[0..meta.wardrobe.count], 0..) |*outfit, i| {
        if (outfit.format != .webp) return error.UnsupportedFormat;
        const name = outfit.displayName();
        @memcpy(result.outfits[i].name[0..name.len], name);
        var buffer: [64]u8 = undefined;
        const path = try outfit.path(&buffer);
        const leaf = path["outfits/".len..];
        @memcpy(result.outfits[i].leaf[0..leaf.len], leaf);
        result.outfit_count += 1;
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
        result.count += 1;
    }
    return result;
}

pub fn parse(input: [*]const u8, len: usize, id: [*]const u8, id_len: usize, out: *Package) callconv(.c) c_int {
    out.* = .{};
    if (len == 0 or len > assets.max_metadata_bytes or id_len == 0 or id_len > 64) return 1;
    const allocator = std.heap.page_allocator;
    const scratch = allocator.alloc(u8, 2 * 1024 * 1024) catch return 1;
    defer allocator.free(scratch);
    var fixed = std.heap.FixedBufferAllocator.init(scratch);
    out.* = project(fixed.allocator(), input[0..len], id[0..id_len]) catch return 1;
    return 0;
}

test "bounded C ABI parser accepts the Windows smoke metadata" {
    const input = "{\"id\": \"cat\", \"displayName\": \"Cat\", \"description\": \"Fixture\", \"spritesheetPath\": \"spritesheet.webp\", \"activities\": [{\"id\": \"nap\", \"displayName\": \"Nap\", \"outfitId\": \"default\", \"spritesheetPath\": \"activities/nap.webp\", \"frameCount\": 4, \"fps\": 4}]}";
    var out: Package = .{};
    try std.testing.expectEqual(@as(c_int, 0), parse(input.ptr, input.len, "cat", 3, &out));
    try std.testing.expectEqual(@as(u32, 1), out.version);
    try std.testing.expectEqual(@as(u32, 1), out.count);
    try std.testing.expectEqualStrings("nap.webp", std.mem.sliceTo(&out.items[0].reps[0].leaf, 0));
    try std.testing.expectEqual(@as(c_int, 1), parse(input.ptr, input.len, "other", 5, &out));
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
    try std.testing.expectEqualStrings("nap.webp", std.mem.sliceTo(&result.items[0].reps[1].leaf, 0));
    try std.testing.expectEqualStrings("nap.default.webp", std.mem.sliceTo(&result.items[0].reps[0].leaf, 0));
    try std.testing.expectEqual(@as(u32, 8), result.items[0].reps[0].frames);
    try std.testing.expectEqual(@as(u32, 0), result.items[0].reps[2].frames);
}

test "SVG outfit is not silently discarded" {
    const input = "{\"id\":\"a\",\"displayName\":\"A\",\"description\":\"A\",\"spritesheetPath\":\"spritesheet.webp\",\"wardrobe\":{\"outfits\":[{\"id\":\"night\",\"displayName\":\"Night\",\"spritesheetPath\":\"outfits/night.svg\"}]}}";
    try std.testing.expectError(error.UnsupportedFormat, project(std.testing.allocator, input, "a"));
}
