//! Serialized worker-facing market service. Connect bounded HTTPS tasks,
//! durable cache, typed V3 parsers and selected package download admission.
//! No UI calls. The owner keeps the roots, allocator and tasks alive and
//! never invokes this blocking service on the Pulse UI thread.
const std = @import("std");
const market = @import("companion/pet_market.zig");
const download = @import("companion/pet_market_download.zig");
const tasks_mod = @import("companion/pet_market_tasks.zig");
const cache_mod = @import("companion_market_cache.zig");
const codec = @import("companion/pet_market_cache.zig");
const http = @import("companion/pet_market_http_win32.zig");
const installer = @import("companion_market_install.zig");
const importing = @import("companion/pet_import.zig");
const Budget = @import("runtime_budget").Budget;

fn hitKey(hit: *const market.Hit) ![32]u8 {
    if (hit.id_len == 0 or hit.id_len > hit.id.len or hit.name_len == 0 or hit.name_len > hit.name.len) return error.InvalidCatalog;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var lengths: [12]u8 = undefined;
    std.mem.writeInt(u32, lengths[0..4], @intCast(hit.id_len), .little);
    std.mem.writeInt(u32, lengths[4..8], @intCast(hit.name_len), .little);
    std.mem.writeInt(u32, lengths[8..12], hit.catalog_page, .little);
    hash.update(&lengths);
    hash.update(hit.sourceId());
    hash.update(hit.displayName());
    return hash.finalResult();
}

pub const Policy = enum { online, offline_only, stale_on_network_failure };

pub const Root = struct {
    parsed: std.json.Parsed(market.Index),
    stale: bool,
    stored_at: u64,

    pub fn fresh(self: *const Root, now: u64) bool {
        return !self.stale and now >= self.stored_at and now - self.stored_at < 15 * 60;
    }

    pub fn deinit(self: *Root) void {
        self.parsed.deinit();
    }
};

pub const Search = struct {
    summary: market.Scan.Summary,
    revision: [64]u8 = undefined,
    revision_len: usize,
    stale: bool,
    created_at: u64,
    expires_at: u64,
    row_keys: [128][32]u8 = undefined,

    pub fn contains(self: *const Search, hit: *const market.Hit) bool {
        if (self.summary.written > self.row_keys.len) return false;
        const key = hitKey(hit) catch return false;
        for (self.row_keys[0..self.summary.written]) |expected| {
            if (std.mem.eql(u8, &key, &expected)) return true;
        }
        return false;
    }

    pub fn matches(self: *const Search, root: *const Root) bool {
        return self.revision_len <= self.revision.len and
            std.mem.eql(u8, self.revision[0..self.revision_len], root.parsed.value.generatedAt);
    }
};

pub fn Service(comptime Transport: type) type {
    return ServiceFor(Transport, cache_mod.Cache, false);
}

pub fn ServiceFor(comptime Transport: type, comptime CacheType: type, comptime inline_work: bool) type {
    return struct {
        const Self = @This();
        const Tasks = tasks_mod.TasksMode(Transport, inline_work);
        const Body = struct {
            storage: []u8,
            payload: []const u8,
            stale: bool,
            stored_at: u64,

            fn deinit(self: Body, allocator: std.mem.Allocator) void {
                allocator.free(self.storage);
            }
        };

        const Pending = struct {
            id: u64,
            source: [64]u8 = @splat(0),
            source_len: usize,
            consumed: bool = false,
        };

        pub const Finish = struct {
            result: anyerror!importing.Result,
            stage_cleanup: ?anyerror = null,
            transfer_cleanup: ?anyerror = null,
        };

        allocator: std.mem.Allocator,
        tasks: *Tasks,
        pending: [8]?Pending = @splat(null),
        cache: CacheType,
        transport: Transport,
        policy: Policy = .online,
        cancel: importing.Cancel = .{},
        // Supplied UTC epoch seconds; refresh from the owner for each user
        // operation. A single search uses a consistent freshness snapshot.
        now: u64,

        fn readDownload(self: *Self, request: cache_mod.Request, url: []const u8, buffer: []u8) ![]const u8 {
            const kind: download.Kind = if (request == .root) .index else .catalog;
            const id = try self.tasks.start(kind, url, self.transport);
            const result = self.tasks.join(id) catch |err| {
                try self.tasks.release(id);
                return err;
            };
            const length = self.copyBody(result, buffer) catch |err| {
                try self.tasks.release(id);
                return err;
            };
            try self.tasks.release(id);
            return buffer[0..length];
        }

        fn copyBody(self: *Self, result: download.Result, buffer: []u8) !usize {
            if (result.bytes == 0 or result.bytes > market.max_response_bytes or result.bytes > buffer.len) return error.InvalidResponse;
            const stat = try result.file.stat(self.tasks.io);
            if (stat.kind != .file or stat.size != result.bytes) return error.InvalidResponse;
            const got = try result.file.readPositionalAll(self.tasks.io, buffer[0..result.bytes], 0);
            if (got != result.bytes) return error.InvalidResponse;
            return got;
        }

        fn get(self: *Self, request: cache_mod.Request) !Body {
            try self.cancel.check();
            if (self.now == 0) return error.InvalidClock;
            const key = try request.key();
            const buffer = try self.allocator.alloc(u8, codec.max_record);
            errdefer self.allocator.free(buffer);
            if (try self.cache.load(self.allocator, request, buffer, self.now, self.policy == .offline_only)) |entry| {
                return .{ .storage = buffer, .payload = entry.payload, .stale = entry.stale, .stored_at = entry.stored_at };
            }
            if (self.policy == .offline_only) return error.OfflineMiss;
            const payload = self.readDownload(request, key.url, buffer) catch |err| {
                // Never hide malformed responses, cancellation, budget or
                // cleanup failures behind an apparently successful cache hit.
                if (err == error.NetworkFailed and self.policy == .stale_on_network_failure) {
                    if (try self.cache.load(self.allocator, request, buffer, self.now, true)) |entry| {
                        return .{ .storage = buffer, .payload = entry.payload, .stale = true, .stored_at = entry.stored_at };
                    }
                }
                return err;
            };
            // save validates before writing; a cache write failure is visible.
            try self.cache.save(self.allocator, request, payload, self.now);
            return .{ .storage = buffer, .payload = payload, .stale = false, .stored_at = self.now };
        }

        pub fn openRoot(self: *Self) !Root {
            const body = try self.get(.root);
            defer body.deinit(self.allocator);
            return .{ .parsed = try market.parseIndex(self.allocator, body.payload), .stale = body.stale, .stored_at = body.stored_at };
        }

        fn openSearch(self: *Self, root: market.Index, stale: *bool, expires: *u64) !std.json.Parsed(market.SearchIndex) {
            const body = try self.get(.{ .search_index = root });
            defer body.deinit(self.allocator);
            stale.* = stale.* or body.stale;
            expires.* = @min(expires.*, body.stored_at +| (24 * 60 * 60));
            return market.parseSearchIndex(self.allocator, body.payload, root);
        }

        /// One revision and one search page at a time. Caller must discard
        /// output on error; only a completed scan authorizes result rows.
        pub fn search(self: *Self, root: *const Root, filter: market.Filter, offset: usize, output: []market.Hit) !Search {
            const index = root.parsed.value;
            var stale = !root.fresh(self.now);
            var scan = try market.Scan.init(self.allocator, filter, offset, output);
            defer scan.deinit();
            var expires = root.stored_at +| (15 * 60);
            const search_index = try self.openSearch(index, &stale, &expires);
            defer search_index.deinit();
            for (search_index.value.pages, 0..) |_, n| {
                const number: u32 = @intCast(n);
                const body = try self.get(.{ .search_page = .{ .root = index, .index = search_index.value, .number = number } });
                defer body.deinit(self.allocator);
                stale = stale or body.stale;
                expires = @min(expires, body.stored_at +| (24 * 60 * 60));
                const parsed = try market.parseSearchPage(self.allocator, body.payload, index, search_index.value, number);
                defer parsed.deinit();
                try scan.append(parsed.value);
            }
            var result: Search = .{ .summary = try scan.finish(search_index.value), .revision_len = index.generatedAt.len, .stale = stale, .created_at = self.now, .expires_at = expires };
            @memcpy(result.revision[0..result.revision_len], index.generatedAt);
            for (output[0..result.summary.written], 0..) |*hit, n| {
                result.row_keys[n] = try hitKey(hit);
            }
            return result;
        }

        /// Rehydrate the selected ID from its validated detail page. Stale
        /// or offline results are browsable but cannot initiate installation.
        /// Return a task ID: dispatcher later joins it and calls Install.run.
        pub fn startPackage(self: *Self, root: *const Root, result: *const Search, hit: *const market.Hit, full: bool) !u64 {
            try self.cancel.check();
            if (!result.matches(root) or !result.contains(hit)) return error.StaleSelection;
            var free_slot: ?usize = null;
            for (self.pending, 0..) |entry, n| {
                if (entry) |pending| {
                    if (std.mem.eql(u8, pending.source[0..pending.source_len], hit.sourceId())) return error.AlreadyQueued;
                } else if (free_slot == null) free_slot = n;
            }
            const slot = free_slot orelse return error.ResourceLimit;
            if (!root.fresh(self.now) or result.stale or self.now < result.created_at or self.now >= result.expires_at or self.policy == .offline_only) return error.StaleSelection;
            const index = root.parsed.value;
            const body = try self.get(.{ .detail = .{ .root = index, .number = hit.catalog_page } });
            defer body.deinit(self.allocator);
            if (body.stale) return error.StaleSelection;
            const parsed = try market.parsePage(self.allocator, body.payload, hit.catalog_page, index.pageSize);
            defer parsed.deinit();
            const pet = try market.resolveHit(hit, parsed.value);
            if (!std.mem.eql(u8, pet.displayName, hit.displayName())) return error.StaleSelection;
            const url = pet.download(full) orelse return error.UnsupportedPackage;
            const id = try self.tasks.start(.zip, url, self.transport);
            var pending: Pending = .{ .id = id, .source_len = pet.id.len };
            @memcpy(pending.source[0..pending.source_len], pet.id);
            self.pending[slot] = pending;
            return id;
        }

        fn pendingSlot(self: *Self, id: u64) !usize {
            for (self.pending, 0..) |entry, n| {
                if (entry) |pending| {
                    if (pending.id == id) return n;
                }
            }
            return error.NotOwned;
        }

        pub fn packageProgress(self: *Self, id: u64) !Tasks.Progress {
            _ = try self.pendingSlot(id);
            return self.tasks.progress(id);
        }

        pub fn cancelPackage(self: *Self, id: u64) !void {
            _ = try self.pendingSlot(id);
            try self.tasks.cancel(id);
        }

        /// Serialized worker only. The archive is borrowed until run returns.
        /// The source ID comes from the validated detail page, never the UI.
        /// Report committed results separately from cleanup failures; neither
        /// a failed import nor a cleanup failure permits a second installation.
        pub fn finishPackage(self: *Self, id: u64, stage: *installer.Install, scratch: std.Io.Dir, scratch_path: []const u8, budget: *Budget, root: [*:0]const u16, owner: *importing.Coordinator, helper: anytype) !Finish {
            const slot = try self.pendingSlot(id);
            const pending = self.pending[slot].?;
            if (pending.consumed) return error.AlreadyConsumed;
            if (stage.charged != 0 or stage.stage.root_created or stage.recovery_required) return error.Busy;
            self.pending[slot].?.consumed = true;
            const archive = self.tasks.join(id);
            var outcome: Finish = .{ .result = error.Canceled };
            if (archive) |file| {
                const progress = self.tasks.progress(id) catch unreachable;
                if (!progress.canceled) {
                    outcome.result = stage.run(self.tasks.io, scratch, scratch_path, budget, file, root, owner, helper, pending.source[0..pending.source_len]);
                    stage.cleanup(self.tasks.io, scratch, budget) catch |err| {
                        outcome.stage_cleanup = err;
                    };
                }
            } else |err| {
                outcome.result = err;
            }
            if (self.tasks.release(id)) |_| {
                self.pending[slot] = null;
            } else |err| {
                outcome.transfer_cleanup = err;
            }
            return outcome;
        }

        // Production consumer owns the lease-bound inventory transaction.
        // The resolved source ID is copied by the service, not taken from UI.
        pub fn finishPackageUsing(self: *Self, id: u64, consumer: anytype) !Finish {
            const slot = try self.pendingSlot(id);
            const pending = self.pending[slot].?;
            if (pending.consumed) return error.AlreadyConsumed;
            self.pending[slot].?.consumed = true;
            const archive = self.tasks.join(id);
            var outcome: Finish = .{ .result = error.Canceled };
            if (archive) |file| {
                const progress = try self.tasks.progress(id);
                if (!progress.canceled) {
                    outcome.result = consumer.run(file, pending.source[0..pending.source_len]);
                    consumer.cleanup() catch |err| {
                        outcome.stage_cleanup = err;
                    };
                }
            } else |err| {
                outcome.result = err;
            }
            if (self.tasks.release(id)) |_| {
                self.pending[slot] = null;
            } else |err| {
                outcome.transfer_cleanup = err;
            }
            return outcome;
        }

        /// Cancel, join, release. A consumed task may only retry cleanup.
        pub fn discardPackage(self: *Self, id: u64) !void {
            const slot = try self.pendingSlot(id);
            self.pending[slot].?.consumed = true;
            try self.tasks.cancel(id);
            _ = self.tasks.join(id) catch {};
            try self.tasks.release(id);
            self.pending[slot] = null;
        }

        /// Reject new transfers and drain all owned package and task slots.
        /// Do not free the service, scratch root or group on failure.
        pub fn shutdown(self: *Self) !void {
            self.tasks.requestStop();
            var failed = false;
            for (self.pending) |entry| {
                if (entry) |pending| {
                    self.discardPackage(pending.id) catch {
                        failed = true;
                    };
                }
            }
            if (failed) return error.CleanupFailed;
            try self.tasks.shutdown();
        }
    };
}

pub const WindowsService = Service(http.Transport);

extern "c" fn pet_catalog_store_fixture_open([*]u16, u32) c_int;
extern "c" fn pet_market_cache_fixture_close([*:0]const u16) c_int;

const root_json = "{\"version\":3,\"generatedAt\":\"revision-a\",\"total\":1,\"pageSize\":20,\"search\":\"https://openpets.dev/pets/catalog.v3/rev/search.json\",\"pages\":[\"https://openpets.dev/pets/catalog.v3/rev/detail.json\"]}";
const search_json = "{\"version\":3,\"generatedAt\":\"revision-a\",\"total\":1,\"pageSize\":100,\"pages\":[\"https://openpets.dev/pets/catalog.v3/rev/s0.json\"]}";
const page_json = "{\"version\":3,\"page\":0,\"pageSize\":100,\"pets\":[{\"id\":\"cat\",\"displayName\":\"Cat\",\"searchText\":\"Cute Cat\",\"category\":\"asian\",\"catalogPage\":0,\"original\":true}]}";
const detail_json = "{\"version\":3,\"page\":0,\"pageSize\":20,\"pets\":[{\"id\":\"cat\",\"displayName\":\"Cat\",\"description\":\"Fixture\",\"thumbnail\":\"https://openpets.dev/pets/cat/thumb.webp\",\"spritesheet\":\"https://openpets.dev/pets/cat/spritesheet.webp\",\"zip\":\"https://zip.openpets.dev/pets/cat/base.zip\",\"category\":\"asian\",\"original\":true}]}";

const Fixture = struct {
    calls: *usize,
    fail: bool = false,

    pub fn get(self: *Fixture, kind: download.Kind, url: []const u8, sink: *download.Sink) !void {
        self.calls.* += 1;
        if (self.fail) return error.NetworkFailed;
        const payload = if (kind == .index) root_json else if (kind == .zip) "fixture archive" else if (std.mem.endsWith(u8, url, "/search.json")) search_json else if (std.mem.endsWith(u8, url, "/s0.json")) page_json else if (std.mem.endsWith(u8, url, "/detail.json")) detail_json else return error.InvalidUrl;
        try sink.headers(payload.len);
        try sink.append(payload);
    }
};

test "market service connects real persistent cache, futures, search and package admission" {
    const io = std.testing.io;
    var cache_root: [1024]u16 = @splat(0);
    try std.testing.expect(pet_catalog_store_fixture_open(&cache_root, cache_root.len) != 0);
    const cache_path: [*:0]const u16 = @ptrCast(&cache_root);
    defer {
        std.testing.expect(pet_market_cache_fixture_close(cache_path) != 0) catch @panic("service cache cleanup failed");
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var group = @import("runtime_group").Group.init(std.testing.allocator, 32 * 1024 * 1024, 0, 2);
    var tasks = tasks_mod.Tasks(Fixture).init(io, tmp.dir, &group);
    defer tasks.shutdown() catch @panic("service transfer cleanup failed");
    var calls: usize = 0;
    var service: Service(Fixture) = .{
        .allocator = group.allocator(),
        .tasks = &tasks,
        .cache = .{ .root = cache_path },
        .transport = .{ .calls = &calls },
        .now = 1000,
    };
    {
        var root = try service.openRoot();
        defer root.deinit();
        var hits: [1]market.Hit = undefined;
        const result = try service.search(&root, .{ .query = "cute" }, 0, &hits);
        try std.testing.expectEqual(@as(usize, 1), result.summary.written);
        try std.testing.expectEqualStrings("cat", hits[0].sourceId());
        try std.testing.expectEqual(@as(usize, 3), calls);
        var wrong = hits[0];
        wrong.name[0] = 'X';
        try std.testing.expectError(error.StaleSelection, service.startPackage(&root, &result, &wrong, false));
        const id = try service.startPackage(&root, &result, &hits[0], false);
        try std.testing.expectError(error.AlreadyQueued, service.startPackage(&root, &result, &hits[0], false));
        const archive = try tasks.join(id);
        try std.testing.expectEqual(@as(usize, "fixture archive".len), archive.bytes);
        try service.discardPackage(id);
        try std.testing.expectError(error.NotOwned, service.packageProgress(id));
        try std.testing.expectEqual(@as(usize, 5), calls);
        service.policy = .offline_only;
        try std.testing.expectError(error.StaleSelection, service.startPackage(&root, &result, &hits[0], false));
        service.now = 1001;
        var offline = try service.openRoot();
        defer offline.deinit();
        try std.testing.expect(!offline.stale);
        try std.testing.expectEqual(@as(usize, 5), calls);
        service.now = 1900;
        service.policy = .stale_on_network_failure;
        service.transport.fail = true;
        var fallback = try service.openRoot();
        defer fallback.deinit();
        try std.testing.expect(fallback.stale);
        try std.testing.expectEqual(@as(usize, 6), calls);
        try std.testing.expectError(error.StaleSelection, service.startPackage(&fallback, &result, &hits[0], false));
    }
    try service.shutdown();
    try tasks.checkDrained();
    try group.checkDrained();
}
