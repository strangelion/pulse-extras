//! Lease-bound durable inventory adapter for the verified runtime module.
//! Reuse the existing PCI3 codec and import coordinator, not a second format.
const std = @import("std");
const runtime = @import("companion_runtime_owner.zig");
const inventory = @import("companion/pet_inventory.zig");
const catalog = @import("companion/pet_catalog.zig");
const importing = @import("companion/pet_import.zig");
const fingerprint = @import("companion/pet_fingerprint.zig");

pub fn loadInventory(owner: *runtime.Owner, out: *inventory.Inventory) !bool {
    var bytes: [inventory.max_bytes]u8 = undefined;
    const len = (try owner.readStore(0, &bytes)) orelse return false;
    try inventory.decode(out, bytes[0..len]);
    return true;
}

pub fn saveInventory(owner: *runtime.Owner, value: *const inventory.Inventory) !void {
    const previous = try std.heap.page_allocator.create(inventory.Inventory);
    defer std.heap.page_allocator.destroy(previous);
    previous.* = .{};
    if (try loadInventory(owner, previous)) {
        if (value.next_id < previous.next_id) return error.InvalidRecord;
    }
    var bytes: [inventory.max_bytes]u8 = undefined;
    try owner.writeStore(0, try inventory.encode(value, &bytes));
}

pub fn loadPreferences(owner: *runtime.Owner, entry: *catalog.Entry) !bool {
    var bytes: [catalog.max_preferences_bytes]u8 = undefined;
    const len = (try owner.readStore(entry.id, &bytes)) orelse return false;
    try catalog.decodePreferences(entry, bytes[0..len]);
    return true;
}

pub fn savePreferences(owner: *runtime.Owner, entry: *const catalog.Entry) !void {
    var old = entry.*;
    _ = try loadPreferences(owner, &old);
    var bytes: [catalog.max_preferences_bytes]u8 = undefined;
    try owner.writeStore(entry.id, try catalog.encodePreferences(entry, &bytes));
}

pub const PreferenceChange = union(enum) {
    favorite: bool,
    add_tag: []const u8,
    remove_tag: []const u8,
};

// Revalidate the local ID, source and content version under the same
// exclusive lease that protects the atomic store. No stale UI overwrite.
pub fn applyPreference(owner: *runtime.Owner, id: u64, source: []const u8, expected: catalog.PreferenceVersion, change: PreferenceChange) !bool {
    const index = try std.heap.page_allocator.create(inventory.Inventory);
    defer std.heap.page_allocator.destroy(index);
    index.* = .{};
    if (!try loadInventory(owner, index)) return error.UnknownAsset;
    const record = try index.get(id);
    if (!std.mem.eql(u8, record.sourceId(), source)) return error.StaleSelection;
    var entry = try catalog.Entry.init(id, source, source, .v1);
    const present = try loadPreferences(owner, &entry);
    if (!std.meta.eql(try catalog.preferenceVersion(&entry, present), expected)) return error.VersionConflict;
    const changed = switch (change) {
        .favorite => |value| blk: {
            const different = entry.favorite != value;
            entry.favorite = value;
            break :blk different;
        },
        .add_tag => |tag| try entry.addTag(tag),
        .remove_tag => |tag| entry.removeTag(tag),
    };
    if (!changed) return false;
    try savePreferences(owner, &entry);
    return true;
}

pub fn importPackage(owner: *runtime.Owner, coordinator: *importing.Coordinator, helper: anytype, source: []const u8, source_id: []const u8) !importing.Result {
    const Adapter = struct {
        owner: *runtime.Owner,
        validator: @TypeOf(helper),

        pub fn probe(self: *@This(), path: []const u8, id: []const u8) !fingerprint.Pair {
            return self.validator.probe(path, id);
        }

        pub fn save(self: *@This(), index: *const inventory.Inventory) !void {
            return saveInventory(self.owner, index);
        }

        pub fn stage(self: *@This(), path: []const u8, id: []const u8, local_id: u64, digest: fingerprint.Pair) !void {
            return self.validator.stage(path, id, local_id, digest);
        }
    };
    var adapter: Adapter = .{ .owner = owner, .validator = helper };
    return coordinator.importPackage(&adapter, source, source_id);
}
