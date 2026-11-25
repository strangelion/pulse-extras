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
const service_mod = @import("companion_market_service.zig");
const market = @import("companion/pet_market.zig");
const Group = @import("runtime_group").Group;
const Budget = @import("runtime_budget").Budget;

const FixtureTransport = struct {
    bytes: []const u8,

    pub fn get(self: *FixtureTransport, kind: download.Kind, url: []const u8, sink: *download.Sink) !void {
        const body = if (kind == .zip) self.bytes else if (kind == .index)
            "{\"version\":3,\"generatedAt\":\"fixture-revision\",\"total\":1,\"pageSize\":20,\"search\":\"https://openpets.dev/pets/catalog.v3/rev/search.json\",\"pages\":[\"https://openpets.dev/pets/catalog.v3/rev/detail.json\"]}"
        else if (std.mem.endsWith(u8, url, "/search.json"))
            "{\"version\":3,\"generatedAt\":\"fixture-revision\",\"total\":1,\"pageSize\":100,\"pages\":[\"https://openpets.dev/pets/catalog.v3/rev/s0.json\"]}"
        else if (std.mem.endsWith(u8, url, "/s0.json"))
            "{\"version\":3,\"page\":0,\"pageSize\":100,\"pets\":[{\"id\":\"fixture-v1\",\"displayName\":\"Fixture\",\"searchText\":\"Fixture\",\"category\":\"asian\",\"catalogPage\":0,\"original\":true}]}"
        else if (std.mem.endsWith(u8, url, "/detail.json"))
            "{\"version\":3,\"page\":0,\"pageSize\":20,\"pets\":[{\"id\":\"fixture-v1\",\"displayName\":\"Fixture\",\"description\":\"Fixture\",\"thumbnail\":\"https://openpets.dev/pets/fixture-v1/thumb.webp\",\"spritesheet\":\"https://openpets.dev/pets/fixture-v1/spritesheet.webp\",\"zip\":\"https://zip.openpets.dev/pets/fixture-v1/base.zip\",\"category\":\"asian\",\"original\":true}]}"
        else
            return error.InvalidUrl;
        try sink.headers(body.len);
        var offset: usize = 0;
        while (offset < body.len) {
            const end = @min(body.len, offset + 37);
            try sink.append(body[offset..end]);
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
extern "c" fn pet_market_cache_fixture_close([*:0]const u16) c_int;

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
    var group = Group.init(std.testing.allocator, 32 * 1024 * 1024, 0, 2);
    var tasks = @import("companion/pet_market_tasks.zig").Tasks(FixtureTransport).init(io, scratch, &group);
    defer tasks.shutdown() catch @panic("download fixture cleanup failed");
    var cache_root: [1024]u16 = @splat(0);
    try std.testing.expect(pet_catalog_store_fixture_open(&cache_root, cache_root.len) != 0);
    const cache_path: [*:0]const u16 = @ptrCast(&cache_root);
    defer {
        std.testing.expect(pet_market_cache_fixture_close(cache_path) != 0) catch @panic("market cache cleanup failed");
    }
    var service: service_mod.Service(FixtureTransport) = .{
        .allocator = group.allocator(),
        .tasks = &tasks,
        .cache = .{ .root = cache_path },
        .transport = .{ .bytes = zip_buf[0..n] },
        .now = 1000,
    };
    defer service.shutdown() catch @panic("market service cleanup failed");
    var market_root = try service.openRoot();
    defer market_root.deinit();
    var hits: [1]market.Hit = undefined;
    const selection = try service.search(&market_root, .{ .query = "fixture" }, 0, &hits);
    try std.testing.expectEqual(@as(usize, 1), selection.summary.written);
    var stage: installer.Install = .{};
    var disk = Budget.init(2 * 1024 * 1024 * 1024);
    defer stage.cleanup(io, scratch, &disk) catch @panic("ZIP fixture cleanup failed");

    // Cancellation after a successful download must not publish anything.
    const canceled = try service.startPackage(&market_root, &selection, &hits[0], false);
    _ = try tasks.join(canceled);
    try service.cancelPackage(canceled);
    const canceled_result = try service.finishPackage(canceled, &stage, scratch, root_path, &disk, root_wide, &owner, &helper);
    try std.testing.expectError(error.Canceled, canceled_result.result);
    try std.testing.expect(canceled_result.stage_cleanup == null and canceled_result.transfer_cleanup == null);
    try std.testing.expectEqual(@as(usize, 0), owner.index.count);

    // Invalid ZIP also releases both archive and extraction reservations.
    service.transport.bytes = "not a zip";
    const invalid = try service.startPackage(&market_root, &selection, &hits[0], false);
    const invalid_result = try service.finishPackage(invalid, &stage, scratch, root_path, &disk, root_wide, &owner, &helper);
    try std.testing.expectError(error.InvalidArchive, invalid_result.result);
    try std.testing.expect(invalid_result.stage_cleanup == null and invalid_result.transfer_cleanup == null);
    try std.testing.expectEqual(@as(usize, 0), disk.used);
    try std.testing.expectEqual(@as(usize, 0), owner.index.count);

    service.transport.bytes = zip_buf[0..n];
    const request = try service.startPackage(&market_root, &selection, &hits[0], false);
    const outcome = try service.finishPackage(request, &stage, scratch, root_path, &disk, root_wide, &owner, &helper);
    try std.testing.expect(outcome.stage_cleanup == null and outcome.transfer_cleanup == null);
    try std.testing.expectEqual(@as(u64, 1), (try outcome.result).imported);
    try std.testing.expectError(error.NotOwned, service.finishPackage(request, &stage, scratch, root_path, &disk, root_wide, &owner, &helper));
    const duplicate_request = try service.startPackage(&market_root, &selection, &hits[0], false);
    const duplicate_outcome = try service.finishPackage(duplicate_request, &stage, scratch, root_path, &disk, root_wide, &owner, &helper);
    try std.testing.expect(duplicate_outcome.stage_cleanup == null and duplicate_outcome.transfer_cleanup == null);
    try std.testing.expectEqual(@as(u64, 1), (try duplicate_outcome.result).existing);
    try std.testing.expectEqual(@as(usize, 0), disk.used);
    try service.shutdown();
    try tasks.checkDrained();
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
    try std.testing.expect(std.meta.eql(snapshot.rows[0].preference_version, try catalog.preferenceVersion(&reloaded, true)));
    try std.testing.expectEqual(@as(usize, 2), snapshot.rows[0].tag_count);
    try @import("companion/pet_library_read.zig").readFilteredAt(std.mem.span(root_wide), &snapshot, .{ .query = "no-match" });
    try std.testing.expectEqual(@as(usize, 0), snapshot.count);
    try std.testing.expectEqual(@as(usize, 1), snapshot.total);
    try runner.checkDrained();
}
