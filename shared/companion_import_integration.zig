//! Windows real executable + approved Runner + actual inventory store.
const std = @import("std");
const store = @import("companion_catalog_store.zig");
const importing = @import("companion/pet_import.zig");
const helper_mod = @import("companion/pet_import_helper.zig");
const inventory = @import("companion/pet_inventory.zig");
const catalog = @import("companion/pet_catalog.zig");
const trust = @import("process_trust");
const process = @import("pulse_process");
const http = @import("companion/pet_market_http_win32.zig");
const download = @import("companion/pet_market_download.zig");
const installer = @import("companion_market_install.zig");
const Group = @import("runtime_group").Group;
const Budget = @import("runtime_budget").Budget;

const FixtureTransport = struct {
    bytes: []const u8,

    pub fn get(self: *FixtureTransport, _: download.Kind, _: []const u8, sink: *download.Sink) !void {
        try sink.headers(self.bytes.len);
        var offset: usize = 0;
        while (offset < self.bytes.len) {
            const end = @min(self.bytes.len, offset + 37);
            try sink.append(self.bytes[offset..end]);
            offset = end;
        }
    }
};

test {
    _ = http;
    _ = http.Downloads;
    _ = @import("companion_market_cache.zig");
    _ = @import("companion_market_service.zig");
    _ = @import("companion_preferences_write.zig");
}

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
    // Independent Python ZIP writer, actual concurrent transfer/store,
    // extraction, approved executable, and durable inventory publication.
    var zip_buf: [4096]u8 = undefined;
    var zip_path_buf: [4096]u8 = undefined;
    const zip_path = try fixturePath(3, &zip_path_buf);
    const archive_file = try std.Io.Dir.openFileAbsolute(io, zip_path, .{ .follow_symlinks = false });
    defer archive_file.close(io);
    const archive_size = (try archive_file.stat(io)).size;
    try std.testing.expect(archive_size > 0 and archive_size <= zip_buf.len);
    const n = try archive_file.readPositionalAll(io, &zip_buf, 0);
    try std.testing.expectEqual(archive_size, @as(u64, n));
    const scratch = try std.Io.Dir.cwd().openDir(io, root_path, .{ .follow_symlinks = false });
    defer scratch.close(io);
    var group = Group.init(std.testing.allocator, 0, 0, 2);
    var tasks = @import("companion/pet_market_tasks.zig").Tasks(FixtureTransport).init(io, scratch, &group);
    defer tasks.shutdown() catch @panic("download fixture cleanup failed");
    const request = try tasks.start(.zip, "https://zip.openpets.dev/pets/fixture-v1/base.zip", .{ .bytes = zip_buf[0..n] });
    const archive = try tasks.join(request);
    var stage: installer.Install = .{};
    var disk = Budget.init(2 * 1024 * 1024 * 1024);
    defer stage.cleanup(io, scratch, &disk) catch @panic("ZIP fixture cleanup failed");
    const result = try stage.run(io, scratch, root_path, &disk, archive, root_wide, &owner, &helper, "fixture-v1");
    try stage.cleanup(io, scratch, &disk);
    try std.testing.expectEqual(@as(usize, 0), disk.used);
    try tasks.release(request);
    try group.checkDrained();
    try std.testing.expectEqual(@as(u64, 1), result.imported);
    var restarted: importing.Coordinator = .{};
    try std.testing.expect(try store.loadInventory(root_wide, &restarted.index));
    try std.testing.expectEqual(@as(u64, 2), restarted.index.next_id);
    try std.testing.expectEqual(@as(u64, 1), (try restarted.index.findPair(source_digest)).?);
    var final_buf: [4096]u8 = undefined;
    const final = try inventory.directory(root_path, 1, &final_buf);
    try std.testing.expect(std.meta.eql(source_digest, try helper.probe(final, "fixture-v1")));
    try std.testing.expect(std.meta.eql(source_digest, try helper.probe(source, "fixture-v1")));
    var snapshot: @import("companion/pet_library_read.zig").Snapshot = .{};
    try @import("companion/pet_library_read.zig").readAt(std.mem.span(root_wide), &snapshot);
    try std.testing.expectEqual(@as(usize, 1), snapshot.count);
    try std.testing.expectEqualStrings("fixture-v1", snapshot.rows[0].sourceId());
    try std.testing.expect(snapshot.rows[0].paired);
    const duplicate = try store.importPackage(root_wide, &restarted, &helper, source, "fixture-v1");
    try std.testing.expectEqual(@as(u64, 1), duplicate.existing);
    try std.testing.expectEqual(@as(u64, 2), restarted.index.next_id);
    var entry = try catalog.Entry.init(1, "fixture-v1", "Fixture", .v1);
    _ = try entry.addTag("test");
    _ = try entry.addTag("second-tag");
    entry.favorite = true;
    try store.save(root_wide, &entry);
    var reloaded = try catalog.Entry.init(1, "fixture-v1", "Fixture", .v1);
    try std.testing.expect(try store.load(root_wide, &reloaded));
    try std.testing.expect(reloaded.hasTag("test"));
    try @import("companion/pet_library_read.zig").readFilteredAt(std.mem.span(root_wide), &snapshot, .{ .query = "SECOND", .favorites_only = true });
    try std.testing.expectEqual(@as(usize, 1), snapshot.count);
    try std.testing.expect(snapshot.rows[0].favorite);
    try std.testing.expectEqual(@as(usize, 2), snapshot.rows[0].tag_count);
    try @import("companion/pet_library_read.zig").readFilteredAt(std.mem.span(root_wide), &snapshot, .{ .query = "no-match" });
    try std.testing.expectEqual(@as(usize, 0), snapshot.count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.total);
    try runner.checkDrained();
}
