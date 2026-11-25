//! Windows real executable + approved Runner + actual inventory store.
const std = @import("std");
const store = @import("companion_catalog_store.zig");
const importing = @import("companion/pet_import.zig");
const helper_mod = @import("companion/pet_import_helper.zig");
const inventory = @import("companion/pet_inventory.zig");
const catalog = @import("companion/pet_catalog.zig");
const trust = @import("process_trust");
const process = @import("pulse_process");

extern "c" fn pet_catalog_store_fixture_open([*]u16, u32) c_int;
extern "c" fn pet_import_fixture_path(c_uint, [*]u8, u32) u32;
extern "c" fn pet_import_fixture_utf8([*:0]const u16, [*]u8, u32) u32;
extern "c" fn pet_import_fixture_close([*:0]const u16) c_int;

fn fixturePath(kind: c_uint, out: []u8) ![]const u8 {
    const len = pet_import_fixture_path(kind, out.ptr, @intCast(out.len));
    if (len == 0 or len > out.len) return error.FixturePath;
    return out[0..len];
}

test "real approved helper imports package and reload deduplicates" {
    const io = std.testing.io;
    var root: [1024]u16 = @splat(0);
    try std.testing.expect(pet_catalog_store_fixture_open(&root, root.len) != 0);
    const root_wide: [*:0]const u16 = @ptrCast(&root);
    defer {
        std.testing.expect(pet_import_fixture_close(root_wide) != 0) catch @panic("import fixture cleanup failed");
    }
    var root_buf: [4096]u8 = undefined;
    const root_len = pet_import_fixture_utf8(root_wide, &root_buf, root_buf.len);
    try std.testing.expect(root_len != 0 and root_len <= root_buf.len);
    const root_path = root_buf[0..root_len];
    var exe_buf: [4096]u8 = undefined;
    var source_buf: [4096]u8 = undefined;
    var system_buf: [4096]u8 = undefined;
    const exe = try fixturePath(0, &exe_buf);
    const source = try fixturePath(1, &source_buf);
    const system = try fixturePath(2, &system_buf);
    // Explicit approval of this CI-built fixture executable only.
    const file = try std.Io.Dir.openFileAbsolute(io, exe, .{ .follow_symlinks = false });
    const digest = trust.digestFile(io, file) catch |err| {
        file.close(io);
        return err;
    };
    file.close(io);

    var runner = process.Runner.init(std.testing.allocator, io);
    try runner.configureApproved(.{ .path = exe, .digest = digest }, 60 * std.time.ns_per_s);
    try runner.configureTree(.windows_job);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    try environ.put("SystemRoot", system);
    try environ.put("TEMP", root_path);
    try environ.put("TMP", root_path);
    var helper: helper_mod.Helper = .{
        .runner = &runner,
        .exe = exe,
        .cwd = root_path,
        .asset_root = root_path,
        .environ = &environ,
    };

    const source_digest = try helper.probe(source, "fixture-v1");
    var owner: importing.Coordinator = .{};
    try std.testing.expect(!try store.loadInventory(root_wide, &owner.index));
    const result = try store.importPackage(root_wide, &owner, &helper, source, "fixture-v1");
    try std.testing.expectEqual(@as(u64, 1), result.imported);
    var restarted: importing.Coordinator = .{};
    try std.testing.expect(try store.loadInventory(root_wide, &restarted.index));
    try std.testing.expectEqual(@as(u64, 2), restarted.index.next_id);
    try std.testing.expectEqual(@as(u64, 1), (try restarted.index.findPair(source_digest)).?);
    var final_buf: [4096]u8 = undefined;
    const final = try inventory.directory(root_path, 1, &final_buf);
    try std.testing.expect(std.meta.eql(source_digest, try helper.probe(final, "fixture-v1")));
    try std.testing.expect(std.meta.eql(source_digest, try helper.probe(source, "fixture-v1")));
    const duplicate = try store.importPackage(root_wide, &restarted, &helper, source, "fixture-v1");
    try std.testing.expectEqual(@as(u64, 1), duplicate.existing);
    try std.testing.expectEqual(@as(u64, 2), restarted.index.next_id);
    var entry = try catalog.Entry.init(1, "fixture-v1", "Fixture", .v1);
    _ = try entry.addTag("test");
    try store.save(root_wide, &entry);
    var reloaded = try catalog.Entry.init(1, "fixture-v1", "Fixture", .v1);
    try std.testing.expect(try store.load(root_wide, &reloaded));
    try std.testing.expect(reloaded.hasTag("test"));
    try runner.checkDrained();
}
