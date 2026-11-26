//! Windows native folder picker for the isolated, approved helper only.
//! No host-window subclassing, UI thread blocking, or shell command.
const std = @import("std");
const Guid = extern struct { a: u32, b: u16, c: u16, d: [8]u8 };
const Object = extern struct { vtable: [*]const *const anyopaque };
const clsid: Guid = .{ .a = 0xdc1c5a9c, .b = 0xe88a, .c = 0x4dde, .d = .{ 0xa5, 0xa1, 0x60, 0xf8, 0x2a, 0x20, 0xae, 0xf7 } };
const iid: Guid = .{ .a = 0xd57c7288, .b = 0xd4ad, .c = 0x4768, .d = .{ 0xbe, 0x02, 0x9d, 0x96, 0x95, 0x32, 0xd9, 0x60 } };

extern "ole32" fn CoInitializeEx(?*anyopaque, u32) callconv(.winapi) i32;
extern "ole32" fn CoUninitialize() callconv(.winapi) void;
extern "ole32" fn CoCreateInstance(*const Guid, ?*anyopaque, u32, *const Guid, *?*Object) callconv(.winapi) i32;
extern "ole32" fn CoTaskMemFree(?*anyopaque) callconv(.winapi) void;
extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn WriteFile(*anyopaque, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;

fn method(comptime F: type, object: *Object, comptime slot: usize) F {
    return @ptrCast(object.vtable[slot]);
}

fn release(object: *Object) void {
    _ = method(*const fn (*Object) callconv(.winapi) u32, object, 2)(object);
}

fn output(bytes: []const u8) !void {
    const handle = GetStdHandle(0xfffffff5) orelse return error.OutputFailed;
    if (@intFromPtr(handle) == std.math.maxInt(usize)) return error.OutputFailed;
    var written: u32 = 0;
    if (WriteFile(handle, bytes.ptr, @intCast(bytes.len), &written, null) == 0 or written != bytes.len) return error.OutputFailed;
}

fn pick() !void {
    // COINIT_APARTMENTTHREADED | COINIT_DISABLE_OLE1DDE.
    if (CoInitializeEx(null, 6) < 0) return error.ComInitialization;
    defer CoUninitialize();
    var instance: ?*Object = null;
    if (CoCreateInstance(&clsid, null, 1, &iid, &instance) < 0) return error.DialogUnavailable;
    const dialog = instance orelse return error.DialogUnavailable;
    defer release(dialog);
    var flags: u32 = 0;
    if (method(*const fn (*Object, *u32) callconv(.winapi) i32, dialog, 10)(dialog, &flags) < 0) return error.DialogFailed;
    // FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST |
    // FOS_NOCHANGEDIR. Do not add selected paths to the recent list.
    if (method(*const fn (*Object, u32) callconv(.winapi) i32, dialog, 9)(dialog, flags | 0x20 | 0x40 | 0x800 | 0x8 | 0x02000000) < 0) return error.DialogFailed;
    const set_title = method(*const fn (*Object, [*:0]const u16) callconv(.winapi) i32, dialog, 17);
    if (set_title(dialog, std.unicode.wtf8ToWtf16LeStringLiteral("选择桌宠素材文件夹")) < 0) return error.DialogFailed;
    // This is a separate process, not a modal child of the Pulse HWND.
    const status = method(*const fn (*Object, ?*anyopaque) callconv(.winapi) i32, dialog, 3)(dialog, null);
    if (@as(u32, @bitCast(status)) == 0x800704c7) return output("PULSE_FOLDER_CANCELLED");
    if (status < 0) return error.DialogFailed;
    var selected: ?*Object = null;
    if (method(*const fn (*Object, *?*Object) callconv(.winapi) i32, dialog, 20)(dialog, &selected) < 0) return error.DialogFailed;
    const item = selected orelse return error.DialogFailed;
    defer release(item);
    var wide: ?[*:0]u16 = null;
    if (method(*const fn (*Object, u32, *?[*:0]u16) callconv(.winapi) i32, item, 5)(item, 0x80058000, &wide) < 0) return error.DialogFailed;
    const path = wide orelse return error.DialogFailed;
    defer CoTaskMemFree(@ptrCast(path));
    var len: usize = 0;
    while (len < 4096 and path[len] != 0) : (len += 1) {}
    if (len == 0 or len == 4096) return error.InvalidPath;
    var bytes: [4096]u8 = undefined;
    const size = try std.unicode.utf16LeToUtf8(&bytes, path[0..len]);
    try output("PULSE_FOLDER_V1 ");
    try output(bytes[0..size]);
}

pub fn run() c_int {
    pick() catch return 1;
    return 0;
}
