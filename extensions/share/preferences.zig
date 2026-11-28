//! Package-owned preferences. A saved path is a suggestion, not permission.
const std = @import("std");
const abi = @import("pulse_abi");
const raw = @import("pulse_raw");
const host_mod = @import("pulse_host");
const managed = @import("managed.zig");

pub const indices = [_]usize{ 0, 1, 2, 4, 5, 6, 8, 9, 10, 12, 13 };
const legacy_indices = [_]usize{ 0, 2, 4, 5, 6 };
const v2_indices = [_]usize{ 0, 1, 2, 4, 5, 6, 8 };
const key = "share.preferences.v1";
pub const limit = 1024;

pub const Values = struct {
    fields: [indices.len]managed.Field = @splat(.{}),

    pub fn value(self: *const Values, index: usize) []const u8 {
        for (indices, 0..) |n, i| {
            if (n != index) continue;
            const s = self.fields[i].slice();
            return if ((index == 6 or index == 10) and s.len == 0) "0" else s;
        }
        return "";
    }

    pub fn encode(self: *const Values, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "v3\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}\n{s}", .{
            self.value(0),
            self.value(1),
            self.value(2),
            self.value(4),
            self.value(5),
            self.value(6),
            self.value(8),
            self.value(9),
            self.value(10),
            self.value(12),
            self.value(13),
        });
    }

    pub fn decode(data: []const u8) !Values {
        if (data.len > limit) return error.InvalidSettings;
        var result: Values = .{};
        var lines = std.mem.splitScalar(u8, data, '\n');
        const version = lines.next() orelse return error.InvalidSettings;
        if (std.mem.eql(u8, version, "v1")) {
            for (legacy_indices) |index| {
                for (indices, 0..) |current, i| {
                    if (current == index) {
                        try result.fields[i].set(lines.next() orelse return error.InvalidSettings);
                        break;
                    }
                }
            }
        } else if (std.mem.eql(u8, version, "v2")) {
            for (v2_indices) |index| {
                for (indices, 0..) |current, i| {
                    if (current == index) {
                        try result.fields[i].set(lines.next() orelse return error.InvalidSettings);
                        break;
                    }
                }
            }
        } else if (std.mem.eql(u8, version, "v3")) {
            for (&result.fields) |*field| try field.set(lines.next() orelse return error.InvalidSettings);
        } else return error.InvalidSettings;
        if (lines.next() != null) return error.InvalidSettings;
        _ = try std.fmt.parseInt(u16, result.value(6), 10);
        if (try std.fmt.parseInt(u8, result.value(10), 10) > 32) return error.InvalidSettings;
        return result;
    }
};

// Read previous Pulse settings once to seed a new desktop profile. The
// desktop's own file wins on subsequent starts; this adapter never writes.
pub const Legacy = struct {
    host: host_mod.Host,
    resources: ?raw.PulseResourcesV1 = null,
    pending: u64 = 0,
    opening: bool = false,
    completed_sync: bool = false,
    loaded: bool = false,
    active: bool = false,
    poisoned: bool = false,
    saved: Values = .{},

    pub fn open(self: *Legacy) host_mod.Error!void {
        if (self.active) return;
        if (self.pending != 0 or self.poisoned) return error.State;
        const resources = try self.host.query(raw.PulseResourcesV1, raw.PULSE_RESOURCES_INTERFACE_NAME, raw.PULSE_RESOURCES_VERSION_1);
        const read = resources.settings_get orelse return error.Unavailable;
        if (resources.cancel_request == null) return error.Unavailable;
        self.resources = resources;
        self.active = true;
        self.opening = true;
        self.completed_sync = false;
        defer self.opening = false;
        var id: u64 = 0;
        host_mod.mapStatus(read(resources.context, &completed, self, &id)) catch |err| {
            self.active = false;
            return err;
        };
        if (self.completed_sync) return;
        if (id == 0) {
            self.poisoned = true;
            return error.State;
        }
        self.pending = id;
    }

    pub fn close(self: *Legacy) host_mod.Error!void {
        self.active = false;
        self.loaded = false;
        if (self.poisoned) return error.State;
        if (self.pending != 0) {
            const resources = self.resources orelse return error.State;
            try host_mod.mapStatus(resources.cancel_request.?(resources.context, self.pending));
            self.pending = 0;
        }
    }

    fn completed(user: ?*anyopaque, reply: [*c]const raw.PulseResourcesReply) callconv(.c) void {
        const self: *Legacy = @ptrCast(@alignCast(user orelse return));
        if (reply == null or reply.*.size < @sizeOf(raw.PulseResourcesReply)) return;
        if (self.opening and self.pending == 0) {
            self.completed_sync = true;
        } else if (self.pending == 0 or reply.*.request_id != self.pending) {
            return;
        } else {
            self.pending = 0;
        }
        if (!self.active or reply.*.status != abi.ok or reply.*.operation != raw.PULSE_RESOURCES_SETTINGS_GET) return;
        const snapshot = reply.*.settings;
        if (snapshot.count > 1024 or (snapshot.count != 0 and snapshot.values == null)) return;
        var values: Values = .{};
        var found = false;
        for (0..snapshot.count) |i| {
            const item = snapshot.values[i];
            if (!std.mem.eql(u8, abi.slice(item.key) orelse return, key)) continue;
            if (found) return;
            found = true;
            values = Values.decode(abi.slice(item.value) orelse return) catch return;
        }
        self.saved = values;
        self.loaded = found;
    }
};

test "preferences roundtrip and malformed data rejected" {
    var values: Values = .{};
    try values.fields[2].set("C:\\中文\\identity");
    try values.fields[5].set("45843");
    try values.fields[6].set("100.64.1.2");
    var buffer: [limit]u8 = undefined;
    const decoded = try Values.decode(try values.encode(&buffer));
    try std.testing.expectEqualStrings("C:\\中文\\identity", decoded.value(2));
    try std.testing.expectEqualStrings("45843", decoded.value(6));
    try std.testing.expectEqualStrings("100.64.1.2", decoded.value(8));
    const legacy = try Values.decode("v1\n127.0.0.1\nC:\\identity\nD:\\received\nC:\\spool\n0");
    try std.testing.expectEqualStrings("C:\\identity", legacy.value(2));
    try std.testing.expectEqualStrings("", legacy.value(8));
    try std.testing.expectError(error.InvalidSettings, Values.decode("v2\n"));
    try std.testing.expectError(error.InvalidSettings, Values.decode("v1\n\n\n\n\n0\nextra"));
}
