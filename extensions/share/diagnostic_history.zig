const std = @import("std");
const messages = @import("worker_messages.zig");

pub const History = struct {
    bytes: [4096]u8 = undefined,
    len: usize = 0,
    latest: []const u8 = "当前会话暂无需要处理的问题。",

    pub fn slice(self: *const History) []const u8 {
        return self.bytes[0..self.len];
    }

    // All fields except the timestamp originate in the application or a fixed
    // classification table. Worker arguments and free-form output stay out.
    pub fn add(self: *History, stamp: []const u8, operation: []const u8, result: []const u8, finding: ?messages.Finding) void {
        var entry: [512]u8 = undefined;
        const line = std.fmt.bufPrint(&entry, "{s}\t{s}\t{s}\t{s}\t{s}\r\n", .{
            stamp,                                    operation,                                  result,
            if (finding) |value| value.code else "-", if (finding) |value| value.message else "",
        }) catch return;
        while (self.len + line.len > self.bytes.len) {
            const cut = (std.mem.indexOfScalar(u8, self.slice(), '\n') orelse return) + 1;
            std.mem.copyForwards(u8, self.bytes[0 .. self.len - cut], self.bytes[cut..self.len]);
            self.len -= cut;
        }
        @memcpy(self.bytes[self.len..][0..line.len], line);
        self.len += line.len;
        if (finding) |value| self.latest = value.message;
    }
};

test "diagnostic history records categories without echoing worker details" {
    var history: History = .{};
    const details = "Pulse Share: dial tcp 192.0.2.4:45843: i/o timeout";
    history.add("fixture", "pair_join", "failed", messages.find(details));
    try std.testing.expect(std.mem.indexOf(u8, history.slice(), "TIMEOUT") != null);
    try std.testing.expect(std.mem.indexOf(u8, history.slice(), "192.0.2.4") == null);
    for (0..250) |_| history.add("fixture", "receive", "completed", null);
    try std.testing.expect(history.len < history.bytes.len);
    try std.testing.expect(std.mem.endsWith(u8, history.slice(), "\r\n"));
}
