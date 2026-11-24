//! Opt-in diagnostics for host test runs.
//!
//! Nothing is written unless the `ABI_PROBE_LOG` environment variable names a
//! file. Lines are appended with `FILE_APPEND_DATA`, which makes each write land
//! atomically at end-of-file, so several host processes can share one log
//! without losing entries. Production packages never set the variable.

const std = @import("std");
const builtin = @import("builtin");

pub const env_var = "ABI_PROBE_LOG";

/// Appends `"<name> tid=<thread>\n"`.
pub fn event(name: []const u8) void {
    if (comptime builtin.os.tag != .windows) return;
    var buffer: [128]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s} tid={d}\n", .{ name, std.Thread.getCurrentId() }) catch return;
    append(line);
}

/// Appends `"<name>=<value> tid=<thread>\n"`.
pub fn status(name: []const u8, value: anytype) void {
    if (comptime builtin.os.tag != .windows) return;
    var buffer: [160]u8 = undefined;
    const line = std.fmt.bufPrint(&buffer, "{s}={d} tid={d}\n", .{ name, value, std.Thread.getCurrentId() }) catch return;
    append(line);
}

fn append(line: []const u8) void {
    const env = std.process.Environ{ .block = .global };
    const path = env.getWindows(std.unicode.wtf8ToWtf16LeStringLiteral(env_var)) orelse return;
    const handle = CreateFileW(
        path.ptr,
        FILE_APPEND_DATA,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_ALWAYS,
        FILE_ATTRIBUTE_NORMAL,
        null,
    );
    if (handle == invalid_handle) return;
    defer _ = CloseHandle(handle);
    var written: u32 = 0;
    _ = WriteFile(handle, line.ptr, @intCast(line.len), &written, null);
}

const invalid_handle = @as(usize, @bitCast(@as(isize, -1)));

const FILE_APPEND_DATA: u32 = 0x0000_0004;
const FILE_SHARE_READ: u32 = 0x0000_0001;
const FILE_SHARE_WRITE: u32 = 0x0000_0002;
const OPEN_ALWAYS: u32 = 4;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x0000_0080;

extern "kernel32" fn CreateFileW(
    file_name: [*:0]const u16,
    desired_access: u32,
    share_mode: u32,
    security_attributes: ?*anyopaque,
    creation_disposition: u32,
    flags_and_attributes: u32,
    template_file: ?*anyopaque,
) callconv(.winapi) usize;

extern "kernel32" fn WriteFile(
    file: usize,
    buffer: [*]const u8,
    bytes_to_write: u32,
    bytes_written: ?*u32,
    overlapped: ?*anyopaque,
) callconv(.winapi) i32;

extern "kernel32" fn CloseHandle(handle: usize) callconv(.winapi) i32;

test "line formats the thread id" {
    var buffer: [64]u8 = undefined;
    const line = try std.fmt.bufPrint(&buffer, "{s} tid={d}\n", .{ "entry", @as(u64, 42) });
    try std.testing.expectEqualStrings("entry tid=42\n", line);
}
