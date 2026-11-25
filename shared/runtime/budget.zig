//! Conservative reservation budget for one serialized resource owner.
//! No allocation, thread, timer or global state. This is a logical resource
//! quota, not an allocator wrapper or an OS memory limit. Synchronize the
//! entire owner externally before sharing across threads.

const std = @import("std");

pub const Budget = struct {
    limit: usize,
    used: usize = 0,
    peak: usize = 0,

    pub fn init(limit: usize) Budget {
        return .{ .limit = limit };
    }

    pub fn reserve(self: *Budget, amount: usize) error{BudgetExceeded}!void {
        if (amount > self.limit - self.used) return error.BudgetExceeded;
        self.used += amount;
        self.peak = @max(self.peak, self.used);
    }

    /// Only release a reservation owned by this budget, exactly once.
    pub fn release(self: *Budget, amount: usize) void {
        std.debug.assert(amount <= self.used);
        self.used -= amount;
    }
};

test "budget rejects oversubscription without changing counters" {
    var budget = Budget.init(10);
    try budget.reserve(6);
    try std.testing.expectError(error.BudgetExceeded, budget.reserve(5));
    try std.testing.expectEqual(@as(usize, 6), budget.used);
    try budget.reserve(4);
    budget.release(6);
    budget.release(4);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
    try std.testing.expectEqual(@as(usize, 10), budget.peak);
}

test "budget handles maximum size without integer overflow" {
    var budget = Budget.init(std.math.maxInt(usize));
    try budget.reserve(std.math.maxInt(usize));
    try std.testing.expectError(error.BudgetExceeded, budget.reserve(1));
    budget.release(std.math.maxInt(usize));
    try budget.reserve(0);
    try std.testing.expectEqual(@as(usize, 0), budget.used);
}
