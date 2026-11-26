//! Optional additive Preview 3 interface from Pulse 1.0.61's SDK bundle.
//! pickers.h SHA-256: 103b59a0289caf0096f00e35dc53b6ff6e8759e3c83438b2a463ca855a5fbf46
//! abi.h is byte-identical to the pinned public SDK. Retain the generated
//! old baseline; only the two used function slots are callable here.
const std = @import("std");
const abi = @import("pulse_abi");

pub const name = "pulse.pickers";
pub const version: u32 = 1;
pub const accepted: u32 = 0;
pub const cancelled: u32 = 1;
pub const failed: u32 = 2;

pub const Request = extern struct {
    size: u32 = @sizeOf(Request),
    flags: u32 = 0,
    title: abi.StringView = .{},
    ok_label: abi.StringView = .{},
    initial_path: abi.StringView = .{},
};

pub const Result = extern struct {
    size: u32,
    outcome: u32,
    request_id: u64,
    filter_index: u32,
    path_count: u32,
    paths: [*c]const abi.StringView,
    selected_id: abi.StringView,
    @"error": abi.StringView,
};
pub const Callback = *const fn (?*anyopaque, [*c]const Result) callconv(.c) void;
pub const Table = extern struct {
    size: u32,
    version: u32,
    context: ?*anyopaque,
    open_files: ?*const anyopaque,
    save_file: ?*const anyopaque,
    pick_folders: ?*const fn (?*anyopaque, *const Request, Callback, ?*anyopaque, *u64) callconv(.c) abi.Status,
    quick_pick: ?*const anyopaque,
    cancel: ?*const fn (?*anyopaque, u64) callconv(.c) abi.Status,
};

comptime {
    if (@sizeOf(usize) == 8) {
        std.debug.assert(@sizeOf(Request) == 56);
        std.debug.assert(@sizeOf(Result) == 64);
        std.debug.assert(@offsetOf(Result, "paths") == 24);
        std.debug.assert(@offsetOf(Result, "error") == 48);
        std.debug.assert(@sizeOf(Table) == 56);
        std.debug.assert(@offsetOf(Table, "pick_folders") == 32);
        std.debug.assert(@offsetOf(Table, "cancel") == 48);
    }
}
