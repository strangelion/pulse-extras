//! Read-only inventory discovery. Does not create a directory, approve its
//! ACL, adopt files, verify artwork, or authorize launch. Treat all bytes
//! as untrusted. The fixed known-folder path is not an arbitrary UI path.
const std = @import("std");
const builtin = @import("builtin");
const inventory = @import("pet_inventory.zig");

pub const Row = struct {
    id: u64,
    source: [64]u8,
    len: u8,
    paired: bool,

    pub fn sourceId(self: *const Row) []const u8 {
        return self.source[0..self.len];
    }
};

pub const Snapshot = struct {
    count: usize = 0,
    rows: [inventory.max_entries]Row = undefined,
    missing: bool = false,
};

const invalid = @as(usize, @bitCast(@as(isize, -1)));
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
const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const local_app_data: Guid = .{ .a = 0xf1b32785, .b = 0x6fba, .c = 0x4fcf, .d = .{ 0x9d, 0x55, 0x7b, 0x8e, 0x7f, 0x15, 0x70, 0x91 } };

const KnownFolderFn = *const fn (*const Guid, u32, ?*anyopaque, *?[*:0]u16) callconv(.winapi) i32;
const TaskMemFreeFn = *const fn (?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?*anyopaque, u32) callconv(.winapi) usize;
extern "kernel32" fn GetProcAddress(usize, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(usize) callconv(.winapi) i32;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?*anyopaque) callconv(.winapi) usize;
extern "kernel32" fn CloseHandle(usize) callconv(.winapi) i32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn GetDriveTypeW([*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetFileInformationByHandle(usize, *Info) callconv(.winapi) i32;
extern "kernel32" fn GetFileType(usize) callconv(.winapi) u32;
extern "kernel32" fn GetFinalPathNameByHandleW(usize, [*]u16, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn CompareStringOrdinal([*]const u16, i32, [*]const u16, i32, i32) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(usize, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;

fn canonical(handle: usize, path: []const u16) bool {
    var actual: [1032]u16 = undefined;
    const n = GetFinalPathNameByHandleW(handle, &actual, actual.len, 0);
    if (n != path.len + 4 or n >= actual.len) return false;
    if (!std.mem.eql(u16, actual[0..4], std.unicode.wtf8ToWtf16LeStringLiteral("\\\\?\\"))) return false;
    return CompareStringOrdinal(actual[4..].ptr, @intCast(path.len), path.ptr, @intCast(path.len), 1) == 2;
}

fn appendPath(out: []u16, base: []const u16, tail: []const u16) ![:0]const u16 {
    if (base.len + tail.len >= out.len) return error.PathTooLong;
    @memcpy(out[0..base.len], base);
    @memcpy(out[base.len..][0..tail.len], tail);
    const len = base.len + tail.len;
    out[len] = 0;
    return out[0..len :0];
}

// Resolve only system DLLs, never search the application directory or PATH.
// The MSVC cross-build needs no external Windows SDK import libraries.
// Keep the libraries loaded until the allocated path has been freed.
fn knownRoot(out: []u16) ![:0]const u16 {
    const system32 = 0x00000800; // LOAD_LIBRARY_SEARCH_SYSTEM32
    const shell = LoadLibraryExW(std.unicode.wtf8ToWtf16LeStringLiteral("shell32.dll"), null, system32);
    if (shell == 0) return error.KnownFolderUnavailable;
    const ole = LoadLibraryExW(std.unicode.wtf8ToWtf16LeStringLiteral("ole32.dll"), null, system32);
    if (ole == 0) {
        if (FreeLibrary(shell) == 0) return error.CleanupFailed;
        return error.KnownFolderUnavailable;
    }
    const result = resolveRoot(shell, ole, out);
    const ole_closed = FreeLibrary(ole) != 0;
    const shell_closed = FreeLibrary(shell) != 0;
    if (!ole_closed or !shell_closed) return error.CleanupFailed;
    return result;
}

fn resolveRoot(shell: usize, ole: usize, out: []u16) ![:0]const u16 {
    const folder: KnownFolderFn = @ptrCast(GetProcAddress(shell, "SHGetKnownFolderPath") orelse return error.KnownFolderUnavailable);
    const free: TaskMemFreeFn = @ptrCast(GetProcAddress(ole, "CoTaskMemFree") orelse return error.KnownFolderUnavailable);
    var path: ?[*:0]u16 = null;
    // KF_FLAG_DONT_VERIFY: do not create or probe arbitrary alternate folders.
    const status = folder(&local_app_data, 0x4000, null, &path);
    defer if (path) |owned| free(@ptrCast(owned));
    if (status != 0) return error.KnownFolderFailed;
    const base = path orelse return error.KnownFolderFailed;
    return appendPath(out, std.mem.span(base), std.unicode.wtf8ToWtf16LeStringLiteral("\\PulseExtras-Companion"));
}

pub fn readDefault(out: *Snapshot) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var root: [1024]u16 = undefined;
    const full = try knownRoot(&root);
    try readAt(full, out);
}

/// Test/worker-only path boundary; no UI path is accepted by readDefault.
/// Open existing normal local directories/files, deny delete sharing, reject
/// reparse points/aliases/hardlinked records. No writes, no executable loading.
pub fn readAt(root: [:0]const u16, out: *Snapshot) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    if (root.len < 4 or root.len > 950 or root[1] != ':' or root[2] != '\\' or root[root.len - 1] == '\\') return error.InvalidRoot;
    const drive = [_:0]u16{ root[0], ':', '\\' };
    if (GetDriveTypeW(&drive) != 3) return error.InvalidRoot;
    const dir = CreateFileW(root.ptr, 0x80, 3, null, 3, 0x02200000, null);
    if (dir == invalid) {
        const code = GetLastError();
        if (code == 2 or code == 3) {
            out.* = .{ .missing = true };
            return;
        }
        return error.OpenRootFailed;
    }
    var result: Snapshot = .{};
    const read = readPinned(dir, root, &result);
    if (CloseHandle(dir) == 0) return error.CleanupFailed;
    try read;
    out.* = result;
}

fn readPinned(dir: usize, root: [:0]const u16, out: *Snapshot) !void {
    var info: Info = undefined;
    if (GetFileInformationByHandle(dir, &info) == 0 or (info.attributes & 0x410) != 0x10 or !canonical(dir, root)) return error.InvalidRoot;
    var name: [1024]u16 = undefined;
    const path = try appendPath(&name, root, std.unicode.wtf8ToWtf16LeStringLiteral("\\inventory.pci"));
    const file = CreateFileW(path.ptr, 0x80000000, 1, null, 3, 0x00200000, null);
    if (file == invalid) {
        if (GetLastError() == 2) {
            out.* = .{ .missing = true };
            return;
        }
        return error.OpenInventoryFailed;
    }
    const result = readFile(file, path, out);
    if (CloseHandle(file) == 0) return error.CleanupFailed;
    try result;
}

fn readFile(file: usize, path: []const u16, out: *Snapshot) !void {
    var info: Info = undefined;
    if (GetFileType(file) != 1 or GetFileInformationByHandle(file, &info) == 0 or
        (info.attributes & 0x410) != 0 or info.links != 1 or info.high != 0 or
        info.low == 0 or info.low > inventory.max_bytes or !canonical(file, path)) return error.InvalidInventory;
    var bytes: [inventory.max_bytes]u8 = undefined;
    var got: u32 = 0;
    if (ReadFile(file, &bytes, info.low, &got, null) == 0 or got != info.low) return error.ReadInventoryFailed;
    var extra: [1]u8 = undefined;
    if (ReadFile(file, &extra, 1, &got, null) == 0 or got != 0) return error.ReadInventoryFailed;
    try decode(bytes[0..info.low], out);
}

pub fn decode(bytes: []const u8, out: *Snapshot) !void {
    var index: inventory.Inventory = .{};
    try inventory.decode(&index, bytes);
    var result: Snapshot = .{ .count = index.count };
    for (index.entries[0..index.count], 0..) |record, n| {
        result.rows[n] = .{ .id = record.id, .source = record.source, .len = record.len, .paired = record.digest != null and record.secondary != null };
    }
    out.* = result;
}
