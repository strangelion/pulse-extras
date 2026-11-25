//! Serialized Windows worker preference transaction. Requires a live private
//! root lease; no arbitrary filenames, preference writes outside inventory,
//! asset launch authorization or UI-thread I/O. All versions are content
//! tokens, not monotonic counters (ABA is possible).
const std = @import("std");
const store = @import("companion_catalog_store.zig");
const catalog = @import("companion/pet_catalog.zig");
const inventory = @import("companion/pet_inventory.zig");

const Native = extern struct {
    parent: ?*anyopaque = null,
    root: ?*anyopaque = null,
    lock: ?*anyopaque = null,
    path: [1024]u16 = @splat(0),
};

extern "c" fn pet_private_root_open(*Native, [*:0]const u16) c_int;
extern "c" fn pet_private_root_close(*Native) c_int;
extern "c" fn pet_catalog_store_fixture_open([*]u16, u32) c_int;
extern "c" fn pet_private_preferences_fixture_close([*:0]const u16) c_int;

fn check(code: c_int) !void {
    return switch (code) {
        0 => {},
        1 => error.InvalidRoot,
        2 => error.Io,
        3 => error.Busy,
        4 => error.CleanupFailed,
        else => error.Io,
    };
}

pub const Version = catalog.PreferenceVersion;

pub const Snapshot = struct {
    entry: catalog.Entry,
    version: Version,
};

pub const Change = union(enum) {
    favorite: bool,
    add_tag: []const u8,
    remove_tag: []const u8,
    default_profile: catalog.Profile,
    alternate_profile: ?catalog.Profile,
};

pub const Result = struct {
    snapshot: Snapshot,
    changed: bool,
};

/// Do not copy an open owner. Keep it at a stable address and serialize all
/// operations, including close. Parent must already be independently approved.
/// Existing incompatible roots are never repaired or adopted by this adapter.
pub const Owner = struct {
    native: Native = .{},
    opened: bool = false,
    faulted: bool = false,

    pub fn open(self: *Owner, parent: [*:0]const u16) !void {
        if (self.opened or self.faulted) return error.Busy;
        check(pet_private_root_open(&self.native, parent)) catch |err| {
            if (err == error.CleanupFailed) self.faulted = true;
            return err;
        };
        if (self.native.parent == null or self.native.root == null or self.native.lock == null or self.native.path[0] == 0) {
            self.faulted = true;
            return error.InvalidRoot;
        }
        self.opened = true;
    }

    pub fn close(self: *Owner) !void {
        self.opened = false;
        check(pet_private_root_close(&self.native)) catch |err| {
            self.faulted = true;
            return err;
        };
        self.faulted = false;
    }

    fn root(self: *const Owner) ![*:0]const u16 {
        if (!self.opened or self.faulted or self.native.lock == null) return error.OwnerUnavailable;
        return @ptrCast(&self.native.path);
    }

    pub fn read(self: *Owner, id: u64, source: []const u8) !Snapshot {
        const path = try self.root();
        var index: inventory.Inventory = .{};
        if (!try store.loadInventory(path, &index)) return error.UnknownAsset;
        const record = try index.get(id);
        if (!std.mem.eql(u8, record.sourceId(), source)) return error.StaleSelection;
        // Placeholder name/layout are never persisted in PCT1 and are not
        // package metadata. This entry represents local preferences only.
        var entry = try catalog.Entry.init(id, source, source, .v1);
        const present = try store.load(path, &entry);
        return .{ .entry = entry, .version = try catalog.preferenceVersion(&entry, present) };
    }

    pub fn apply(self: *Owner, id: u64, source: []const u8, expected: Version, change: Change) !Result {
        const path = try self.root();
        var current = try self.read(id, source);
        if (!std.meta.eql(current.version, expected)) return error.VersionConflict;
        const changed = switch (change) {
            .favorite => |value| blk: {
                const different = current.entry.favorite != value;
                current.entry.favorite = value;
                break :blk different;
            },
            .add_tag => |tag| try current.entry.addTag(tag),
            .remove_tag => |tag| current.entry.removeTag(tag),
            .default_profile => |value| blk: {
                try value.validate();
                const different = !std.meta.eql(current.entry.default_profile, value);
                current.entry.default_profile = value;
                break :blk different;
            },
            .alternate_profile => |value| blk: {
                if (value) |profile| try profile.validate();
                const different = !std.meta.eql(current.entry.alternate_profile, value);
                current.entry.alternate_profile = value;
                break :blk different;
            },
        };
        if (!changed) return .{ .snapshot = current, .changed = false };
        const next = try catalog.preferenceVersion(&current.entry, true);
        store.save(path, &current.entry) catch |err| {
            // A failed write/rename may be ambiguous. Refuse subsequent
            // writes until the owner is closed and disk state is reloaded.
            self.faulted = true;
            return err;
        };
        current.version = next;
        return .{ .snapshot = current, .changed = true };
    }
};

test "private lease binds preference edits to durable identity and snapshot" {
    var parent: [1024]u16 = @splat(0);
    try std.testing.expect(pet_catalog_store_fixture_open(&parent, parent.len) != 0);
    const path: [*:0]const u16 = @ptrCast(&parent);
    defer {
        std.testing.expect(pet_private_preferences_fixture_close(path) != 0) catch @panic("private preference fixture cleanup failed");
    }
    var owner: Owner = .{};
    defer owner.close() catch @panic("private preference owner cleanup failed");
    try owner.open(path);
    try std.testing.expectError(error.UnknownAsset, owner.read(1, "cat"));
    var index: inventory.Inventory = .{};
    const id = try index.reserve();
    try index.publish(id, "cat");
    try store.saveInventory(try owner.root(), &index);
    const initial = try owner.read(id, "cat");
    try std.testing.expect(!initial.version.present);
    try std.testing.expectError(error.StaleSelection, owner.read(id, "dog"));
    const first = try owner.apply(id, "cat", initial.version, .{ .favorite = true });
    try std.testing.expect(first.changed and first.snapshot.entry.favorite);
    try std.testing.expectError(error.VersionConflict, owner.apply(id, "cat", initial.version, .{ .add_tag = "stale" }));
    const second = try owner.apply(id, "cat", first.snapshot.version, .{ .add_tag = "工作" });
    try std.testing.expect(second.changed and second.snapshot.entry.hasTag("工作"));
    const same = try owner.apply(id, "cat", second.snapshot.version, .{ .add_tag = "工作" });
    try std.testing.expect(!same.changed);
    var contender: Owner = .{};
    defer contender.close() catch @panic("contender cleanup failed");
    try std.testing.expectError(error.Busy, contender.open(path));
    try owner.close();
    try std.testing.expectError(error.OwnerUnavailable, owner.read(id, "cat"));
    try contender.open(path);
    const saved = try contender.read(id, "cat");
    try std.testing.expect(std.meta.eql(saved.version, second.snapshot.version));
    try std.testing.expect(saved.entry.favorite and saved.entry.hasTag("工作"));
    const removed = try contender.apply(id, "cat", saved.version, .{ .remove_tag = "工作" });
    try std.testing.expect(removed.changed and removed.snapshot.entry.favorite and !removed.snapshot.entry.hasTag("工作"));
}
