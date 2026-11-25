//! Isolated CI fixture, never used as a production DLL approval authority.
const std = @import("std");
const runtime = @import("companion_group.zig");
const loader = @import("companion_runtime_owner.zig");
const library = @import("companion/pet_library_read.zig");
const inventory = @import("companion/pet_inventory.zig");
const model = @import("companion/pet_manager.zig");
const store = @import("companion_runtime_store.zig");
const catalog = @import("companion/pet_catalog.zig");
const local_import = @import("companion_local_import.zig");

extern "kernel32" fn GetFullPathNameW([*:0]const u16, u32, [*]u16, ?*anyopaque) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?*anyopaque, u32) callconv(.winapi) usize;
extern "kernel32" fn GetProcAddress(usize, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(usize) callconv(.winapi) c_int;
extern "kernel32" fn GetEnvironmentVariableW([*:0]const u16, [*]u16, u32) callconv(.winapi) u32;

extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

const Query = *const fn (u32, u32, *runtime.NativeApi) callconv(.c) c_int;

fn checkAbi() !void {
    var path: [1024]u16 = undefined;
    const len = GetFullPathNameW(std.unicode.wtf8ToWtf16LeStringLiteral("zig-out\\bin\\pulse_companion_runtime.dll"), path.len, &path, null);
    if (len == 0 or len >= path.len) return error.BadFixturePath;
    const module = LoadLibraryExW(path[0..len :0], null, 0x900);
    if (module == 0) return error.LoadFailed;
    // Fixture never launches a child. A production owner must not unload
    // the module before confirmed drain/close.
    defer _ = FreeLibrary(module);
    const query: Query = @ptrCast(GetProcAddress(module, "pulse_companion_runtime_query") orelse return error.MissingQuery);
    var api: runtime.NativeApi = undefined;
    if (query(1, @sizeOf(runtime.NativeApi), &api) != 0 or
        query(2, @sizeOf(runtime.NativeApi) - 1, &api) != 0 or
        query(2, @sizeOf(runtime.NativeApi), &api) == 0 or !api.valid())
        return error.BadRuntimeAbi;
    var group: runtime.Group = .{};
    var invalid = api;
    invalid.start = null;
    if (group.openWithApi(invalid, 2, 256 * 1024 * 1024)) |_| {
        return error.AcceptedInvalidTable;
    } else |err| {
        if (err != error.Invalid) return err;
    }
    try group.openWithApi(api, 2, 256 * 1024 * 1024);
    if (try group.remaining() != 0) return error.UnexpectedChildren;
    try group.beginDrain(false);
    var rows: [runtime.max_tick_slots]runtime.TickResult = undefined;
    if (try group.tick(&rows) != 0) return error.UnexpectedTick;
    try group.close();
    try group.openWithApi(api, 1, 128 * 1024 * 1024);
    try group.close();
    std.debug.print("Companion GNU/MSVC runtime bridge ABI verified\n", .{});
}

fn readDigest(name: [:0]const u16) ![32]u8 {
    var hex: [65]u16 = undefined;
    if (GetEnvironmentVariableW(name.ptr, &hex, hex.len) != 64) return error.MissingFixtureDigest;
    var ascii: [64]u8 = undefined;
    for (&ascii, hex[0..64]) |*out, ch| {
        if (ch > 127) return error.BadFixtureDigest;
        out.* = @intCast(ch);
    }
    var digest: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&digest, &ascii);
    return digest;
}

fn drain(owner: *loader.Owner) !void {
    try owner.group.beginDrain(false);
    const begin = GetTickCount64();
    var rows: [runtime.max_tick_slots]runtime.TickResult = undefined;
    while (try owner.group.remaining() != 0) {
        const elapsed = GetTickCount64() - begin;
        if (elapsed >= 8_000) return error.UnconfirmedShutdown;
        if (elapsed >= 2_000) try owner.group.beginDrain(true);
        _ = try owner.group.tick(&rows);
        Sleep(50);
    }
}

fn exerciseManaged(owner: *loader.Owner, private: [:0]const u16) !void {
    const index = try std.heap.page_allocator.create(inventory.Inventory);
    defer std.heap.page_allocator.destroy(index);
    index.* = .{};
    try library.readManagedIndex(private, index);
    if (index.count != 3) return error.UnexpectedInventory;
    var preference = try catalog.Entry.init(1, "fixture-v1", "Fixture V1", .v1);
    if (try store.loadPreferences(owner, &preference)) return error.UnexpectedPreference;
    const initial = try catalog.preferenceVersion(&preference, false);
    if (!try store.applyPreference(owner, 1, "fixture-v1", initial, .{ .favorite = true })) return error.PreferenceNotPersisted;
    if (store.applyPreference(owner, 1, "fixture-v1", initial, .{ .add_tag = "stale" })) |_| {
        return error.AcceptedStalePreference;
    } else |err| {
        if (err != error.VersionConflict) return err;
    }
    if (!try store.loadPreferences(owner, &preference)) return error.PreferenceNotPersisted;
    const updated = try catalog.preferenceVersion(&preference, true);
    if (!try store.applyPreference(owner, 1, "fixture-v1", updated, .{ .add_tag = "bridge-test" })) return error.PreferenceNotPersisted;
    var reloaded = try catalog.Entry.init(1, "fixture-v1", "Fixture V1", .v1);
    if (!try store.loadPreferences(owner, &reloaded) or !reloaded.favorite or !reloaded.hasTag("bridge-test")) return error.PreferenceNotPersisted;
    if (!try store.loadInventory(owner, index) or index.count != 3) return error.UnexpectedInventory;
    const high_water = index.next_id;
    index.next_id -= 1;
    if (store.saveInventory(owner, index)) |_| {
        return error.AcceptedIdRollback;
    } else |err| {
        if (err != error.InvalidRecord) return err;
    }
    index.next_id = high_water;
    try store.saveInventory(owner, index);
    if (!try store.loadInventory(owner, index) or index.next_id != high_water) return error.InventoryNotPersisted;
    var helper: [1024]u16 = undefined;
    const len = GetFullPathNameW(std.unicode.wtf8ToWtf16LeStringLiteral("zig-out\\bin\\pulse-pet-demo.exe"), helper.len, &helper, null);
    if (len == 0 or len >= helper.len) return error.BadFixturePath;
    const path = helper[0..len :0];
    const digest = try readDigest(std.unicode.wtf8ToWtf16LeStringLiteral("PULSE_BRIDGE_FIXTURE_HELPER_SHA256"));
    // Invalid ID must not reserve capacity or start a child.
    if (owner.group.startManagedWide(path, &digest, index, private, 99)) |_| {
        return error.AcceptedUnknownAsset;
    } else |err| {
        if (err != error.UnknownAsset) return err;
    }
    if (try owner.group.remaining() != 0) return error.UnexpectedChildren;
    const first = try owner.group.startManagedWide(path, &digest, index, private, 1);
    if (first.failure) |err| return err;
    const second = try owner.group.startManagedWide(path, &digest, index, private, 2);
    if (second.failure) |err| return err;
    const begin = GetTickCount64();
    var outcomes: [runtime.max_tick_slots]runtime.TickResult = undefined;
    var items: [3]model.Instance = undefined;
    while (true) {
        if (GetTickCount64() - begin >= 20_000) return error.ReadinessTimeout;
        const count = try owner.group.tick(&outcomes);
        for (outcomes[0..count]) |row| {
            if (row.failure) |err| return err;
            if (row.exit_code) |code| {
                std.debug.print("Managed instance {d} exited before readiness: {d} (0x{x})\n", .{ row.id, code, code });
                return error.UnexpectedChildExit;
            }
        }
        if (try owner.group.snapshot(0, &items) != 2) return error.UnexpectedChildren;
        if (items[0].id != first.id or items[0].asset_id != 1 or items[1].id != second.id or items[1].asset_id != 2) return error.WrongAsset;
        if (items[0].state == .running and items[1].state == .running) break;
        Sleep(50);
    }
    // The actual helper must reject the intentionally wrong fingerprint
    // before publishing first-frame readiness. Healthy siblings stay owned.
    const wrong = try owner.group.startManagedWide(path, &digest, index, private, 3);
    if (wrong.failure) |err| return err;
    const deadline = GetTickCount64();
    var rejected = false;
    while (!rejected) {
        if (GetTickCount64() - deadline >= 20_000) return error.RejectionTimeout;
        const count = try owner.group.tick(&outcomes);
        for (outcomes[0..count]) |row| {
            if (row.failure) |err| return err;
            if (row.exit_code) |code| {
                if (row.id != wrong.id or code == 0) {
                    std.debug.print("Unexpected managed exit: ID {d}, code {d} (0x{x})\n", .{ row.id, code, code });
                    return error.UnexpectedChildExit;
                }
                rejected = true;
            }
        }
        const owned = try owner.group.snapshot(0, &items);
        for (items[0..owned]) |item| {
            if (item.id == wrong.id and item.state == .running) return error.AcceptedWrongFingerprint;
        }
        Sleep(50);
    }
    if (try owner.group.remaining() != 2) return error.UnexpectedChildren;
    if (store.quarantineRemove(owner, try index.get(1))) |_| {
        return error.RemovedActiveAsset;
    } else |err| {
        if (err != error.ActiveInstances) return err;
    }
    std.debug.print("Two managed pets ready; incorrect fingerprint rejected\n", .{});
}

fn exerciseImport(io: std.Io, owner: *loader.Owner, parent: [:0]const u16, private: [:0]const u16) !void {
    var path: [4096]u8 = undefined;
    const n = try std.unicode.utf16LeToUtf8(&path, parent);
    var source: [4096]u8 = undefined;
    const fresh = try std.fmt.bufPrint(&source, "{s}\\source\\fresh", .{path[0..n]});
    var helper: [1024]u16 = undefined;
    const len = GetFullPathNameW(std.unicode.wtf8ToWtf16LeStringLiteral("zig-out\\bin\\pulse-pet-demo.exe"), helper.len, &helper, null);
    if (len == 0 or len >= helper.len) return error.BadFixturePath;
    const digest = try readDigest(std.unicode.wtf8ToWtf16LeStringLiteral("PULSE_BRIDGE_FIXTURE_HELPER_SHA256"));
    const CancelProbe = struct {
        calls: usize = 0,
        fn check(ctx: ?*anyopaque) callconv(.c) u32 {
            const self: *@This() = @ptrCast(@alignCast(ctx orelse unreachable));
            self.calls += 1;
            return @intFromBool(self.calls >= 3);
        }
    };
    var cancel: CancelProbe = .{};
    if (local_import.runControlled(io, owner, private, helper[0..len :0], digest, fresh, "fresh", .{ .callback = CancelProbe.check, .context = &cancel })) |_| {
        return error.AcceptedCanceledImport;
    } else |err| {
        if (err != error.Canceled) return err;
    }
    const first = try local_import.run(io, owner, private, helper[0..len :0], digest, fresh, "fresh");
    if (first != .imported or first.imported != 4) return error.UnexpectedImport;
    const second = try local_import.run(io, owner, private, helper[0..len :0], digest, fresh, "fresh");
    if (second != .existing or second.existing != 4) return error.DuplicateImport;
    const index = try std.heap.page_allocator.create(inventory.Inventory);
    defer std.heap.page_allocator.destroy(index);
    index.* = .{};
    if (!try store.loadInventory(owner, index) or index.count != 4 or index.next_id != 5) return error.InventoryNotPersisted;
    const record = try index.get(4);
    if (!std.mem.eql(u8, record.sourceId(), "fresh") or record.digest == null or record.secondary == null) return error.UnexpectedImport;
    std.debug.print("Local import and duplicate detection verified through durable bridge\n", .{});
    const missing_id = try index.reserve();
    try index.publish(missing_id, "missing-fixture");
    try store.saveInventory(owner, index);
    var tiny: [1]@import("companion/pet_recovery_scan.zig").Row = undefined;
    if (owner.scanStore(&tiny)) |_| {
        return error.AcceptedTruncatedScan;
    } else |err| {
        if (err != error.StoreBusy) return err;
    }
    const report = try store.scanRecovery(owner);
    if (report.registered != 4 or report.missing != 1 or report.orphan_packages != 1 or
        report.pending_directories != 1 or report.pending_records != 1 or report.orphan_preferences != 1 or
        report.invalid != 1 or report.unknown != 1 or report.unreserved != 5) return error.UnexpectedRecoveryScan;
    const repeated = try store.scanRecovery(owner);
    if (!std.meta.eql(report, repeated)) return error.ScanChangedStore;
    std.debug.print("Read-only recovery classification and bounded enumeration verified\n", .{});
    var stale = record;
    stale.source[0] = 'x';
    if (store.quarantineRemove(owner, stale)) |_| {
        return error.AcceptedStaleRemoval;
    } else |err| {
        if (err != error.StaleSelection) return err;
    }
    // Simulate interruption after the durable rename but before index commit.
    try owner.moveQuarantine(record.id, false);
    const interrupted = try store.scanRecoveryDetailed(owner);
    if (interrupted.summary.quarantined_registered != 1 or interrupted.summary.missing != 2) return error.UnexpectedRecoveryScan;
    if (interrupted.stateFor(record.id) != .interrupted_removal) return error.UnexpectedRecoveryScan;
    const measured = interrupted.summary.quarantine_registered_bytes;
    if (measured == 0 or interrupted.summary.quarantine_removed_bytes != 0 or interrupted.summary.quarantine_unmeasured != 0) return error.UnexpectedQuarantineUsage;
    if (try owner.quarantineUsage(record.id) != measured) return error.UnexpectedQuarantineUsage;
    if (interrupted.quarantine_count != 1 or interrupted.quarantine[0].id != record.id or interrupted.quarantine[0].state != .interrupted_removal or interrupted.quarantine[0].logical_bytes != measured) return error.UnexpectedQuarantineUsage;
    try store.restoreInterruptedRemoval(owner, record);
    const restored = try store.scanRecoveryDetailed(owner);
    if (!std.meta.eql(report, restored.summary) or restored.stateFor(record.id) != .normal) return error.RestoreFailed;
    try store.quarantineRemove(owner, record);
    const removed = try store.scanRecovery(owner);
    if (removed.quarantined_removed != 1 or removed.quarantined_registered != 0 or removed.registered != 3 or removed.missing != 1) return error.UnexpectedRecoveryScan;
    if (removed.quarantine_removed_bytes != measured or removed.quarantine_registered_bytes != 0 or removed.quarantine_unmeasured != 0) return error.UnexpectedQuarantineUsage;
    const retained = try store.scanRecoveryDetailed(owner);
    if (retained.stateFor(record.id) != null) return error.UnexpectedRecoveryScan;
    if (retained.quarantine_count != 1 or retained.quarantine[0].id != record.id or retained.quarantine[0].state != .unregistered_retained or retained.quarantine[0].logical_bytes != measured) return error.UnexpectedQuarantineUsage;
    if (!try store.loadInventory(owner, index) or index.count != 4 or index.next_id != 6) return error.InventoryNotPersisted;
    if (store.restoreInterruptedRemoval(owner, record)) |_| {
        return error.RestoredRemovedId;
    } else |err| {
        if (err != error.UnknownAsset) return err;
    }
    // The external source remains intact and reimport gets a fresh ID.
    const reimport = try local_import.run(io, owner, private, helper[0..len :0], digest, fresh, "fresh");
    if (reimport != .imported or reimport.imported != 6) return error.UnexpectedImport;
    const after_reimport = try store.scanRecovery(owner);
    if (after_reimport.quarantined_removed != 1 or after_reimport.registered != 4) return error.UnexpectedRecoveryScan;
    std.debug.print("Quarantine removal, interrupted recovery and fresh-ID reimport verified\n", .{});
}

pub fn main(init: std.process.Init) !void {
    try checkAbi();
    var hex: [65]u16 = undefined;
    if (GetEnvironmentVariableW(std.unicode.wtf8ToWtf16LeStringLiteral("PULSE_BRIDGE_FIXTURE_SHA256"), &hex, hex.len) != 64) return error.MissingFixtureDigest;
    var ascii: [64]u8 = undefined;
    for (&ascii, hex[0..64]) |*out, ch| {
        if (ch > 127) return error.BadFixtureDigest;
        out.* = @intCast(ch);
    }
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, &ascii);
    var root: [1024]u16 = undefined;
    const len = GetFullPathNameW(std.unicode.wtf8ToWtf16LeStringLiteral("zig-out\\bin"), root.len, &root, null);
    if (len == 0 or len >= root.len) return error.BadFixturePath;
    var owner: loader.Owner = .{};
    var wrong = expected;
    wrong[0] ^= 1;
    if (owner.open(root[0..len :0], wrong, 2, 256 * 1024 * 1024)) |_| {
        return error.AcceptedWrongDigest;
    } else |err| {
        if (err != error.UnapprovedModule) return err;
    }
    try owner.open(root[0..len :0], expected, 2, 256 * 1024 * 1024);
    if (try owner.group.remaining() != 0) return error.UnexpectedChildren;
    try owner.group.beginDrain(false);
    try owner.close();
    try owner.open(root[0..len :0], expected, 1, 128 * 1024 * 1024);
    // The workflow supplies an isolated, freshly created directory. Never
    // obtain the actual user's LocalAppData for this fixture.
    var parent: [1024]u16 = undefined;
    const parent_len = GetEnvironmentVariableW(std.unicode.wtf8ToWtf16LeStringLiteral("PULSE_BRIDGE_FIXTURE_PRIVATE_PARENT"), &parent, parent.len);
    if (parent_len == 0 or parent_len >= parent.len) return error.MissingFixtureParent;
    const fixture_parent = parent[0..parent_len :0];
    const private = try owner.privateRoot(fixture_parent);
    const suffix = std.unicode.wtf8ToWtf16LeStringLiteral("\\PulseExtras-Companion");
    if (private.len != fixture_parent.len + suffix.len or
        !std.mem.eql(u16, private[0..fixture_parent.len], fixture_parent) or
        !std.mem.endsWith(u16, private, suffix)) return error.BadPrivateFixturePath;
    _ = try owner.privateRoot(fixture_parent);
    try owner.close();
    try owner.open(root[0..len :0], expected, 1, 128 * 1024 * 1024);
    _ = try owner.privateRoot(fixture_parent);
    try owner.close();
    // Second invocation after the independent fixture generator.
    var managed: [2]u16 = undefined;
    if (GetEnvironmentVariableW(std.unicode.wtf8ToWtf16LeStringLiteral("PULSE_BRIDGE_FIXTURE_MANAGED"), &managed, managed.len) == 1 and managed[0] == '1') {
        try owner.open(root[0..len :0], expected, 3, 3 * model.child_commit_ceiling);
        const approved = try owner.privateRoot(fixture_parent);
        const outcome = exerciseManaged(&owner, approved);
        drain(&owner) catch |err| {
            try owner.abandon();
            return err;
        };
        try owner.close();
        try outcome;
        try owner.open(root[0..len :0], expected, 1, 128 * 1024 * 1024);
        const import_root = try owner.privateRoot(fixture_parent);
        try exerciseImport(init.io, &owner, fixture_parent, import_root);
        var reopened = try catalog.Entry.init(1, "fixture-v1", "Fixture V1", .v1);
        if (!try store.loadPreferences(&owner, &reopened) or !reopened.favorite or !reopened.hasTag("bridge-test")) return error.PreferenceNotPersisted;
        try owner.close();
    }
    std.debug.print("Pinned runtime owner and private lease ABI verified\n", .{});
}
