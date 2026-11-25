//! Windows durable preference adapter. The caller supplies an approved private
//! directory and serializes catalog operations. Never save to source folders.
const std = @import("std");
const catalog = @import("companion/pet_catalog.zig");
const inventory = @import("companion/pet_inventory.zig");

extern "c" fn pet_store_read([*:0]const u16, u64, [*]u8, usize, *usize) c_int;
extern "c" fn pet_store_write([*:0]const u16, u64, [*]const u8, usize) c_int;
extern "c" fn pet_inventory_read([*:0]const u16, [*]u8, usize, *usize) c_int;
extern "c" fn pet_inventory_write([*:0]const u16, [*]const u8, usize) c_int;
extern "c" fn pet_catalog_store_fixture_open([*]u16, u32) c_int;
extern "c" fn pet_catalog_store_fixture_close([*:0]const u16) c_int;

pub const Error = error{ Invalid, Io, Busy, CleanupFailed };
fn check(code: c_int) Error!void {
    return switch (code) {
        0 => {},
        2 => error.Invalid,
        3 => error.Io,
        4 => error.Busy,
        5 => error.CleanupFailed,
        else => error.Io,
    };
}

pub fn load(root: [*:0]const u16, entry: *catalog.Entry) !bool {
    var bytes: [catalog.max_preferences_bytes]u8 = undefined;
    var len: usize = 0;
    const result = pet_store_read(root, entry.id, &bytes, bytes.len, &len);
    if (result == 1) return false;
    try check(result);
    if (len > bytes.len) return error.Invalid;
    try catalog.decodePreferences(entry, bytes[0..len]);
    return true;
}

// Validate existing record against its identity before replacing it. Never
// overwrite corrupt/unknown-version records. Single private-directory writer.
pub fn save(root: [*:0]const u16, entry: *const catalog.Entry) !void {
    var previous = entry.*;
    _ = try load(root, &previous);
    var bytes: [catalog.max_preferences_bytes]u8 = undefined;
    const encoded = try catalog.encodePreferences(entry, &bytes);
    try check(pet_store_write(root, entry.id, encoded.ptr, encoded.len));
}

pub fn loadInventory(root: [*:0]const u16, value: *inventory.Inventory) !bool {
    var bytes: [inventory.max_bytes]u8 = undefined;
    var len: usize = 0;
    const result = pet_inventory_read(root, &bytes, bytes.len, &len);
    if (result == 1) return false;
    try check(result);
    if (len > bytes.len) return error.Invalid;
    try inventory.decode(value, bytes[0..len]);
    return true;
}

// Do not replace a corrupt inventory or roll back the ID high-water mark.
pub fn saveInventory(root: [*:0]const u16, value: *const inventory.Inventory) !void {
    var previous: inventory.Inventory = .{};
    if (try loadInventory(root, &previous)) {
        if (value.next_id < previous.next_id) return error.Invalid;
    }
    var bytes: [inventory.max_bytes]u8 = undefined;
    const encoded = try inventory.encode(value, &bytes);
    try check(pet_inventory_write(root, encoded.ptr, encoded.len));
}

test "preference file survives reload and rejects corrupt old data" {
    var root: [1024]u16 = @splat(0);
    try std.testing.expect(pet_catalog_store_fixture_open(&root, root.len) != 0);
    const path: [*:0]const u16 = @ptrCast(&root);
    defer {
        std.testing.expect(pet_catalog_store_fixture_close(path) != 0) catch @panic("fixture cleanup failed");
    }
    var entry = try catalog.Entry.init(1, "cat", "Cat", .v2);
    try std.testing.expect(!try load(path, &entry));
    _ = try entry.addTag("工作");
    try save(path, &entry);
    var reopened = try catalog.Entry.init(1, "cat", "Updated", .v2);
    try std.testing.expect(try load(path, &reopened));
    try std.testing.expect(reopened.hasTag("工作"));
    reopened.favorite = true;
    try save(path, &reopened);
    try std.testing.expect(try load(path, &entry));
    try std.testing.expect(entry.favorite);
    try check(pet_store_write(path, 1, "bad", 3));
    try std.testing.expectError(error.InvalidRecord, save(path, &entry));
    try std.testing.expectError(error.InvalidRecord, load(path, &entry));
    try std.testing.expect(entry.favorite and entry.hasTag("工作"));
}

test "inventory high-water mark persists independently of preferences" {
    var root: [1024]u16 = @splat(0);
    try std.testing.expect(pet_catalog_store_fixture_open(&root, root.len) != 0);
    const path: [*:0]const u16 = @ptrCast(&root);
    defer {
        std.testing.expect(pet_catalog_store_fixture_close(path) != 0) catch @panic("fixture cleanup failed");
    }
    var value: inventory.Inventory = .{};
    try std.testing.expect(!try loadInventory(path, &value));
    const id = try value.reserve();
    try saveInventory(path, &value);
    try value.publishVerified(id, "cat", @splat(17));
    try saveInventory(path, &value);
    var restored: inventory.Inventory = .{};
    try std.testing.expect(try loadInventory(path, &restored));
    try std.testing.expectEqual(@as(u64, 2), restored.next_id);
    const record = try restored.get(id);
    try std.testing.expectEqualStrings("cat", record.sourceId());
    try std.testing.expectEqual(id, restored.findDigest(@splat(17)).?);
    try restored.remove(id);
    try saveInventory(path, &restored);
    try std.testing.expectError(error.Invalid, saveInventory(path, &.{}));
    try std.testing.expect(try loadInventory(path, &value));
    try std.testing.expectEqual(@as(usize, 0), value.count);
    try std.testing.expectEqual(@as(u64, 2), try value.reserve());
}
