//! OpenPets lease experiment, independent of live Windows transport.
//! Contract: OpenPetsHQ/openpets@2f02bb04d872dec6923a47572343305235c63482.
//! No automatic acquisition, default-pet reactions or retry after ambiguity.
const std = @import("std");
const wire = @import("openpets_protocol.zig");

pub const Id = struct {
    bytes: [120]u8,
    len: usize,

    pub fn parse(value: []const u8) error{InvalidId}!Id {
        if (!atom(value, 120)) return error.InvalidId;
        var result: Id = .{ .bytes = undefined, .len = value.len };
        @memset(&result.bytes, 0);
        @memcpy(result.bytes[0..value.len], value);
        return result;
    }

    pub fn slice(self: *const Id) []const u8 {
        return self.bytes[0..self.len];
    }
};

fn atom(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max) return false;
    for (value) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

fn petId(value: []const u8) bool {
    if (!atom(value, 64)) return false;
    if (!(std.ascii.isDigit(value[0]) or (value[0] >= 'a' and value[0] <= 'z'))) return false;
    for (value) |c| {
        if (c >= 'A' and c <= 'Z') return false;
    }
    return true;
}

pub const Acquire = struct {
    pet_id: []const u8,
    client_pid: u32,
    session_nonce: []const u8,
};

pub const Request = union(enum) {
    acquire: Acquire,
    heartbeat: []const u8,
    release: []const u8,
};

pub fn encode(buffer: []u8, id: []const u8, token: []const u8, request: Request) error{ InvalidId, InvalidToken, InvalidLease, InvalidTarget, NoSpaceLeft }![]const u8 {
    if (!atom(id, 120)) return error.InvalidId;
    if (token.len < 16 or !atom(token, 256)) return error.InvalidToken;
    return switch (request) {
        .acquire => |a| blk: {
            if (!petId(a.pet_id) or a.client_pid == 0 or !atom(a.session_nonce, 120)) return error.InvalidTarget;
            break :blk std.fmt.bufPrint(buffer, "{{\"id\":\"{s}\",\"version\":1,\"token\":\"{s}\",\"method\":\"lease.acquire\",\"params\":{{\"requestedPetId\":\"{s}\",\"clientPid\":{d},\"sessionNonce\":\"{s}\"}}}}\n", .{ id, token, a.pet_id, a.client_pid, a.session_nonce });
        },
        .heartbeat, .release => |lease_id| blk: {
            if (!atom(lease_id, 120)) return error.InvalidLease;
            const method: []const u8 = if (request == .heartbeat) "lease.heartbeat" else "lease.release";
            break :blk std.fmt.bufPrint(buffer, "{{\"id\":\"{s}\",\"version\":1,\"token\":\"{s}\",\"method\":\"{s}\",\"params\":{{\"leaseId\":\"{s}\"}}}}\n", .{ id, token, method, lease_id });
        },
    };
}

pub const Acquired = struct {
    lease_id: Id,
    explicit_target: bool,
    expires_at: u64,
};

pub const Response = union(enum) {
    acquired: Acquired,
    heartbeat: u64,
    released: bool,
    unknown_lease,
    rejected,
};

const PeerResult = struct {
    leaseId: ?[]const u8 = null,
    requestedPetId: ?[]const u8 = null,
    targetKind: ?[]const u8 = null,
    actualTargetPetId: ?[]const u8 = null,
    usingDefaultPet: ?bool = null,
    fallbackReason: ?[]const u8 = null,
    leaseActive: ?bool = null,
    clientPid: ?u32 = null,
    expiresAt: ?u64 = null,
    released: ?bool = null,
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

/// Return only owned bounded identifiers and closed result categories.
/// Even a fallback lease may be released, but may never drive a reaction.
/// expiresAt is the peer's wall clock, not a local scheduling deadline.
pub fn decode(allocator: std.mem.Allocator, frame: []const u8, id: []const u8, request: Request) error{ InvalidFrame, InvalidResponse, MismatchedId, OutOfMemory }!Response {
    if (frame.len == 0 or frame.len > wire.max_message_bytes or frame[frame.len - 1] != '\n') return error.InvalidFrame;
    const payload = frame[0 .. frame.len - 1];
    if (std.mem.indexOfScalar(u8, payload, '\n') != null or std.mem.indexOfScalar(u8, payload, '\r') != null or !std.unicode.utf8ValidateSlice(payload)) return error.InvalidFrame;
    const parsed = std.json.parseFromSlice(Envelope, allocator, payload, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidResponse,
    };
    defer parsed.deinit();
    const value = parsed.value;
    if (!value.ok) {
        if (value.result != null) return error.InvalidResponse;
        const failure = value.@"error" orelse return error.InvalidResponse;
        if (value.id) |response_id| {
            if (!std.mem.eql(u8, response_id, id)) return error.MismatchedId;
            if (request == .heartbeat and std.mem.eql(u8, failure.code, "unknown_lease")) return .unknown_lease;
        }
        return .rejected;
    }
    if (!std.mem.eql(u8, value.id orelse return error.MismatchedId, id)) return error.MismatchedId;
    if (value.@"error" != null) return error.InvalidResponse;
    const result = value.result orelse return error.InvalidResponse;
    return switch (request) {
        .acquire => |a| blk: {
            const lease_id = Id.parse(result.leaseId orelse return error.InvalidResponse) catch return error.InvalidResponse;
            const expiry = result.expiresAt orelse return error.InvalidResponse;
            if (expiry == 0 or result.leaseActive != true or result.clientPid != a.client_pid) return error.InvalidResponse;
            if (!std.mem.eql(u8, result.requestedPetId orelse return error.InvalidResponse, a.pet_id)) return error.InvalidResponse;
            const target = result.targetKind orelse return error.InvalidResponse;
            const actual = result.actualTargetPetId orelse return error.InvalidResponse;
            if (!petId(actual)) return error.InvalidResponse;
            const is_default = result.usingDefaultPet orelse return error.InvalidResponse;
            const explicit = std.mem.eql(u8, target, "explicit");
            if (!explicit and !std.mem.eql(u8, target, "default")) return error.InvalidResponse;
            if (explicit == is_default) return error.InvalidResponse;
            break :blk .{ .acquired = .{
                .lease_id = lease_id,
                .explicit_target = explicit and result.fallbackReason == null and std.mem.eql(u8, actual, a.pet_id),
                .expires_at = expiry,
            } };
        },
        .heartbeat => |lease_id| blk: {
            if (!std.mem.eql(u8, result.leaseId orelse return error.InvalidResponse, lease_id)) return error.InvalidResponse;
            const expiry = result.expiresAt orelse return error.InvalidResponse;
            if (expiry == 0) return error.InvalidResponse;
            break :blk .{ .heartbeat = expiry };
        },
        .release => .{ .released = result.released orelse return error.InvalidResponse },
    };
}

pub const renew_ms: u64 = 5000;
// Conservative local validity window under pinned upstream's 15s TTL.
// Anchor to request START, not receipt, to include network/worker delay.
pub const local_valid_ms: u64 = 10000;

pub const Session = struct {
    state: enum { empty, active, suspended, release_only } = .empty,
    lease_id: ?Id = null,
    renew_at: u64 = 0,
    valid_until: u64 = 0,

    pub fn clear(self: *Session) void {
        self.* = .{};
    }

    /// Accept only an initial, explicitly approved acquisition result.
    /// A rejected/late/fallback lease is retained solely for cleanup.
    pub fn acceptAcquire(self: *Session, response: Acquired, started: u64, now: u64) error{AlreadyOwned}!void {
        if (self.state != .empty) return error.AlreadyOwned;
        self.lease_id = response.lease_id;
        self.state = .release_only;
        if (response.explicit_target and now >= started and now < started +| local_valid_ms) {
            self.state = .active;
            self.renew_at = started +| renew_ms;
            self.valid_until = started +| local_valid_ms;
        }
    }

    pub fn reaction(self: *const Session, now: u64, value: wire.Reaction) ?wire.Request {
        if (self.state != .active or now >= self.renew_at or now >= self.valid_until) return null;
        const id = if (self.lease_id) |*owned| owned else return null;
        return .{ .react = .{ .reaction = value, .lease_id = id.slice() } };
    }

    /// Suspend mutations immediately, including during an in-flight heartbeat.
    /// Caller must serialize I/O and apply the matching result before another
    /// action. Only the existing lease may be renewed; never auto-acquire.
    pub fn beginHeartbeat(self: *Session, now: u64) ?Request {
        if (self.state != .active and self.state != .suspended) return null;
        if (now >= self.valid_until) {
            self.state = .release_only;
            return null;
        }
        const id = if (self.lease_id) |*owned| owned else return null;
        self.state = .suspended;
        return .{ .heartbeat = id.slice() };
    }

    pub fn acceptHeartbeat(self: *Session, response: Response, started: u64, now: u64) void {
        if (self.state != .suspended) return;
        switch (response) {
            .unknown_lease => self.clear(),
            .heartbeat => |expiry| {
                if (expiry == 0 or now < started or now >= self.valid_until or now >= started +| local_valid_ms) {
                    self.state = .release_only;
                    return;
                }
                self.renew_at = started +| renew_ms;
                self.valid_until = started +| local_valid_ms;
                self.state = .active;
            },
            else => self.state = .release_only,
        }
    }

    pub fn invalidate(self: *Session) void {
        if (self.state != .empty) self.state = .release_only;
    }

    pub fn beginRelease(self: *Session) ?Request {
        const id = if (self.lease_id) |*owned| owned else return null;
        self.state = .release_only;
        return .{ .release = id.slice() };
    }

    /// On ambiguous release failure retain release-only state; expiry is the
    /// server's final cleanup mechanism. No reaction or implicit reacquire.
    pub fn acceptRelease(self: *Session, response: Response) void {
        if (self.state != .release_only) return;
        if (response == .released) self.clear();
    }
};

const t = std.testing;
const token = "0123456789abcdef0123456789abcdef";
const acquire: Request = .{ .acquire = .{ .pet_id = "pulse-pet", .client_pid = 42, .session_nonce = "session-1" } };
const explicit_fixture = "{\"id\":\"a\",\"ok\":true,\"result\":{\"leaseId\":\"lease-1\",\"requestedPetId\":\"pulse-pet\",\"targetKind\":\"explicit\",\"actualTargetPetId\":\"pulse-pet\",\"usingDefaultPet\":false,\"leaseActive\":true,\"clientPid\":42,\"expiresAt\":1700000015000}}\n";
const fallback_fixture = "{\"id\":\"a\",\"ok\":true,\"result\":{\"leaseId\":\"lease-2\",\"requestedPetId\":\"pulse-pet\",\"targetKind\":\"default\",\"actualTargetPetId\":\"default-pet\",\"usingDefaultPet\":true,\"fallbackReason\":\"pet_not_installed\",\"leaseActive\":true,\"clientPid\":42,\"expiresAt\":1700000015000}}\n";

test "lease requests use pinned method shapes and refuse implicit targets" {
    var buffer: [1024]u8 = undefined;
    try t.expectEqualStrings("{\"id\":\"a\",\"version\":1,\"token\":\"0123456789abcdef0123456789abcdef\",\"method\":\"lease.acquire\",\"params\":{\"requestedPetId\":\"pulse-pet\",\"clientPid\":42,\"sessionNonce\":\"session-1\"}}\n", try encode(&buffer, "a", token, acquire));
    try t.expectEqualStrings("{\"id\":\"a\",\"version\":1,\"token\":\"0123456789abcdef0123456789abcdef\",\"method\":\"lease.heartbeat\",\"params\":{\"leaseId\":\"lease-1\"}}\n", try encode(&buffer, "a", token, .{ .heartbeat = "lease-1" }));
    try t.expectEqualStrings("{\"id\":\"a\",\"version\":1,\"token\":\"0123456789abcdef0123456789abcdef\",\"method\":\"lease.release\",\"params\":{\"leaseId\":\"lease-1\"}}\n", try encode(&buffer, "a", token, .{ .release = "lease-1" }));
    try t.expectError(error.InvalidTarget, encode(&buffer, "a", token, .{ .acquire = .{ .pet_id = "", .client_pid = 42, .session_nonce = "session-1" } }));
    try t.expectError(error.InvalidLease, encode(&buffer, "a", token, .{ .release = "bad\n" }));
}

test "lease responses have no nested ok field and preserve fallback for cleanup" {
    const response = try decode(t.allocator, explicit_fixture, "a", acquire);
    try t.expect(response.acquired.explicit_target);
    try t.expectEqualStrings("lease-1", response.acquired.lease_id.slice());
    const fallback = try decode(t.allocator, fallback_fixture, "a", acquire);
    try t.expect(!fallback.acquired.explicit_target);
    try t.expectEqualStrings("lease-2", fallback.acquired.lease_id.slice());
    try t.expectError(error.MismatchedId, decode(t.allocator, explicit_fixture, "b", acquire));
    try t.expectError(error.InvalidResponse, decode(t.allocator, "{\"id\":\"a\",\"ok\":true,\"result\":{\"leaseId\":\"other\",\"expiresAt\":1}}\n", "a", .{ .heartbeat = "lease-1" }));
    const heartbeat = try decode(t.allocator, "{\"id\":\"a\",\"ok\":true,\"result\":{\"leaseId\":\"lease-1\",\"expiresAt\":1700000020000}}\n", "a", .{ .heartbeat = "lease-1" });
    try t.expectEqual(@as(u64, 1700000020000), heartbeat.heartbeat);
    const release = try decode(t.allocator, "{\"id\":\"a\",\"ok\":true,\"result\":{\"released\":false}}\n", "a", .{ .release = "lease-1" });
    try t.expect(!release.released);
}

test "lease session renews early and suspends reactions during renewal" {
    const response = try decode(t.allocator, explicit_fixture, "a", acquire);
    var session: Session = .{};
    try session.acceptAcquire(response.acquired, 100, 200);
    try t.expect(session.reaction(5099, .working) != null);
    try t.expect(session.reaction(5100, .working) == null);
    const heartbeat = session.beginHeartbeat(5100).?;
    try t.expectEqualStrings("lease-1", heartbeat.heartbeat);
    try t.expect(session.reaction(5101, .working) == null);
    session.acceptHeartbeat(.{ .heartbeat = 1700000020000 }, 5100, 5200);
    try t.expect(session.reaction(5200, .working) != null);
    try t.expect(session.beginHeartbeat(15100) == null);
    try t.expect(session.reaction(15100, .working) == null);
    const release = session.beginRelease().?;
    try t.expectEqualStrings("lease-1", release.release);
    session.acceptRelease(.{ .released = false });
    try t.expect(session.lease_id == null);
}

test "fallback and late leases never react and can be released" {
    const fallback = try decode(t.allocator, fallback_fixture, "a", acquire);
    var session: Session = .{};
    try session.acceptAcquire(fallback.acquired, 100, 200);
    try t.expect(session.reaction(200, .working) == null);
    try t.expect(session.beginHeartbeat(200) == null);
    try t.expectError(error.AlreadyOwned, session.acceptAcquire(fallback.acquired, 100, 200));
    try t.expect(session.beginRelease() != null);
    session.acceptRelease(.rejected);
    try t.expect(session.lease_id != null);
    session.acceptRelease(.{ .released = true });
    const response = try decode(t.allocator, explicit_fixture, "a", acquire);
    try session.acceptAcquire(response.acquired, 100, 10100);
    try t.expect(session.reaction(10100, .working) == null);
}

test "unknown lease and ambiguous transport stop mutations" {
    const response = try decode(t.allocator, explicit_fixture, "a", acquire);
    var session: Session = .{};
    try session.acceptAcquire(response.acquired, 100, 200);
    try t.expect(session.beginHeartbeat(5100) != null);
    const unknown = try decode(t.allocator, "{\"id\":\"a\",\"ok\":false,\"error\":{\"code\":\"unknown_lease\",\"message\":\"peer detail\"}}\n", "a", .{ .heartbeat = "lease-1" });
    session.acceptHeartbeat(unknown, 5100, 5200);
    try t.expect(session.lease_id == null);
    try session.acceptAcquire(response.acquired, 100, 200);
    session.invalidate();
    try t.expect(session.reaction(201, .working) == null);
    try t.expect(session.beginHeartbeat(201) == null);
    try t.expect(session.beginRelease() != null);
}
