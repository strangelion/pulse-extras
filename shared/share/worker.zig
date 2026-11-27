//! One supervised worker per local copy. The parent alone publishes files.
//! These exports are private to the linked C worker; not a public Pulse ABI.

const std = @import("std");
const transfer = @import("transfer.zig");

var current: ?transfer.Receive = null;

extern "c" fn share_worker_run() c_int;

export fn share_receive_begin(size: u64, expected: *const transfer.Digest) callconv(.c) c_int {
    if (current != null) return 0;
    current = transfer.Receive.init(size, expected.*) catch return 0;
    if (current) |*state| {
        state.approve(true) catch return 0;
        return 1;
    }
    return 0;
}

export fn share_receive_chunk(offset: u64, bytes: [*]const u8, len: u32) callconv(.c) c_int {
    if (len == 0 or len > transfer.max_chunk_bytes) return 0;
    if (current) |*state| {
        state.staged(offset, bytes[0..len]) catch return 0;
        return 1;
    }
    return 0;
}

export fn share_receive_verify() callconv(.c) c_int {
    if (current) |*state| {
        state.verify() catch return 0;
        return 1;
    }
    return 0;
}

pub fn main(_: std.process.Init) !void {
    if (share_worker_run() != 0) return error.ShareWorkerFailed;
}
