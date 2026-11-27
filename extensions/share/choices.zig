//! Bounded presentation-only choices from the digest-pinned helper.
//! No parsed discovery result establishes trust or initiates a connection.
const std = @import("std");
const abi = @import("pulse_abi");

pub const Kind = enum { local, endpoint, peer };
const max_choices = 24;

pub const Choice = struct {
    data: [128]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const Choice) []const u8 {
        return self.data[0..self.len];
    }
};

pub const List = struct {
    values: [max_choices]Choice = @splat(.{}),
    count: usize = 0,

    pub fn options(self: *const List, out: *[max_choices + 1]abi.StringView) []const abi.StringView {
        out[0] = abi.view("请选择");
        for (self.values[0..self.count], 0..) |*entry, i| out[i + 1] = abi.view(entry.slice());
        return out[0 .. self.count + 1];
    }

    pub fn selected(self: *const List, index: usize) ?[]const u8 {
        if (index == 0 or index > self.count) return null;
        return self.values[index - 1].slice();
    }

    fn add(self: *List, value: []const u8) void {
        if (self.count == max_choices or value.len == 0 or value.len > 128) return;
        for (self.values[0..self.count]) |*entry| {
            if (std.mem.eql(u8, entry.slice(), value)) return;
        }
        @memcpy(self.values[self.count].data[0..value.len], value);
        self.values[self.count].len = value.len;
        self.count += 1;
    }
};

pub const Options = [max_choices + 1]abi.StringView;

fn hex(c: u8) bool {
    return std.ascii.isDigit(c) or (c >= 'a' and c <= 'f') or (c >= 'A' and c <= 'F');
}

fn label(value: []const u8) bool {
    if (value.len == 0 or value.len > 48) return false;
    for (value) |c| {
        if (!((c >= 'a' and c <= 'z') or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

// This is only a display grammar. The helper performs authoritative
// numeric address, interface and on-link checks before use.
fn address(value: []const u8, kind: Kind) bool {
    if (value.len == 0 or value.len > 96) return false;
    var colon = false;
    var dot = false;
    var zone = false;
    for (value) |c| {
        if (c == '%') {
            if (zone) return false;
            zone = true;
            continue;
        }
        if (c == ':') colon = true;
        if (c == '.') dot = true;
        if (zone and std.ascii.isDigit(c)) continue;
        if (hex(c) or c == ':' or c == '.' or (kind == .endpoint and (c == '[' or c == ']'))) continue;
        return false;
    }
    if (kind == .endpoint and !colon) return false;
    return dot or colon;
}

pub fn parse(kind: Kind, output: []const u8) List {
    var result: List = .{};
    var lines = std.mem.splitScalar(u8, output, '\n');
    const prefix: []const u8 = switch (kind) {
        .local => "LOCAL ",
        .endpoint => "UNVERIFIED ",
        .peer => "PEER ",
    };
    while (lines.next()) |line| {
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const token = rest[0..end];
        if (kind == .peer) {
            if (!label(token) or end == rest.len) continue;
            const fingerprint = rest[end + 1 ..];
            if (fingerprint.len != 64) continue;
            var valid = true;
            for (fingerprint) |c| {
                if (!hex(c)) valid = false;
            }
            if (!valid) continue;
        } else {
            if (kind == .endpoint and end != rest.len) continue;
            if (!address(token, kind)) continue;
        }
        result.add(token);
    }
    return result;
}

test "choices filter, deduplicate and retain an explicit empty selection" {
    const locals = parse(.local, "LOCAL 192.168.1.20  \"LAN\"\nLOCAL fe80::1%12  \"Ethernet\"\nLOCAL 192.168.1.20  \"same\"\nLOCAL INVENTORY TRUNCATED\nLOCAL evil path\n");
    try std.testing.expectEqual(@as(usize, 2), locals.count);
    try std.testing.expect(locals.selected(0) == null);
    try std.testing.expectEqualStrings("fe80::1%12", locals.selected(2).?);
    try std.testing.expect(locals.selected(3) == null);
    const endpoints = parse(.endpoint, "UNVERIFIED 192.168.1.21:45843\nUNVERIFIED [fe80::2%12]:45843\nUNVERIFIED example.com:12\nUNVERIFIED 192.168.1.22:3 extra\n");
    try std.testing.expectEqual(@as(usize, 2), endpoints.count);
    const peers = parse(.peer, "PEER laptop 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nPEER ../bad 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nPEER wrong invalid\n");
    try std.testing.expectEqual(@as(usize, 1), peers.count);
    try std.testing.expectEqualStrings("laptop", peers.selected(1).?);
}

test "bounded options never select beyond the represented rows" {
    var list: List = .{};
    var buffer: [32]u8 = undefined;
    for (0..64) |i| {
        const value = try std.fmt.bufPrint(&buffer, "peer-{d}", .{i});
        list.add(value);
    }
    try std.testing.expectEqual(@as(usize, max_choices), list.count);
    var opts: Options = undefined;
    try std.testing.expectEqual(@as(usize, max_choices + 1), list.options(&opts).len);
    try std.testing.expect(list.selected(max_choices + 1) == null);
}
