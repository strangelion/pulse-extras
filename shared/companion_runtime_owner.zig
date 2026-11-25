//! Serialized, stable-address worker owner for the versioned runtime DLL.
//! Approval of the canonical installation root/ACLs and expected digest must
//! originate outside this loader. Never use asset paths or UI-entered paths.
const std = @import("std");
const runtime = @import("companion_group.zig");

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
        if (self.opened) {
            try self.group.close();
            self.opened = false;
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
