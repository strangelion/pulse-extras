//! Bounded presentation-only choices from the digest-pinned helper.
//! No parsed discovery result establishes trust or initiates a connection.
const std = @import("std");
const abi = @import("pulse_abi");

pub const Kind = enum { local, endpoint, pair_endpoint, peer };

fn endpointKind(kind: Kind) bool {
    return kind == .endpoint or kind == .pair_endpoint;
}
const max_choices = 24;
const max_peer_bytes = 48 * 4;

pub const Choice = struct {
    data: [max_peer_bytes]u8 = @splat(0),
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
        if (self.count == max_choices or value.len == 0 or value.len > max_peer_bytes) return;
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

fn legacyLabel(value: []const u8) bool {
    if (value.len == 0 or value.len > 48) return false;
    for (value) |c| {
        if (!((c >= 'a' and c <= 'z') or std.ascii.isDigit(c) or c == '-' or c == '_')) return false;
    }
    return true;
}

pub fn validPeerName(value: []const u8) bool {
    if (value.len == 0 or value.len > max_peer_bytes or value[0] == ' ' or value[value.len - 1] == ' ') return false;
    const view = std.unicode.Utf8View.init(value) catch return false;
    var letters = view.iterator();
    var count: usize = 0;
    while (letters.nextCodepoint()) |cp| {
        count += 1;
        if (count > 48 or cp < 32 or (cp >= 0x7f and cp <= 0x9f) or
            (cp >= 0x2028 and cp <= 0x202e) or (cp >= 0x2066 and cp <= 0x2069) or cp == 0xfeff)
            return false;
        if (cp < 128 and std.mem.indexOfScalar(u8, "<>:\"/\\|?*", @intCast(cp)) != null) return false;
    }
    return true;
}

fn fingerprint(value: []const u8) bool {
    if (value.len != 64) return false;
    for (value) |c| if (!hex(c)) return false;
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
        if (hex(c) or c == ':' or c == '.' or (endpointKind(kind) and (c == '[' or c == ']'))) continue;
        return false;
    }
    if (endpointKind(kind) and !colon) return false;
    return dot or colon;
}

pub fn parse(kind: Kind, output: []const u8) List {
    var result: List = .{};
    var lines = std.mem.splitScalar(u8, output, '\n');
    const prefix: []const u8 = switch (kind) {
        .local => "LOCAL ",
        .endpoint => "UNVERIFIED ",
        .pair_endpoint => "PAIR_UNVERIFIED ",
        .peer => "PEER ",
    };
    while (lines.next()) |raw_line| {
        // The managed helper inventory uses CRLF; strip only the framing CR.
        const line = if (std.mem.endsWith(u8, raw_line, "\r")) raw_line[0 .. raw_line.len - 1] else raw_line;
        if (std.mem.indexOfScalar(u8, line, '\r') != null) continue;
        if (kind == .peer and std.mem.startsWith(u8, line, "PEER2 ")) {
            const rest = line["PEER2 ".len..];
            const end = std.mem.indexOfScalar(u8, rest, ' ') orelse continue;
            const name = rest[end + 1 ..];
            if (fingerprint(rest[0..end]) and validPeerName(name)) result.add(name);
            continue;
        }
        if (!std.mem.startsWith(u8, line, prefix)) continue;
        const rest = line[prefix.len..];
        const end = std.mem.indexOfScalar(u8, rest, ' ') orelse rest.len;
        const token = rest[0..end];
        if (kind == .peer) {
            if (!legacyLabel(token) or end == rest.len or !fingerprint(rest[end + 1 ..])) continue;
        } else {
            if (endpointKind(kind) and end != rest.len) continue;
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
    const pairing = parse(.pair_endpoint, "UNVERIFIED 192.168.1.21:42\nPAIR_UNVERIFIED [fe80::2%12]:45843\n");
    try std.testing.expectEqual(@as(usize, 1), pairing.count);
    try std.testing.expectEqualStrings("[fe80::2%12]:45843", pairing.selected(1).?);
    const peers = parse(.peer, "PEER laptop 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nPEER ../bad 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef\nPEER wrong invalid\n");
    try std.testing.expectEqual(@as(usize, 1), peers.count);
    try std.testing.expectEqualStrings("laptop", peers.selected(1).?);
}

test "managed CRLF inventory accepts complete choices and rejects embedded CR" {
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const inventory = "LOCAL 192.0.2.10  \"Fixture\"\r\n" ++
        "UNVERIFIED 192.0.2.14:45843\r\n" ++
        "PAIR_UNVERIFIED 192.0.2.15:45844\r\n" ++
        "PAIR_UNVERIFIED 192.0.2.\r16:45844\r\n" ++
        "PEER laptop " ++ digest ++ "\r\n" ++
        "PEER2 " ++ digest ++ " 客厅电脑\r\n";
    const locals = parse(.local, inventory);
    try std.testing.expectEqual(@as(usize, 1), locals.count);
    try std.testing.expectEqualStrings("192.0.2.10", locals.selected(1).?);
    const endpoints = parse(.endpoint, inventory);
    try std.testing.expectEqual(@as(usize, 1), endpoints.count);
    try std.testing.expectEqualStrings("192.0.2.14:45843", endpoints.selected(1).?);
    const pairing = parse(.pair_endpoint, inventory);
    try std.testing.expectEqual(@as(usize, 1), pairing.count);
    try std.testing.expectEqualStrings("192.0.2.15:45844", pairing.selected(1).?);
    const peers = parse(.peer, inventory);
    try std.testing.expectEqual(@as(usize, 2), peers.count);
    try std.testing.expectEqualStrings("laptop", peers.selected(1).?);
    try std.testing.expectEqualStrings("客厅电脑", peers.selected(2).?);
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

test "legacy and UTF-8 peers are distinct and keep complete labels" {
    const digest = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    const peers = parse(.peer, "PEER laptop " ++ digest ++ "\n" ++
        "PEER2 " ++ digest ++ " 客厅 电脑 💻\n" ++
        "PEER2 " ++ digest ++ " 客厅 电脑 💻\n" ++
        "PEER2 " ++ digest ++ " ../伪造\n" ++
        "PEER2 bad 名称\n");
    try std.testing.expectEqual(@as(usize, 2), peers.count);
    try std.testing.expectEqualStrings("客厅 电脑 💻", peers.selected(2).?);
    try std.testing.expect(validPeerName("Café PC"));
    try std.testing.expect(!validPeerName("隐藏\u{202e}控制"));
    try std.testing.expect(!validPeerName(" 换行\n"));
}
