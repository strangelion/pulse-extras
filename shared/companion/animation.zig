//! Classic sprite timeline. Integer-only sampling, no frame queue or timer.
//! Timing and reaction mapping follow the pinned upstream animation.ts.
const std = @import("std");
const assets = @import("pet_assets.zig");
const wire = @import("openpets_protocol.zig");

pub const State = enum { idle, running_right, running_left, waving, jumping, failed, waiting, running, review };
pub const Definition = struct { row: u32, frames: u32, duration: u64, loops: ?u64 = null };

pub fn definition(state: State) Definition {
    return switch (state) {
        .idle => .{ .row = 0, .frames = 6, .duration = 5500 },
        .running_right => .{ .row = 1, .frames = 8, .duration = 1060 },
        .running_left => .{ .row = 2, .frames = 8, .duration = 1060 },
        .waving => .{ .row = 3, .frames = 4, .duration = 700, .loops = 2 },
        .jumping => .{ .row = 4, .frames = 5, .duration = 840, .loops = 2 },
        .failed => .{ .row = 5, .frames = 8, .duration = 1220, .loops = 2 },
        .waiting => .{ .row = 6, .frames = 6, .duration = 1010 },
        .running => .{ .row = 7, .frames = 6, .duration = 820 },
        .review => .{ .row = 8, .frames = 6, .duration = 1030 },
    };
}

pub fn forReaction(value: wire.Reaction) State {
    return switch (value) {
        .idle => .idle,
        .thinking => .review,
        .working, .editing, .running => .running,
        .testing, .waiting => .waiting,
        .waving => .waving,
        .success, .celebrating => .jumping,
        .@"error" => .failed,
    };
}

pub const Rect = struct { x: u32, y: u32, width: u32 = assets.frame_width, height: u32 = assets.frame_height };

pub fn frameRect(layout: assets.Layout, row: u32, column: u32) error{InvalidFrame}!Rect {
    if (row >= layout.rows() or column >= assets.columns) return error.InvalidFrame;
    return .{ .x = column * assets.frame_width, .y = row * assets.frame_height };
}

pub const Sample = struct {
    row: u32,
    column: u32,
    // Relative time until the next different frame; null for a static pose.
    next_in: ?u64,
};

/// Constant-time sampling even after a long suspend. Finite animations
/// fall through to idle at their exact end, not to an empty atlas cell.
pub fn sample(layout: assets.Layout, state: State, elapsed: u64, reduced_motion: bool) Sample {
    if (reduced_motion) return .{ .row = 0, .column = if (layout == .v2) 6 else 0, .next_in = null };
    var current = definition(state);
    var time = elapsed;
    if (current.loops) |loops| {
        const end = current.duration * loops;
        if (time >= end) {
            time -= end;
            current = definition(.idle);
        }
    }
    const phase = time % current.duration;
    const frames: u64 = current.frames;
    const index = phase * frames / current.duration;
    const boundary = ((index + 1) * current.duration + frames - 1) / frames;
    return .{ .row = current.row, .column = @intCast(index), .next_in = boundary - phase };
}

pub const Player = struct {
    state: State = .idle,
    started: u64 = 0,
    last: u64 = 0,
    visible: bool = false,
    reduced_motion: bool = false,

    fn advance(self: *Player, now: u64) error{ClockRegression}!void {
        if (now < self.last) return error.ClockRegression;
        self.last = now;
    }

    /// Repeated/mapped-equivalent reactions do not restart a timeline.
    /// An explicit restart is required to replay the same finite event.
    pub fn select(self: *Player, now: u64, value: wire.Reaction, restart: bool) error{ClockRegression}!void {
        try self.advance(now);
        const next = forReaction(value);
        if (next != self.state or restart) {
            self.state = next;
            self.started = now;
        }
    }

    /// Hidden windows have no frame wake-ups. On show, resume continuous
    /// animations from the current monotonic timeline; expired one-shots
    /// are not replayed. Reduced motion renders only the neutral pose.
    pub fn setVisible(self: *Player, now: u64, visible: bool) error{ClockRegression}!void {
        try self.advance(now);
        self.visible = visible;
    }

    pub fn setReducedMotion(self: *Player, now: u64, enabled: bool) error{ClockRegression}!void {
        try self.advance(now);
        self.reduced_motion = enabled;
    }

    pub fn current(self: *Player, layout: assets.Layout, now: u64) error{ClockRegression}!?Sample {
        try self.advance(now);
        if (!self.visible) return null;
        return sample(layout, self.state, now - self.started, self.reduced_motion);
    }
};

const t = std.testing;

test "classic rows and mapped reactions match the pinned layout" {
    try t.expectEqual(State.running, forReaction(.editing));
    try t.expectEqual(State.waiting, forReaction(.testing));
    try t.expectEqual(State.review, forReaction(.thinking));
    const rect = try frameRect(.v2, 10, 7);
    try t.expectEqual(@as(u32, 1344), rect.x);
    try t.expectEqual(@as(u32, 2080), rect.y);
    try t.expectError(error.InvalidFrame, frameRect(.v1, 9, 0));
    try t.expectError(error.InvalidFrame, frameRect(.v2, 0, 8));
}

test "frame boundaries never produce invalid cells or zero intervals" {
    for (std.enums.values(State)) |state| {
        const def = definition(state);
        for (0..def.duration) |elapsed| {
            const point = sample(.v1, state, elapsed, false);
            try t.expect(point.column < def.frames);
            try t.expect(point.next_in.? > 0);
            const next = sample(.v1, state, elapsed + point.next_in.?, false);
            try t.expect(next.column != point.column or next.row != point.row);
        }
    }
    const huge = sample(.v2, .running, std.math.maxInt(u64), false);
    try t.expect(huge.column < 6);
}

test "finite animations fall through to idle and neutral pose is static" {
    try t.expectEqual(@as(u32, 4), sample(.v2, .jumping, 1679, false).row);
    try t.expectEqual(@as(u32, 0), sample(.v2, .jumping, 1680, false).row);
    try t.expectEqual(@as(u32, 6), sample(.v2, .failed, 0, true).column);
    try t.expectEqual(@as(u32, 0), sample(.v1, .failed, 0, true).column);
    try t.expect(sample(.v2, .failed, 0, true).next_in == null);
}

test "hidden player does not wake or replay expired animation" {
    var player: Player = .{};
    try player.select(100, .success, false);
    try t.expect((try player.current(.v2, 101)) == null);
    try player.setVisible(2000, true);
    try t.expectEqual(@as(u32, 0), (try player.current(.v2, 2000)).?.row);
    try player.select(2001, .success, false);
    try t.expectEqual(@as(u32, 0), (try player.current(.v2, 2001)).?.row);
    try player.select(2002, .success, true);
    try t.expectEqual(@as(u32, 4), (try player.current(.v2, 2002)).?.row);
    try player.setReducedMotion(2003, true);
    try t.expect((try player.current(.v2, 2003)).?.next_in == null);
    try t.expectError(error.ClockRegression, player.current(.v2, 1));
}
