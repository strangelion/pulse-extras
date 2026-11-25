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
pub const Progress = http.Progress;

pub const SearchRequest = struct {
    query: [256]u8 = @splat(0),
    len: usize = 0,
    offset: usize = 0,
    offline: bool = false,

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

pub const Request = union(enum) {
    search: SearchRequest,
    install: Selection,
};

pub const Snapshot = struct {
    rows: [page_size]market.Hit = undefined,
    result: ?service_mod.Search = null,
    query: SearchRequest = .{},

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
            out.snapshot.result = try service.search(&root, .{ .query = search.query[0..search.len] }, search.offset, &out.snapshot.rows);
            try service.cancel.check();
        },
        .install => |selected| {
            // A new operation obtains current UTC and reopens the root;
            // stale revisions, copied-row mismatches and expiry are refused.
            const id = try service.startPackage(&root, &selected.result, &selected.hit, selected.full);
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

fn runWork(io: std.Io, owner: *runtime.Owner, private: [:0]const u16, exe: [:0]const u16, digest: [32]u8, root: [:0]const u16, work: [:0]const u16, request: *const Request, out: *Outcome, progress: *Progress, cancel: importing.Cancel, drained: *bool) !void {
    var utf8: [4096]u8 = undefined;
    const len = try std.unicode.utf16LeToUtf8(&utf8, work);
    const work_path = utf8[0..len];
    const scratch = try std.Io.Dir.cwd().openDir(io, work_path, .{ .follow_symlinks = false });
    defer scratch.close(io);
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
        .transport = .{ .call = @ptrCast(try owner.marketSymbol("pet_market_http_get")), .cancel = cancel, .progress = progress },
        .policy = switch (request.*) {
            .search => |search| if (search.offline) .offline_only else .stale_on_network_failure,
            .install => .online,
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
