const std = @import("std");

pub const capacity = 128;

pub const Ticket = struct {
    routed: bool,
    endpoint: []const u8,
    code: []const u8,

    pub fn parse(text: []const u8) !Ticket {
        if (text.len > capacity) return error.InvalidTicket;
        var words = std.mem.tokenizeAny(u8, text, " \t\r\n");
        const tag = words.next() orelse return error.InvalidTicket;
        const routed = if (std.mem.eql(u8, tag, "PSH1")) false else if (std.mem.eql(u8, tag, "PSH1-ROUTED")) true else return error.InvalidTicket;
        const address = words.next() orelse return error.InvalidTicket;
        const code = words.next() orelse return error.InvalidTicket;
        var canonical: [capacity]u8 = undefined;
        if (words.next() != null or code.len != 8 or endpoint(address, &canonical) == null) return error.InvalidTicket;
        for (code) |digit| if (!std.ascii.isDigit(digit)) return error.InvalidTicket;
        return .{ .routed = routed, .endpoint = address, .code = code };
    }

    pub fn format(routed: bool, bound: []const u8, code: u32, out: []u8) ![]const u8 {
        var canonical: [capacity]u8 = undefined;
        const address = endpoint(bound, &canonical) orelse return error.InvalidTicket;
        if (code >= 100000000) return error.InvalidTicket;
        return std.fmt.bufPrint(out, "{s} {s} {d:0>8}", .{ if (routed) "PSH1-ROUTED" else "PSH1", address, code });
    }
};

// A listener may report an IPv6 zone for its own interface. Copy the address
// without that system-local zone so the recipient's helper can use its own.
pub fn endpoint(value: []const u8, out: []u8) ?[]const u8 {
    if (value.len == 0 or value.len > 96 or value.len >= out.len) return null;
    const canonical = if (std.mem.indexOfScalar(u8, value, '%')) |zone| blk: {
        if (value[0] != '[') return null;
        const bracket = std.mem.indexOfScalarPos(u8, value, zone, ']') orelse return null;
        if (bracket <= zone + 1) return null;
        for (value[zone + 1 .. bracket]) |digit| if (!std.ascii.isDigit(digit)) return null;
        break :blk std.fmt.bufPrint(out, "{s}{s}", .{ value[0..zone], value[bracket..] }) catch return null;
    } else value;
    const port_start = std.mem.lastIndexOfScalar(u8, canonical, ':') orelse return null;
    if (port_start + 1 == canonical.len) return null;
    for (canonical[port_start + 1 ..]) |digit| if (!std.ascii.isDigit(digit)) return null;
    const parsed = std.Io.net.IpAddress.parseLiteral(canonical) catch return null;
    if (parsed.getPort() == 0) return null;
    return canonical;
}

test "pair tickets carry a numeric address, route and complete zero-padded code" {
    var buffer: [capacity]u8 = undefined;
    const encoded = try Ticket.format(true, "[fe80::1%12]:45843", 123, &buffer);
    try std.testing.expectEqualStrings("PSH1-ROUTED [fe80::1]:45843 00000123", encoded);
    const decoded = try Ticket.parse(encoded);
    try std.testing.expect(decoded.routed);
    try std.testing.expectEqualStrings("[fe80::1]:45843", decoded.endpoint);
    try std.testing.expectEqualStrings("00000123", decoded.code);
    try std.testing.expect(!(try Ticket.parse("PSH1 192.168.0.20:45843 12345678")).routed);
    try std.testing.expectError(error.InvalidTicket, Ticket.parse("PSH1 example.test:45843 12345678"));
    try std.testing.expectError(error.InvalidTicket, Ticket.parse("PSH1 192.168.0.20 12345678"));
    try std.testing.expectError(error.InvalidTicket, Ticket.parse("PSH1 192.168.0.20:0 12345678"));
    try std.testing.expectError(error.InvalidTicket, Ticket.parse("PSH1 192.168.0.20:45843 12345678 extra"));
}
