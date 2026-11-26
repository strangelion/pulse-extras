//! Bounded parallel transfer owner. No detached jobs or inline fallback.
//! Keep owner at a stable address until drained. Only the dispatcher calls
//! methods; workers own their slot's Store and Transport until joined.
//! Scratch directory is approved/private and exclusive to this owner.
const std = @import("std");
const download = @import("pet_market_download.zig");
const Store = @import("runtime_temp_store").Store;
const Group = @import("runtime_group").Group;

pub fn Tasks(comptime Transport: type) type {
    return TasksMode(Transport, false);
}

// The host already supplies a dedicated worker. Inline mode keeps all host
// cancellation callbacks on that worker; it is never used on the UI thread.
pub fn TasksMode(comptime Transport: type, comptime inline_work: bool) type {
    return struct {
        const Self = @This();
        const Outcome = anyerror!download.Result;
        const State = enum { idle, running, joined };
        const Slot = struct {
            state: State = .idle,
            id: u64 = 0,
            kind: download.Kind = .index,
            url: [2048]u8 = undefined,
            url_len: usize = 0,
            control: download.Control = .{},
            done: std.atomic.Value(bool) = .init(false),
            store: Store = undefined,
            transport: Transport = undefined,
            future: ?std.Io.Future(Outcome) = null,
            outcome: ?Outcome = null,

            fn run(slot: *Slot) Outcome {
                defer slot.done.store(true, .release);
                return download.fetch(&slot.store, &slot.transport, slot.kind, slot.url[0..slot.url_len], &slot.control);
            }
        };

        pub const Progress = struct {
            received: usize,
            expected: usize,
            finished: bool,
            canceled: bool,
        };

        io: std.Io,
        scratch: std.Io.Dir,
        group: *Group,
        pool: download.Pool = .{},
        accepting: bool = true,
        slots: [17]Slot = @splat(.{}),

        pub fn init(io: std.Io, scratch: std.Io.Dir, group: *Group) Self {
            return .{ .io = io, .scratch = scratch, .group = group };
        }

        fn find(self: *Self, id: u64) !*Slot {
            for (&self.slots) |*slot| {
                if (slot.state != .idle and slot.id == id) return slot;
            }
            return error.NotOwned;
        }

        /// Admission is nonblocking: backpressure preserves the caller's
        /// request. Each worker uses one unique exclusive temporary filename.
        /// The dispatcher must not move/copy this owner after a successful start.
        pub fn start(self: *Self, kind: download.Kind, url: []const u8, transport: Transport) !u64 {
            if (!self.accepting) return error.Stopped;
            if (!download.validUrl(kind, url) or url.len > 2048) return error.InvalidUrl;
            const id = try self.pool.acquire(kind);
            errdefer self.pool.release(id) catch unreachable;
            try self.group.reserveRunning();
            errdefer self.group.releaseRunning();
            for (&self.slots) |*slot| {
                if (slot.state != .idle) continue;
                slot.* = .{
                    .state = .running,
                    .id = id,
                    .kind = kind,
                    .url_len = url.len,
                    .store = Store.init(self.io, self.scratch, download.limit(kind)),
                    .transport = transport,
                };
                // fetch creates exactly one file. Distinct monotonic lease
                // IDs prevent collisions between workers. Existing files
                // from older sessions are refused, never overwritten.
                slot.store.next_id = id;
                @memcpy(slot.url[0..url.len], url);
                errdefer slot.* = .{};
                if (inline_work) {
                    slot.outcome = Slot.run(slot);
                    slot.state = .joined;
                    self.group.releaseRunning();
                } else {
                    slot.future = try self.io.concurrent(Slot.run, .{slot});
                }
                return id;
            }
            return error.ResourceLimit;
        }

        pub fn progress(self: *Self, id: u64) !Progress {
            const slot = try self.find(id);
            return .{
                .received = slot.control.received.load(.acquire),
                .expected = slot.control.expected.load(.acquire),
                .finished = slot.done.load(.acquire),
                .canceled = slot.control.canceled.load(.acquire),
            };
        }

        pub fn cancel(self: *Self, id: u64) !void {
            const slot = try self.find(id);
            slot.control.cancel();
        }

        /// Worker join may block; use the dispatcher, never the UI thread.
        /// Once joined, successful file is borrowed until release. Transport
        /// errors are retained so cleanup cannot silently turn failure into success.
        pub fn join(self: *Self, id: u64) !download.Result {
            const slot = try self.find(id);
            if (slot.state == .running) {
                const future = if (slot.future) |*value| value else unreachable;
                slot.outcome = future.await(self.io);
                slot.future = null;
                slot.state = .joined;
                self.group.releaseRunning();
            }
            return slot.outcome orelse unreachable;
        }

        /// All borrowers must stop before release. Keep the lease on file
        /// cleanup failure, or unconfirmed native transport cleanup.
        pub fn release(self: *Self, id: u64) !void {
            const slot = try self.find(id);
            if (slot.state != .joined) return error.Busy;
            try slot.store.cleanup();
            try slot.store.checkDrained();
            if (slot.outcome) |outcome| {
                if (outcome) |_| {} else |err| {
                    if (err == error.TransportCleanupFailed) return error.TransportCleanupFailed;
                }
            }
            try self.pool.release(id);
            slot.* = .{};
        }

        pub fn requestStop(self: *Self) void {
            self.accepting = false;
            for (&self.slots) |*slot| {
                if (slot.state == .running) slot.control.cancel();
            }
        }

        /// Call only after external file borrowers have stopped. Join every
        /// worker even on failure, retain failed cleanup slots for recovery.
        pub fn shutdown(self: *Self) !void {
            self.requestStop();
            var failed = false;
            for (&self.slots) |*slot| {
                if (slot.state == .idle) continue;
                const id = slot.id;
                _ = self.join(id) catch {};
                self.release(id) catch {
                    failed = true;
                };
            }
            if (failed) return error.CleanupFailed;
            try self.checkDrained();
        }

        pub fn checkDrained(self: *Self) !void {
            for (&self.slots) |*slot| {
                if (slot.state != .idle) return error.Busy;
            }
            if (self.pool.disk.used != 0) return error.Busy;
        }
    };
}

const Mock = struct {
    fail_cleanup: bool = false,

    pub fn get(self: *Mock, _: download.Kind, _: []const u8, sink: *download.Sink) !void {
        if (self.fail_cleanup) return error.TransportCleanupFailed;
        try sink.headers(2);
        try sink.append("ok");
    }
};

const TestTasks = Tasks(Mock);
const test_url = "https://zip.openpets.dev/pets/cat/asset.zip";

test "parallel worker admission joins and returns isolated sealed files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var group = Group.init(std.testing.allocator, 0, 0, 2);
    var tasks = TestTasks.init(io, tmp.dir, &group);
    defer tasks.shutdown() catch unreachable;
    const first = try tasks.start(.zip, test_url, .{});
    const second = try tasks.start(.zip, test_url, .{});
    try std.testing.expect(first != second);
    try std.testing.expectEqual(@as(usize, 2), group.running);
    try std.testing.expectError(error.ResourceBusy, tasks.start(.zip, test_url, .{}));
    try std.testing.expectEqual(@as(usize, 2 * download.limit(.zip)), tasks.pool.disk.used);
    try std.testing.expectError(error.Busy, tasks.release(first));
    const one = try tasks.join(first);
    const two = try tasks.join(second);
    var buf: [2]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 2), try one.file.readPositionalAll(io, &buf, 0));
    try std.testing.expectEqualStrings("ok", &buf);
    try std.testing.expectEqual(@as(usize, 2), try two.file.readPositionalAll(io, &buf, 0));
    try std.testing.expectEqualStrings("ok", &buf);
    try std.testing.expect((try tasks.progress(first)).finished);
    try tasks.release(first);
    try tasks.release(second);
    try std.testing.expectError(error.NotOwned, tasks.release(first));
    try tasks.checkDrained();
    try group.checkDrained();
}

test "stop cancels active work without releasing leases before join" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var group = Group.init(std.testing.allocator, 0, 0, 2);
    var tasks = TestTasks.init(std.testing.io, tmp.dir, &group);
    defer tasks.shutdown() catch unreachable;
    const id = try tasks.start(.zip, test_url, .{});
    tasks.requestStop();
    try std.testing.expect((try tasks.progress(id)).canceled);
    try std.testing.expectError(error.Stopped, tasks.start(.zip, test_url, .{}));
    try std.testing.expectEqual(@as(usize, 1), group.running);
    try tasks.shutdown();
    try tasks.checkDrained();
    try group.checkDrained();
}

test "inline transfer uses the same ownership and release rules" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var group = Group.init(std.testing.allocator, 0, 0, 1);
    var tasks = TasksMode(Mock, true).init(std.testing.io, tmp.dir, &group);
    const id = try tasks.start(.zip, test_url, .{});
    try std.testing.expect((try tasks.progress(id)).finished);
    try std.testing.expectEqual(@as(usize, 2), (try tasks.join(id)).bytes);
    try tasks.release(id);
    try tasks.shutdown();
    try group.checkDrained();
}
