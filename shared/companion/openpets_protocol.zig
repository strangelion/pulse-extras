//! Experimental OpenPets v1 local IPC wire codec.
//! No discovery file I/O, socket access, process creation, or host callbacks.
//! Contract: OpenPetsHQ/openpets@2f02bb04d872dec6923a47572343305235c63482.
//! Caller owns buffers and transport; never log requests (they contain tokens).

const std = @import("std");

pub const max_message_bytes: usize = 16 * 1024;
pub const protocol_version: u32 = 1;
pub const Reaction = enum {
    idle,
    thinking,
    working,
    editing,
    running,
    testing,
    waiting,
    waving,
    success,
    @"error",
    celebrating,
};

pub const Request = union(enum) {
    hello,
    status,
    react: struct {
        reaction: Reaction,
        lease_id: []const u8,
    },
};

pub const Method = enum { hello, status, react };

fn safeAtom(value: []const u8, min: usize, max: usize) bool {
    if (value.len < min or value.len > max) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// The experiment intentionally accepts a strict ASCII subset of the wire
/// protocol: UUID/base64url IDs and tokens. This makes interpolation safe.
/// The server emits base64url tokens. Reactions always require a lease ID;
/// no default-pet mutations, installation, arbitrary text, or media methods.
pub fn encode(buf: []u8, id: []const u8, token: []const u8, request: Request) error{ InvalidId, InvalidToken, InvalidLease, NoSpaceLeft }![]const u8 {
    if (!safeAtom(id, 1, 120)) return error.InvalidId;
    if (!safeAtom(token, 16, 256)) return error.InvalidToken;
    return switch (request) {
        .hello => std.fmt.bufPrint(buf, "{{\"id\":\"{s}\",\"version\":1,\"token\":\"{s}\",\"method\":\"hello\",\"params\":{{}}}}\n", .{ id, token }),
        .status => std.fmt.bufPrint(buf, "{{\"id\":\"{s}\",\"version\":1,\"token\":\"{s}\",\"method\":\"status\",\"params\":{{}}}}\n", .{ id, token }),
        .react => |react| blk: {
            if (!safeAtom(react.lease_id, 1, 120)) return error.InvalidLease;
            break :blk std.fmt.bufPrint(buf, "{{\"id\":\"{s}\",\"version\":1,\"token\":\"{s}\",\"method\":\"pet.react\",\"params\":{{\"reaction\":\"{s}\",\"leaseId\":\"{s}\"}}}}\n", .{ id, token, @tagName(react.reaction), react.lease_id });
        },
    };
}

pub const Response = union(enum) {
    hello,
    status: struct {
        running: bool,
        paused: bool,
        visible: bool,
    },
    reaction: struct {
        shown: bool,
    },
    // Never expose arbitrary peer error strings to logs or callers.
    rejected,
};

const PeerResult = struct {
    ok: bool,
    protocol: ?[]const u8 = null,
    protocolVersion: ?u32 = null,
    appRunning: ?bool = null,
    paused: ?bool = null,
    defaultPetVisible: ?bool = null,
    shown: ?bool = null,
    reaction: ?[]const u8 = null,
    leaseId: ?[]const u8 = null,
};

const PeerError = struct {
    code: []const u8,
    message: []const u8,
};

const Envelope = struct {
    id: ?[]const u8,
    ok: bool,
    result: ?PeerResult = null,
    @"error": ?PeerError = null,
};

/// Accept exactly one bounded LF-terminated JSON object. A transport must
/// assemble the complete frame, enforce deadlines and authenticate the peer
/// before using this codec. It must not forward untrusted discovery tokens.
pub fn decode(allocator: std.mem.Allocator, frame: []const u8, id: []const u8, request: Request) error{ InvalidFrame, InvalidResponse, MismatchedId, OutOfMemory }!Response {
    if (frame.len == 0 or frame.len > max_message_bytes or frame[frame.len - 1] != '\n') return error.InvalidFrame;
    const payload = frame[0 .. frame.len - 1];
    if (std.mem.indexOfScalar(u8, payload, '\n') != null or std.mem.indexOfScalar(u8, payload, '\r') != null) return error.InvalidFrame;
    if (!std.unicode.utf8ValidateSlice(payload)) return error.InvalidFrame;
    const parsed = std.json.parseFromSlice(Envelope, allocator, payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (!value.ok) {
        if (value.result != null or value.@"error" == null) return error.InvalidResponse;
        // The server may return null for pre-dispatch authentication failures.
        if (value.id) |response_id| {
            if (!std.mem.eql(u8, response_id, id)) return error.MismatchedId;
        }
        return .rejected;
    }
    const response_id = value.id orelse return error.MismatchedId;
    if (!std.mem.eql(u8, response_id, id)) return error.MismatchedId;
    if (value.@"error" != null) return error.InvalidResponse;
    const result = value.result orelse return error.InvalidResponse;
    if (!result.ok) return error.InvalidResponse;
    return switch (request) {
        .hello => blk: {
            if (result.protocolVersion != protocol_version) return error.InvalidResponse;
            if (!std.mem.eql(u8, result.protocol orelse return error.InvalidResponse, "openpets-ipc")) return error.InvalidResponse;
            break :blk .hello;
        },
        .status => blk: {
            if (result.protocolVersion != protocol_version) return error.InvalidResponse;
            break :blk .{ .status = .{
                .running = result.appRunning orelse return error.InvalidResponse,
                .paused = result.paused orelse return error.InvalidResponse,
                .visible = result.defaultPetVisible orelse return error.InvalidResponse,
            } };
        },
        .react => |react| blk: {
            if (!std.mem.eql(u8, result.reaction orelse return error.InvalidResponse, @tagName(react.reaction))) return error.InvalidResponse;
            if (!std.mem.eql(u8, result.leaseId orelse return error.InvalidResponse, react.lease_id)) return error.InvalidResponse;
            break :blk .{ .reaction = .{ .shown = result.shown orelse return error.InvalidResponse } };
        },
    };
}

const testing = std.testing;
const fixture_token = "0123456789abcdef0123456789abcdef";

test "hello and status requests use the v1 JSON-line contract" {
    var buf: [1024]u8 = undefined;
    const hello = try encode(&buf, "request-1", fixture_token, .hello);
    try testing.expectEqualStrings("{\"id\":\"request-1\",\"version\":1,\"token\":\"0123456789abcdef0123456789abcdef\",\"method\":\"hello\",\"params\":{}}\n", hello);
    const status = try encode(&buf, "request-2", fixture_token, .status);
    try testing.expectEqualStrings("{\"id\":\"request-2\",\"version\":1,\"token\":\"0123456789abcdef0123456789abcdef\",\"method\":\"status\",\"params\":{}}\n", status);
}

test "react targets a lease and never accepts arbitrary JSON" {
    var buf: [1024]u8 = undefined;
    const react: Request = .{ .react = .{ .reaction = .working, .lease_id = "lease-1" } };
    const message = try encode(&buf, "request-3", fixture_token, react);
    try testing.expectEqualStrings("{\"id\":\"request-3\",\"version\":1,\"token\":\"0123456789abcdef0123456789abcdef\",\"method\":\"pet.react\",\"params\":{\"reaction\":\"working\",\"leaseId\":\"lease-1\"}}\n", message);
    try testing.expectError(error.InvalidId, encode(&buf, "bad\"\n", fixture_token, .hello));
    try testing.expectError(error.InvalidToken, encode(&buf, "id", "not a token", .hello));
    try testing.expectError(error.InvalidLease, encode(&buf, "id", fixture_token, .{ .react = .{ .reaction = .idle, .lease_id = "" } }));
    try testing.expectError(error.NoSpaceLeft, encode(buf[0..8], "id", fixture_token, .hello));
}

test "hello validates identity version and result" {
    const good = "{\"id\":\"a\",\"ok\":true,\"result\":{\"ok\":true,\"protocol\":\"openpets-ipc\",\"protocolVersion\":1,\"appVersion\":\"0.0.0\"}}\n";
    try testing.expect((try decode(testing.allocator, good, "a", .hello)) == .hello);
    try testing.expectError(error.MismatchedId, decode(testing.allocator, good, "b", .hello));
    try testing.expectError(error.InvalidResponse, decode(testing.allocator, "{\"id\":\"a\",\"ok\":true,\"result\":{\"ok\":true,\"protocol\":\"openpets-ipc\",\"protocolVersion\":2}}\n", "a", .hello));
    try testing.expectError(error.InvalidResponse, decode(testing.allocator, "{\"id\":\"a\",\"ok\":true,\"result\":{\"ok\":true,\"protocol\":\"other\",\"protocolVersion\":1}}\n", "a", .hello));
}

test "status and reaction preserve false values" {
    const response = try decode(testing.allocator, "{\"id\":\"a\",\"ok\":true,\"result\":{\"ok\":true,\"protocolVersion\":1,\"appRunning\":true,\"paused\":true,\"defaultPetVisible\":false}}\n", "a", .status);
    try testing.expect(response.status.running);
    try testing.expect(response.status.paused);
    try testing.expect(!response.status.visible);
    const react: Request = .{ .react = .{ .reaction = .working, .lease_id = "lease-1" } };
    const result = try decode(testing.allocator, "{\"id\":\"a\",\"ok\":true,\"result\":{\"ok\":true,\"reaction\":\"working\",\"shown\":false,\"leaseId\":\"lease-1\",\"reason\":\"paused\"}}\n", "a", react);
    try testing.expect(!result.reaction.shown);
    try testing.expectError(error.InvalidResponse, decode(testing.allocator, "{\"id\":\"a\",\"ok\":true,\"result\":{\"ok\":true,\"reaction\":\"working\",\"shown\":true,\"leaseId\":\"wrong\"}}\n", "a", react));
}

test "reject error envelopes malformed and oversized frames" {
    const rejection = try decode(testing.allocator, "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"invalid_token\",\"message\":\"Invalid IPC token.\"}}\n", "a", .hello);
    try testing.expect(rejection == .rejected);
    try testing.expectError(error.InvalidFrame, decode(testing.allocator, "{}", "a", .hello));
    try testing.expectError(error.InvalidFrame, decode(testing.allocator, "{}\n{}\n", "a", .hello));
    try testing.expectError(error.InvalidResponse, decode(testing.allocator, "not-json\n", "a", .hello));
    try testing.expectError(error.InvalidResponse, decode(testing.allocator, "{\"id\":\"a\",\"ok\":true}\n", "a", .hello));
    const too_large = [_]u8{'x'} ** (max_message_bytes + 1);
    try testing.expectError(error.InvalidFrame, decode(testing.allocator, &too_large, "a", .hello));
}
