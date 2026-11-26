//! Experimental Windows worker adapter. No automatic discovery or startup.
const std = @import("std");
const protocol = @import("openpets_protocol.zig");

const Handle = ?*anyopaque;
const Pipe = extern struct {
    handle: Handle = null,
};

extern "c" fn op_bridge_now() u64;
extern "c" fn op_bridge_discovery([*:0]const u16, [*]u8, u32, *u32, u64, Handle) c_int;
extern "c" fn op_bridge_connect(*Pipe, [*]const u8, u32, u32, [*:0]const u16, u64, Handle) c_int;
extern "c" fn op_pipe_read(*Pipe, [*]u8, u32, *u32, u64, Handle) c_int;
extern "c" fn op_pipe_write(*Pipe, [*]const u8, u32, *u32, u64, Handle) c_int;
extern "c" fn op_pipe_close(*Pipe) void;

fn check(result: c_int) protocol.TransportError!void {
    return switch (result) {
        0 => {},
        1 => error.Unavailable,
        2 => error.Untrusted,
        3 => error.TimedOut,
        4 => error.Canceled,
        else => error.IoFailure,
    };
}

/// Borrow approved, NUL-terminated UTF-16 paths and an optional manual-reset
/// cancellation event for the duration of one worker-only probe. Paths must
/// come from independent user approval, never discovery or environment.
/// No shared adapter/pipe between simultaneous probes.
pub const Config = struct {
    directory: [*:0]const u16,
    image: [*:0]const u16,
    cancel: Handle = null,
};

const Adapter = struct {
    config: Config,
    pipe: Pipe = .{},

    fn fromContext(ctx: *anyopaque) *Adapter {
        return @ptrCast(@alignCast(ctx));
    }

    fn now(_: *anyopaque) u64 {
        return op_bridge_now();
    }

    fn discovery(ctx: *anyopaque, bytes: []u8, deadline: u64) protocol.TransportError!usize {
        const self = fromContext(ctx);
        if (bytes.len > protocol.max_message_bytes) return error.IoFailure;
        var count: u32 = 0;
        try check(op_bridge_discovery(self.config.directory, bytes.ptr, @intCast(bytes.len), &count, deadline, self.config.cancel));
        return count;
    }

    fn connect(ctx: *anyopaque, endpoint: []const u8, pid: u32, deadline: u64) protocol.TransportError!void {
        const self = fromContext(ctx);
        if (endpoint.len > protocol.max_endpoint_bytes) return error.Untrusted;
        try check(op_bridge_connect(&self.pipe, endpoint.ptr, @intCast(endpoint.len), pid, self.config.image, deadline, self.config.cancel));
    }

    fn write(ctx: *anyopaque, bytes: []const u8, deadline: u64) protocol.TransportError!usize {
        const self = fromContext(ctx);
        if (bytes.len > protocol.max_message_bytes) return error.IoFailure;
        var count: u32 = 0;
        try check(op_pipe_write(&self.pipe, bytes.ptr, @intCast(bytes.len), &count, deadline, self.config.cancel));
        return count;
    }

    fn read(ctx: *anyopaque, bytes: []u8, deadline: u64) protocol.TransportError!usize {
        const self = fromContext(ctx);
        if (bytes.len > protocol.max_message_bytes) return error.IoFailure;
        var count: u32 = 0;
        try check(op_pipe_read(&self.pipe, bytes.ptr, @intCast(bytes.len), &count, deadline, self.config.cancel));
        return count;
    }

    fn close(ctx: *anyopaque) void {
        op_pipe_close(&fromContext(ctx).pipe);
    }

    fn transport(self: *Adapter) protocol.ProbeTransport {
        return .{
            .context = self,
            .now_ms = now,
            .read_trusted_discovery = discovery,
            .connect_verified = connect,
            .write = write,
            .read = read,
            .close = close,
        };
    }
};

pub fn probe(config: Config, workspace: *protocol.ProbeWorkspace, id: []const u8, kind: protocol.ProbeKind) protocol.ProbeError!protocol.Response {
    var adapter: Adapter = .{ .config = config };
    defer op_pipe_close(&adapter.pipe);
    return protocol.probe(adapter.transport(), workspace, id, kind);
}

const FixtureCallback = *const fn ([*:0]const u16, [*:0]const u16, Handle) callconv(.c) c_int;
extern "c" fn op_bridge_fixture(FixtureCallback) c_int;

fn fixtureProbe(directory: [*:0]const u16, image: [*:0]const u16, cancel: Handle) callconv(.c) c_int {
    var workspace: protocol.ProbeWorkspace = undefined;
    const result = probe(.{ .directory = directory, .image = image, .cancel = cancel }, &workspace, "bridge-1", .hello) catch |err| {
        if (err == error.Canceled) return 2;
        if (err == error.Untrusted) return 3;
        return 1;
    };
    return if (result == .hello) 0 else 1;
}

test "Windows adapter uses trusted file and real kernel pipe end to end" {
    try std.testing.expectEqual(@as(c_int, 0), op_bridge_fixture(fixtureProbe));
}

test "Windows adapter maps only closed error categories" {
    try std.testing.expectError(error.Untrusted, check(2));
    try std.testing.expectError(error.Canceled, check(4));
    try std.testing.expectError(error.IoFailure, check(999));
}
