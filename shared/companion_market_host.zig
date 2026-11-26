//! Worker-only production market owner. The runtime DLL and both private
//! leases outlive every inline transfer, parser, extraction and import.
const std = @import("std");
const runtime = @import("companion_runtime_owner.zig");
const market = @import("companion/pet_market.zig");
const service_mod = @import("companion_market_service.zig");
const cache_mod = @import("companion_market_cache.zig");
const tasks_mod = @import("companion/pet_market_tasks.zig");
const http = @import("companion/pet_market_http_win32.zig");
const download = @import("companion/pet_market_download.zig");
const installer = @import("companion_market_install.zig");
const local_import = @import("companion_local_import.zig");
const importing = @import("companion/pet_import.zig");
const Group = @import("runtime_group").Group;
const Budget = @import("runtime_budget").Budget;

extern "kernel32" fn GetSystemTimeAsFileTime(*[2]u32) callconv(.winapi) void;

pub const page_size = 12;
pub const queue_capacity = 8;
pub const JobState = enum(u32) { waiting, downloading, installing, imported, existing, failed, canceled, cleanup_required };
pub const JobProgress = struct {
    state: std.atomic.Value(u32) = .init(@backingInt(JobState.waiting)),
    transfer: http.Progress = .{},
    canceled: std.atomic.Value(bool) = .init(false),

    // Called only by this job's transfer thread. Never call Pulse's borrowed
    // host cancellation callback from a concurrent WinHTTP callback.
    fn transferCanceled(context: ?*anyopaque) callconv(.c) u32 {
        const self: *JobProgress = @ptrCast(@alignCast(context orelse return 1));
        return @intFromBool(self.canceled.load(.acquire));
    }

    pub fn set(self: *JobProgress, state: JobState) void {
        self.state.store(@backingInt(state), .release);
    }

    pub fn get(self: *const JobProgress) JobState {
        return @fromBackingInt(@intCast(self.state.load(.acquire)));
    }
};

pub const Progress = struct {
    http_progress: http.Progress = .{},
    scan: service_mod.ScanProgress = .{},
    jobs: [queue_capacity]JobProgress = @splat(.{}),

    pub fn resetTransfer(self: *Progress) void {
        self.http_progress.reset();
        self.scan.reset();
    }

    pub fn reset(self: *Progress) void {
        self.resetTransfer();
        for (&self.jobs) |*job| {
            job.set(.waiting);
            job.transfer.reset();
            job.canceled.store(false, .release);
        }
    }
};

extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

pub const FilterMode = enum { curated, all, original, featured, exact_id };
pub const Filters = struct {
    mode: FilterMode = .curated,
    category: market.Category = .any,
    version: market.SpriteVersion = .any,

    pub fn apply(self: Filters, query: []const u8) market.Filter {
        return .{
            .query = query,
            .category = self.category,
            .version = self.version,
            .curated = self.mode == .curated,
            .original_only = self.mode == .original,
            .featured_only = self.mode == .featured,
            .exact_id = self.mode == .exact_id,
        };
    }
};

pub const Detail = service_mod.Detail;

pub const SearchRequest = struct {
    query: [256]u8 = @splat(0),
    len: usize = 0,
    offset: usize = 0,
    offline: bool = false,
    filters: Filters = .{},

    pub fn init(query: []const u8, offset: usize, offline: bool) !SearchRequest {
        if (query.len > 256 or offset > market.max_total or !std.unicode.utf8ValidateSlice(query) or std.mem.indexOfScalar(u8, query, 0) != null) return error.InvalidCatalog;
        var result: SearchRequest = .{ .len = query.len, .offset = offset, .offline = offline };
        @memcpy(result.query[0..query.len], query);
        return result;
    }
};

pub const Selection = struct {
    result: service_mod.Search,
    hit: market.Hit,
    full: bool,
};

pub const Batch = struct {
    count: usize = 0,
    concurrency: usize = 4,
    selections: [queue_capacity]Selection = undefined,

    pub fn append(self: *Batch, selection: Selection) !void {
        if (self.count >= self.selections.len or self.concurrency == 0 or self.concurrency > queue_capacity) return error.ResourceLimit;
        if (selection.result.stale or !selection.result.contains(&selection.hit)) return error.StaleSelection;
        for (self.selections[0..self.count]) |*item| {
            if (std.mem.eql(u8, item.hit.sourceId(), selection.hit.sourceId())) return error.AlreadyQueued;
        }
        self.selections[self.count] = selection;
        self.count += 1;
    }

    pub fn remove(self: *Batch, index: usize) void {
        if (index >= self.count) return;
        var n = index;
        while (n + 1 < self.count) : (n += 1) self.selections[n] = self.selections[n + 1];
        self.count -= 1;
    }
};

pub const DetailRequest = struct {
    result: service_mod.Search,
    hit: market.Hit,
    offline: bool,
};

pub const Request = union(enum) {
    search: SearchRequest,
    detail: DetailRequest,
    install: Selection,
    batch: Batch,
};

pub const Snapshot = struct {
    rows: [page_size]market.Hit = undefined,
    result: ?service_mod.Search = null,
    query: SearchRequest = .{},

    pub fn detailIndex(self: *const Snapshot, index: usize) !Request {
        const result = self.result orelse return error.StaleSelection;
        if (result.summary.written > self.rows.len or index >= result.summary.written) return error.StaleSelection;
        const row = &self.rows[index];
        if (!result.contains(row)) return error.StaleSelection;
        return .{ .detail = .{ .result = result, .hit = row.*, .offline = self.query.offline or result.stale } };
    }

    pub fn selectIndex(self: *const Snapshot, index: usize, full: bool) !Request {
        const result = self.result orelse return error.StaleSelection;
        if (self.query.offline or result.stale or result.summary.written > self.rows.len or index >= result.summary.written) return error.StaleSelection;
        const row = &self.rows[index];
        if (!result.contains(row)) return error.StaleSelection;
        return .{ .install = .{ .result = result, .hit = row.*, .full = full } };
    }

    pub fn select(self: *const Snapshot, id: []const u8, full: bool) !Request {
        const result = self.result orelse return error.StaleSelection;
        if (self.query.offline or result.stale or result.summary.written > self.rows.len) return error.StaleSelection;
        for (self.rows[0..result.summary.written], 0..) |*row, n| {
            if (std.mem.eql(u8, row.sourceId(), id)) return self.selectIndex(n, full);
        }
        return error.StaleSelection;
    }
};

pub const Outcome = struct {
    snapshot: Snapshot = .{},
    installed: ?importing.Result = null,
    detail: ?Detail = null,
    batch_committed: usize = 0,
    batch_existing: usize = 0,
    batch_failed: usize = 0,
    batch_canceled: usize = 0,
};

const Access = struct {
    owner: ?*runtime.Owner = null,

    pub fn read(self: Access, _: [*:0]const u16, slot: u32, buffer: []u8) !?usize {
        return (self.owner orelse return error.OwnerUnavailable).marketRead(slot, buffer);
    }

    pub fn write(self: Access, _: [*:0]const u16, slot: u32, data: []const u8) !void {
        try (self.owner orelse return error.OwnerUnavailable).marketWrite(slot, data);
    }
};

const Cache = cache_mod.CacheFor(Access);
const Service = service_mod.ServiceFor(http.BoundTransport, Cache, true);
const Tasks = tasks_mod.TasksMode(http.BoundTransport, true);

fn now() !u64 {
    var value: [2]u32 = undefined;
    GetSystemTimeAsFileTime(&value);
    const seconds = ((@as(u64, value[1]) << 32) | value[0]) / 10_000_000;
    if (seconds <= 11_644_473_600) return error.InvalidClock;
    return seconds - 11_644_473_600;
}

const Consumer = struct {
    io: std.Io,
    owner: *runtime.Owner,
    private: [:0]const u16,
    exe: [:0]const u16,
    digest: [32]u8,
    scratch: std.Io.Dir,
    scratch_path: []const u8,
    cancel: importing.Cancel,
    stage: *installer.Install,
    budget: Budget = Budget.init(640 * 1024 * 1024),

    pub fn run(self: *Consumer, archive: download.Result, source: []const u8) !importing.Result {
        try self.cancel.check();
        var path: [4096]u8 = undefined;
        const unpacked = try self.stage.unpack(self.io, self.scratch, self.scratch_path, &self.budget, archive, &path);
        try self.cancel.check();
        return local_import.runControlled(self.io, self.owner, self.private, self.exe, self.digest, unpacked, source, self.cancel) catch |err| {
            if (err == error.RecoveryRequired or err == error.CleanupFailed) self.stage.recovery_required = true;
            return err;
        };
    }

    pub fn cleanup(self: *Consumer) !void {
        try self.stage.cleanup(self.io, self.scratch, &self.budget);
        if (self.budget.used != 0) return error.CleanupFailed;
    }
};

fn execute(service: *Service, consumer: *Consumer, request: *const Request, out: *Outcome, safe: *bool) !void {
    var root = try service.openRoot();
    defer root.deinit();
    switch (request.*) {
        .search => |search| {
            out.snapshot.query = search;
            out.snapshot.result = try service.search(&root, search.filters.apply(search.query[0..search.len]), search.offset, &out.snapshot.rows);
            try service.cancel.check();
        },
        .detail => |selected| {
            out.detail = try service.detail(&root, &selected.result, &selected.hit);
        },
        .batch => unreachable,
        .install => |selected| {
            // A new operation obtains current UTC and reopens the root;
            // stale revisions, copied-row mismatches and expiry are refused.
            const id = try service.startPackageStrict(&root, &selected.result, &selected.hit, selected.full);
            const finish = try service.finishPackageUsing(id, consumer);
            if (finish.result) |installed| {
                out.installed = installed;
            } else |err| {
                if (finish.stage_cleanup != null or finish.transfer_cleanup != null) {
                    safe.* = false;
                    return error.MarketCleanupFailed;
                }
                return err;
            }
            if (finish.stage_cleanup != null or finish.transfer_cleanup != null) {
                safe.* = false;
                return error.MarketCleanupFailed;
            }
        },
    }
}

const BatchService = service_mod.ServiceFor(http.BoundTransport, Cache, false);
const BatchTasks = tasks_mod.TasksMode(http.BoundTransport, false);

const JobCancel = struct {
    host: importing.Cancel,
    job: *JobProgress,

    fn check(context: ?*anyopaque) callconv(.c) u32 {
        const self: *JobCancel = @ptrCast(@alignCast(context orelse return 1));
        self.host.check() catch return 1;
        return @intFromBool(self.job.canceled.load(.acquire));
    }
};

fn failJob(job: *JobProgress, out: *Outcome, err: anyerror) void {
    if (err == error.Canceled) {
        job.set(.canceled);
        out.batch_canceled += 1;
    } else {
        job.set(.failed);
        out.batch_failed += 1;
    }
}

fn executeBatch(service: *BatchService, consumer: *Consumer, batch: *const Batch, out: *Outcome, progress: *Progress, host_cancel: importing.Cancel, safe: *bool) !void {
    if (batch.count == 0 or batch.count > queue_capacity or batch.concurrency == 0 or batch.concurrency > queue_capacity) return error.InvalidLimit;
    var root = try service.openRoot();
    defer root.deinit();
    var ids: [queue_capacity]?u64 = @splat(null);
    var next: usize = 0;
    var active: usize = 0;
    while (next < batch.count or active != 0) {
        const stopping = blk: {
            host_cancel.check() catch break :blk true;
            break :blk false;
        };
        while (next < batch.count and active < batch.concurrency) : (next += 1) {
            const job = &progress.jobs[next];
            if (stopping or job.canceled.load(.acquire)) {
                failJob(job, out, error.Canceled);
                continue;
            }
            const selected = &batch.selections[next];
            service.now = try now();
            // Tasks copy the transport into their stable owned slots. Each
            // transfer can publish progress and observe row cancellation
            // while the host worker is resolving another row or importing.
            service.transport.cancel = .{ .callback = JobProgress.transferCanceled, .context = job };
            service.transport.progress = &job.transfer;
            const id = service.startPackageStrict(&root, &selected.result, &selected.hit, selected.full) catch |err| {
                failJob(job, out, err);
                if (err == error.CleanupFailed or err == error.TransportCleanupFailed) {
                    safe.* = false;
                    return error.MarketCleanupFailed;
                }
                continue;
            };
            ids[next] = id;
            active += 1;
            job.set(.downloading);
        }
        var progressed = false;
        for (ids[0..batch.count], 0..) |entry, n| {
            const id = entry orelse continue;
            const job = &progress.jobs[n];
            if (stopping or job.canceled.load(.acquire)) try service.cancelPackage(id);
            const status = try service.packageProgress(id);
            if (!status.finished) continue;
            job.set(.installing);
            var job_cancel: JobCancel = .{ .host = host_cancel, .job = job };
            consumer.cancel = .{ .callback = JobCancel.check, .context = &job_cancel };
            const finish = try service.finishPackageUsing(id, consumer);
            consumer.cancel = host_cancel;
            ids[n] = null;
            active -= 1;
            progressed = true;
            if (finish.result) |installed| {
                switch (installed) {
                    .imported => {
                        out.batch_committed += 1;
                        job.set(.imported);
                    },
                    .existing => {
                        out.batch_existing += 1;
                        job.set(.existing);
                    },
                }
            } else |err| failJob(job, out, err);
            if (finish.stage_cleanup != null or finish.transfer_cleanup != null) {
                // Keep a committed outcome visible even if cleanup failed.
                if (finish.result) |_| {} else |_| job.set(.cleanup_required);
                safe.* = false;
                return error.MarketCleanupFailed;
            }
        }
        if (!progressed and active != 0) Sleep(25);
    }
    try host_cancel.check();
}

fn runBatchWork(io: std.Io, owner: *runtime.Owner, private: [:0]const u16, exe: [:0]const u16, digest: [32]u8, root: [:0]const u16, scratch: std.Io.Dir, work_path: []const u8, batch: *const Batch, out: *Outcome, progress: *Progress, cancel: importing.Cancel, drained: *bool) !void {
    if (batch.count == 0 or batch.count > queue_capacity or batch.concurrency == 0 or batch.concurrency > queue_capacity) return error.InvalidLimit;
    // One extra metadata slot, with a distinct aggregate archive reservation.
    // Extraction has its own 640 MiB reservation and is strictly serialized.
    var group = Group.init(std.heap.page_allocator, 64 * 1024 * 1024, 0, batch.concurrency + 1);
    const tasks = try std.heap.page_allocator.create(BatchTasks);
    defer std.heap.page_allocator.destroy(tasks);
    tasks.* = BatchTasks.init(io, scratch, &group);
    tasks.pool.downloads = batch.concurrency;
    tasks.pool.disk = Budget.init(queue_capacity * download.limit(.zip) + download.limit(.catalog));
    const stage = try std.heap.page_allocator.create(installer.Install);
    defer std.heap.page_allocator.destroy(stage);
    stage.* = .{};
    var consumer: Consumer = .{ .io = io, .owner = owner, .private = private, .exe = exe, .digest = digest, .scratch = scratch, .scratch_path = work_path, .cancel = cancel, .stage = stage };
    var service: BatchService = .{
        .allocator = group.allocator(),
        .tasks = tasks,
        .cache = .{ .root = root.ptr, .access = .{ .owner = owner } },
        // No host callback or shared progress pointer crosses to transfer threads.
        .transport = .{ .call = @ptrCast(try owner.marketSymbol("pet_market_http_get")) },
        .policy = .online,
        .cancel = cancel,
        .now = try now(),
    };
    var safe = true;
    const result = executeBatch(&service, &consumer, batch, out, progress, cancel, &safe);
    // Cancel any remaining transfer before joining, including callbacks
    // blocked on another job's serialized import. Preserve committed states.
    for (progress.jobs[0..batch.count]) |*job| {
        switch (job.get()) {
            .waiting, .downloading, .installing => job.canceled.store(true, .release),
            else => {},
        }
    }
    const shutdown = service.shutdown();
    const terminal_error = if (result) |_| error.Canceled else |err| err;
    for (progress.jobs[0..batch.count]) |*job| {
        switch (job.get()) {
            .waiting, .downloading, .installing => failJob(job, out, terminal_error),
            else => {},
        }
    }
    try shutdown;
    try group.checkDrained();
    drained.* = safe;
    return result;
}

fn runWork(io: std.Io, owner: *runtime.Owner, private: [:0]const u16, exe: [:0]const u16, digest: [32]u8, root: [:0]const u16, work: [:0]const u16, request: *const Request, out: *Outcome, progress: *Progress, cancel: importing.Cancel, drained: *bool) !void {
    var utf8: [4096]u8 = undefined;
    const len = try std.unicode.utf16LeToUtf8(&utf8, work);
    const work_path = utf8[0..len];
    const scratch = try std.Io.Dir.cwd().openDir(io, work_path, .{ .follow_symlinks = false });
    defer scratch.close(io);
    if (request.* == .batch) return runBatchWork(io, owner, private, exe, digest, root, scratch, work_path, &request.batch, out, progress, cancel, drained);
    var group = Group.init(std.heap.page_allocator, 64 * 1024 * 1024, 0, 1);
    const tasks = try std.heap.page_allocator.create(Tasks);
    defer std.heap.page_allocator.destroy(tasks);
    tasks.* = Tasks.init(io, scratch, &group);
    const stage = try std.heap.page_allocator.create(installer.Install);
    defer std.heap.page_allocator.destroy(stage);
    stage.* = .{};
    var consumer: Consumer = .{ .io = io, .owner = owner, .private = private, .exe = exe, .digest = digest, .scratch = scratch, .scratch_path = work_path, .cancel = cancel, .stage = stage };
    var service: Service = .{
        .allocator = group.allocator(),
        .tasks = tasks,
        .cache = .{ .root = root.ptr, .access = .{ .owner = owner } },
        .transport = .{ .call = @ptrCast(try owner.marketSymbol("pet_market_http_get")), .cancel = cancel, .progress = &progress.http_progress },
        .scan_progress = &progress.scan,
        .policy = switch (request.*) {
            .search => |search| if (search.offline) .offline_only else .stale_on_network_failure,
            .detail => |selected| if (selected.offline) .offline_only else .stale_on_network_failure,
            .install, .batch => .online,
        },
        .cancel = cancel,
        .now = try now(),
    };
    var safe = true;
    const result = execute(&service, &consumer, request, out, &safe);
    try service.shutdown();
    try group.checkDrained();
    drained.* = safe;
    return result;
}

pub fn run(io: std.Io, owner: *runtime.Owner, private: [:0]const u16, exe: [:0]const u16, digest: [32]u8, request: *const Request, out: *Outcome, progress: *Progress, cancel: importing.Cancel) !void {
    out.* = .{};
    try cancel.check();
    const root = try owner.openMarketRoot();
    const work = try owner.createMarketWork();
    var drained = false;
    const result = runWork(io, owner, private, exe, digest, root, work, request, out, progress, cancel, &drained);
    // Never remove a preexisting or incompletely drained scratch directory.
    if (drained) try owner.finishMarketWork();
    return result;
}

test "market search copies bounded query and empty selection cannot install" {
    const search = try SearchRequest.init("cat", 12, true);
    try std.testing.expectEqualStrings("cat", search.query[0..search.len]);
    try std.testing.expectError(error.InvalidCatalog, SearchRequest.init("a\x00b", 0, false));
    const empty: Snapshot = .{};
    try std.testing.expectError(error.StaleSelection, empty.select("cat", true));
    try std.testing.expectError(error.StaleSelection, empty.selectIndex(0, true));
    var snapshot: Snapshot = .{};
    snapshot.result = .{ .summary = .{ .total = 1, .written = 1 }, .revision_len = 0, .stale = false, .created_at = 1, .expires_at = 2, .row_keys = @splat(@splat(0)) };
    snapshot.rows[0] = .{ .id = @splat('a'), .id_len = 1, .name = @splat('b'), .name_len = 1, .catalog_page = 0 };
    try std.testing.expectError(error.StaleSelection, snapshot.selectIndex(1, false));
    try std.testing.expectError(error.StaleSelection, snapshot.selectIndex(0, false));
    snapshot.query.offline = true;
    try std.testing.expectError(error.StaleSelection, snapshot.selectIndex(0, true));
}

test "filter projection preserves explicit mode and bounded search" {
    const filters: Filters = .{ .mode = .original, .category = .asian, .version = .v2 };
    const projected = filters.apply("cat");
    try std.testing.expect(projected.original_only and !projected.curated and !projected.featured_only);
    try std.testing.expectEqual(market.Category.asian, projected.category);
    try std.testing.expectEqual(market.SpriteVersion.v2, projected.version);
    const exact = (Filters{ .mode = .exact_id }).apply("cat");
    try std.testing.expect(exact.exact_id and !exact.curated);
    const empty: Snapshot = .{};
    try std.testing.expectError(error.StaleSelection, empty.detailIndex(0));
}

test "batch rejects invalid capacity and stale rows without transfer admission" {
    var batch: Batch = .{ .concurrency = 0 };
    var selection: Selection = undefined;
    try std.testing.expectError(error.ResourceLimit, batch.append(selection));
    batch.concurrency = 4;
    selection.result = .{ .summary = .{ .total = 0, .written = 0 }, .revision_len = 0, .stale = true, .created_at = 0, .expires_at = 0 };
    selection.hit = .{ .id = @splat('a'), .id_len = 1, .name = @splat('b'), .name_len = 1, .catalog_page = 0 };
    selection.full = false;
    try std.testing.expectError(error.StaleSelection, batch.append(selection));
    try std.testing.expectEqual(@as(usize, 0), batch.count);
    var progress: Progress = .{};
    progress.jobs[0].set(.imported);
    progress.jobs[0].canceled.store(true, .release);
    progress.reset();
    try std.testing.expectEqual(JobState.waiting, progress.jobs[0].get());
    try std.testing.expect(!progress.jobs[0].canceled.load(.acquire));
    try std.testing.expectEqual(@as(u32, 0), JobProgress.transferCanceled(&progress.jobs[0]));
    progress.jobs[0].canceled.store(true, .release);
    try std.testing.expectEqual(@as(u32, 1), JobProgress.transferCanceled(&progress.jobs[0]));
    try std.testing.expectEqual(@as(u32, 0), JobProgress.transferCanceled(&progress.jobs[1]));
    try std.testing.expectEqual(@as(u32, 1), JobProgress.transferCanceled(null));
    progress.jobs[1].transfer.received.store(123, .release);
    try std.testing.expectEqual(@as(usize, 0), progress.jobs[0].transfer.received.load(.acquire));
    progress.reset();
    try std.testing.expectEqual(@as(usize, 0), progress.jobs[1].transfer.received.load(.acquire));
}

test "batch terminal failure does not masquerade as user cancellation" {
    var out: Outcome = .{};
    var job: JobProgress = .{};
    failJob(&job, &out, error.NetworkFailed);
    try std.testing.expectEqual(JobState.failed, job.get());
    try std.testing.expectEqual(@as(usize, 1), out.batch_failed);
    try std.testing.expectEqual(@as(usize, 0), out.batch_canceled);
    failJob(&job, &out, error.Canceled);
    try std.testing.expectEqual(JobState.canceled, job.get());
    try std.testing.expectEqual(@as(usize, 1), out.batch_canceled);
}
