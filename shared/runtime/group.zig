//! Optional caller-owned resource group for multiple serialized task owners.
//! Queue/job admission is owner-thread only. The backing allocator is the
//! existing concurrency-accounted allocator. No globals or cross-DLL ABI.

const std = @import("std");
const memory = @import("runtime_allocator");

pub const Group = struct {
    pool: memory.BoundedAllocator,
    queue_limit: usize,
    running_limit: usize,
    queued: usize = 0,
    running: usize = 0,
    queue_peak: usize = 0,
    running_peak: usize = 0,
    rejected: usize = 0,

    pub const Diagnostics = struct {
        queued: usize,
        running: usize,
        queue_peak: usize,
        running_peak: usize,
        rejected: usize,
        memory: memory.Stats,
    };

    pub fn init(backing: std.mem.Allocator, bytes: usize, queued: usize, running: usize) Group {
        return .{ .pool = memory.BoundedAllocator.init(backing, bytes), .queue_limit = queued, .running_limit = running };
    }

    /// Construct child allocators/Runners with this as their backing allocator.
    /// Group must outlive all children, including failed allocations and jobs.
    pub fn allocator(self: *Group) std.mem.Allocator {
        return self.pool.allocator();
    }

    pub fn reserveQueued(self: *Group) error{ResourceBusy}!void {
        if (self.queued >= self.queue_limit) {
            self.rejected +|= 1;
            return error.ResourceBusy;
        }
        self.queued += 1;
        self.queue_peak = @max(self.queue_peak, self.queued);
    }

    pub fn releaseQueued(self: *Group) void {
        std.debug.assert(self.queued != 0);
        self.queued -= 1;
    }

    pub fn reserveRunning(self: *Group) error{ResourceBusy}!void {
        if (self.running >= self.running_limit) {
            self.rejected +|= 1;
            return error.ResourceBusy;
        }
        self.running += 1;
        self.running_peak = @max(self.running_peak, self.running);
    }

    pub fn releaseRunning(self: *Group) void {
        std.debug.assert(self.running != 0);
        self.running -= 1;
    }

    pub fn diagnostics(self: *Group) Diagnostics {
        return .{
            .queued = self.queued,
            .running = self.running,
            .queue_peak = self.queue_peak,
            .running_peak = self.running_peak,
            .rejected = self.rejected,
            .memory = self.pool.stats(),
        };
    }

    pub fn checkDrained(self: *Group) error{ Busy, OutstandingAllocations }!void {
        if (self.running != 0 or self.queued != 0) return error.Busy;
        try self.pool.checkDrained();
    }
};

test "child allocation limits share one aggregate budget without sharing ownership" {
    var group = Group.init(std.testing.allocator, 64, 2, 1);
    var first = memory.BoundedAllocator.init(group.allocator(), 48);
    var second = memory.BoundedAllocator.init(group.allocator(), 48);
    const a = first.allocator();
    const b = second.allocator();
    {
        const one = try a.alloc(u8, 40);
        defer a.free(one);
        try std.testing.expectError(error.OutOfMemory, b.alloc(u8, 32));
        const two = try b.alloc(u8, 24);
        defer b.free(two);
        try std.testing.expectEqual(@as(usize, 64), group.diagnostics().memory.live_bytes);
        try std.testing.expectError(error.OutstandingAllocations, group.checkDrained());
    }
    try first.checkDrained();
    try second.checkDrained();
    try group.checkDrained();
}

test "aggregate admission enforces queue and running limits independently" {
    var group = Group.init(std.testing.allocator, 0, 1, 1);
    try group.reserveQueued();
    try std.testing.expectError(error.ResourceBusy, group.reserveQueued());
    try group.reserveRunning();
    try std.testing.expectError(error.ResourceBusy, group.reserveRunning());
    try std.testing.expectError(error.Busy, group.checkDrained());
    group.releaseQueued();
    group.releaseRunning();
    try group.checkDrained();
    try std.testing.expectEqual(@as(usize, 2), group.diagnostics().rejected);
}
