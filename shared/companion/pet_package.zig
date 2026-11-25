//! Owned C-ABI projection of validated default-outfit Classic metadata.
const std = @import("std");
const assets = @import("pet_assets.zig");

pub const Item = extern struct {
    frames: u32 = 0,
    fps: u32 = 0,
    name: [161]u8 = @splat(0),
    leaf: [80]u8 = @splat(0),
};

pub const Package = extern struct {
    version: u32 = 0,
    count: u32 = 0,
    items: [16]Item = @splat(.{}),
};

pub fn project(allocator: std.mem.Allocator, input: []const u8, id: []const u8) !Package {
    const meta = try assets.parseMetadata(allocator, input, id);
    // Do not silently drop validated wardrobe data in the old native ABI.
    if (meta.wardrobe.count != 0) return error.UnsupportedFormat;
    var result: Package = .{ .version = if (meta.layout == .v1) 1 else 2 };
    for (meta.activities.items[0..meta.activities.count]) |*activity| {
        const repr = activity.resolve("default") orelse return error.InvalidMetadata;
        const item = &result.items[result.count];
        item.frames = repr.frames;
        item.fps = repr.fps;
        const name = activity.displayName();
        @memcpy(item.name[0..name.len], name);
        var buffer: [96]u8 = undefined;
        const path = try repr.path(&activity.id, true, &buffer);
        const leaf = path["activities/".len..];
        @memcpy(item.leaf[0..leaf.len], leaf);
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
    try std.testing.expectEqualStrings("nap.webp", std.mem.sliceTo(&out.items[0].leaf, 0));
    try std.testing.expectEqual(@as(c_int, 1), parse(input.ptr, input.len, "other", 5, &out));
    try std.testing.expectEqual(@as(u32, 0), out.count);
}

test "project owned names and canonical activity leaves" {
    const input = "{\"id\":\"cat\",\"displayName\":\"Cat\",\"description\":\"Test\",\"spritesheetPath\":\"spritesheet.webp\",\"spriteVersionNumber\":2,\"activities\":[{\"id\":\"nap\",\"displayName\":\"睡觉\",\"outfitId\":\"default\",\"spritesheetPath\":\"activities/nap.webp\",\"frameCount\":8,\"fps\":4}]}";
    const result = try project(std.testing.allocator, input, "cat");
    try std.testing.expectEqual(@as(u32, 2), result.version);
    try std.testing.expectEqual(@as(u32, 1), result.count);
    try std.testing.expectEqualStrings("睡觉", std.mem.sliceTo(&result.items[0].name, 0));
    try std.testing.expectEqualStrings("nap.webp", std.mem.sliceTo(&result.items[0].leaf, 0));
    try std.testing.expectEqual(@as(u32, 8), result.items[0].frames);
    try std.testing.expectError(error.InvalidMetadata, project(std.testing.allocator, input, "other"));
}

test "native package gate rejects wardrobe until renderer is ready" {
    const input = "{\"id\":\"a\",\"displayName\":\"A\",\"description\":\"A\",\"spritesheetPath\":\"spritesheet.webp\",\"wardrobe\":{\"outfits\":[{\"id\":\"night\",\"displayName\":\"Night\",\"spritesheetPath\":\"outfits/night.webp\"}]}}";
    try std.testing.expectError(error.UnsupportedFormat, project(std.testing.allocator, input, "a"));
}
