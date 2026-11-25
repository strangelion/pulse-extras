//! Windows native companion host seam. One serialized worker owns the
//! controller, process and borrowed wait handle. Never run on the UI thread.
//! No SDK callback registration or automatic restart.
const std = @import("std");
const trust = @import("process/trust.zig");
const behavior = @import("companion/behavior.zig");
const dispatch = @import("companion/native_dispatch.zig");

const Handle = ?*anyopaque;
const Owner = extern struct {
    job: Handle = null,
    process: Handle = null,
    stop: Handle = null,
    state_mapping: Handle = null,
    state_event: Handle = null,
    state_slot: Handle = null,
    generation: u32 = 0,
    reaction: u32 = 0,
};

const Options = extern struct {
    smoke: c_int = 0,
    remember: c_int = 0,
    reduced: c_int = 0,
    topmost: c_int = 0,
    scale: u32 = 100,
};

comptime {
    if (@sizeOf(usize) != 8) @compileError("native companion host requires x64");
    std.debug.assert(@sizeOf(Owner) == 56);
    std.debug.assert(@sizeOf(Options) == 20);
}

extern "c" fn pet_child_start(*Owner, [*:0]const u16, *const Options) c_int;
extern "c" fn pet_child_publish(*Owner, u32) c_int;
extern "c" fn pet_child_status(*const Owner, *c_int, *u32) c_int;
extern "c" fn pet_child_stop(*Owner, u32, *c_int, *u32) c_int;
extern "c" fn pet_child_abandon(*Owner) void;

pub const Error = error{ Invalid, Busy, OsError, ContainmentFailed, Timeout };
fn check(status: c_int) Error!void {
    return switch (status) {
        0 => {},
        1 => error.Invalid,
        2 => error.Busy,
        3 => error.OsError,
        4 => error.ContainmentFailed,
        5 => error.Timeout,
        else => error.OsError,
    };
}

pub const Config = struct {
    remember: bool = false,
    reduced: bool = false,
    topmost: bool = false,
    scale: u32 = 100,
};

pub const Exit = struct { code: u32, forced: bool };
pub const Step = union(enum) { idle, admitted, exited: Exit, disconnected };

pub const Host = struct {
    owner: Owner = .{},
    controller: dispatch.Controller = .{},

    /// The caller must independently approve the expected hash and install
    /// root ACLs; never derive approval from an untrusted executable itself.
    /// A pathname hash check plus pin-on-launch is not race-free authentication.
    pub fn start(self: *Host, io: std.Io, approval: trust.Approval, now: u64, config: Config) !void {
        try self.startInternal(io, approval, now, .{
            .remember = @intFromBool(config.remember),
            .reduced = @intFromBool(config.reduced),
            .topmost = @intFromBool(config.topmost),
            .scale = config.scale,
        });
    }

    fn startInternal(self: *Host, io: std.Io, approval: trust.Approval, now: u64, options: Options) !void {
        if (self.owner.job != null) return error.Busy;
        if (options.scale < 50 or options.scale > 200) return error.Invalid;
        if (now < self.controller.scheduler.last_time) return error.ClockRegression;
        try approval.verify(io, approval.path);
        var path: [1024]u16 = undefined;
        const len = try std.unicode.utf8ToUtf16Le(path[0 .. path.len - 1], approval.path);
        path[len] = 0;
        try check(pet_child_start(&self.owner, path[0..len :0], &options));
        errdefer pet_child_abandon(&self.owner);
        try self.controller.setAvailable(now, true);
    }

    pub fn observe(self: *Host, now: u64, event: behavior.Event) behavior.EventError!void {
        try self.controller.observe(now, event);
    }

    fn publish(context: *anyopaque, code: u32) bool {
        const owner: *Owner = @ptrCast(@alignCast(context));
        return pet_child_publish(owner, code) == 0;
    }

    /// Call after input, deadline or borrowed process-handle signal. No
    /// automatic relaunch. Ambiguous publication disables the channel and
    /// requests job cleanup; no claimed render acknowledgement.
    pub fn pump(self: *Host, now: u64) !Step {
        if (now < self.controller.scheduler.last_time) return error.ClockRegression;
        if (self.owner.job == null) return .idle;
        var running: c_int = 0;
        var exit_code: u32 = 0;
        check(pet_child_status(&self.owner, &running, &exit_code)) catch |err| {
            self.abandon();
            return err;
        };
        if (running == 0) {
            try self.controller.setAvailable(now, false);
            return .{ .exited = (try self.stop(0)).? };
        }
        return switch (try self.controller.pump(now, .{ .context = &self.owner, .publish = publish })) {
            .idle => .idle,
            .admitted => .admitted,
            .disconnected => blk: {
                self.abandon();
                break :blk .disconnected;
            },
        };
    }

    /// Borrowed handle for the owner's wait set, valid only until stop or
    /// abandon. Do not close, duplicate, or wait on it after owner release.
    pub fn processWaitHandle(self: *const Host) Handle {
        return self.owner.process;
    }

    pub fn nextWake(self: *Host, now: u64) behavior.EventError!?u64 {
        return self.controller.nextWake(now);
    }

    /// Clear pending events before stopping. On a failed stop the job is
    /// still owned, dispatch disabled; caller may retry stop or abandon.
    pub fn stop(self: *Host, grace_ms: u32) !?Exit {
        if (grace_ms > 5000) return error.Invalid;
        try self.controller.reset(self.controller.scheduler.last_time);
        if (self.owner.job == null) return null;
        var forced: c_int = 0;
        var code: u32 = 0;
        try check(pet_child_stop(&self.owner, grace_ms, &forced, &code));
        return .{ .code = code, .forced = forced != 0 };
    }

    /// Last-resort nonblocking cleanup; no claim of confirmed termination.
    pub fn abandon(self: *Host) void {
        self.controller.reset(self.controller.scheduler.last_time) catch unreachable;
        pet_child_abandon(&self.owner);
    }
};

extern "c" fn pet_host_fixture_path([*]u8, u32) u32;
extern "c" fn pet_host_fixture_wait(Handle, u32) c_int;

test "approved native host delivers scheduler state to actual hidden demo" {
    const io = std.testing.io;
    var path: [4096]u8 = undefined;
    const len = pet_host_fixture_path(&path, path.len);
    try std.testing.expect(len > 0 and len < path.len);
    const name = path[0..len];
    const file = try std.Io.Dir.openFileAbsolute(io, name, .{ .follow_symlinks = false });
    const digest = blk: {
        defer file.close(io);
        break :blk try trust.digestFile(io, file);
    };
    var host: Host = .{};
    defer host.abandon();
    var wrong = digest;
    wrong[0] ^= 1;
    try std.testing.expectError(error.UnapprovedExecutable, host.startInternal(io, .{ .path = name, .digest = wrong }, 0, .{ .smoke = 1 }));
    try std.testing.expect(host.processWaitHandle() == null);
    // CI-generated executable in an isolated runner is the test approval.
    try host.startInternal(io, .{ .path = name, .digest = digest }, 0, .{ .smoke = 1 });
    try host.observe(0, .{ .begin = .{ .id = 1, .activity = .testing } });
    try std.testing.expectEqual(std.meta.Tag(Step).admitted, std.meta.activeTag(try host.pump(0)));
    try std.testing.expectEqual(@as(u32, 5), host.owner.reaction);
    try std.testing.expectEqual(@as(c_int, 1), pet_host_fixture_wait(host.processWaitHandle(), 10000));
    const result = try host.pump(1000);
    try std.testing.expectEqual(std.meta.Tag(Step).exited, std.meta.activeTag(result));
    try std.testing.expectEqual(@as(u32, 0), result.exited.code);
    try std.testing.expect(!result.exited.forced);
    try std.testing.expect(host.processWaitHandle() == null);
    try std.testing.expectEqual(@as(?u64, null), try host.nextWake(1000));
    try std.testing.expect((try host.stop(0)) == null);
}

test "native status mapping rejects unknown result codes" {
    try std.testing.expectError(error.ContainmentFailed, check(4));
    try std.testing.expectError(error.OsError, check(99));
}
