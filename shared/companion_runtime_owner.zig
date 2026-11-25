//! Serialized, stable-address worker owner for the versioned runtime DLL.
//! Approval of the canonical installation root/ACLs and expected digest must
//! originate outside this loader. Never use asset paths or UI-entered paths.
const std = @import("std");
const runtime = @import("companion_group.zig");
const scan = @import("companion/pet_recovery_scan.zig");
const receipt = @import("companion/pet_removal_receipt.zig");
const fingerprint = @import("companion/pet_fingerprint.zig");

const invalid = @as(usize, @bitCast(@as(isize, -1)));
const name = std.unicode.wtf8ToWtf16LeStringLiteral("pulse_companion_runtime.dll");
const suffix = std.unicode.wtf8ToWtf16LeStringLiteral("\\pulse_companion_runtime.dll");
const Info = extern struct {
    attributes: u32,
    creation: [2]u32,
    access: [2]u32,
    write: [2]u32,
    volume: u32,
    high: u32,
    low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};
const Query = *const fn (u32, u32, *runtime.NativeApi) callconv(.c) c_int;
const Lease = extern struct {
    parent: usize = 0,
    root: usize = 0,
    lock: usize = 0,
    path: [1024]u16 = @splat(0),
};
const LeaseOpen = *const fn (*Lease, usize, [*:0]const u16) callconv(.c) c_int;
const LeaseClose = *const fn (*Lease, usize) callconv(.c) c_int;
const StoreRead = *const fn (*const Lease, usize, u64, [*]u8, usize, *usize) callconv(.c) c_int;
const StoreWrite = *const fn (*const Lease, usize, u64, [*]const u8, usize) callconv(.c) c_int;
const StoreScan = *const fn (*const Lease, usize, [*]scan.Row, usize, *usize) callconv(.c) c_int;
const StoreQuarantine = *const fn (*const Lease, usize, u64, c_int) callconv(.c) c_int;
const StoreQuarantineV2 = *const fn (*const Lease, usize, u64, c_int, *u32, *u64) callconv(.c) c_int;
const StoreQuarantineIdentity = *const fn (*const Lease, usize, u64, *u32, *u64) callconv(.c) c_int;
const quarantine_pin_max = 293;
const StoreQuarantinePin = *const fn (*const Lease, usize, u64, u32, u64, [*]usize, usize, *usize) callconv(.c) c_int;
const StoreQuarantineRecheck = *const fn (*const Lease, usize, u64, u32, u64, [*]const usize, usize) callconv(.c) c_int;
const StoreCleanupDispose = *const fn (*const Lease, usize, u64, u32, u64, [*]usize, *usize, [*]const u8, usize) callconv(.c) c_int;
const StoreQuarantineUsage = *const fn (*const Lease, usize, u64, *u64) callconv(.c) c_int;

extern "kernel32" fn CreateDirectoryW([*:0]const u16, ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn RemoveDirectoryW([*:0]const u16) callconv(.winapi) c_int;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) usize;
extern "kernel32" fn CloseHandle(usize) callconv(.winapi) c_int;
extern "kernel32" fn GetDriveTypeW([*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetFileType(usize) callconv(.winapi) u32;
extern "kernel32" fn GetFileInformationByHandle(usize, *Info) callconv(.winapi) c_int;
extern "kernel32" fn GetFinalPathNameByHandleW(usize, [*]u16, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn CompareStringOrdinal([*]const u16, i32, [*]const u16, i32, c_int) callconv(.winapi) c_int;
extern "kernel32" fn ReadFile(usize, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn GetModuleHandleW([*:0]const u16) callconv(.winapi) usize;
extern "kernel32" fn GetModuleFileNameW(usize, [*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?*anyopaque, u32) callconv(.winapi) usize;
extern "kernel32" fn GetProcAddress(usize, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(usize) callconv(.winapi) c_int;

fn samePath(a: []const u16, b: []const u16) bool {
    return a.len == b.len and CompareStringOrdinal(a.ptr, @intCast(a.len), b.ptr, @intCast(b.len), 1) == 2;
}

fn canonical(handle: usize, path: []const u16) bool {
    var actual: [1032]u16 = undefined;
    const n = GetFinalPathNameByHandleW(handle, &actual, actual.len, 0);
    if (n != path.len + 4 or n >= actual.len) return false;
    return std.mem.eql(u16, actual[0..4], std.unicode.wtf8ToWtf16LeStringLiteral("\\\\?\\")) and samePath(actual[4..n], path);
}

fn checkRoot(root: [:0]const u16) !void {
    if (root.len < 4 or root.len + suffix.len >= 1024 or root[1] != ':' or root[2] != '\\' or root[root.len - 1] == '\\') return error.InvalidRoot;
    if (!((root[0] >= 'A' and root[0] <= 'Z') or (root[0] >= 'a' and root[0] <= 'z'))) return error.InvalidRoot;
    if (std.mem.indexOfScalar(u16, root, 0) != null) return error.InvalidRoot;
    const drive = [_:0]u16{ root[0], ':', '\\' };
    if (GetDriveTypeW(&drive) != 3) return error.InvalidRoot;
}

fn hashPinned(file: usize, info: Info) ![32]u8 {
    if (info.high != 0 or info.low == 0 or info.low > 256 * 1024 * 1024) return error.InvalidImage;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var bytes: [16384]u8 = undefined;
    var remaining: u32 = info.low;
    while (remaining != 0) {
        const want: u32 = @min(remaining, bytes.len);
        var got: u32 = 0;
        if (ReadFile(file, &bytes, want, &got, null) == 0 or got != want) return error.ReadFailed;
        hash.update(bytes[0..got]);
        remaining -= got;
    }
    return hash.finalResult();
}

pub const Owner = struct {
    group: runtime.Group = .{},
    root_handle: usize = invalid,
    image_handle: usize = invalid,
    module: usize = 0,
    opened: bool = false,
    lease: Lease = .{},
    lease_opened: bool = false,
    lease_close: ?LeaseClose = null,
    store_faulted: bool = false,
    quarantine_pins: [quarantine_pin_max]usize = undefined,
    quarantine_pin_count: usize = 0,
    cleanup_pins: bool = false,
    market_lease: Lease = .{},
    market_lease_opened: bool = false,
    market_lease_close: ?LeaseClose = null,
    market_work_handle: usize = invalid,
    market_work_path: [1024]u16 = @splat(0),

    /// Worker only. Root must already be independently approved; the file
    /// pin denies writes/deletes, and the module stays loaded through drain.
    pub fn open(self: *Owner, root: [:0]const u16, expected: [32]u8, limit: usize, budget: usize) !void {
        if (self.root_handle != invalid or self.image_handle != invalid or self.module != 0 or self.opened) return error.Busy;
        self.openInternal(root, expected, limit, budget) catch |err| {
            self.close() catch return error.CleanupFailed;
            return err;
        };
    }

    fn openInternal(self: *Owner, root: [:0]const u16, expected: [32]u8, limit: usize, budget: usize) !void {
        try checkRoot(root);
        self.root_handle = CreateFileW(root.ptr, 0x80, 3, null, 3, 0x02200000, null);
        if (self.root_handle == invalid) return error.OpenRootFailed;
        var info: Info = undefined;
        if (GetFileInformationByHandle(self.root_handle, &info) == 0 or (info.attributes & 0x410) != 0x10 or !canonical(self.root_handle, root)) return error.InvalidRoot;
        var path: [1024]u16 = undefined;
        @memcpy(path[0..root.len], root);
        @memcpy(path[root.len..][0..suffix.len], suffix);
        const len = root.len + suffix.len;
        path[len] = 0;
        const full = path[0..len :0];
        self.image_handle = CreateFileW(full.ptr, 0x80000000, 1, null, 3, 0x00200000, null);
        if (self.image_handle == invalid) return error.OpenImageFailed;
        if (GetFileType(self.image_handle) != 1 or GetFileInformationByHandle(self.image_handle, &info) == 0 or
            (info.attributes & 0x410) != 0 or info.links != 1 or !canonical(self.image_handle, full)) return error.InvalidImage;
        const actual = try hashPinned(self.image_handle, info);
        if (!std.mem.eql(u8, &actual, &expected)) return error.UnapprovedModule;
        // Reject already loaded same-name modules rather than adopting an
        // image whose in-memory bytes were not verified by this owner.
        if (GetModuleHandleW(name) != 0) return error.ModuleAlreadyLoaded;
        self.module = LoadLibraryExW(full.ptr, null, 0x800);
        if (self.module == 0) return error.LoadFailed;
        var loaded: [1024]u16 = undefined;
        const count = GetModuleFileNameW(self.module, &loaded, loaded.len);
        if (count == 0 or count >= loaded.len or !samePath(loaded[0..count], full)) return error.InvalidImage;
        const query: Query = @ptrCast(GetProcAddress(self.module, "pulse_companion_runtime_query") orelse return error.MissingQuery);
        var api: runtime.NativeApi = undefined;
        if (query(2, @sizeOf(runtime.NativeApi), &api) == 0 or !api.valid()) return error.BadRuntimeAbi;
        try self.group.openWithApi(api, limit, budget);
        self.opened = true;
    }

    pub fn privateRoot(self: *Owner, parent: [:0]const u16) ![:0]const u16 {
        if (!self.opened or self.module == 0) return error.Invalid;
        if (!self.lease_opened) {
            const open_lease: LeaseOpen = @ptrCast(GetProcAddress(self.module, "pulse_companion_private_open_v1") orelse return error.MissingLeaseApi);
            self.lease_close = @ptrCast(GetProcAddress(self.module, "pulse_companion_private_close_v1") orelse return error.MissingLeaseApi);
            const code = open_lease(&self.lease, @sizeOf(Lease), parent.ptr);
            if (code != 0) {
                if (code == 3) return error.PrivateRootBusy;
                if (code == 4) return error.CleanupFailed;
                return error.PrivateRootRejected;
            }
            self.lease_opened = true;
        }
        const len = std.mem.indexOfScalar(u16, &self.lease.path, 0) orelse return error.InvalidRoot;
        if (len == 0) return error.InvalidRoot;
        return self.lease.path[0..len :0];
    }

    // Reuse the private-root ACL verification and exclusive owner lock for a
    // separate nested market namespace. Never share it with pet inventory.
    pub fn openMarketRoot(self: *Owner) ![:0]const u16 {
        if (!self.opened or !self.lease_opened or self.store_faulted or self.market_lease_opened) return error.OwnerUnavailable;
        const open_lease: LeaseOpen = @ptrCast(GetProcAddress(self.module, "pulse_companion_private_open_v1") orelse return error.MissingLeaseApi);
        self.market_lease_close = @ptrCast(GetProcAddress(self.module, "pulse_companion_private_close_v1") orelse return error.MissingLeaseApi);
        const parent = std.mem.sliceTo(&self.lease.path, 0);
        const code = open_lease(&self.market_lease, @sizeOf(Lease), parent.ptr);
        if (code != 0) {
            if (code == 3) return error.PrivateRootBusy;
            if (code == 4) return error.CleanupFailed;
            return error.PrivateRootRejected;
        }
        self.market_lease_opened = true;
        const len = std.mem.indexOfScalar(u16, &self.market_lease.path, 0) orelse return error.InvalidRoot;
        if (len == 0) return error.InvalidRoot;
        return self.market_lease.path[0..len :0];
    }

    pub fn marketSymbol(self: *Owner, symbol: [:0]const u8) !*const anyopaque {
        if (!self.opened or !self.market_lease_opened or self.store_faulted) return error.OwnerUnavailable;
        return GetProcAddress(self.module, symbol.ptr) orelse return error.MissingStoreApi;
    }

    pub fn marketRead(self: *Owner, slot: u32, bytes: []u8) !?usize {
        const read: StoreRead = @ptrCast(try self.marketSymbol("pulse_companion_market_read_v1"));
        var len: usize = 0;
        const code = read(&self.market_lease, @sizeOf(Lease), slot, bytes.ptr, bytes.len, &len);
        if (code == 1) return null;
        try checkStore(code);
        if (len > bytes.len) return error.InvalidRecord;
        return len;
    }

    pub fn marketWrite(self: *Owner, slot: u32, bytes: []const u8) !void {
        const write: StoreWrite = @ptrCast(try self.marketSymbol("pulse_companion_market_write_v1"));
        try checkStore(write(&self.market_lease, @sizeOf(Lease), slot, bytes.ptr, bytes.len));
    }

    // Exclusive create: interrupted work stays on disk and blocks future
    // operations; never adopt or recursively remove a preexisting directory.
    pub fn createMarketWork(self: *Owner) ![:0]const u16 {
        if (!self.market_lease_opened or self.market_work_handle != invalid) return error.OwnerUnavailable;
        const root = std.mem.sliceTo(&self.market_lease.path, 0);
        const tail = std.unicode.wtf8ToWtf16LeStringLiteral("\\market-work");
        const len = root.len + tail.len;
        if (len >= self.market_work_path.len) return error.InvalidRoot;
        @memcpy(self.market_work_path[0..root.len], root);
        @memcpy(self.market_work_path[root.len..len], tail);
        self.market_work_path[len] = 0;
        const path = self.market_work_path[0..len :0];
        if (CreateDirectoryW(path.ptr, null) == 0) return error.MarketWorkBlocked;
        self.market_work_handle = CreateFileW(path.ptr, 0x80, 3, null, 3, 0x02200000, null);
        if (self.market_work_handle == invalid) return error.MarketWorkBlocked;
        var info: Info = undefined;
        if (GetFileInformationByHandle(self.market_work_handle, &info) == 0 or (info.attributes & 0x410) != 0x10 or !canonical(self.market_work_handle, path)) return error.InvalidRoot;
        return path;
    }

    // Call only after all temporary files, borrowers and directory handles
    // are drained. RemoveDirectory refuses unknown remaining entries.
    pub fn finishMarketWork(self: *Owner) !void {
        if (self.market_work_handle == invalid) return error.OwnerUnavailable;
        if (CloseHandle(self.market_work_handle) == 0) return error.CleanupFailed;
        self.market_work_handle = invalid;
        if (RemoveDirectoryW(@ptrCast(&self.market_work_path)) == 0) return error.MarketWorkBlocked;
        self.market_work_path[0] = 0;
    }

    fn checkStore(code: c_int) !void {
        return switch (code) {
            0 => {},
            2 => error.InvalidRecord,
            3 => error.StoreIo,
            4 => error.StoreBusy,
            5 => error.CleanupFailed,
            else => error.StoreIo,
        };
    }

    // ID zero selects inventory; nonzero selects one preference record.
    // Only typed codecs should call these byte-level adapters.
    pub fn readStore(self: *Owner, id: u64, bytes: []u8) !?usize {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        const read: StoreRead = @ptrCast(GetProcAddress(self.module, "pulse_companion_store_read_v1") orelse return error.MissingStoreApi);
        var len: usize = 0;
        const code = read(&self.lease, @sizeOf(Lease), id, bytes.ptr, bytes.len, &len);
        if (code == 1) return null;
        try checkStore(code);
        if (len > bytes.len) return error.InvalidRecord;
        return len;
    }

    pub fn writeStore(self: *Owner, id: u64, bytes: []const u8) !void {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        const write: StoreWrite = @ptrCast(GetProcAddress(self.module, "pulse_companion_store_write_v1") orelse return error.MissingStoreApi);
        checkStore(write(&self.lease, @sizeOf(Lease), id, bytes.ptr, bytes.len)) catch |err| {
            // No retry following an ambiguous write. Reload after close.
            self.store_faulted = true;
            return err;
        };
    }

    pub fn scanStore(self: *Owner, rows: []scan.Row) !usize {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        if (rows.len == 0 or rows.len > scan.max_rows) return error.InvalidScan;
        const enumerate: StoreScan = @ptrCast(GetProcAddress(self.module, "pulse_companion_scan_v1") orelse return error.MissingStoreApi);
        var count: usize = 0;
        checkStore(enumerate(&self.lease, @sizeOf(Lease), rows.ptr, rows.len, &count)) catch |err| {
            if (err == error.CleanupFailed) self.store_faulted = true;
            return err;
        };
        if (count > rows.len) return error.InvalidScan;
        return count;
    }

    pub fn readRemovalReceipt(self: *Owner, id: u64) !?receipt.Receipt {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        if (id == 0) return error.InvalidRecord;
        const read: StoreRead = @ptrCast(GetProcAddress(self.module, "pulse_companion_receipt_read_v1") orelse return error.MissingStoreApi);
        var bytes: [receipt.encoded_size]u8 = undefined;
        var len: usize = 0;
        const code = read(&self.lease, @sizeOf(Lease), id, &bytes, bytes.len, &len);
        if (code == 1) return null;
        checkStore(code) catch |err| {
            if (err == error.CleanupFailed) self.store_faulted = true;
            return err;
        };
        if (len != bytes.len) return error.InvalidReceipt;
        return try receipt.Receipt.decode(&bytes, id);
    }

    pub fn writeRemovalReceipt(self: *Owner, value: receipt.Receipt) !void {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        if (try self.group.remaining() != 0) return error.ActiveInstances;
        var bytes: [receipt.encoded_size]u8 = undefined;
        try value.encode(&bytes);
        const write: StoreWrite = @ptrCast(GetProcAddress(self.module, "pulse_companion_receipt_write_v1") orelse return error.MissingStoreApi);
        checkStore(write(&self.lease, @sizeOf(Lease), value.record.id, &bytes, bytes.len)) catch |err| {
            if (err != error.StoreBusy) self.store_faulted = true;
            return err;
        };
    }

    pub fn quarantineUsage(self: *Owner, id: u64) !u64 {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        if (id == 0) return error.InvalidRecord;
        const measure: StoreQuarantineUsage = @ptrCast(GetProcAddress(self.module, "pulse_companion_quarantine_usage_v1") orelse return error.MissingStoreApi);
        var bytes: u64 = 0;
        checkStore(measure(&self.lease, @sizeOf(Lease), id, &bytes)) catch |err| {
            if (err == error.CleanupFailed) self.store_faulted = true;
            return err;
        };
        if (bytes > 320 * 1024 * 1024) return error.InvalidRecord;
        return bytes;
    }

    // Internal fixed-name move; the store layer validates durable identity
    // and recovery state. No caller-supplied path or recursive deletion.
    pub const DirectoryIdentity = struct {
        volume: u32 = 0,
        file_index: u64 = 0,
    };

    pub fn pinQuarantine(self: *Owner, id: u64, identity: DirectoryIdentity) !void {
        return self.pinMode(id, identity, false);
    }

    pub fn pinCleanup(self: *Owner, id: u64, identity: DirectoryIdentity) !void {
        return self.pinMode(id, identity, true);
    }

    fn pinMode(self: *Owner, id: u64, identity: DirectoryIdentity, deleting: bool) !void {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        if (id == 0 or identity.file_index == 0) return error.InvalidRecord;
        if (self.quarantine_pin_count != 0 or try self.group.remaining() != 0) return error.StoreBusy;
        const pin: StoreQuarantinePin = @ptrCast(GetProcAddress(self.module, if (deleting) "pulse_companion_cleanup_pin_v1" else "pulse_companion_quarantine_pin_v1") orelse return error.MissingStoreApi);
        self.cleanup_pins = deleting;
        const code = pin(&self.lease, @sizeOf(Lease), id, identity.volume, identity.file_index, &self.quarantine_pins, self.quarantine_pins.len, &self.quarantine_pin_count);
        if (self.quarantine_pin_count > self.quarantine_pins.len) {
            self.store_faulted = true;
            return error.CleanupFailed;
        }
        checkStore(code) catch |err| {
            self.releaseQuarantine() catch return error.CleanupFailed;
            if (err == error.CleanupFailed) self.store_faulted = true;
            return err;
        };
        if (self.quarantine_pin_count < 3) {
            self.releaseQuarantine() catch return error.CleanupFailed;
            return error.InvalidRecord;
        }
    }

    pub fn recheckQuarantine(self: *Owner, id: u64, identity: DirectoryIdentity) !void {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        if (id == 0 or identity.file_index == 0) return error.InvalidRecord;
        if (self.quarantine_pin_count < 3 or self.quarantine_pin_count > self.quarantine_pins.len) return error.StoreBusy;
        const recheck: StoreQuarantineRecheck = @ptrCast(GetProcAddress(self.module, if (self.cleanup_pins) "pulse_companion_cleanup_recheck_v1" else "pulse_companion_quarantine_recheck_v1") orelse return error.MissingStoreApi);
        checkStore(recheck(&self.lease, @sizeOf(Lease), id, identity.volume, identity.file_index, &self.quarantine_pins, self.quarantine_pin_count)) catch |err| {
            if (err == error.CleanupFailed) self.store_faulted = true;
            return err;
        };
    }

    // Retain the failing handle on error; close() retries before unloading.
    pub fn releaseQuarantine(self: *Owner) !void {
        if (self.quarantine_pin_count > self.quarantine_pins.len) return error.CleanupFailed;
        while (self.quarantine_pin_count != 0) {
            const handle = self.quarantine_pins[self.quarantine_pin_count - 1];
            if (CloseHandle(handle) == 0) {
                self.store_faulted = true;
                return error.CleanupFailed;
            }
            self.quarantine_pin_count -= 1;
        }
        self.cleanup_pins = false;
    }

    // Compute both digests from the exact delete-capable handles.
    pub fn cleanupPair(self: *Owner, id: u64, cancel: anytype) !fingerprint.Pair {
        if (!self.cleanup_pins or self.quarantine_pin_count < 3) return error.StoreBusy;
        const Work = struct {
            paths: [fingerprint.max_files][96]u8,
            files: [fingerprint.max_files]fingerprint.FileDigest,
        };
        const work = try std.heap.page_allocator.create(Work);
        defer std.heap.page_allocator.destroy(work);
        var prefix: [1032]u16 = undefined;
        const root = std.mem.sliceTo(&self.lease.path, 0);
        var suffix_buf: [64]u8 = undefined;
        const leaf = try std.fmt.bufPrint(&suffix_buf, "\\pet-{x:0>16}.removed\\", .{id});
        const pre = std.unicode.wtf8ToWtf16LeStringLiteral("\\\\?\\");
        if (pre.len + root.len + leaf.len >= prefix.len) return error.InvalidRecord;
        @memcpy(prefix[0..pre.len], pre);
        @memcpy(prefix[pre.len..][0..root.len], root);
        for (leaf, 0..) |ch, n| prefix[pre.len + root.len + n] = ch;
        const prefix_len = pre.len + root.len + leaf.len;
        var count: usize = 0;
        var total: u64 = 0;
        var buffer: [16 * 1024]u8 = undefined;
        for (self.quarantine_pins[0..self.quarantine_pin_count]) |handle| {
            try cancel.check();
            var info: Info = undefined;
            if (GetFileInformationByHandle(handle, &info) == 0) return error.StoreIo;
            if ((info.attributes & 0x10) != 0) continue;
            if (count == fingerprint.max_files or info.links != 1 or (info.attributes & 0x401) != 0) return error.InvalidRecord;
            var actual: [1032]u16 = undefined;
            const n = GetFinalPathNameByHandleW(handle, &actual, actual.len, 0);
            if (n <= prefix_len or n >= actual.len or !samePath(actual[0..prefix_len], prefix[0..prefix_len])) return error.InvalidRecord;
            const len = try std.unicode.utf16LeToUtf8(&work.paths[count], actual[prefix_len..n]);
            for (work.paths[count][0..len]) |*ch| {
                if (ch.* == '\\') ch.* = '/';
            }
            const size = (@as(u64, info.high) << 32) | info.low;
            if (size == 0 or size > fingerprint.max_file_bytes or size > fingerprint.max_total_bytes - total) return error.InvalidRecord;
            total += size;
            var primary = std.crypto.hash.sha2.Sha256.init(.{});
            var secondary = std.crypto.hash.sha2.Sha512.init(.{});
            var remaining = size;
            while (remaining != 0) {
                try cancel.check();
                const want: u32 = @intCast(@min(remaining, buffer.len));
                var got: u32 = 0;
                if (ReadFile(handle, &buffer, want, &got, null) == 0 or got != want) return error.StoreIo;
                primary.update(buffer[0..got]);
                secondary.update(buffer[0..got]);
                remaining -= got;
            }
            var after: Info = undefined;
            if (GetFileInformationByHandle(handle, &after) == 0 or after.high != info.high or after.low != info.low or !std.meta.eql(after.write, info.write)) return error.ContentChanged;
            work.files[count] = .{ .path = work.paths[count][0..len], .size = size, .digest = primary.finalResult(), .secondary = secondary.finalResult() };
            count += 1;
        }
        return fingerprint.digestPair(work.files[0..count]);
    }

    // Publish immutable intent before the first disposition. Never retry.
    pub fn disposeCleanup(self: *Owner, value: receipt.Receipt) !void {
        if (!self.cleanup_pins or self.quarantine_pin_count < 3 or self.store_faulted) return error.StoreBusy;
        const write: StoreWrite = @ptrCast(GetProcAddress(self.module, "pulse_companion_cleanup_marker_write_v1") orelse return error.MissingStoreApi);
        const dispose: StoreCleanupDispose = @ptrCast(GetProcAddress(self.module, "pulse_companion_cleanup_dispose_v1") orelse return error.MissingStoreApi);
        var bytes: [receipt.encoded_size]u8 = undefined;
        try value.encode(&bytes);
        checkStore(write(&self.lease, @sizeOf(Lease), value.record.id, &bytes, bytes.len)) catch {
            self.store_faulted = true;
            return error.CleanupIntentUncertain;
        };
        checkStore(dispose(&self.lease, @sizeOf(Lease), value.record.id, value.volume, value.file_index, &self.quarantine_pins, &self.quarantine_pin_count, &bytes, bytes.len)) catch {
            self.store_faulted = true;
            return error.CleanupInterrupted;
        };
        if (self.quarantine_pin_count != 0) return error.CleanupInterrupted;
    }

    pub fn quarantineIdentity(self: *Owner, id: u64) !DirectoryIdentity {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        if (id == 0) return error.InvalidRecord;
        const query: StoreQuarantineIdentity = @ptrCast(GetProcAddress(self.module, "pulse_companion_quarantine_identity_v1") orelse return error.MissingStoreApi);
        var identity: DirectoryIdentity = .{};
        checkStore(query(&self.lease, @sizeOf(Lease), id, &identity.volume, &identity.file_index)) catch |err| {
            if (err == error.CleanupFailed) self.store_faulted = true;
            return err;
        };
        if (identity.file_index == 0) return error.InvalidRecord;
        return identity;
    }

    // No unbound V1 fallback for a receipt-producing removal.
    pub fn moveQuarantineBound(self: *Owner, id: u64) !DirectoryIdentity {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        if (id == 0) return error.InvalidRecord;
        if (self.quarantine_pin_count != 0) return error.StoreBusy;
        if (try self.group.remaining() != 0) return error.ActiveInstances;
        _ = GetProcAddress(self.module, "pulse_companion_receipt_write_v1") orelse return error.MissingStoreApi;
        const move: StoreQuarantineV2 = @ptrCast(GetProcAddress(self.module, "pulse_companion_quarantine_v2") orelse return error.MissingStoreApi);
        var identity: DirectoryIdentity = .{};
        checkStore(move(&self.lease, @sizeOf(Lease), id, 0, &identity.volume, &identity.file_index)) catch |err| {
            self.store_faulted = true;
            return err;
        };
        if (identity.file_index == 0) {
            self.store_faulted = true;
            return error.InvalidRecord;
        }
        return identity;
    }

    pub fn moveQuarantine(self: *Owner, id: u64, restore: bool) !void {
        if (!self.opened or !self.lease_opened or self.module == 0 or self.store_faulted) return error.OwnerUnavailable;
        if (id == 0) return error.InvalidRecord;
        if (self.quarantine_pin_count != 0) return error.StoreBusy;
        if (try self.group.remaining() != 0) return error.ActiveInstances;
        const move: StoreQuarantine = @ptrCast(GetProcAddress(self.module, "pulse_companion_quarantine_v1") orelse return error.MissingStoreApi);
        checkStore(move(&self.lease, @sizeOf(Lease), id, @intFromBool(restore))) catch |err| {
            self.store_faulted = true;
            return err;
        };
    }

    // Last-resort terminal shutdown. Caller must report unconfirmed exit.
    pub fn abandon(self: *Owner) !void {
        if (self.opened) {
            try self.group.abandon();
            self.opened = false;
        }
        try self.close();
    }

    /// Refuses to unload while a child remains owned. Cleanup errors retain
    /// the failing handle so the serialized caller can retry close.
    pub fn close(self: *Owner) !void {
        try self.releaseQuarantine();
        if (self.market_work_handle != invalid) {
            if (CloseHandle(self.market_work_handle) == 0) return error.CleanupFailed;
            self.market_work_handle = invalid;
        }
        if (self.market_lease_close) |close_lease| {
            if (close_lease(&self.market_lease, @sizeOf(Lease)) != 0) return error.CleanupFailed;
            self.market_lease_close = null;
            self.market_lease_opened = false;
        }
        if (self.opened) {
            try self.group.close();
            self.opened = false;
        }
        if (self.lease_close) |close_lease| {
            if (close_lease(&self.lease, @sizeOf(Lease)) != 0) return error.CleanupFailed;
            self.lease_close = null;
            self.lease_opened = false;
            self.store_faulted = false;
        }
        if (self.module != 0) {
            if (FreeLibrary(self.module) == 0) return error.CleanupFailed;
            self.module = 0;
        }
        if (self.image_handle != invalid) {
            if (CloseHandle(self.image_handle) == 0) return error.CleanupFailed;
            self.image_handle = invalid;
        }
        if (self.root_handle != invalid) {
            if (CloseHandle(self.root_handle) == 0) return error.CleanupFailed;
            self.root_handle = invalid;
        }
    }
};
