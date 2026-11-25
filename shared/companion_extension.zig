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
const history = @import("companion/pet_history.zig");
const local_import = @import("companion_local_import.zig");
const market_host = @import("companion_market_host.zig");
const process = @import("pulse_process");

pub const Snapshot = library.Snapshot;
const catalog = @import("companion/pet_catalog.zig");
pub const Profile = catalog.Profile;
pub const LaunchProfile = catalog.LaunchProfile;
pub const PreferenceAction = enum { toggle_favorite, add_tag, remove_tag, save_default_profile, save_alternate_profile, reset_default_profile, clear_alternate_profile };
pub const PreferenceEdit = struct {
    row: library.Row,
    action: PreferenceAction,
    tag: [64]u8 = @splat(0),
    tag_len: usize = 0,
    profile: Profile = .{},
};
pub const readFilteredDefault = library.readFilteredDefault;

extern "kernel32" fn GetModuleHandleExW(u32, *const anyopaque, *usize) callconv(.winapi) c_int;
extern "kernel32" fn GetModuleFileNameW(usize, [*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetSystemTimeAsFileTime(*[2]u32) callconv(.winapi) void;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
extern "kernel32" fn GetWindowsDirectoryW([*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?*anyopaque, u32) callconv(.winapi) usize;
extern "kernel32" fn GetProcAddress(usize, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(usize) callconv(.winapi) c_int;

pub const market_gallery_url = "https://openpets.dev/gallery";
const ShellOpen = *const fn (?*anyopaque, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, c_int) callconv(.winapi) usize;
const ComInit = *const fn (?*anyopaque, u32) callconv(.winapi) i32;
const ComUninit = *const fn () callconv(.winapi) void;

fn invokeMarketGallery(open: ShellOpen) !void {
    const operation = std.unicode.wtf8ToWtf16LeStringLiteral("open");
    const url = std.unicode.wtf8ToWtf16LeStringLiteral(market_gallery_url);
    // No command line, user-provided URL, working directory or parameters.
    // Values <= 32 are ShellExecuteW errors; success is handoff, not page load.
    if (open(null, operation, url, null, null, 1) <= 32) return error.BrowserOpenFailed;
}

/// Explicit UI action only, on the host-owned background task. The default
/// browser is an OS-managed application, not an owned companion child.
pub fn openMarketGallery() !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    // Resolve only Windows system DLLs, not the current working directory
    // or plugin package. Shell extensions can require COM initialization.
    const system32 = 0x800;
    const ole = LoadLibraryExW(std.unicode.wtf8ToWtf16LeStringLiteral("ole32.dll"), null, system32);
    if (ole == 0) return error.BrowserUnavailable;
    defer _ = FreeLibrary(ole);
    const initialize: ComInit = @ptrCast(GetProcAddress(ole, "CoInitializeEx") orelse return error.BrowserUnavailable);
    const uninitialize: ComUninit = @ptrCast(GetProcAddress(ole, "CoUninitialize") orelse return error.BrowserUnavailable);
    if (initialize(null, 2) < 0) return error.BrowserUnavailable;
    defer uninitialize();
    const shell = LoadLibraryExW(std.unicode.wtf8ToWtf16LeStringLiteral("shell32.dll"), null, system32);
    if (shell == 0) return error.BrowserUnavailable;
    defer _ = FreeLibrary(shell);
    const open: ShellOpen = @ptrCast(GetProcAddress(shell, "ShellExecuteW") orelse return error.BrowserUnavailable);
    try invokeMarketGallery(open);
}

test "gallery fallback uses only the approved fixed HTTPS URL and reports launch refusal" {
    const Fixture = struct {
        fn accept(window: ?*anyopaque, verb: [*:0]const u16, url: [*:0]const u16, args: ?[*:0]const u16, directory: ?[*:0]const u16, show: c_int) callconv(.winapi) usize {
            const valid = window == null and args == null and directory == null and show == 1 and
                std.mem.eql(u16, std.mem.span(verb), std.unicode.wtf8ToWtf16LeStringLiteral("open")) and
                std.mem.eql(u16, std.mem.span(url), std.unicode.wtf8ToWtf16LeStringLiteral(market_gallery_url));
            return if (valid) 33 else 31;
        }

        fn refuse(_: ?*anyopaque, _: [*:0]const u16, _: [*:0]const u16, _: ?[*:0]const u16, _: ?[*:0]const u16, _: c_int) callconv(.winapi) usize {
            return 32;
        }
    };
    try invokeMarketGallery(Fixture.accept);
    try std.testing.expectError(error.BrowserOpenFailed, invokeMarketGallery(Fixture.refuse));
}

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
        .save_default_profile => .{ .default_profile = edit.profile },
        .save_alternate_profile => .{ .alternate_profile = edit.profile },
        .reset_default_profile => .{ .default_profile = .{} },
        .clear_alternate_profile => .{ .alternate_profile = null },
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
pub const MarketFilters = market_host.Filters;
pub const MarketDetail = market_host.Detail;
pub const MarketBatch = market_host.Batch;
pub const MarketJobState = market_host.JobState;
pub const MarketQueueCapacity = market_host.queue_capacity;

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

pub const AssetDetailRequest = inventory.Record;
pub const AssetDetail = local_import.Detail;

pub fn describeDefault(runtime_hex: []const u8, helper_hex: []const u8, request: AssetDetailRequest, cancel: ImportCancel) !AssetDetail {
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
        owner.open(root, digest, 1, 128 * 1024 * 1024) catch |err| break :blk @as(anyerror!AssetDetail, err);
        const private = openPrivateDefault(owner) catch |err| break :blk @as(anyerror!AssetDetail, err);
        break :blk local_import.describeManaged(threaded.io(), owner, private, exe[0..len :0], helper_digest, request, cancel);
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
pub const session_limit: usize = model.max_instances;
pub const commit_per_instance_mib: usize = model.child_commit_ceiling / (1024 * 1024);

pub const RuntimeLimits = struct {
    instances: usize = 8,
    commit_mib: usize = 1024,

    pub fn validate(self: RuntimeLimits) !void {
        if (self.instances == 0 or self.instances > session_limit or self.commit_mib < commit_per_instance_mib or self.commit_mib > session_limit * commit_per_instance_mib) return error.InvalidLimits;
    }

    pub fn effective(self: RuntimeLimits) usize {
        return @min(self.instances, self.commit_mib / commit_per_instance_mib);
    }

    pub fn parse(count: []const u8, memory: []const u8) !RuntimeLimits {
        for (count) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidLimits;
        for (memory) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidLimits;
        const limits: RuntimeLimits = .{
            .instances = std.fmt.parseInt(usize, count, 10) catch return error.InvalidLimits,
            .commit_mib = std.fmt.parseInt(usize, memory, 10) catch return error.InvalidLimits,
        };
        try limits.validate();
        return limits;
    }

    pub fn decode(value: []const u8) !RuntimeLimits {
        const split = std.mem.indexOfScalar(u8, value, ':') orelse return error.InvalidLimits;
        return parse(value[0..split], value[split + 1 ..]);
    }
};

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

pub const LaunchEntry = struct {
    asset_id: u64 = 0,
    count: usize = 0,
    profile: u32 = 0,
};

pub const RuntimePolicy = struct {
    automatic: bool = false,
    hide_on_minimize: bool = false,
    retain_history: bool = false,
    capture_crashes: bool = false,
    batch_size: usize = 4,
    interval_ms: u64 = 500,
    grace_ms: u64 = 2000,
    timeout_ms: u64 = 10000,
    entries: [8]LaunchEntry = @splat(.{}),
    count: usize = 0,

    fn number(comptime T: type, value: []const u8) !T {
        if (value.len == 0) return error.InvalidPolicy;
        for (value) |ch| if (!std.ascii.isDigit(ch)) return error.InvalidPolicy;
        return std.fmt.parseInt(T, value, 10) catch error.InvalidPolicy;
    }

    pub fn effective(self: *const RuntimePolicy, limits: RuntimeLimits) usize {
        if (!self.capture_crashes) return limits.effective();
        return @min(@min(limits.instances, 4), limits.commit_mib / (2 * commit_per_instance_mib));
    }

    pub fn total(self: *const RuntimePolicy) usize {
        var result: usize = 0;
        for (self.entries[0..self.count]) |entry| result += entry.count;
        return result;
    }

    pub fn at(self: *const RuntimePolicy, index: usize) ?LaunchEntry {
        var remaining = index;
        for (self.entries[0..self.count]) |entry| {
            if (remaining < entry.count) return entry;
            remaining -= entry.count;
        }
        return null;
    }

    pub fn decode(value: []const u8) !RuntimePolicy {
        if (value.len > 512) return error.InvalidPolicy;
        var sections = std.mem.splitScalar(u8, value, ';');
        var fields = std.mem.splitScalar(u8, sections.next() orelse return error.InvalidPolicy, ':');
        const automatic = try number(u8, fields.next() orelse return error.InvalidPolicy);
        var policy: RuntimePolicy = .{
            .automatic = automatic == 1,
            .batch_size = try number(usize, fields.next() orelse return error.InvalidPolicy),
            .interval_ms = try number(u64, fields.next() orelse return error.InvalidPolicy),
            .grace_ms = try number(u64, fields.next() orelse return error.InvalidPolicy),
            .timeout_ms = try number(u64, fields.next() orelse return error.InvalidPolicy),
        };
        if (fields.next()) |flag| {
            const value_flag = try number(u8, flag);
            if (value_flag > 1) return error.InvalidPolicy;
            policy.hide_on_minimize = value_flag == 1;
        }
        if (fields.next()) |flag| {
            const value_flag = try number(u8, flag);
            if (value_flag > 1) return error.InvalidPolicy;
            policy.retain_history = value_flag == 1;
        }
        if (fields.next()) |flag| {
            const value_flag = try number(u8, flag);
            if (value_flag > 1) return error.InvalidPolicy;
            policy.capture_crashes = value_flag == 1;
        }
        if (fields.next() != null or automatic > 1 or policy.batch_size == 0 or policy.batch_size > 16 or policy.interval_ms < 100 or policy.interval_ms > 3000 or policy.grace_ms > 5000 or policy.timeout_ms > 10000 or policy.timeout_ms < policy.grace_ms + 2000) return error.InvalidPolicy;
        while (sections.next()) |section| {
            if (policy.count == policy.entries.len) return error.InvalidPolicy;
            var row = std.mem.splitScalar(u8, section, ':');
            const key = row.next() orelse return error.InvalidPolicy;
            const id = if (std.mem.eql(u8, key, "builtin")) builtin_asset_id else try number(u64, key);
            const count = try number(usize, row.next() orelse return error.InvalidPolicy);
            const profile = try number(u32, row.next() orelse return error.InvalidPolicy);
            if (id == 0 or count == 0 or count > session_limit or profile > 1 or (id == builtin_asset_id and profile != 0) or row.next() != null) return error.InvalidPolicy;
            for (policy.entries[0..policy.count]) |prior| if (prior.asset_id == id) return error.InvalidPolicy;
            policy.entries[policy.count] = .{ .asset_id = id, .count = count, .profile = profile };
            policy.count += 1;
            if (policy.total() > session_limit) return error.InvalidPolicy;
        }
        if (policy.automatic and policy.count == 0) return error.InvalidPolicy;
        return policy;
    }

    pub fn encode(self: *const RuntimePolicy, buffer: []u8) ![]const u8 {
        const header = try std.fmt.bufPrint(buffer, "{d}:{d}:{d}:{d}:{d}", .{ @intFromBool(self.automatic), self.batch_size, self.interval_ms, self.grace_ms, self.timeout_ms });
        var len = header.len;
        if (self.hide_on_minimize or self.retain_history or self.capture_crashes) {
            const suffix = try std.fmt.bufPrint(buffer[len..], ":{d}", .{@intFromBool(self.hide_on_minimize)});
            len += suffix.len;
        }
        if (self.retain_history or self.capture_crashes) {
            const suffix = try std.fmt.bufPrint(buffer[len..], ":{d}", .{@intFromBool(self.retain_history)});
            len += suffix.len;
        }
        if (self.capture_crashes) {
            const suffix = try std.fmt.bufPrint(buffer[len..], ":1", .{});
            len += suffix.len;
        }
        for (self.entries[0..self.count]) |entry| {
            const suffix = if (entry.asset_id == builtin_asset_id)
                try std.fmt.bufPrint(buffer[len..], ";builtin:{d}:{d}", .{ entry.count, entry.profile })
            else
                try std.fmt.bufPrint(buffer[len..], ";{d}:{d}:{d}", .{ entry.asset_id, entry.count, entry.profile });
            len += suffix.len;
        }
        return buffer[0..len];
    }
};

pub const Visibility = enum { unknown, visible, hidden, pending_show, pending_hide };
pub const HostWindowState = enum(u32) { unknown, normal, minimized };

// Read-only fallback for the exact main-window class verified in pinned
// upstream src/app/single_instance_coordinator.cpp. The class is not a
// stable SDK contract: absence, API failure or an incomplete enumeration
// returns unknown. No HWND survives the synchronous observation.
const WindowProbe = struct {
    const Enumerate = *const fn (*const fn (usize, isize) callconv(.winapi) c_int, isize) callconv(.winapi) c_int;
    const Process = *const fn (usize, *u32) callconv(.winapi) u32;
    const ClassName = *const fn (usize, [*]u16, c_int) callconv(.winapi) c_int;
    const Predicate = *const fn (usize) callconv(.winapi) c_int;
    module: usize,
    enumerate: Enumerate,
    process: Process,
    class_name: ClassName,
    visible: Predicate,
    iconic: Predicate,

    fn open() !WindowProbe {
        const name = std.unicode.wtf8ToWtf16LeStringLiteral("user32.dll");
        const module = LoadLibraryExW(name, null, 0x800);
        if (module == 0) return error.WindowProbeUnavailable;
        errdefer _ = FreeLibrary(module);
        return .{
            .module = module,
            .enumerate = @ptrCast(GetProcAddress(module, "EnumWindows") orelse return error.WindowProbeUnavailable),
            .process = @ptrCast(GetProcAddress(module, "GetWindowThreadProcessId") orelse return error.WindowProbeUnavailable),
            .class_name = @ptrCast(GetProcAddress(module, "GetClassNameW") orelse return error.WindowProbeUnavailable),
            .visible = @ptrCast(GetProcAddress(module, "IsWindowVisible") orelse return error.WindowProbeUnavailable),
            .iconic = @ptrCast(GetProcAddress(module, "IsIconic") orelse return error.WindowProbeUnavailable),
        };
    }

    fn close(self: WindowProbe) void {
        _ = FreeLibrary(self.module);
    }

    const Observation = struct {
        probe: *const WindowProbe,
        pid: u32,
        scanned: usize = 0,
        windows: usize = 0,
        normal: usize = 0,
    };

    fn visit(window: usize, context: isize) callconv(.winapi) c_int {
        const observation: *Observation = @ptrFromInt(@as(usize, @bitCast(context)));
        observation.scanned += 1;
        if (observation.scanned > 4096) return 0;
        var pid: u32 = 0;
        if (observation.probe.process(window, &pid) == 0 or pid != observation.pid) return 1;
        var name: [128]u16 = undefined;
        const len = observation.probe.class_name(window, &name, name.len);
        const main = std.unicode.wtf8ToWtf16LeStringLiteral("PulseMainWindow");
        if (len <= 0 or len >= name.len - 1) return 0;
        if (@as(usize, @intCast(len)) != main.len or !std.mem.eql(u16, name[0..@intCast(len)], main)) return 1;
        if (observation.probe.visible(window) == 0) return 1;
        observation.windows += 1;
        if (observation.probe.iconic(window) == 0) observation.normal += 1;
        return 1;
    }

    fn observe(self: *const WindowProbe) HostWindowState {
        var observation: Observation = .{ .probe = self, .pid = GetCurrentProcessId() };
        if (self.enumerate(visit, @bitCast(@intFromPtr(&observation))) == 0) return .unknown;
        return classifyWindows(observation.windows, observation.normal);
    }
};

fn classifyWindows(windows: usize, normal: usize) HostWindowState {
    if (windows == 0 or normal > windows) return .unknown;
    return if (normal == 0) .minimized else .normal;
}

const AutoVisibility = struct {
    hidden_by_policy: bool = false,
    manual_override: bool = false,

    fn desired(self: *AutoVisibility, state: HostWindowState, current: Visibility, manual: ?bool) ?bool {
        if (state != .minimized) self.manual_override = false;
        if (manual) |show| {
            self.hidden_by_policy = false;
            self.manual_override = state == .minimized;
            return show;
        }
        if (state == .minimized) {
            if (current == .visible and !self.manual_override) return false;
        } else if (self.hidden_by_policy and current == .hidden) {
            // Unknown observation restores only our own acknowledged hide,
            // preventing a changed host class or tray state from stranding pets.
            return true;
        }
        return null;
    }

    fn accepted(self: *AutoVisibility, show: bool, manual: bool) void {
        if (!manual) self.hidden_by_policy = !show;
    }
};
pub const RunningRow = model.Instance;
pub const RunningSource = struct {
    id: u64 = 0,
    profile: Profile = .{},
    visibility: Visibility = .unknown,
    visibility_since: u64 = 0,
    visibility_failed: bool = false,
    auto_visibility: AutoVisibility = .{},
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
    // Set by the UI before admitting a new worker; immutable during that session.
    limits: RuntimeLimits = .{},
    policy: RuntimePolicy = .{},
    planned: bool = false,
    plan_active: std.atomic.Value(bool) = .init(false),
    plan_cancel: std.atomic.Value(bool) = .init(false),
    plan_attempted: std.atomic.Value(usize) = .init(0),
    plan_launched: std.atomic.Value(usize) = .init(0),
    exits: std.atomic.Value(usize) = .init(0),
    abnormal_exits: std.atomic.Value(usize) = .init(0),
    last_exit: std.atomic.Value(u32) = .init(0),
    history_status: std.atomic.Value(u32) = .init(0),
    dumps_saved: std.atomic.Value(u32) = .init(0),
    dumps_failed: std.atomic.Value(u32) = .init(0),
    dump_stats_available: std.atomic.Value(bool) = .init(false),
    visibility_busy: std.atomic.Value(bool) = .init(false),
    visibility_id: std.atomic.Value(u64) = .init(0),
    visibility_show: std.atomic.Value(bool) = .init(true),
    host_window_state: std.atomic.Value(u32) = .init(@backingInt(HostWindowState.unknown)),
    phase: std.atomic.Value(u32) = .init(@backingInt(Phase.idle)),
    working_set: std.atomic.Value(usize) = .init(0),
    private_bytes: std.atomic.Value(usize) = .init(0),
    owned: std.atomic.Value(usize) = .init(0),
    ready: std.atomic.Value(usize) = .init(0),
    denied: std.atomic.Value(usize) = .init(0),
    last_rejection: std.atomic.Value(u32) = .init(@backingInt(Rejection.none)),
    pending_start: std.atomic.Value(bool) = .init(false),
    start_asset: std.atomic.Value(u64) = .init(builtin_asset_id),
    start_profile: std.atomic.Value(u32) = .init(0),
    pending_stop: std.atomic.Value(u64) = .init(0),
    stopping_id: std.atomic.Value(u64) = .init(0),
    snapshot_lock: std.atomic.Value(bool) = .init(false),
    snapshot: RunningSnapshot = .{},

    pub fn set(self: *Session, phase: Phase) void {
        self.phase.store(@backingInt(phase), .release);
    }

    pub fn canStart(self: *const Session) bool {
        return self.phase.load(.acquire) == @backingInt(Phase.running) and
            self.owned.load(.acquire) < self.policy.effective(self.limits) and !self.plan_active.load(.acquire) and !self.pending_start.load(.acquire) and
            self.pending_stop.load(.acquire) == 0 and self.stopping_id.load(.acquire) == 0;
    }

    // Called only by the UI producer. A duplicate request is not queued.
    // Worker revalidates native admission before each actual launch.
    pub fn requestStart(self: *Session) bool {
        return self.requestAsset(builtin_asset_id);
    }

    // Single UI producer, worker reads only after pending_start publishes.
    pub fn requestAsset(self: *Session, asset_id: u64) bool {
        return self.requestAssetProfile(asset_id, .asset_default);
    }

    pub fn requestAssetProfile(self: *Session, asset_id: u64, choice: LaunchProfile) bool {
        if (asset_id == 0 or !self.canStart()) return false;
        const packed_profile = choice.pack() catch return false;
        self.start_profile.store(packed_profile, .monotonic);
        self.start_asset.store(asset_id, .monotonic);
        self.pending_start.store(true, .release);
        return true;
    }

    pub fn requestVisibility(self: *Session, id: u64, show: bool) bool {
        if (id == 0 or self.phase.load(.acquire) != @backingInt(Phase.running) or self.visibility_busy.load(.acquire) or self.visibility_id.load(.acquire) != 0 or self.pending_start.load(.acquire) or self.pending_stop.load(.acquire) != 0 or self.stopping_id.load(.acquire) != 0) return false;
        self.visibility_show.store(show, .monotonic);
        self.visibility_id.store(id, .release);
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
        // Bounded open-addressed lookup: one build per publication, rather
        // than scanning 1024 labels for each row. Zero denotes an empty slot.
        const table_size = session_limit * 2;
        var lookup: [table_size]u16 = @splat(0);
        for (sources, 0..) |source, n| {
            if (source.id == 0) continue;
            var slot: usize = @intCast(source.id % table_size);
            while (lookup[slot] != 0) slot = (slot + 1) % table_size;
            lookup[slot] = @intCast(n + 1);
        }
        for (rows[0..self.snapshot.count], 0..) |row, n| {
            var slot: usize = @intCast(row.id % table_size);
            while (lookup[slot] != 0) : (slot = (slot + 1) % table_size) {
                const source = &sources[lookup[slot] - 1];
                if (source.id == row.id) {
                    self.snapshot.sources[n] = source.*;
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
        self.plan_active.store(false, .release);
        self.plan_cancel.store(false, .release);
        self.plan_attempted.store(0, .release);
        self.plan_launched.store(0, .release);
        self.exits.store(0, .release);
        self.abnormal_exits.store(0, .release);
        self.last_exit.store(0, .release);
        self.history_status.store(0, .release);
        self.dumps_saved.store(0, .release);
        self.dumps_failed.store(0, .release);
        self.dump_stats_available.store(false, .release);
        self.denied.store(0, .release);
        self.last_rejection.store(@backingInt(Rejection.none), .release);
        self.visibility_busy.store(false, .release);
        self.visibility_id.store(0, .release);
        self.clearLive();
    }

    fn clearLive(self: *Session) void {
        self.host_window_state.store(@backingInt(HostWindowState.unknown), .release);
        self.plan_active.store(false, .release);
        self.visibility_busy.store(false, .release);
        self.visibility_id.store(0, .release);
        self.pending_stop.store(0, .release);
        self.stopping_id.store(0, .release);
        self.publishRows(&.{});
        self.pending_start.store(false, .release);
        self.start_asset.store(builtin_asset_id, .release);
        self.start_profile.store(0, .release);
        self.owned.store(0, .release);
        self.ready.store(0, .release);
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
    defer session.clearLive();
    const started_at = GetTickCount64();
    const outcome = runOwned(owner, session, root, digest, helper[0..len :0], &helper_digest, canceled, context);
    // The loop can return early from any native API. Always attempt normal
    // drain before close or emergency abandonment, even after such errors.
    const drained = drainOwned(owner, session);
    if (owner.opened and session.policy.capture_crashes) {
        if (drained) |_| {} else |_| session.dump_stats_available.store(false, .release);
        if (owner.crashStats()) |stats| {
            session.dumps_saved.store(stats[0], .release);
            session.dumps_failed.store(stats[1], .release);
        } else |_| {
            session.dump_stats_available.store(false, .release);
        }
    }
    // History is best effort and independent of the runtime outcome.
    // Never access the private store while children may still be alive.
    if (owner.opened and session.policy.retain_history) {
        if (drained) |_| {
            const failed = if (outcome) |_| false else |_| true;
            appendSessionHistory(owner, session, GetTickCount64() - started_at, failed) catch {
                session.history_status.store(2, .release);
            };
        } else |_| {
            session.history_status.store(2, .release);
        }
    }
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

fn unixSeconds() !u64 {
    var value: [2]u32 = undefined;
    GetSystemTimeAsFileTime(&value);
    const seconds = ((@as(u64, value[1]) << 32) | value[0]) / 10_000_000;
    if (seconds <= 11_644_473_600) return error.InvalidClock;
    return seconds - 11_644_473_600;
}

fn appendSessionHistory(owner: *runtime.Owner, session: *Session, elapsed_ms: u64, failed: bool) !void {
    _ = try openPrivateDefault(owner);
    var buffer: [history.max_bytes]u8 = undefined;
    var log: history.History = .{};
    if (try owner.readHistory(&buffer)) |len| log = try history.History.decode(buffer[0..len]);
    const now = try unixSeconds();
    try log.append(.{
        .stamp = now,
        .elapsed_ms = elapsed_ms,
        .attempted = session.plan_attempted.load(.acquire),
        .launched = session.plan_launched.load(.acquire),
        .exits = session.exits.load(.acquire),
        .abnormal = session.abnormal_exits.load(.acquire),
        .denied = session.denied.load(.acquire),
        .last_exit = session.last_exit.load(.acquire),
        .failed = @intFromBool(failed),
    });
    try owner.writeHistory(try log.encode(&buffer));
    session.history_status.store(1, .release);
}

// Read an existing typed history through an independent verified owner.
// Never auto-create a dump or scan arbitrary paths; callers can report
// unavailable if the private lease is held by a running session.
pub fn appendDiagnosticHistory(runtime_hex: []const u8, output: []u8) !usize {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const digest = try parseDigest(runtime_hex);
    var path: [1024]u16 = undefined;
    const root = try packageRoot(&path);
    const owner = try std.heap.page_allocator.create(runtime.Owner);
    owner.* = .{};
    const outcome = blk: {
        owner.open(root, digest, 1, 128 * 1024 * 1024) catch |err| break :blk @as(anyerror!usize, err);
        _ = openPrivateDefault(owner) catch |err| break :blk @as(anyerror!usize, err);
        var buffer: [history.max_bytes]u8 = undefined;
        const len = (owner.readHistory(&buffer) catch |err| break :blk @as(anyerror!usize, err)) orelse break :blk @as(anyerror!usize, 0);
        const log = history.History.decode(buffer[0..len]) catch |err| break :blk @as(anyerror!usize, err);
        break :blk log.format(output);
    };
    owner.close() catch return error.CleanupFailed;
    std.heap.page_allocator.destroy(owner);
    return outcome;
}

fn launchAsset(owner: *runtime.Owner, helper: [:0]const u16, digest: *const [32]u8, asset_id: u64, packed_profile: u32, sources: *[session_limit]RunningSource) !group.Start {
    const choice = try LaunchProfile.unpack(packed_profile);
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
        name.profile = try choice.resolve(.{}, null);
        break :blk try owner.group.startBuiltinProfile(helper, digest, name.profile);
    } else blk: {
        const approved = try openPrivateDefault(owner);
        const index = try std.heap.page_allocator.create(inventory.Inventory);
        defer std.heap.page_allocator.destroy(index);
        index.* = .{};
        try library.readManagedIndex(approved, index);
        const record = try index.get(asset_id);
        @memcpy(name.bytes[0..record.len], record.sourceId());
        name.len = record.len;
        // Resolve profiles against the current durable preferences under
        // the same lease as the asset. Invalid records are not overwritten.
        var preferences = try catalog.Entry.init(record.id, record.sourceId(), record.sourceId(), .v1);
        _ = try store.loadPreferences(owner, &preferences);
        name.profile = try choice.resolve(preferences.default_profile, preferences.alternate_profile);
        break :blk try owner.group.startManagedProfile(helper, digest, index, approved, asset_id, name.profile);
    };
    name.id = started.id;
    slot.* = name;
    return started;
}

fn runOwned(owner: *runtime.Owner, session: *Session, root: [:0]const u16, digest: [32]u8, helper: [:0]const u16, helper_digest: *const [32]u8, canceled: *const fn (?*anyopaque) callconv(.c) u32, context: ?*anyopaque) !void {
    if (canceled(context) != 0) return;
    session.set(.starting);
    try session.limits.validate();
    const capacity = session.policy.effective(session.limits);
    if (capacity == 0) return error.BudgetExceeded;
    try owner.open(root, digest, capacity, session.limits.commit_mib * 1024 * 1024);
    if (session.policy.capture_crashes) {
        try owner.configureCrash();
        session.dump_stats_available.store(true, .release);
    }
    if (canceled(context) != 0) return;
    const Buffers = struct {
        sources: [session_limit]RunningSource = @splat(.{}),
        items: [session_limit]model.Instance = undefined,
    };
    const buffers = try std.heap.page_allocator.create(Buffers);
    defer std.heap.page_allocator.destroy(buffers);
    buffers.* = .{};
    const sources = &buffers.sources;
    var plan_index: usize = 0;
    if (session.planned) {
        session.plan_active.store(true, .release);
        session.plan_attempted.store(1, .release);
    }
    const started = launchAsset(owner, helper, helper_digest, session.start_asset.load(.acquire), session.start_profile.load(.acquire), sources) catch |err| {
        session.reject(rejectionFor(err));
        return err;
    };
    if (session.planned) {
        plan_index = 1;
        if (started.failure == null) session.plan_launched.store(1, .release);
        if (plan_index >= session.policy.total()) session.plan_active.store(false, .release);
    }
    var failure: ?anyerror = started.failure;
    var rows: [group.max_tick_slots]group.TickResult = undefined;
    var begin = GetTickCount64();
    var stop_since: u64 = 0;
    var next_batch = begin + session.policy.interval_ms;
    var all_ready = false;
    const probe: ?WindowProbe = if (session.policy.hide_on_minimize) WindowProbe.open() catch null else null;
    defer if (probe) |value| value.close();
    var host_window_state: HostWindowState = .unknown;
    var next_window_poll: u64 = 0;
    while (failure == null and canceled(context) == 0) {
        if (probe) |*value| {
            const now = GetTickCount64();
            if (now >= next_window_poll) {
                host_window_state = value.observe();
                session.host_window_state.store(@backingInt(host_window_state), .release);
                next_window_poll = now + 500;
            }
        }
        if (session.plan_cancel.load(.acquire)) session.plan_active.store(false, .release);
        if (session.plan_active.load(.acquire) and all_ready and session.pending_stop.load(.acquire) == 0 and session.stopping_id.load(.acquire) == 0 and !session.visibility_busy.load(.acquire) and session.visibility_id.load(.acquire) == 0 and (plan_index % session.policy.batch_size != 0 or GetTickCount64() >= next_batch)) {
            if (session.policy.at(plan_index)) |entry| {
                session.plan_attempted.store(plan_index + 1, .release);
                if (launchAsset(owner, helper, helper_digest, entry.asset_id, entry.profile, sources)) |next| {
                    if (next.failure) |err| {
                        failure = err;
                        session.plan_active.store(false, .release);
                    } else {
                        _ = session.plan_launched.fetchAdd(1, .acq_rel);
                    }
                    plan_index += 1;
                    begin = GetTickCount64();
                    if (plan_index % session.policy.batch_size == 0) next_batch = begin + session.policy.interval_ms;
                    if (plan_index >= session.policy.total()) session.plan_active.store(false, .release);
                } else |err| {
                    session.reject(rejectionFor(err));
                    session.plan_active.store(false, .release);
                    if (err == error.CleanupFailed) failure = err;
                }
            } else session.plan_active.store(false, .release);
        }
        if (session.pending_start.load(.acquire)) {
            session.set(.starting);
            if (canceled(context) == 0) {
                if (launchAsset(owner, helper, helper_digest, session.start_asset.load(.acquire), session.start_profile.load(.acquire), sources)) |next| {
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
        if (stopping != 0 and GetTickCount64() - stop_since >= session.policy.grace_ms) {
            owner.group.stop(stopping, true) catch |err| {
                if (err != error.UnknownInstance) failure = err;
            };
        }
        const count = try owner.group.tick(&rows);
        var child_failed = false;
        for (rows[0..count]) |row| {
            if (row.failure) |err| failure = err;
            if (row.exit_code) |code| {
                _ = session.exits.fetchAdd(1, .acq_rel);
                session.last_exit.store(code, .release);
                if (code != 0 and row.id != stopping) {
                    _ = session.abnormal_exits.fetchAdd(1, .acq_rel);
                    session.plan_active.store(false, .release);
                }
                for (sources) |*source| {
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
        if (session.stopping_id.load(.acquire) != 0 and GetTickCount64() - stop_since >= session.policy.timeout_ms) failure = error.UnconfirmedShutdown;
        const items = &buffers.items;
        const owned = try owner.group.snapshot(0, items);
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
        all_ready = starting == 0 and ready != 0;
        const visibility = session.visibility_id.load(.acquire);
        const show = session.visibility_show.load(.acquire);
        if (visibility != 0) session.visibility_busy.store(true, .release);
        var visibility_pending = false;
        var defer_manual = false;
        // Index by source slot; only the worker mutates acknowledgement state.
        for (sources) |*source| {
            if (source.id == 0) continue;
            const manual = visibility != 0 and (visibility == std.math.maxInt(u64) or visibility == source.id);
            if (source.visibility == .pending_show or source.visibility == .pending_hide) {
                const acknowledged = owner.group.visibilityAck(source.id) catch false;
                if (acknowledged) {
                    source.visibility = if (source.visibility == .pending_show) .visible else .hidden;
                } else if (GetTickCount64() - source.visibility_since >= 3000) {
                    source.visibility = .unknown;
                    source.visibility_failed = true;
                    session.reject(.unknown_instance);
                } else {
                    visibility_pending = true;
                    if (manual) defer_manual = true;
                    continue;
                }
            }
            if (source.visibility_failed) continue;
            // Only a first-frame-confirmed row can reuse its ready event.
            var running = false;
            for (items[0..owned]) |item| {
                if (item.id == source.id) {
                    running = item.state == .running;
                    break;
                }
            }
            if (!running) continue;
            if (source.visibility == .unknown) source.visibility = .visible;
            const requested_visibility = source.auto_visibility.desired(host_window_state, source.visibility, if (manual) show else null) orelse continue;
            if (source.visibility == (if (requested_visibility) Visibility.visible else Visibility.hidden)) continue;
            owner.group.requestVisibility(source.id, requested_visibility) catch {
                source.visibility = .unknown;
                source.visibility_failed = true;
                session.reject(.unknown_instance);
                continue;
            };
            source.auto_visibility.accepted(requested_visibility, manual);
            source.visibility = if (requested_visibility) .pending_show else .pending_hide;
            source.visibility_since = GetTickCount64();
            visibility_pending = true;
        }
        if (visibility != 0 and !defer_manual) session.visibility_id.store(0, .release);
        session.visibility_busy.store(visibility_pending, .release);
        session.publishNamedRows(items[0..owned], sources);
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
        // Tick remains bounded to 32 native slots. Large sessions use a
        // shorter worker cadence so readiness and stop acknowledgement do
        // not wait a full multi-second rotation. UI polling remains 100 ms.
        if (session.policy.capture_crashes) {
            if (owner.crashStats()) |stats| {
                session.dumps_saved.store(stats[0], .release);
                session.dumps_failed.store(stats[1], .release);
            } else |_| {
                session.dump_stats_available.store(false, .release);
            }
        }
        if (failure == null) Sleep(if (capacity > 128) 20 else 100);
    }
    if (failure) |err| return err;
}

fn drainOwned(owner: *runtime.Owner, session: *Session) !void {
    session.set(.stopping);
    session.plan_active.store(false, .release);
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
        if (elapsed >= session.policy.timeout_ms) return error.UnconfirmedShutdown;
        if (elapsed >= session.policy.grace_ms) try owner.group.beginDrain(true);
        const count = try owner.group.tick(&rows);
        for (rows[0..count]) |row| {
            if (row.failure) |err| failure = err;
            if (row.exit_code) |code| {
                _ = session.exits.fetchAdd(1, .acq_rel);
                session.last_exit.store(code, .release);
            }
        }
        if (try owner.group.remaining() != 0) Sleep(if (session.policy.effective(session.limits) > 128) 20 else 50);
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
    session.owned.store(session.policy.effective(session.limits), .release);
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

test "runtime limit validation and actual session admission" {
    const defaults: RuntimeLimits = .{};
    try std.testing.expectEqual(@as(usize, 8), defaults.effective());
    const maximum = try RuntimeLimits.decode("1024:131072");
    try std.testing.expectEqual(@as(usize, 1024), maximum.effective());
    const constrained = try RuntimeLimits.parse("1024", "384");
    try std.testing.expectEqual(@as(usize, 3), constrained.effective());
    for ([_][]const u8{ "0:1024", "1025:1024", "8:127", "8:131073", "8:1:2", "+8:1024", "8:0x400" }) |bad| {
        try std.testing.expectError(error.InvalidLimits, RuntimeLimits.decode(bad));
    }
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = .{ .limits = constrained };
    session.set(.running);
    session.owned.store(2, .release);
    try std.testing.expect(session.canStart());
    session.owned.store(3, .release);
    try std.testing.expect(!session.canStart());
}

test "session copies per-launch overrides without changing the prior pending request" {
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = .{};
    session.set(.running);
    const custom: LaunchProfile = .{ .custom = try Profile.parse("125:1:0") };
    try std.testing.expect(session.requestAssetProfile(4, custom));
    try std.testing.expect(!session.requestAssetProfile(5, .alternate));
    try std.testing.expectEqual(@as(u64, 4), session.start_asset.load(.acquire));
    try std.testing.expectEqualDeep(custom, try LaunchProfile.unpack(session.start_profile.load(.acquire)));
    session.reset();
    try std.testing.expectEqual(@as(u32, 0), session.start_profile.load(.acquire));
}

test "runtime policy validates bounded opt-in launch plan and shutdown deadlines" {
    const policy = try RuntimePolicy.decode("1:4:500:2000:10000;builtin:3:0;27:2:1");
    try std.testing.expect(policy.automatic);
    try std.testing.expectEqual(@as(usize, 5), policy.total());
    try std.testing.expectEqual(builtin_asset_id, policy.at(2).?.asset_id);
    try std.testing.expectEqual(@as(u64, 27), policy.at(3).?.asset_id);
    try std.testing.expectEqual(@as(u32, 1), policy.at(4).?.profile);
    try std.testing.expect(policy.at(5) == null);
    var buffer: [512]u8 = undefined;
    try std.testing.expectEqualStrings("1:4:500:2000:10000;builtin:3:0;27:2:1", try policy.encode(&buffer));
    for ([_][]const u8{ "1:4:500:2000:10000", "0:0:500:2000:10000", "0:4:99:2000:10000", "0:4:500:5000:6000", "0:4:500:2000:10001", "0:4:500:2000:10000;builtin:1:1", "0:4:500:2000:10000;5:1:0;5:1:1", "0:4:500:2000:10000;5:1025:0" }) |bad| {
        try std.testing.expectError(error.InvalidPolicy, RuntimePolicy.decode(bad));
    }
}

test "visibility and launch policy commands retain one pending request" {
    const session = try std.testing.allocator.create(Session);
    defer std.testing.allocator.destroy(session);
    session.* = .{};
    session.set(.running);
    session.plan_active.store(true, .release);
    try std.testing.expect(!session.canStart());
    session.plan_active.store(false, .release);
    try std.testing.expect(session.requestVisibility(7, false));
    try std.testing.expect(!session.requestVisibility(8, true));
    try std.testing.expectEqual(@as(u64, 7), session.visibility_id.load(.acquire));
    try std.testing.expect(!session.visibility_show.load(.acquire));
}

extern "kernel32" fn GetTempPathW(u32, [*]u16) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) usize;
extern "kernel32" fn WriteFile(usize, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn FlushFileBuffers(usize) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(usize) callconv(.winapi) c_int;

pub fn exportDiagnostic(report: []const u8, output: []u8) !usize {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (report.len == 0 or report.len > 4096) return error.InvalidDiagnostic;
    var path: [1024]u16 = undefined;
    const root_len = GetTempPathW(path.len, &path);
    if (root_len == 0 or root_len >= path.len or path[root_len - 1] != '\\') return error.DiagnosticPath;
    var name: [128]u8 = undefined;
    const suffix = try std.fmt.bufPrint(&name, "PulseExtras-Companion-diagnostic-{d}-{d}.txt", .{ GetCurrentProcessId(), GetTickCount64() });
    if (root_len + suffix.len >= path.len) return error.DiagnosticPath;
    for (suffix, 0..) |ch, n| path[root_len + n] = ch;
    const len = root_len + suffix.len;
    path[len] = 0;
    const output_len = try std.unicode.utf16LeToUtf8(output, path[0..len]);
    // CREATE_NEW, FILE_FLAG_OPEN_REPARSE_POINT. Never overwrite or follow
    // a preexisting leaf. The OS temp directory is the explicit destination.
    const file = CreateFileW(path[0..len :0].ptr, 0x40000000, 0, null, 1, 0x00200080, null);
    if (file == std.math.maxInt(usize)) return error.DiagnosticCreate;
    var written: u32 = 0;
    const ok = WriteFile(file, report.ptr, @intCast(report.len), &written, null) != 0 and written == report.len and FlushFileBuffers(file) != 0;
    const closed = CloseHandle(file) != 0;
    if (!ok or !closed) return error.DiagnosticWrite;
    return output_len;
}

test "minimize fallback respects manual hides and restores only policy hides" {
    try std.testing.expectEqual(HostWindowState.unknown, classifyWindows(0, 0));
    try std.testing.expectEqual(HostWindowState.normal, classifyWindows(2, 1));
    try std.testing.expectEqual(HostWindowState.minimized, classifyWindows(2, 0));
    var auto: AutoVisibility = .{};
    try std.testing.expectEqual(@as(?bool, false), auto.desired(.minimized, .visible, null));
    auto.accepted(false, false);
    try std.testing.expectEqual(@as(?bool, true), auto.desired(.unknown, .hidden, null));
    auto.accepted(true, false);
    try std.testing.expect(auto.desired(.normal, .hidden, null) == null);
    try std.testing.expectEqual(@as(?bool, false), auto.desired(.minimized, .hidden, false));
    try std.testing.expect(auto.desired(.normal, .hidden, null) == null);
    try std.testing.expectEqual(@as(?bool, true), auto.desired(.minimized, .hidden, true));
    try std.testing.expect(auto.desired(.minimized, .visible, null) == null);
    _ = auto.desired(.normal, .visible, null);
    try std.testing.expectEqual(@as(?bool, false), auto.desired(.minimized, .visible, null));
    const policy = try RuntimePolicy.decode("0:4:500:2000:10000:1");
    try std.testing.expect(policy.hide_on_minimize);
    var encoded: [512]u8 = undefined;
    try std.testing.expectEqualStrings("0:4:500:2000:10000:1", try policy.encode(&encoded));
    try std.testing.expect(!(try RuntimePolicy.decode("0:4:500:2000:10000")).hide_on_minimize);
    try std.testing.expectError(error.InvalidPolicy, RuntimePolicy.decode("0:4:500:2000:10000:2"));
    const history_policy = try RuntimePolicy.decode("0:4:500:2000:10000:0:1");
    try std.testing.expect(history_policy.retain_history and !history_policy.hide_on_minimize);
    try std.testing.expectEqualStrings("0:4:500:2000:10000:0:1", try history_policy.encode(&encoded));
    try std.testing.expect(!(try RuntimePolicy.decode("0:4:500:2000:10000")).retain_history);
    try std.testing.expectError(error.InvalidPolicy, RuntimePolicy.decode("0:4:500:2000:10000:0:2"));
}

test "managed crash capture is opt-in and charges the monitor budget" {
    const defaults: RuntimePolicy = .{};
    try std.testing.expectEqual(@as(usize, 8), defaults.effective(.{}));
    const policy = try RuntimePolicy.decode("0:4:500:2000:10000:0:0:1");
    try std.testing.expect(policy.capture_crashes and !policy.retain_history);
    try std.testing.expectEqual(@as(usize, 4), policy.effective(.{}));
    try std.testing.expectEqual(@as(usize, 0), policy.effective(.{ .instances = 8, .commit_mib = 128 }));
    var encoded: [512]u8 = undefined;
    try std.testing.expectEqualStrings("0:4:500:2000:10000:0:0:1", try policy.encode(&encoded));
    try std.testing.expectError(error.InvalidPolicy, RuntimePolicy.decode("0:4:500:2000:10000:0:0:2"));
}
