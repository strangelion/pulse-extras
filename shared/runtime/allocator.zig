//! Bounded allocator accounting for requested live bytes, not RSS or heap
//! overhead. No allocation metadata, background tasks or global state.
//! The backing allocator must support the concurrency of its callers.
//! The short accounting lock is never held across backing allocator calls.
//! Keep the wrapper at a stable address until all allocations are freed.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Budget = @import("runtime_budget").Budget;

pub const Stats = struct {
    live_bytes: usize,
    reserved_peak: usize,
    live_allocations: usize,
    denied: usize,
};

pub const BoundedAllocator = struct {
    backing: Allocator,
    budget: Budget,
    lock: std.atomic.Mutex = .unlocked,
    live_allocations: usize = 0,
    denied: usize = 0,

    pub fn init(backing: Allocator, limit: usize) BoundedAllocator {
        return .{ .backing = backing, .budget = Budget.init(limit) };
    }

    pub fn allocator(self: *BoundedAllocator) Allocator {
        return .{ .ptr = self, .vtable = &.{
            .alloc = alloc,
            .resize = resize,
            .remap = remap,
            .free = free,
        } };
    }

    fn enter(self: *BoundedAllocator) void {
        while (!self.lock.tryLock()) std.atomic.spinLoopHint();
    }

    /// Coherent accounting snapshot. In-flight reservations count until the
    /// backing call succeeds or is rolled back. Peak includes reservations.
    pub fn stats(self: *BoundedAllocator) Stats {
        self.enter();
        defer self.lock.unlock();
        return .{
            .live_bytes = self.budget.used,
            .reserved_peak = self.budget.peak,
            .live_allocations = self.live_allocations,
            .denied = self.denied,
        };
    }

    /// Only call when all allocator users have stopped; this is not a join.
    pub fn checkDrained(self: *BoundedAllocator) error{OutstandingAllocations}!void {
        const snapshot = self.stats();
        if (snapshot.live_bytes != 0 or snapshot.live_allocations != 0) return error.OutstandingAllocations;
    }

    fn reserve(self: *BoundedAllocator, amount: usize, new_allocation: bool) bool {
        self.enter();
        defer self.lock.unlock();
        self.budget.reserve(amount) catch {
            self.denied +|= 1;
            return false;
        };
        if (new_allocation) self.live_allocations += 1;
        return true;
    }

    fn release(self: *BoundedAllocator, amount: usize, allocation: bool) void {
        self.enter();
        defer self.lock.unlock();
        self.budget.release(amount);
        if (allocation) self.live_allocations -= 1;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        // The public Allocator API handles zero-length allocations itself.
        if (len == 0) return null;
        if (!self.reserve(len, true)) return null;
        return self.backing.rawAlloc(len, alignment, ra) orelse {
            self.release(len, true);
            return null;
        };
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        const growth = new_len -| memory.len;
        if (!self.reserve(growth, false)) return false;
        if (!self.backing.rawResize(memory, alignment, new_len, ra)) {
            self.release(growth, false);
            return false;
        }
        self.release(memory.len -| new_len, false);
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        const growth = new_len -| memory.len;
        if (!self.reserve(growth, false)) return null;
        const result = self.backing.rawRemap(memory, alignment, new_len, ra) orelse {
            self.release(growth, false);
            return null;
        };
        self.release(memory.len -| new_len, false);
        return result;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *BoundedAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
        self.release(memory.len, true);
    }
};

const testing = std.testing;

test "bounded allocator rejects oversubscription and tracks release" {
    var bounded = BoundedAllocator.init(testing.allocator, 64);
    const allocator = bounded.allocator();
    {
        const bytes = try allocator.alloc(u8, 48);
        defer allocator.free(bytes);
        const other = try allocator.alloc(u8, 16);
        defer allocator.free(other);
        try testing.expectError(error.OutOfMemory, allocator.alloc(u8, 1));
        const snapshot = bounded.stats();
        try testing.expectEqual(@as(usize, 64), snapshot.live_bytes);
        try testing.expectEqual(@as(usize, 2), snapshot.live_allocations);
        try testing.expectEqual(@as(usize, 1), snapshot.denied);
        try testing.expectError(error.OutstandingAllocations, bounded.checkDrained());
    }
    try bounded.checkDrained();
    try testing.expectEqual(@as(usize, 64), bounded.stats().reserved_peak);
}

test "backing OOM rolls back reservations" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .fail_index = 0 });
    var bounded = BoundedAllocator.init(failing.allocator(), 64);
    try testing.expectError(error.OutOfMemory, bounded.allocator().alloc(u8, 16));
    try bounded.checkDrained();
    try testing.expectEqual(@as(usize, 0), bounded.stats().denied);
}

test "failed resize and remap preserve original live bytes" {
    var failing = testing.FailingAllocator.init(testing.allocator, .{ .resize_fail_index = 0 });
    var bounded = BoundedAllocator.init(failing.allocator(), 64);
    const allocator = bounded.allocator();
    {
        const bytes = try allocator.alloc(u8, 16);
        defer allocator.free(bytes);
        @memset(bytes, 42);
        try testing.expect(!allocator.resize(bytes, 32));
        try testing.expect(allocator.remap(bytes, 32) == null);
        try testing.expect(!allocator.resize(bytes, 65));
        try testing.expect(allocator.remap(bytes, 65) == null);
        try testing.expectEqual(@as(usize, 16), bounded.stats().live_bytes);
        try testing.expectEqual(@as(u8, 42), bytes[0]);
    }
    try bounded.checkDrained();
}

test "successful resize and remap account for changed length and preserve contents" {
    var storage: [128]u8 = undefined;
    var fixed = std.heap.FixedBufferAllocator.init(&storage);
    var bounded = BoundedAllocator.init(fixed.allocator(), 64);
    const allocator = bounded.allocator();
    {
        var bytes = try allocator.alloc(u8, 16);
        defer allocator.free(bytes);
        @memset(bytes, 23);
        try testing.expect(allocator.resize(bytes, 32));
        bytes = bytes.ptr[0..32];
        try testing.expectEqual(@as(usize, 32), bounded.stats().live_bytes);
        bytes = allocator.remap(bytes, 8) orelse return error.TestExpectedRemap;
        try testing.expectEqual(@as(usize, 8), bounded.stats().live_bytes);
        try testing.expectEqual(@as(u8, 23), bytes[7]);
    }
    try bounded.checkDrained();
}

test "zero-length allocation and independent owners do not consume another budget" {
    var first = BoundedAllocator.init(testing.allocator, 16);
    var second = BoundedAllocator.init(testing.allocator, 16);
    const a = first.allocator();
    const b = second.allocator();
    {
        const empty = try a.alloc(u8, 0);
        defer a.free(empty);
        try first.checkDrained();
        const aligned = try a.alloc(u64, 2);
        defer a.free(aligned);
        const bytes = try b.alloc(u8, 16);
        defer b.free(bytes);
        try testing.expectEqual(@as(usize, 16), first.stats().live_bytes);
        try testing.expectEqual(@as(usize, 16), second.stats().live_bytes);
        try testing.expectError(error.OutOfMemory, a.alloc(u8, 1));
    }
    try first.checkDrained();
    try second.checkDrained();
}


fn concurrentAllocations(bounded: *BoundedAllocator) error{OutOfMemory}!void {
    const allocator = bounded.allocator();
    for (0..128) |index| {
        const bytes = try allocator.alloc(u8, 64 + index % 32);
        defer allocator.free(bytes);
        @memset(bytes, @intCast(index));
    }
}

test "bounded allocator accounting supports concurrent callers" {
    // The test allocator must support worker threads; use the system page
    // allocator for this small contention test, not the test debug allocator.
    var bounded = BoundedAllocator.init(std.heap.page_allocator, 4096);
    var first = try std.Io.concurrent(testing.io, concurrentAllocations, .{&bounded});
    var second = std.Io.concurrent(testing.io, concurrentAllocations, .{&bounded}) catch |err| {
        try first.await(testing.io);
        return err;
    };
    const first_result = first.await(testing.io);
    const second_result = second.await(testing.io);
    try first_result;
    try second_result;
    try bounded.checkDrained();
    const snapshot = bounded.stats();
    try testing.expect(snapshot.reserved_peak <= 4096);
    try testing.expectEqual(@as(usize, 0), snapshot.denied);
}
