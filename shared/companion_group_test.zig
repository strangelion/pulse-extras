//! Native Windows integration test root; not imported by the extension DLL.
const std = @import("std");
const adapter = @import("companion_group.zig");
const model = @import("companion/pet_manager.zig");
const trust = @import("process/trust.zig");
const Group = adapter.Group;
const TickResult = adapter.TickResult;
const max_tick_slots = adapter.max_tick_slots;
const Drain = adapter.Drain;

extern "c" fn pet_host_fixture_path([*]u8, u32) u32;
extern "c" fn pet_host_fixture_sleep(u32) void;

fn waitReap(group: *Group, id: u64) !u32 {
    for (0..200) |_| {
        if (try group.reap(id)) |code| return code;
        pet_host_fixture_sleep(25);
    }
    return error.Timeout;
}

test "group adapter binds two approved demo children and recovers reservations" {
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
    const approval: trust.Approval = .{ .path = name, .digest = digest };
    var group: Group = .{};
    try group.open(model.max_configured_instances, model.child_commit_ceiling * 2);
    var ids: [2]u64 = @splat(0);
    defer {
        for (ids) |id| {
            if (id == 0) continue;
            group.stop(id, true) catch {};
            _ = waitReap(&group, id) catch {};
        }
        group.close() catch {};
    }
    var wrong = approval;
    wrong.digest[0] ^= 1;
    try std.testing.expectError(error.UnapprovedExecutable, group.startSmokeFixture(io, wrong, 1));
    try std.testing.expectEqual(@as(usize, 0), try group.remaining());
    for (&ids) |*id| {
        const started = try group.startSmokeFixture(io, approval, 1);
        id.* = started.id;
        try std.testing.expect(started.failure == null);
        try group.publish(id.*, 5); // Required testing reaction for hidden smoke.
    }
    try std.testing.expect(ids[0] != ids[1]);
    try std.testing.expectError(error.BudgetExceeded, group.startSmokeFixture(io, approval, 1));
    var rows: [2]model.Instance = undefined;
    try std.testing.expectEqual(@as(usize, 2), try group.snapshot(0, &rows));
    try std.testing.expectEqual(model.State.starting, rows[0].state);
    try std.testing.expectError(error.Busy, group.close());
    var empty: [0]TickResult = .{};
    try std.testing.expectError(error.Invalid, group.tick(&empty));
    var tick_results: [max_tick_slots]TickResult = undefined;
    // Each active ID is observed even with many empty physical slots.
    const observed = try group.tick(&tick_results);
    try std.testing.expectEqual(@as(usize, 2), observed);
    for (tick_results[0..observed], 0..) |result, i| {
        try std.testing.expectEqual(ids[i], result.id);
        try std.testing.expect(result.failure == null);
        if (result.exit_code) |code| {
            try std.testing.expectEqual(@as(u32, 0), code);
            ids[i] = 0;
        }
    }
    // Smoke can exit quickly; assert acknowledgment on a separate native
    // fixture below rather than relying on a scheduler-sensitive poll here.
    for (&ids) |*id| {
        if (id.* == 0) continue;
        try std.testing.expectEqual(@as(u32, 0), try waitReap(&group, id.*));
        id.* = 0;
    }
    try std.testing.expectEqual(@as(usize, 0), try group.snapshot(0, &rows));
    const last = try group.startSmokeFixture(io, approval, 1);
    ids[0] = last.id;
    try std.testing.expect(last.failure == null);
    try group.publish(last.id, 5);
    try group.beginDrain(false);
    try std.testing.expectError(error.Draining, group.startSmokeFixture(io, approval, 1));
    try std.testing.expectError(error.Busy, group.close());
    // Walk the physical ring without losing a child when occupied rows shift.
    for (0..200) |_| {
        const n = try group.tick(&tick_results);
        for (tick_results[0..n]) |result| {
            try std.testing.expectEqual(last.id, result.id);
            try std.testing.expect(result.failure == null);
            if (result.exit_code != null) ids[0] = 0;
        }
        if (try group.remaining() == 0) break;
        pet_host_fixture_sleep(25);
    }
    try std.testing.expectEqual(@as(usize, 0), try group.remaining());
    try std.testing.expectEqual(@as(u64, 0), ids[0]);
    try group.close();
    try group.open(2, model.child_commit_ceiling * 2);
    try std.testing.expectEqual(Drain.normal, group.drain);
    try group.beginDrain(true);
    try group.beginDrain(false);
    try std.testing.expectEqual(Drain.force, group.drain);
}
