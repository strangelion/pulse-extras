//! One import root for the settings extension, so catalog and manager types
//! have the same module identity.
const std = @import("std");
const builtin = @import("builtin");
const library = @import("companion/pet_library_read.zig");
const runtime = @import("companion_runtime_owner.zig");
const group = @import("companion_group.zig");
const model = @import("companion/pet_manager.zig");
const inventory = @import("companion/pet_inventory.zig");
pub const builtin_asset_id = group.Group.builtin_asset_id;

const store = @import("companion_runtime_store.zig");
const local_import = @import("companion_local_import.zig");
const market_host = @import("companion_market_host.zig");
const process = @import("pulse_process");

pub const Snapshot = library.Snapshot;
pub const PreferenceAction = enum { toggle_favorite, add_tag, remove_tag };
pub const PreferenceEdit = struct {
    row: library.Row,
    action: PreferenceAction,
    tag: [64]u8 = @splat(0),
    tag_len: usize = 0,
};
pub const readFilteredDefault = library.readFilteredDefault;

extern "kernel32" fn GetModuleHandleExW(u32, *const anyopaque, *usize) callconv(.winapi) c_int;
extern "kernel32" fn GetModuleFileNameW(usize, [*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn GetWindowsDirectoryW([*]u16, u32) callconv(.winapi) u32;

pub fn parseDigest(hex: []const u8) ![32]u8 {
    if (hex.len != 64) return error.InvalidRuntimeDigest;
    var digest: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&digest, hex) catch return error.InvalidRuntimeDigest;
    return digest;
}

fn packageRoot(path: *[1024]u16) ![:0]const u16 {
    var module: usize = 0;
    // FROM_ADDRESS | UNCHANGED_REFCOUNT: locate this exact entry DLL.
    if (GetModuleHandleExW(6, @ptrCast(&checkRuntime), &module) == 0 or module == 0) return error.ModulePathUnavailable;
    const len = GetModuleFileNameW(module, path, path.len);
    if (len == 0 or len >= path.len) return error.ModulePathUnavailable;
    const last = std.mem.lastIndexOfScalar(u16, path[0..len], '\\') orelse return error.ModulePathUnavailable;
    path[last] = 0;
    return path[0..last :0];
}

pub fn checkRuntime(hex: []const u8) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(hex);
    var path: [1024]u16 = undefined;
    const root = try packageRoot(&path);
    // No children in this one-shot check. Keep the owner stable until close.
    const owner = try std.heap.page_allocator.create(runtime.Owner);
    owner.* = .{};
    owner.open(root, digest, 1, 128 * 1024 * 1024) catch |err| {
        owner.close() catch return error.CleanupFailed;
        std.heap.page_allocator.destroy(owner);
        return err;
    };
    owner.close() catch return error.CleanupFailed;
    std.heap.page_allocator.destroy(owner);
}

fn openPrivateDefault(owner: *runtime.Owner) ![:0]const u16 {
    var path: [1024]u16 = undefined;
    const root = try library.knownRoot(&path);
    const suffix = std.unicode.wtf8ToWtf16LeStringLiteral("\\PulseExtras-Companion");
    if (!std.mem.endsWith(u16, root, suffix) or root.len <= suffix.len) return error.InvalidRoot;
    const parent_len = root.len - suffix.len;
    path[parent_len] = 0;
    return owner.privateRoot(path[0..parent_len :0]);
}

fn applyEdit(owner: *runtime.Owner, edit: *const PreferenceEdit) !void {
    _ = try openPrivateDefault(owner);
    _ = try store.applyPreference(owner, edit.row.id, edit.row.sourceId(), edit.row.preference_version, switch (edit.action) {
        .toggle_favorite => .{ .favorite = !edit.row.favorite },
        .add_tag => .{ .add_tag = edit.tag[0..edit.tag_len] },
        .remove_tag => .{ .remove_tag = edit.tag[0..edit.tag_len] },
    });
}

pub fn editPreferenceDefault(hex: []const u8, edit: *const PreferenceEdit) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(hex);
    var path: [1024]u16 = undefined;
    const root = try packageRoot(&path);
    const owner = try std.heap.page_allocator.create(runtime.Owner);
    owner.* = .{};
    const outcome = blk: {
        owner.open(root, digest, 1, 128 * 1024 * 1024) catch |err| break :blk @as(anyerror!void, err);
        break :blk applyEdit(owner, edit);
    };
    owner.close() catch return error.CleanupFailed;
    std.heap.page_allocator.destroy(owner);
    return outcome;
}

const recovery = @import("companion/pet_recovery_scan.zig");
pub const RecoveryReport = recovery.Report;
pub const RecoverySnapshot = recovery.Snapshot;
pub const RecoveryState = recovery.RegisteredState;
pub const QuarantineDetail = recovery.QuarantineDetail;

pub const RemovalAction = enum { quarantine, restore_interrupted, purge };
pub const CleanupReceipt = @import("companion/pet_removal_receipt.zig").Receipt;
pub const RemovalRequest = struct {
    expected: inventory.Record,
    action: RemovalAction,
    cleanup: ?CleanupReceipt = null,

    pub fn init(row: *const library.Row, snapshot: *const RecoverySnapshot, action: RemovalAction) !RemovalRequest {
        const expected = try row.removalRecord();
        const state = snapshot.stateFor(expected.id) orelse return error.RecoveryRequired;
        const required: RecoveryState = switch (action) {
            .quarantine => .normal,
            .restore_interrupted => .interrupted_removal,
            .purge => return error.InvalidRecord,
        };
        if (state != required) return error.RecoveryRequired;
        return .{ .expected = expected, .action = action };
    }

    pub fn initCleanup(detail: *const QuarantineDetail) !RemovalRequest {
        if (detail.state != .unregistered_retained or detail.receipt_state != .matched_identity or detail.logical_bytes == null) return error.RecoveryRequired;
        const value = detail.cleanup_receipt orelse return error.MissingReceipt;
        if (value.record.id != detail.id) return error.InvalidReceipt;
        return .{ .expected = value.record, .action = .purge, .cleanup = value };
    }
};

// Called only after explicit host confirmation. The earlier diagnostic
// snapshot is an admission hint, never authorization: store rechecks
// the copied record and exact directory state under the private lease.
pub fn applyRemovalDefault(hex: []const u8, request: *const RemovalRequest, cancel: ImportCancel) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(hex);
    var path: [1024]u16 = undefined;
    const root = try packageRoot(&path);
    const owner = try std.heap.page_allocator.create(runtime.Owner);
    owner.* = .{};
    const outcome = blk: {
        owner.open(root, digest, 1, 128 * 1024 * 1024) catch |err| break :blk @as(anyerror!void, err);
        _ = openPrivateDefault(owner) catch |err| break :blk @as(anyerror!void, err);
        break :blk switch (request.action) {
            .quarantine => store.quarantineRemove(owner, request.expected),
            .restore_interrupted => store.restoreInterruptedRemoval(owner, request.expected),
            .purge => if (request.cleanup) |value| store.cleanupPermanent(owner, value, cancel) else error.MissingReceipt,
        };
    };
    owner.close() catch return error.CleanupFailed;
    std.heap.page_allocator.destroy(owner);
    return outcome;
}

// Use the same verified module and private-root lease as other maintenance
// operations. The scan never adopts or deletes any asset or preference.
pub fn scanRecoveryDefault(hex: []const u8) !RecoverySnapshot {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(hex);
    var path: [1024]u16 = undefined;
    const root = try packageRoot(&path);
    const owner = try std.heap.page_allocator.create(runtime.Owner);
    owner.* = .{};
    const outcome = blk: {
        owner.open(root, digest, 1, 128 * 1024 * 1024) catch |err| break :blk @as(anyerror!RecoverySnapshot, err);
        _ = openPrivateDefault(owner) catch |err| break :blk @as(anyerror!RecoverySnapshot, err);
        break :blk store.scanRecoveryDetailed(owner);
    };
    owner.close() catch return error.CleanupFailed;
    std.heap.page_allocator.destroy(owner);
    return outcome;
}

pub const MarketRequest = market_host.Request;
pub const MarketSnapshot = market_host.Snapshot;
pub const MarketOutcome = market_host.Outcome;
pub const MarketProgress = market_host.Progress;
pub const MarketSearch = market_host.SearchRequest;

pub fn marketDefault(runtime_hex: []const u8, helper_hex: []const u8, request: *const MarketRequest, out: *MarketOutcome, progress: *MarketProgress, cancel: ImportCancel) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(runtime_hex);
    const helper_digest = try parseDigest(helper_hex);
    var path: [1024]u16 = undefined;
    const root = try packageRoot(&path);
    const suffix = std.unicode.wtf8ToWtf16LeStringLiteral("\\pulse-pet-demo.exe");
    var exe: [1024]u16 = undefined;
    if (root.len + suffix.len >= exe.len) return error.ModulePathUnavailable;
    @memcpy(exe[0..root.len], root);
    @memcpy(exe[root.len..][0..suffix.len], suffix);
    const len = root.len + suffix.len;
    exe[len] = 0;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const owner = try std.heap.page_allocator.create(runtime.Owner);
    owner.* = .{};
    const outcome = blk: {
        owner.open(root, digest, 1, 128 * 1024 * 1024) catch |err| break :blk @as(anyerror!void, err);
        const private = openPrivateDefault(owner) catch |err| break :blk @as(anyerror!void, err);
        break :blk market_host.run(threaded.io(), owner, private, exe[0..len :0], helper_digest, request, out, progress, cancel);
    };
    owner.close() catch return error.CleanupFailed;
    std.heap.page_allocator.destroy(owner);
    return outcome;
}

pub const ImportResult = local_import.Result;
pub const ImportCancel = local_import.Cancel;
pub const ImportRequest = struct {
    source: [4096]u8 = undefined,
    source_len: usize = 0,
    source_id: [64]u8 = undefined,
    id_len: usize = 0,

    pub fn init(source: []const u8, id: []const u8) !ImportRequest {
        if (source.len < 4 or source.len > 4096 or !std.ascii.isAlphabetic(source[0]) or source[1] != ':' or source[2] != '\\' or
            std.mem.indexOfScalar(u8, source, 0) != null or !std.unicode.utf8ValidateSlice(source) or !inventory.validSource(id)) return error.InvalidSource;
        var request: ImportRequest = .{};
        @memcpy(request.source[0..source.len], source);
        @memcpy(request.source_id[0..id.len], id);
        request.source_len = source.len;
        request.id_len = id.len;
        return request;
    }
};

pub const validSourceId = inventory.validSource;

pub const PickedFolder = struct {
    path: [4096]u8 = undefined,
    len: usize = 0,
};

// The picker is a separate, job-contained approved helper, not a COM call
// inside the Pulse DLL. Its only successful output is one bounded path or
// an explicit cancellation. The timeout also bounds shutdown of old hosts.
pub fn pickFolderDefault(helper_hex: []const u8) !?PickedFolder {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(helper_hex);
    var wide: [1024]u16 = undefined;
    const root = try packageRoot(&wide);
    var root_bytes: [4096]u8 = undefined;
    const root_len = try std.unicode.utf16LeToUtf8(&root_bytes, root);
    var exe_bytes: [4096]u8 = undefined;
    const exe = try std.fmt.bufPrint(&exe_bytes, "{s}\\pulse-pet-demo.exe", .{root_bytes[0..root_len]});
    var system_wide: [1024]u16 = undefined;
    const n = GetWindowsDirectoryW(&system_wide, system_wide.len);
    if (n == 0 or n >= system_wide.len) return error.InvalidSystemDirectory;
    var system_bytes: [4096]u8 = undefined;
    const system_len = try std.unicode.utf16LeToUtf8(&system_bytes, system_wide[0..n]);
    var environ = std.process.Environ.Map.init(std.heap.page_allocator);
    defer environ.deinit();
    try environ.put("SystemRoot", system_bytes[0..system_len]);
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    var runner = process.Runner.init(std.heap.page_allocator, threaded.io());
    try runner.configureApproved(.{ .path = exe, .digest = digest }, 60 * std.time.ns_per_s);
    try runner.configureTree(.windows_job);
    const outcome = blk: {
        var result = runner.run(.{
            .argv = &.{ exe, "--pick-folder" },
            .cwd = root_bytes[0..root_len],
            .environ_map = &environ,
            .timeout_ns = 60 * std.time.ns_per_s,
            .stdout_limit = 4128,
            .stderr_limit = 16 * 1024,
        }) catch |err| break :blk @as(anyerror!?PickedFolder, err);
        defer result.deinit();
        if (!result.succeeded()) break :blk @as(anyerror!?PickedFolder, error.PickerFailed);
        break :blk parsePickedFolder(result.stdout);
    };
    try runner.checkDrained();
    return outcome;
}

fn parsePickedFolder(bytes: []const u8) !?PickedFolder {
    if (std.mem.eql(u8, bytes, "PULSE_FOLDER_CANCELLED")) return null;
    const prefix = "PULSE_FOLDER_V1 ";
    if (!std.mem.startsWith(u8, bytes, prefix)) return error.InvalidPickerOutput;
    const path = bytes[prefix.len..];
    if (path.len < 4 or path.len > 4096 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '\\' or !std.unicode.utf8ValidateSlice(path) or std.mem.indexOfAny(u8, path, "\x00\r\n") != null) return error.InvalidPickerOutput;
    var result: PickedFolder = .{ .len = path.len };
    @memcpy(result.path[0..path.len], path);
    return result;
}

test "picker output is bounded and distinguishes cancellation" {
    try std.testing.expect((try parsePickedFolder("PULSE_FOLDER_CANCELLED")) == null);
    const chosen = (try parsePickedFolder("PULSE_FOLDER_V1 C:\\素材\\cat")).?;
    try std.testing.expectEqualStrings("C:\\素材\\cat", chosen.path[0..chosen.len]);
    try std.testing.expectError(error.InvalidPickerOutput, parsePickedFolder("PULSE_FOLDER_V1 relative"));
    try std.testing.expectError(error.InvalidPickerOutput, parsePickedFolder("PULSE_FOLDER_V1 C:\\cat\nextra"));
}

pub fn importDefault(runtime_hex: []const u8, helper_hex: []const u8, request: *const ImportRequest, cancel: ImportCancel) !ImportResult {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(runtime_hex);
    const helper_digest = try parseDigest(helper_hex);
    var path: [1024]u16 = undefined;
    const root = try packageRoot(&path);
    const suffix = std.unicode.wtf8ToWtf16LeStringLiteral("\\pulse-pet-demo.exe");
    var exe: [1024]u16 = undefined;
    if (root.len + suffix.len >= exe.len) return error.ModulePathUnavailable;
    @memcpy(exe[0..root.len], root);
    @memcpy(exe[root.len..][0..suffix.len], suffix);
    const len = root.len + suffix.len;
    exe[len] = 0;
    var threaded = std.Io.Threaded.init(std.heap.page_allocator, .{});
    defer threaded.deinit();
    const owner = try std.heap.page_allocator.create(runtime.Owner);
    owner.* = .{};
    const outcome = blk: {
        owner.open(root, digest, 1, 128 * 1024 * 1024) catch |err| break :blk @as(anyerror!ImportResult, err);
        const private = openPrivateDefault(owner) catch |err| break :blk @as(anyerror!ImportResult, err);
        break :blk local_import.runControlled(threaded.io(), owner, private, exe[0..len :0], helper_digest, request.source[0..request.source_len], request.source_id[0..request.id_len], cancel);
    };
    owner.close() catch return error.CleanupFailed;
    std.heap.page_allocator.destroy(owner);
    return outcome;
}

test "import request copies bounded local path and valid metadata identity" {
    const request = try ImportRequest.init("C:\\素材\\cat", "cat");
    try std.testing.expectEqualStrings("C:\\素材\\cat", request.source[0..request.source_len]);
    try std.testing.expectError(error.InvalidSource, ImportRequest.init("relative", "cat"));
    try std.testing.expectError(error.InvalidSource, ImportRequest.init("C:\\cat", "builtin"));
    try std.testing.expectError(error.InvalidSource, ImportRequest.init("C:\\cat", "CAT"));
}

// Experimental UI admission ceiling, independent of native storage capacity.
pub const session_limit: usize = 8;

// One pending built-in start; all native operations remain worker-owned.
pub const Phase = enum(u32) { idle, starting, running, stopping };
pub const Rejection = enum(u32) {
    none,
    capacity,
    unverified,
    private_root,
    unknown_asset,
    launch_failed,
    unknown_instance,
    child_exit,
};

pub fn rejectionFor(err: anyerror) Rejection {
    return switch (err) {
        error.Capacity, error.StorageCapacity, error.BudgetExceeded, error.CountLimit, error.StorageLimit, error.BudgetLimit, error.SystemMemory => .capacity,
        error.UnverifiedAsset, error.UnapprovedExecutable => .unverified,
        error.PrivateRootBusy, error.PrivateRootRejected, error.MissingLeaseApi, error.InvalidRoot => .private_root,
        error.UnknownAsset => .unknown_asset,
        error.UnknownInstance => .unknown_instance,
        else => .launch_failed,
    };
}

pub const RunningRow = model.Instance;
pub const RunningSource = struct {
    id: u64 = 0,
    bytes: [64]u8 = @splat(0),
    len: usize = 0,

    pub fn text(self: *const RunningSource) []const u8 {
        return self.bytes[0..self.len];
    }
};

pub const RunningSnapshot = struct {
    count: usize = 0,
    rows: [session_limit]RunningRow = undefined,
    sources: [session_limit]RunningSource = @splat(.{}),
};

pub const Session = struct {
    phase: std.atomic.Value(u32) = .init(@backingInt(Phase.idle)),
    working_set: std.atomic.Value(usize) = .init(0),
    private_bytes: std.atomic.Value(usize) = .init(0),
    owned: std.atomic.Value(usize) = .init(0),
    ready: std.atomic.Value(usize) = .init(0),
    denied: std.atomic.Value(usize) = .init(0),
    last_rejection: std.atomic.Value(u32) = .init(@backingInt(Rejection.none)),
    pending_start: std.atomic.Value(bool) = .init(false),
    start_asset: std.atomic.Value(u64) = .init(builtin_asset_id),
    pending_stop: std.atomic.Value(u64) = .init(0),
    stopping_id: std.atomic.Value(u64) = .init(0),
    snapshot_lock: std.atomic.Value(bool) = .init(false),
    snapshot: RunningSnapshot = .{},

    pub fn set(self: *Session, phase: Phase) void {
        self.phase.store(@backingInt(phase), .release);
    }

    pub fn canStart(self: *const Session) bool {
        return self.phase.load(.acquire) == @backingInt(Phase.running) and
            self.owned.load(.acquire) < session_limit and !self.pending_start.load(.acquire) and
            self.pending_stop.load(.acquire) == 0 and self.stopping_id.load(.acquire) == 0;
    }

    // Called only by the UI producer. A duplicate request is not queued.
    // Worker revalidates native admission before each actual launch.
    pub fn requestStart(self: *Session) bool {
        return self.requestAsset(builtin_asset_id);
    }

    // Single UI producer, worker reads only after pending_start publishes.
    pub fn requestAsset(self: *Session, asset_id: u64) bool {
        if (asset_id == 0 or !self.canStart()) return false;
        self.start_asset.store(asset_id, .monotonic);
        self.pending_start.store(true, .release);
        return true;
    }

    pub fn requestStop(self: *Session, id: u64) bool {
        if (id == 0 or self.phase.load(.acquire) != @backingInt(Phase.running) or
            self.pending_start.load(.acquire) or self.stopping_id.load(.acquire) != 0) return false;
        return self.pending_stop.cmpxchgStrong(0, id, .acq_rel, .acquire) == null;
    }

    // Neither side waits for the other. Skip a busy publication/read;
    // the next tick retries. All non-atomic row fields are lock-protected.
    pub fn publishRows(self: *Session, rows: []const RunningRow) void {
        if (self.snapshot_lock.swap(true, .acquire)) return;
        defer self.snapshot_lock.store(false, .release);
        self.snapshot.count = @min(rows.len, session_limit);
        @memcpy(self.snapshot.rows[0..self.snapshot.count], rows[0..self.snapshot.count]);
        self.snapshot.sources = @splat(.{});
    }

    fn publishNamedRows(self: *Session, rows: []const RunningRow, sources: *const [session_limit]RunningSource) void {
        if (self.snapshot_lock.swap(true, .acquire)) return;
        defer self.snapshot_lock.store(false, .release);
        self.snapshot.count = @min(rows.len, session_limit);
        @memcpy(self.snapshot.rows[0..self.snapshot.count], rows[0..self.snapshot.count]);
        self.snapshot.sources = @splat(.{});
        for (rows[0..self.snapshot.count], 0..) |row, n| {
            for (sources) |source| {
                if (source.id == row.id) {
                    self.snapshot.sources[n] = source;
                    break;
                }
            }
        }
    }

    pub fn copyRows(self: *Session, out: *RunningSnapshot) void {
        if (self.snapshot_lock.swap(true, .acquire)) return;
        defer self.snapshot_lock.store(false, .release);
        out.count = self.snapshot.count;
        @memcpy(out.rows[0..out.count], self.snapshot.rows[0..out.count]);
        out.sources = self.snapshot.sources;
    }

    pub fn reject(self: *Session, reason: Rejection) void {
        self.last_rejection.store(@backingInt(reason), .release);
        _ = self.denied.fetchAdd(1, .monotonic);
    }

    pub fn reset(self: *Session) void {
        self.pending_stop.store(0, .release);
        self.stopping_id.store(0, .release);
        self.publishRows(&.{});
        self.pending_start.store(false, .release);
        self.start_asset.store(builtin_asset_id, .release);
        self.owned.store(0, .release);
        self.ready.store(0, .release);
        self.denied.store(0, .release);
        self.last_rejection.store(@backingInt(Rejection.none), .release);
        self.working_set.store(0, .release);
        self.private_bytes.store(0, .release);
        self.set(.idle);
    }
};

pub fn runBuiltin(session: *Session, runtime_hex: []const u8, helper_hex: []const u8, canceled: *const fn (?*anyopaque) callconv(.c) u32, context: ?*anyopaque) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(runtime_hex);
    const helper_digest = try parseDigest(helper_hex);
    var path: [1024]u16 = undefined;
    const root = try packageRoot(&path);
    const suffix = std.unicode.wtf8ToWtf16LeStringLiteral("\\pulse-pet-demo.exe");
    if (root.len + suffix.len >= path.len) return error.ModulePathUnavailable;
    // Use separate storage because owner.open still needs the root terminator.
    var helper: [1024]u16 = undefined;
    @memcpy(helper[0..root.len], root);
    @memcpy(helper[root.len..][0..suffix.len], suffix);
    const len = root.len + suffix.len;
    helper[len] = 0;
    const owner = try std.heap.page_allocator.create(runtime.Owner);
    owner.* = .{};
    defer session.reset();
    const outcome = runOwned(owner, session, root, digest, helper[0..len :0], &helper_digest, canceled, context);
    // The loop can return early from any native API. Always attempt normal
    // drain before close or emergency abandonment, even after such errors.
    const drained = drainOwned(owner, session);
    const closed = owner.close();
    if (closed) |_| {
        std.heap.page_allocator.destroy(owner);
    } else |_| {
        owner.abandon() catch return error.CleanupFailed;
        std.heap.page_allocator.destroy(owner);
        return error.UnconfirmedShutdown;
    }
    try drained;
    return outcome;
}

fn launchAsset(owner: *runtime.Owner, helper: [:0]const u16, digest: *const [32]u8, asset_id: u64, sources: *[session_limit]RunningSource) !group.Start {
    var free: ?*RunningSource = null;
    for (sources) |*source| {
        if (source.id == 0) {
            free = source;
            break;
        }
    }
    const slot = free orelse return error.Capacity;
    var name: RunningSource = .{};
    const started = if (asset_id == builtin_asset_id) blk: {
        const builtin_name = "内置桌宠";
        @memcpy(name.bytes[0..builtin_name.len], builtin_name);
        name.len = builtin_name.len;
        break :blk try owner.group.startBuiltin(helper, digest);
    } else blk: {
        const approved = try openPrivateDefault(owner);
        const index = try std.heap.page_allocator.create(inventory.Inventory);
        defer std.heap.page_allocator.destroy(index);
        index.* = .{};
        try library.readManagedIndex(approved, index);
        const record = try index.get(asset_id);
        @memcpy(name.bytes[0..record.len], record.sourceId());
        name.len = record.len;
        break :blk try owner.group.startManagedWide(helper, digest, index, approved, asset_id);
    };
    name.id = started.id;
    slot.* = name;
    return started;
}

fn runOwned(owner: *runtime.Owner, session: *Session, root: [:0]const u16, digest: [32]u8, helper: [:0]const u16, helper_digest: *const [32]u8, canceled: *const fn (?*anyopaque) callconv(.c) u32, context: ?*anyopaque) !void {
    if (canceled(context) != 0) return;
    session.set(.starting);
    try owner.open(root, digest, session_limit, session_limit * model.child_commit_ceiling);
    if (canceled(context) != 0) return;
    var sources: [session_limit]RunningSource = @splat(.{});
    const started = try launchAsset(owner, helper, helper_digest, session.start_asset.load(.acquire), &sources);
    var failure: ?anyerror = started.failure;
    var rows: [group.max_tick_slots]group.TickResult = undefined;
    var begin = GetTickCount64();
    var stop_since: u64 = 0;
    while (failure == null and canceled(context) == 0) {
        if (session.pending_start.load(.acquire)) {
            session.set(.starting);
            if (canceled(context) == 0) {
                if (launchAsset(owner, helper, helper_digest, session.start_asset.load(.acquire), &sources)) |next| {
                    if (next.failure) |err| failure = err;
                    begin = GetTickCount64();
                } else |err| {
                    // A native cleanup failure is not an ordinary refusal.
                    if (err == error.CleanupFailed) {
                        failure = err;
                    } else {
                        session.reject(rejectionFor(err));
                    }
                }
            }
            session.pending_start.store(false, .release);
        }
        const requested = session.pending_stop.load(.acquire);
        if (requested != 0 and canceled(context) == 0) {
            // Keep admission closed before clearing the pending command.
            session.stopping_id.store(requested, .release);
            if (owner.group.stop(requested, false)) |_| {
                stop_since = GetTickCount64();
            } else |err| {
                session.stopping_id.store(0, .release);
                if (err == error.UnknownInstance) {
                    session.reject(.unknown_instance);
                } else {
                    failure = err;
                }
            }
            session.pending_stop.store(0, .release);
        }
        const stopping = session.stopping_id.load(.acquire);
        if (stopping != 0 and GetTickCount64() - stop_since >= 2_000) {
            owner.group.stop(stopping, true) catch |err| {
                if (err != error.UnknownInstance) failure = err;
            };
        }
        const count = try owner.group.tick(&rows);
        var child_failed = false;
        for (rows[0..count]) |row| {
            if (row.failure) |err| failure = err;
            if (row.exit_code) |code| {
                for (&sources) |*source| {
                    if (source.id == row.id) source.* = .{};
                }
                if (row.id == stopping) {
                    session.stopping_id.store(0, .release);
                } else if (code != 0) {
                    // Confirmed reap proves this child no longer owns a
                    // process. Do not drain unrelated healthy instances.
                    session.reject(.child_exit);
                    child_failed = true;
                }
            }
        }
        if (session.stopping_id.load(.acquire) != 0 and GetTickCount64() - stop_since >= 5_000) failure = error.UnconfirmedShutdown;
        var items: [session_limit]model.Instance = undefined;
        const owned = try owner.group.snapshot(0, &items);
        var ready: usize = 0;
        var starting: usize = 0;
        var working_set: usize = 0;
        var private_bytes: usize = 0;
        for (items[0..owned]) |item| {
            if (item.state == .running) ready += 1;
            if (item.state == .starting) starting += 1;
            if (item.metrics) |metrics| {
                working_set += metrics.working_set;
                private_bytes += metrics.private_bytes;
            }
        }
        session.publishNamedRows(items[0..owned], &sources);
        session.owned.store(owned, .release);
        session.ready.store(ready, .release);
        session.working_set.store(working_set, .release);
        session.private_bytes.store(private_bytes, .release);
        if (owned == 0) {
            if (child_failed and failure == null) failure = error.ChildExited;
            session.set(.stopping);
            break;
        }
        if (starting == 0) {
            session.set(.running);
        } else if (GetTickCount64() - begin >= 15_000) {
            failure = error.ReadinessTimeout;
        }
        if (failure == null) Sleep(100);
    }
    if (failure) |err| return err;
}

fn drainOwned(owner: *runtime.Owner, session: *Session) !void {
    session.set(.stopping);
    session.pending_start.store(false, .release);
    session.pending_stop.store(0, .release);
    if (!owner.opened) return;
    if (try owner.group.remaining() == 0) return;
    try owner.group.beginDrain(false);
    const stop = GetTickCount64();
    var rows: [group.max_tick_slots]group.TickResult = undefined;
    var failure: ?anyerror = null;
    while (try owner.group.remaining() != 0) {
        const elapsed = GetTickCount64() - stop;
        if (elapsed >= 5_000) return error.UnconfirmedShutdown;
        if (elapsed >= 2_000) try owner.group.beginDrain(true);
        const count = try owner.group.tick(&rows);
        for (rows[0..count]) |row| {
            if (row.failure) |err| failure = err;
        }
        if (try owner.group.remaining() != 0) Sleep(50);
    }
    if (failure) |err| return err;
}

test "session admits only one pending start within the pilot limit" {
    var session: Session = .{};
    try std.testing.expect(!session.requestStart());
    session.owned.store(1, .release);
    session.set(.running);
    try std.testing.expect(session.requestAsset(27));
    try std.testing.expectEqual(@as(u64, 27), session.start_asset.load(.acquire));
    try std.testing.expect(!session.requestStart());
    try std.testing.expectEqual(@as(u64, 27), session.start_asset.load(.acquire));
    session.pending_start.store(false, .release);
    session.owned.store(session_limit, .release);
    try std.testing.expect(!session.requestStart());
    session.reset();
    try std.testing.expectEqual(@as(usize, 0), session.owned.load(.acquire));
    try std.testing.expect(!session.requestStart());
}

test "running snapshot copies stable IDs and stop requests are bounded" {
    var session: Session = .{};
    const rows = [_]RunningRow{ .{ .id = 9, .asset_id = 1 }, .{ .id = 11, .asset_id = 1 } };
    session.publishRows(&rows);
    var copy: RunningSnapshot = .{};
    session.copyRows(&copy);
    try std.testing.expectEqual(@as(usize, 2), copy.count);
    try std.testing.expectEqual(@as(u64, 11), copy.rows[1].id);
    session.set(.running);
    try std.testing.expect(!session.requestStop(0));
    try std.testing.expect(session.requestStop(11));
    try std.testing.expect(!session.requestStop(9));
    try std.testing.expect(!session.canStart());
    session.reset();
    session.copyRows(&copy);
    try std.testing.expectEqual(@as(usize, 0), copy.count);
}

test "runtime rejection distinguishes native admission from launch failure" {
    for ([_]anyerror{ error.Capacity, error.StorageCapacity, error.BudgetExceeded, error.CountLimit, error.StorageLimit, error.BudgetLimit, error.SystemMemory }) |err| {
        try std.testing.expectEqual(Rejection.capacity, rejectionFor(err));
    }
    try std.testing.expectEqual(Rejection.unverified, rejectionFor(error.UnapprovedExecutable));
    try std.testing.expectEqual(Rejection.launch_failed, rejectionFor(error.ContainmentFailed));
    try std.testing.expectEqual(Rejection.launch_failed, rejectionFor(error.OsError));
}

test "session retains explicit rejection and clears it on reset" {
    var session: Session = .{};
    session.reject(rejectionFor(error.UnknownAsset));
    try std.testing.expectEqual(@as(usize, 1), session.denied.load(.acquire));
    try std.testing.expectEqual(@as(u32, @backingInt(Rejection.unknown_asset)), session.last_rejection.load(.acquire));
    session.reject(.child_exit);
    try std.testing.expectEqual(@as(usize, 2), session.denied.load(.acquire));
    session.reset();
    try std.testing.expectEqual(@as(u32, @backingInt(Rejection.none)), session.last_rejection.load(.acquire));
}

test "runtime approval requires exactly one SHA-256 hex digest" {
    try std.testing.expectError(error.InvalidRuntimeDigest, parseDigest(""));
    try std.testing.expectError(error.InvalidRuntimeDigest, parseDigest("zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"));
    const digest = try parseDigest("0101010101010101010101010101010101010101010101010101010101010101");
    try std.testing.expectEqual(@as(u8, 1), digest[31]);
}

test "removal request binds selected identity and requires matching diagnostic state" {
    var row: library.Row = .{ .id = 1, .source = @splat(0), .len = 3, .paired = true, .digest = @splat(7), .secondary = @splat(9) };
    @memcpy(row.source[0..3], "cat");
    var snapshot: RecoverySnapshot = .{};
    try std.testing.expectError(error.RecoveryRequired, RemovalRequest.init(&row, &snapshot, .quarantine));
    snapshot.count = 1;
    snapshot.details[0] = .{ .id = 1, .state = .normal };
    const request = try RemovalRequest.init(&row, &snapshot, .quarantine);
    try std.testing.expectError(error.RecoveryRequired, RemovalRequest.init(&row, &snapshot, .restore_interrupted));
    snapshot.details[0].state = .interrupted_removal;
    _ = try RemovalRequest.init(&row, &snapshot, .restore_interrupted);
    row.digest = @splat(8);
    try std.testing.expectEqual(@as(u8, 7), request.expected.digest.?[0]);
    try std.testing.expectEqual(@as(u8, 9), request.expected.secondary.?[0]);
    row.paired = false;
    try std.testing.expectError(error.NeedsRevalidation, RemovalRequest.init(&row, &snapshot, .restore_interrupted));
}

test "cleanup request copies receipt and refuses unmeasured or blocked entries" {
    var record = try inventory.Record.init(7, "cat");
    record.digest = @splat(1);
    record.secondary = @splat(2);
    const value: CleanupReceipt = .{ .record = record, .volume = 4, .file_index = 5 };
    var detail: QuarantineDetail = .{ .id = 7, .state = .unregistered_retained, .receipt_state = .matched_identity, .cleanup_receipt = value };
    try std.testing.expectError(error.RecoveryRequired, RemovalRequest.initCleanup(&detail));
    detail.logical_bytes = 1024;
    const request = try RemovalRequest.initCleanup(&detail);
    detail.cleanup_receipt = null;
    try std.testing.expectEqualDeep(value, request.cleanup.?);
    try std.testing.expectError(error.MissingReceipt, RemovalRequest.initCleanup(&detail));
    detail.receipt_state = .cleanup_started;
    try std.testing.expectError(error.RecoveryRequired, RemovalRequest.initCleanup(&detail));
}

test "running source labels follow stable instance IDs across row reorder" {
    var session: Session = .{};
    var sources: [session_limit]RunningSource = @splat(.{});
    sources[0] = .{ .id = 9, .len = 3 };
    @memcpy(sources[0].bytes[0..3], "cat");
    sources[1] = .{ .id = 11, .len = 3 };
    @memcpy(sources[1].bytes[0..3], "dog");
    const rows = [_]RunningRow{ .{ .id = 11, .asset_id = 2 }, .{ .id = 9, .asset_id = 1 } };
    session.publishNamedRows(&rows, &sources);
    var copy: RunningSnapshot = .{};
    session.copyRows(&copy);
    try std.testing.expectEqualStrings("dog", copy.sources[0].text());
    try std.testing.expectEqualStrings("cat", copy.sources[1].text());
    session.publishNamedRows(rows[0..1], &sources);
    session.copyRows(&copy);
    try std.testing.expectEqual(@as(usize, 1), copy.count);
    try std.testing.expectEqual(@as(u64, 0), copy.sources[1].id);
}
