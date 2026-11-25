//! Lease-bound durable inventory adapter for the verified runtime module.
//! Reuse the existing PCI3 codec and import coordinator, not a second format.
const std = @import("std");
const runtime = @import("companion_runtime_owner.zig");
const inventory = @import("companion/pet_inventory.zig");
const catalog = @import("companion/pet_catalog.zig");
const importing = @import("companion/pet_import.zig");
const fingerprint = @import("companion/pet_fingerprint.zig");
const recovery = @import("companion/pet_recovery_scan.zig");
const receipt = @import("companion/pet_removal_receipt.zig");

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

// A complete bounded scan under the private lease. No mutation or automatic
// adoption; a malformed inventory or incomplete enumeration is an error.
pub fn scanRecovery(owner: *runtime.Owner) !recovery.Report {
    return (try scanRecoveryDetailed(owner)).summary;
}

pub fn scanRecoveryDetailed(owner: *runtime.Owner) !recovery.Snapshot {
    const index = try std.heap.page_allocator.create(inventory.Inventory);
    defer std.heap.page_allocator.destroy(index);
    index.* = .{};
    _ = try loadInventory(owner, index);
    const rows = try std.heap.page_allocator.alloc(recovery.Row, recovery.max_rows);
    defer std.heap.page_allocator.free(rows);
    const count = try owner.scanStore(rows);
    var snapshot = try recovery.inspect(index, rows[0..count]);
    // Bound additional work to 64 packages per diagnostic invocation.
    // A refused or skipped package contributes to the unknown count,
    // not an apparent zero-size directory. No authorization to delete.
    snapshot.summary.quarantine_unmeasured = snapshot.summary.quarantined_registered + snapshot.summary.quarantined_removed;
    for (snapshot.quarantine[0..snapshot.quarantine_count]) |*detail| {
        if (detail.state == .blocked) {
            if (recovery.hasCleanup(rows[0..count], detail.id)) {
                detail.receipt_state = .cleanup_started;
            } else if (recovery.hasReceipt(rows[0..count], detail.id)) detail.receipt_state = .invalid;
            continue;
        }
        if (detail.state == .unregistered_retained) try inspectReceipt(owner, detail);
        const bytes = owner.quarantineUsage(detail.id) catch |err| switch (err) {
            error.MissingStoreApi => break,
            error.InvalidRecord, error.StoreIo, error.StoreBusy => continue,
            else => return err,
        };
        detail.logical_bytes = bytes;
        if (detail.state == .interrupted_removal) {
            snapshot.summary.quarantine_registered_bytes += bytes;
        } else {
            snapshot.summary.quarantine_removed_bytes += bytes;
        }
        snapshot.summary.quarantine_unmeasured -= 1;
    }
    return snapshot;
}

fn inspectReceipt(owner: *runtime.Owner, detail: *recovery.QuarantineDetail) !void {
    const id = detail.id;
    detail.receipt_state = .unavailable;
    const value = (owner.readRemovalReceipt(id) catch |err| switch (err) {
        error.MissingStoreApi, error.StoreIo, error.StoreBusy => return,
        error.InvalidRecord, error.InvalidReceipt => {
            detail.receipt_state = .invalid;
            return;
        },
        else => return err,
    }) orelse {
        detail.receipt_state = .absent;
        return;
    };
    const identity = owner.quarantineIdentity(id) catch |err| switch (err) {
        error.MissingStoreApi, error.StoreIo, error.StoreBusy => return,
        error.InvalidRecord => {
            detail.receipt_state = .invalid;
            return;
        },
        else => return err,
    };
    if (value.volume != identity.volume or value.file_index != identity.file_index) {
        detail.receipt_state = .invalid;
        return;
    }
    detail.receipt_state = .matched_identity;
    detail.cleanup_receipt = value;
}

fn checkedCleanupRecord(owner: *runtime.Owner, id: u64) !receipt.Receipt {
    if (try owner.group.remaining() != 0) return error.ActiveInstances;
    const index = try std.heap.page_allocator.create(inventory.Inventory);
    defer std.heap.page_allocator.destroy(index);
    index.* = .{};
    if (!try loadInventory(owner, index) or id == 0 or id >= index.next_id) return error.RecoveryRequired;
    if (index.get(id)) |_| {
        return error.ActiveRecord;
    } else |err| {
        if (err != error.UnknownAsset) return err;
    }
    const rows = try std.heap.page_allocator.alloc(recovery.Row, recovery.max_rows);
    defer std.heap.page_allocator.free(rows);
    const count = try owner.scanStore(rows);
    _ = try recovery.classify(index, rows[0..count]);
    if (try recovery.removalState(rows[0..count], id) != .quarantined) return error.RecoveryRequired;
    return (try owner.readRemovalReceipt(id)) orelse return error.MissingReceipt;
}

pub fn cleanupReceipt(owner: *runtime.Owner, id: u64) !receipt.Receipt {
    const value = try checkedCleanupRecord(owner, id);
    const identity = try owner.quarantineIdentity(id);
    if (value.volume != identity.volume or value.file_index != identity.file_index) return error.StaleSelection;
    _ = try owner.quarantineUsage(id);
    return value;
}

// Cancellation is accepted only before immutable intent publication.
// Partial deletion is never retried.
pub fn cleanupPermanent(owner: *runtime.Owner, expected: receipt.Receipt, cancel: importing.Cancel) !void {
    try cancel.check();
    const id = expected.record.id;
    const current = try cleanupReceipt(owner, id);
    if (!std.meta.eql(expected, current)) return error.StaleSelection;
    const identity: runtime.Owner.DirectoryIdentity = .{ .volume = expected.volume, .file_index = expected.file_index };
    try owner.pinCleanup(id, identity);
    const outcome = cleanupPinned(owner, expected, identity, cancel);
    try owner.releaseQuarantine();
    return outcome;
}

fn cleanupPinned(owner: *runtime.Owner, expected: receipt.Receipt, identity: runtime.Owner.DirectoryIdentity, cancel: importing.Cancel) !void {
    const id = expected.record.id;
    try expected.verifyPair(try owner.cleanupPair(id, cancel));
    const latest = try checkedCleanupRecord(owner, id);
    if (!std.meta.eql(expected, latest)) return error.StaleSelection;
    try owner.recheckQuarantine(id, identity);
    try cancel.check();
    try owner.disposeCleanup(expected);
}

fn checkedRemoval(owner: *runtime.Owner, index: *inventory.Inventory, expected: inventory.Record, state: recovery.RemovalState) !void {
    if (try owner.group.remaining() != 0) return error.ActiveInstances;
    if (!try loadInventory(owner, index)) return error.UnknownAsset;
    const actual = try index.get(expected.id);
    if (!std.meta.eql(actual, expected)) return error.StaleSelection;
    if (actual.digest == null or actual.secondary == null) return error.NeedsRevalidation;
    const rows = try std.heap.page_allocator.alloc(recovery.Row, recovery.max_rows);
    defer std.heap.page_allocator.free(rows);
    const count = try owner.scanStore(rows);
    if (recovery.hasReceipt(rows[0..count], expected.id)) return error.RecoveryRequired;
    if (try recovery.removalState(rows[0..count], expected.id) != state) return error.RecoveryRequired;
    if (try owner.readRemovalReceipt(expected.id) != null) return error.RecoveryRequired;
}

// A same-volume no-replace rename is the durable recovery marker. The
// inventory commit follows it; a failure leaves the copy quarantined.
// Never recursively delete, alter original sources, or reuse the old ID.
pub fn quarantineRemove(owner: *runtime.Owner, expected: inventory.Record) !void {
    const index = try std.heap.page_allocator.create(inventory.Inventory);
    defer std.heap.page_allocator.destroy(index);
    index.* = .{};
    try checkedRemoval(owner, index, expected, .normal);
    try index.remove(expected.id);
    const identity = owner.moveQuarantineBound(expected.id) catch return error.RecoveryRequired;
    saveInventory(owner, index) catch return error.RecoveryRequired;
    // Committed inventory must not be described as rolled back on receipt failure.
    owner.writeRemovalReceipt(.{ .record = expected, .volume = identity.volume, .file_index = identity.file_index }) catch return error.RemovalCommittedWithoutReceipt;
}

// Explicit recovery only for an interrupted removal whose registered
// identity still exists. Completed removals cannot resurrect old IDs.
pub fn restoreInterruptedRemoval(owner: *runtime.Owner, expected: inventory.Record) !void {
    const index = try std.heap.page_allocator.create(inventory.Inventory);
    defer std.heap.page_allocator.destroy(index);
    index.* = .{};
    try checkedRemoval(owner, index, expected, .quarantined);
    owner.moveQuarantine(expected.id, true) catch return error.RecoveryRequired;
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
    return importPackageControlled(owner, coordinator, helper, source, source_id, .{});
}

pub fn importPackageControlled(owner: *runtime.Owner, coordinator: *importing.Coordinator, helper: anytype, source: []const u8, source_id: []const u8, cancel: importing.Cancel) !importing.Result {
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
    return coordinator.importPackageControlled(&adapter, source, source_id, cancel);
}
