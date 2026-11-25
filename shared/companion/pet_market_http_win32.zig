//! Synchronous WinHTTP adapter; execute only on an owned download worker.
//! All C callbacks return before get returns. No cross-thread close.
const std = @import("std");
const download = @import("pet_market_download.zig");

const HeaderFn = *const fn (*anyopaque, u64) callconv(.c) c_int;
const ChunkFn = *const fn (*anyopaque, [*]const u8, usize) callconv(.c) c_int;
const CancelFn = *const fn (*anyopaque) callconv(.c) c_int;

extern "c" fn pet_market_http_get(kind: c_uint, url: [*]const u8, length: usize, cap: usize, ctx: *anyopaque, headers: HeaderFn, chunk: ChunkFn, canceled: CancelFn, os_error: *u32) c_int;
extern "c" fn pet_market_http_valid(kind: c_uint, url: [*]const u8, length: usize) c_int;

const Context = struct {
    sink: *download.Sink,
    failure: ?anyerror = null,

    fn header(ctx: *anyopaque, length: u64) callconv(.c) c_int {
        const self: *Context = @ptrCast(@alignCast(ctx));
        const expected = if (length == 0) null else std.math.cast(usize, length) orelse {
            self.failure = error.ResourceLimit;
            return 0;
        };
        self.sink.headers(expected) catch |err| {
            self.failure = err;
            return 0;
        };
        return 1;
    }

    fn chunk(ctx: *anyopaque, data: [*]const u8, size: usize) callconv(.c) c_int {
        const self: *Context = @ptrCast(@alignCast(ctx));
        self.sink.append(data[0..size]) catch |err| {
            self.failure = err;
            return 0;
        };
        return 1;
    }

    fn canceled(ctx: *anyopaque) callconv(.c) c_int {
        const self: *Context = @ptrCast(@alignCast(ctx));
        return @intFromBool(self.sink.control.canceled.load(.acquire));
    }
};

pub const Transport = struct {
    last_os_error: u32 = 0,

    pub fn get(self: *Transport, kind: download.Kind, url: []const u8, sink: *download.Sink) !void {
        if (!download.validUrl(kind, url)) return error.InvalidUrl;
        var context: Context = .{ .sink = sink };
        const code = pet_market_http_get(@backingInt(kind), url.ptr, url.len, sink.cap, &context, Context.header, Context.chunk, Context.canceled, &self.last_os_error);
        if (code == 6) return error.CleanupFailed;
        if (context.failure) |err| return err;
        return switch (code) {
            0 => {},
            1 => error.InvalidUrl,
            2 => error.NetworkFailed,
            3 => error.InvalidResponse,
            4 => error.Canceled,
            5 => error.ResourceLimit,
            else => error.NetworkFailed,
        };
    }
};

test "native policy matches Zig and canceled transport never connects" {
    const cases = [_]struct { kind: download.Kind, url: []const u8 }{
        .{ .kind = .index, .url = "https://openpets.dev/pets/catalog.v3.json" },
        .{ .kind = .catalog, .url = "https://openpets.dev/pets/catalog.v3/page-000.json" },
        .{ .kind = .zip, .url = "https://zip.openpets.dev/pets/cat/asset.zip" },
        .{ .kind = .zip, .url = "https://zip.openpets.dev/pets/../bad.zip" },
        .{ .kind = .zip, .url = "https://zip.openpets.dev.evil.test/pets/a.zip" },
        .{ .kind = .preview, .url = "https://openpets.dev/pets/cat/p.svg" },
        .{ .kind = .preview, .url = "https://openpets.dev/pets/cat/p.webp" },
    };
    for (cases) |item| {
        try std.testing.expectEqual(download.validUrl(item.kind, item.url), pet_market_http_valid(@backingInt(item.kind), item.url.ptr, item.url.len) != 0);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = @import("runtime_temp_store").Store.init(std.testing.io, tmp.dir, 1024);
    var control: download.Control = .{};
    control.cancel();
    var transport: Transport = .{};
    try std.testing.expectError(error.Canceled, download.fetch(&store, &transport, .index, cases[0].url, &control));
    try store.checkDrained();
    var sink: download.Sink = .{ .store = &store, .control = &control, .id = 0, .cap = 1024 };
    try std.testing.expectError(error.Canceled, transport.get(.index, cases[0].url, &sink));
}
