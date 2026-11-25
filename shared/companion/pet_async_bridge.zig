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

fn decode(context: *anyopaque, _: std.mem.Allocator, selection: task.Selection) ?[]u8 {
    const ctx: *Context = @ptrCast(@alignCast(context));
    var bytes: usize = 0;
    // The native loader allocates through this same Group's pool.
    const pixels = ctx.decode(ctx.user, @intFromEnum(selection.kind), selection.outfit, selection.activity, &bytes) orelse return null;
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
            out.* = .{ .kind = @intFromEnum(selection.kind), .outfit = selection.outfit, .activity = selection.activity };
            return 2;
        },
        .ready => |result| {
            out.* = .{ .kind = @intFromEnum(result.selection.kind), .outfit = result.selection.outfit, .activity = result.selection.activity, .pixels = result.bytes.ptr, .bytes = result.bytes.len };
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
