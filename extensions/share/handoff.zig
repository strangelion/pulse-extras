const std = @import("std");
const managed = @import("managed.zig");

pub const capacity = 4096;

pub const Selection = struct {
    count: u32 = 0,
    single_file: bool = false,
    paths: []const u8 = "",
    preferences: []const u8 = "",

    pub fn encode(self: Selection, out: []u8) ![]const u8 {
        if (!self.valid()) return error.InvalidSelection;
        return std.fmt.bufPrint(out, "{d}\n{d}\n{s}\n{s}", .{ self.count, @intFromBool(self.single_file), self.paths, self.preferences });
    }

    pub fn decode(bytes: []const u8) !Selection {
        if (bytes.len > capacity) return error.InvalidSelection;
        var parts = std.mem.splitScalar(u8, bytes, '\n');
        const count = std.fmt.parseInt(u32, parts.next() orelse return error.InvalidSelection, 10) catch return error.InvalidSelection;
        const kind = parts.next() orelse return error.InvalidSelection;
        if (!std.mem.eql(u8, kind, "0") and !std.mem.eql(u8, kind, "1")) return error.InvalidSelection;
        const result: Selection = .{
            .count = count,
            .single_file = kind[0] == '1',
            .paths = parts.next() orelse return error.InvalidSelection,
            .preferences = parts.rest(),
        };
        if (!result.valid()) return error.InvalidSelection;
        return result;
    }

    pub fn valid(self: Selection) bool {
        if (self.count > 64 or self.preferences.len > 1024 or self.paths.len >= 2048) return false;
        if (self.count == 0) return self.paths.len == 0 and !self.single_file;
        if (self.single_file and self.count != 1) return false;
        var paths = std.mem.splitScalar(u8, self.paths, '|');
        var seen: u32 = 0;
        while (paths.next()) |path| : (seen += 1) {
            if (path.len < 4 or !std.ascii.isAlphabetic(path[0]) or path[1] != ':' or path[2] != '\\') return false;
            var field: managed.Field = .{};
            field.set(path) catch return false;
        }
        return seen == self.count;
    }
};

test "selection handoff retains Unicode and rejects mismatched or non-local paths" {
    var data: [capacity]u8 = undefined;
    const input: Selection = .{ .count = 2, .paths = "C:\\项目\\a|D:\\b", .preferences = "v3\n\n" };
    const actual = try Selection.decode(try input.encode(&data));
    try std.testing.expectEqual(input.count, actual.count);
    try std.testing.expectEqualStrings(input.paths, actual.paths);
    try std.testing.expectEqualStrings(input.preferences, actual.preferences);
    try std.testing.expectError(error.InvalidSelection, Selection.decode("2\n0\nC:\\a\n"));
    try std.testing.expectError(error.InvalidSelection, Selection.decode("1\n1\n\\\\server\\folder\n"));
    try std.testing.expectError(error.InvalidSelection, Selection.decode("1\n1\nC:\\a|D:\\b\n"));
    try std.testing.expectError(error.InvalidSelection, Selection.decode("1\n1\nC:\\bad\"name\n"));
}
