//! One companion-owned memory domain, reusing the shared runtime allocator.
//! C receives callbacks and an opaque owner, never a Zig allocator ABI.
const std = @import("std");
const resources = @import("pet_resources.zig");
pub const BoundedAllocator = @import("runtime_allocator").BoundedAllocator;

pub const limit = 48 * 1024 * 1024;

pub const Bridge = extern struct {
    context: *BoundedAllocator,
    allocate: *const fn (*BoundedAllocator, usize) callconv(.c) ?[*]u8,
    release: *const fn (*BoundedAllocator, [*]u8, usize) callconv(.c) void,
    resource_bridge: *const resources.Bridge,

    pub fn init(owner: *BoundedAllocator, resource_bridge: *const resources.Bridge) Bridge {
        return .{ .context = owner, .allocate = alloc, .release = free, .resource_bridge = resource_bridge };
    }

    pub fn allocator(self: *const Bridge) std.mem.Allocator {
        return self.context.allocator();
    }
};

fn alloc(owner: *BoundedAllocator, len: usize) callconv(.c) ?[*]u8 {
    if (len == 0) return null;
    const bytes = owner.allocator().alloc(u8, len) catch return null;
    return bytes.ptr;
}

fn free(owner: *BoundedAllocator, ptr: [*]u8, len: usize) callconv(.c) void {
    // Internal trusted C callers return exactly the original length.
    std.debug.assert(len != 0);
    owner.allocator().free(ptr[0..len]);
}

test "C bridge and Zig scratch share one budget and drain" {
    var owner = BoundedAllocator.init(std.testing.allocator, 64);
    var resource_owner: resources.Owner = .{};
    const resource_bridge = resources.Bridge.init(&resource_owner);
    const bridge = Bridge.init(&owner, &resource_bridge);
    const first = bridge.allocate(bridge.context, 48).?;
    const second = try bridge.allocator().alloc(u8, 16);
    try std.testing.expect(bridge.allocate(bridge.context, 1) == null);
    try std.testing.expect(bridge.allocate(bridge.context, 0) == null);
    try std.testing.expectError(error.OutOfMemory, bridge.allocator().alloc(u8, 1));
    try std.testing.expectError(error.OutstandingAllocations, owner.checkDrained());
    bridge.release(bridge.context, first, 48);
    bridge.allocator().free(second);
    try owner.checkDrained();
    try std.testing.expectEqual(@as(usize, 64), owner.stats().reserved_peak);
    try std.testing.expectEqual(@as(usize, 2), owner.stats().denied);
}

test "backing allocation failure rolls back C bridge reservation" {
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var owner = BoundedAllocator.init(failing.allocator(), 64);
    var resource_owner: resources.Owner = .{};
    const resource_bridge = resources.Bridge.init(&resource_owner);
    const bridge = Bridge.init(&owner, &resource_bridge);
    try std.testing.expect(bridge.allocate(bridge.context, 32) == null);
    try owner.checkDrained();
}
