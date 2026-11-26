//! C ABI adapter for the companion's owner-thread decode task.
const std = @import("std");
const Group = @import("runtime_group").Group;
const task = @import("pet_decode_task.zig");

const DecodeFn = *const fn (*anyopaque, u32, u32, u32, *usize) callconv(.c) ?[*]u8;
const NotifyFn = *const fn (*anyopaque) callconv(.c) void;

pub const Result = extern struct {
    kind: u32 = 0,
    outfit: u32 = 0,
    activity: u32 = 0,
    pixels: ?[*]u8 = null,
    bytes: usize = 0,
};

const Context = struct {
    user: *anyopaque,
    decode: DecodeFn,
    notify: NotifyFn,
};

pub const Owner = struct {
    io: std.Io,
    group: *Group,
    context: Context = undefined,
    decoder: ?task.Decoder = null,

    pub fn init(io: std.Io, group: *Group) Owner {
        return .{ .io = io, .group = group };
    }

    pub fn stop(self: *Owner) void {
        if (self.decoder) |*decoder| decoder.stop();
        self.decoder = null;
    }
};

pub const Bridge = extern struct {
    owner: *Owner,
    bind: *const fn (*Owner, *anyopaque, DecodeFn, NotifyFn) callconv(.c) c_int,
    submit: *const fn (*Owner, u32, u32, u32) callconv(.c) c_int,
    start: *const fn (*Owner) callconv(.c) c_int,
    take: *const fn (*Owner, *Result) callconv(.c) c_int,
    invalidate: *const fn (*Owner) callconv(.c) void,
    busy: *const fn (*Owner) callconv(.c) c_int,
    stop: *const fn (*Owner) callconv(.c) void,

    pub fn init(owner: *Owner) Bridge {
        return .{ .owner = owner, .bind = bindTask, .submit = submitTask, .start = startTask, .take = takeTask, .invalidate = invalidateTask, .busy = busyTask, .stop = stopTask };
    }
};

fn wireKind(kind: task.Kind) u32 {
    return switch (kind) {
        .outfit => 0,
        .activity => 1,
    };
}

fn decode(context: *anyopaque, _: std.mem.Allocator, selection: task.Selection) ?[]u8 {
    const ctx: *Context = @ptrCast(@alignCast(context));
    var bytes: usize = 0;
    // The native loader allocates through this same Group's pool.
    const pixels = ctx.decode(ctx.user, wireKind(selection.kind), selection.outfit, selection.activity, &bytes) orelse return null;
    std.debug.assert(bytes != 0);
    return pixels[0..bytes];
}

fn notify(context: *anyopaque) void {
    const ctx: *Context = @ptrCast(@alignCast(context));
    ctx.notify(ctx.user);
}

fn bindTask(owner: *Owner, userdata: *anyopaque, decoder: DecodeFn, notifier: NotifyFn) callconv(.c) c_int {
    if (owner.decoder != null) return 0;
    owner.context = .{ .user = userdata, .decode = decoder, .notify = notifier };
    owner.decoder = task.Decoder.init(owner.io, owner.group, &owner.context, decode, notify);
    return 1;
}

fn submitTask(owner: *Owner, kind: u32, outfit: u32, activity: u32) callconv(.c) c_int {
    const decoder = if (owner.decoder) |*value| value else return 0;
    if (kind > 1 or outfit > 16 or activity > 15) return 0;
    decoder.submit(.{ .kind = if (kind == 0) .outfit else .activity, .outfit = @intCast(outfit), .activity = @intCast(activity) }) catch return 0;
    return 1;
}

// Start only when no future is running. Failure clears the queued intent,
// never falls back to inline decoding on the window thread.
fn startTask(owner: *Owner) callconv(.c) c_int {
    const decoder = if (owner.decoder) |*value| value else return 0;
    if (decoder.slot.running != null) return 0;
    return if (decoder.startNext() catch {
        decoder.invalidate();
        return -1;
    }) 1 else 0;
}

fn takeTask(owner: *Owner, out: *Result) callconv(.c) c_int {
    out.* = .{};
    const decoder = if (owner.decoder) |*value| value else return -1;
    const completed = decoder.join() catch return -1;
    switch (completed) {
        .stale => return 0,
        .failed => |selection| {
            out.* = .{ .kind = wireKind(selection.kind), .outfit = selection.outfit, .activity = selection.activity };
            return 2;
        },
        .ready => |result| {
            out.* = .{ .kind = wireKind(result.selection.kind), .outfit = result.selection.outfit, .activity = result.selection.activity, .pixels = result.bytes.ptr, .bytes = result.bytes.len };
            return 1;
        },
    }
}

fn invalidateTask(owner: *Owner) callconv(.c) void {
    if (owner.decoder) |*decoder| decoder.invalidate();
}

fn busyTask(owner: *Owner) callconv(.c) c_int {
    return if (owner.decoder) |*decoder| @intFromBool(decoder.busy()) else 0;
}

fn stopTask(owner: *Owner) callconv(.c) void {
    owner.stop();
}

const Fixture = struct {
    group: *Group,
    notifications: usize = 0,

    fn load(user: *anyopaque, kind: u32, outfit: u32, activity: u32, bytes: *usize) callconv(.c) ?[*]u8 {
        const self: *Fixture = @ptrCast(@alignCast(user));
        bytes.* = 0;
        if (activity == 15) return null;
        const result = self.group.allocator().alloc(u8, 16) catch return null;
        @memset(result, @intCast(kind * 32 + outfit));
        bytes.* = result.len;
        return result.ptr;
    }

    fn signal(user: *anyopaque) callconv(.c) void {
        const self: *Fixture = @ptrCast(@alignCast(user));
        self.notifications += 1;
    }
};

test "native bridge transfers only latest result with explicit wire codes" {
    var group = Group.init(std.testing.allocator, 64, 1, 1);
    var owner = Owner.init(std.testing.io, &group);
    defer owner.stop();
    var fixture: Fixture = .{ .group = &group };
    const abi = Bridge.init(&owner);
    var result: Result = .{};
    try std.testing.expectEqual(@as(c_int, 0), abi.submit(abi.owner, 0, 0, 0));
    try std.testing.expectEqual(@as(c_int, -1), abi.take(abi.owner, &result));
    try std.testing.expectEqual(@as(c_int, 1), abi.bind(abi.owner, &fixture, Fixture.load, Fixture.signal));
    try std.testing.expectEqual(@as(c_int, 0), abi.bind(abi.owner, &fixture, Fixture.load, Fixture.signal));
    try std.testing.expectEqual(@as(c_int, 0), abi.submit(abi.owner, 2, 0, 0));
    try std.testing.expectEqual(@as(c_int, 0), abi.submit(abi.owner, 0, 17, 0));
    try std.testing.expectEqual(@as(c_int, 0), abi.submit(abi.owner, 1, 0, 16));
    try std.testing.expectEqual(@as(c_int, 1), abi.submit(abi.owner, 0, 1, 0));
    try std.testing.expectEqual(@as(c_int, 1), abi.start(abi.owner));
    try std.testing.expectEqual(@as(c_int, 1), abi.submit(abi.owner, 0, 2, 0));
    try std.testing.expectEqual(@as(c_int, 1), abi.submit(abi.owner, 1, 3, 4));
    try std.testing.expectEqual(@as(c_int, 0), abi.start(abi.owner));
    try std.testing.expectEqual(@as(c_int, 0), abi.take(abi.owner, &result));
    try std.testing.expect(result.pixels == null);
    try std.testing.expectEqual(@as(usize, 0), group.diagnostics().memory.live_bytes);
    try std.testing.expectEqual(@as(c_int, 1), abi.start(abi.owner));
    try std.testing.expectEqual(@as(c_int, 1), abi.take(abi.owner, &result));
    {
        const pixels = result.pixels orelse return error.MissingPixels;
        defer group.allocator().free(pixels[0..result.bytes]);
        try std.testing.expectEqual(@as(u32, 1), result.kind);
        try std.testing.expectEqual(@as(u32, 3), result.outfit);
        try std.testing.expectEqual(@as(u32, 4), result.activity);
        try std.testing.expectEqual(@as(usize, 16), result.bytes);
        try std.testing.expectEqual(@as(u8, 35), pixels[0]);
    }
    try std.testing.expectEqual(@as(usize, 2), fixture.notifications);
    try std.testing.expectEqual(@as(c_int, 0), abi.busy(abi.owner));
    try group.checkDrained();
}

test "native bridge failure cancellation and stop drain all reservations" {
    var group = Group.init(std.testing.allocator, 64, 1, 1);
    var owner = Owner.init(std.testing.io, &group);
    defer owner.stop();
    var fixture: Fixture = .{ .group = &group };
    const abi = Bridge.init(&owner);
    var result: Result = .{};
    try std.testing.expectEqual(@as(c_int, 1), abi.bind(abi.owner, &fixture, Fixture.load, Fixture.signal));
    try std.testing.expectEqual(@as(c_int, 1), abi.submit(abi.owner, 1, 0, 15));
    try std.testing.expectEqual(@as(c_int, 1), abi.start(abi.owner));
    try std.testing.expectEqual(@as(c_int, 2), abi.take(abi.owner, &result));
    try std.testing.expectEqual(@as(u32, 15), result.activity);
    try std.testing.expect(result.pixels == null and result.bytes == 0);
    try std.testing.expectEqual(@as(c_int, 1), abi.submit(abi.owner, 0, 1, 0));
    try std.testing.expectEqual(@as(c_int, 1), abi.start(abi.owner));
    abi.invalidate(abi.owner);
    try std.testing.expectEqual(@as(c_int, 0), abi.take(abi.owner, &result));
    try group.checkDrained();
    try std.testing.expectEqual(@as(c_int, 1), abi.submit(abi.owner, 0, 2, 0));
    try std.testing.expectEqual(@as(c_int, 1), abi.start(abi.owner));
    try std.testing.expectEqual(@as(c_int, 1), abi.submit(abi.owner, 0, 3, 0));
    abi.stop(abi.owner);
    abi.stop(abi.owner);
    try std.testing.expectEqual(@as(c_int, 0), abi.busy(abi.owner));
    try group.checkDrained();
}
