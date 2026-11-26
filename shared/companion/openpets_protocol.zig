//! Experimental OpenPets v1 local IPC wire codec.
//! Pure wire codec, Windows discovery validation, bounded framing and a mockable probe.
//! OS authentication and deadline-aware I/O are adapter responsibilities.
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
    var too_large: [max_message_bytes + 1]u8 = undefined;
    @memset(&too_large, 'x');
    try testing.expectError(error.InvalidFrame, decode(testing.allocator, &too_large, "a", .hello));
}

// The pinned Windows server generates \\.\pipe\openpets-<16 hex>-<pid>.
// Deliberately reject custom endpoints, TCP, UNC hosts and Unix sockets.
const pipe_prefix = "\\\\.\\pipe\\openpets-";
pub const max_endpoint_bytes: usize = 240;
pub const max_token_bytes: usize = 256;

const DiscoveryWire = struct {
    protocol: []const u8,
    protocolVersion: u32,
    endpoint: []const u8,
    token: []const u8,
    appVersion: []const u8,
    pid: u32,
    platform: []const u8,
};

/// Owned, bounded copy. Never format or log this value: it contains a token.
/// clear() removes the active copy; the caller also owns and must clear the
/// input and any scratch storage used by its allocator.
pub const WindowsDiscovery = struct {
    endpoint_bytes: [max_endpoint_bytes]u8,
    token_bytes: [max_token_bytes]u8,
    endpoint_len: usize,
    token_len: usize,
    pid: u32,

    pub fn endpoint(self: *const WindowsDiscovery) []const u8 {
        return self.endpoint_bytes[0..self.endpoint_len];
    }

    pub fn token(self: *const WindowsDiscovery) []const u8 {
        return self.token_bytes[0..self.token_len];
    }

    pub fn clear(self: *WindowsDiscovery) void {
        @memset(&self.endpoint_bytes, 0);
        @memset(&self.token_bytes, 0);
        self.endpoint_len = 0;
        self.token_len = 0;
        self.pid = 0;
    }
};

fn validWindowsPipe(endpoint: []const u8, pid: u32) bool {
    if (endpoint.len > max_endpoint_bytes or !std.mem.startsWith(u8, endpoint, pipe_prefix)) return false;
    const suffix = endpoint[pipe_prefix.len..];
    if (suffix.len < 18 or suffix[16] != '-') return false;
    for (suffix[0..16]) |c| {
        if (!(c >= '0' and c <= '9') and !(c >= 'a' and c <= 'f')) return false;
    }
    const pid_text = suffix[17..];
    if (pid_text[0] == '0') return false;
    for (pid_text) |c| {
        if (c < '0' or c > '9') return false;
    }
    const parsed_pid = std.fmt.parseInt(u32, pid_text, 10) catch return false;
    return pid != 0 and parsed_pid == pid;
}

/// Pure discovery validation only. A syntactically valid endpoint is NOT
/// authenticated. The future transport must verify file ownership/ACLs,
/// reparse points and server identity on opened handles before sending a
/// token. Use a bounded scratch allocator; no OS I/O is performed here.
/// On error, out is unchanged. No peer strings escape except the validated
/// endpoint and token.
pub fn parseWindowsDiscovery(allocator: std.mem.Allocator, input: []const u8, out: *WindowsDiscovery) error{ InvalidDiscovery, OutOfMemory }!void {
    if (input.len == 0 or input.len > max_message_bytes or !std.unicode.utf8ValidateSlice(input)) return error.InvalidDiscovery;
    const parsed = std.json.parseFromSlice(DiscoveryWire, allocator, input, .{ .ignore_unknown_fields = true }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidDiscovery,
    };
    defer parsed.deinit();
    const wire = parsed.value;
    if (wire.protocolVersion != protocol_version or !std.mem.eql(u8, wire.protocol, "openpets-ipc")) return error.InvalidDiscovery;
    if (!std.mem.eql(u8, wire.platform, "win32")) return error.InvalidDiscovery;
    if (wire.appVersion.len == 0 or wire.appVersion.len > 128) return error.InvalidDiscovery;
    if (!validWindowsPipe(wire.endpoint, wire.pid) or !safeAtom(wire.token, 16, max_token_bytes)) return error.InvalidDiscovery;

    out.clear();
    @memcpy(out.endpoint_bytes[0..wire.endpoint.len], wire.endpoint);
    @memcpy(out.token_bytes[0..wire.token.len], wire.token);
    out.endpoint_len = wire.endpoint.len;
    out.token_len = wire.token.len;
    out.pid = wire.pid;
}

/// Incremental LF framing over caller-owned storage. One instance per
/// connection, no allocation or unbounded accumulation. The transport owns
/// timeouts/cancellation and must stop reading at EOF or its deadline.
/// Reject extra bytes in the same chunk or later chunks; never decode a
/// failed frame. Call finish after the peer closes the response stream.
pub const ResponseFramer = struct {
    storage: []u8,
    len: usize = 0,
    state: enum { receiving, complete, failed } = .receiving,

    pub fn init(storage: []u8) ResponseFramer {
        return .{ .storage = storage[0..@min(storage.len, max_message_bytes)] };
    }

    pub fn feed(self: *ResponseFramer, chunk: []const u8) error{InvalidFrame}!void {
        if (self.state == .failed) return error.InvalidFrame;
        if (chunk.len == 0) return;
        if (self.state == .complete or chunk.len > self.storage.len - self.len) {
            self.state = .failed;
            return error.InvalidFrame;
        }
        if (std.mem.indexOfScalar(u8, chunk, '\r') != null) {
            self.state = .failed;
            return error.InvalidFrame;
        }
        if (std.mem.indexOfScalar(u8, chunk, '\n')) |newline| {
            if (newline != chunk.len - 1 or (newline == 0 and self.len == 0)) {
                self.state = .failed;
                return error.InvalidFrame;
            }
            self.state = .complete;
        } else if (chunk.len == self.storage.len - self.len) {
            // No room remains for the required LF.
            self.state = .failed;
            return error.InvalidFrame;
        }
        @memcpy(self.storage[self.len..][0..chunk.len], chunk);
        self.len += chunk.len;
    }

    pub fn finish(self: *const ResponseFramer) error{InvalidFrame}![]const u8 {
        if (self.state != .complete) return error.InvalidFrame;
        return self.storage[0..self.len];
    }

    pub fn reset(self: *ResponseFramer) void {
        @memset(self.storage[0..self.len], 0);
        self.len = 0;
        self.state = .receiving;
    }
};

const discovery_fixture = "{\"protocol\":\"openpets-ipc\",\"protocolVersion\":1,\"endpoint\":\"\\\\\\\\.\\\\pipe\\\\openpets-0123456789abcdef-42\",\"token\":\"0123456789abcdef0123456789abcdef\",\"appVersion\":\"0.0.0\",\"pid\":42,\"platform\":\"win32\"}";

test "Windows discovery owns validated endpoint and token" {
    var input: [discovery_fixture.len]u8 = undefined;
    @memcpy(&input, discovery_fixture);
    var discovery: WindowsDiscovery = undefined;
    try parseWindowsDiscovery(testing.allocator, &input, &discovery);
    @memset(&input, 0);
    try testing.expectEqualStrings(pipe_prefix ++ "0123456789abcdef-42", discovery.endpoint());
    try testing.expectEqualStrings(fixture_token, discovery.token());
    try testing.expectEqual(@as(u32, 42), discovery.pid);
    discovery.clear();
    try testing.expectEqual(@as(usize, 0), discovery.token().len);
    for (discovery.token_bytes) |byte| try testing.expectEqual(@as(u8, 0), byte);
}

test "Windows discovery rejects remote and ambiguous pipe names" {
    try testing.expect(!validWindowsPipe("tcp://127.0.0.1:1234", 42));
    try testing.expect(!validWindowsPipe("\\\\remote\\pipe\\openpets-0123456789abcdef-42", 42));
    try testing.expect(!validWindowsPipe(pipe_prefix ++ "0123456789abcdef-43", 42));
    try testing.expect(!validWindowsPipe(pipe_prefix ++ "0123456789abcdef-042", 42));
    try testing.expect(!validWindowsPipe(pipe_prefix ++ "0123456789abcdef-42\\other", 42));
    try testing.expect(!validWindowsPipe(pipe_prefix ++ "0123456789abcdef-4294967296", 42));
    try testing.expect(!validWindowsPipe(pipe_prefix ++ "0123456789abcdeG-42", 42));
    try testing.expect(!validWindowsPipe(pipe_prefix ++ "0123456789abcdef-0", 0));
}

test "Windows discovery rejects malformed and oversized input without replacing output" {
    var discovery: WindowsDiscovery = undefined;
    try parseWindowsDiscovery(testing.allocator, discovery_fixture, &discovery);
    defer discovery.clear();
    try testing.expectError(error.InvalidDiscovery, parseWindowsDiscovery(testing.allocator, "{}", &discovery));
    try testing.expectError(error.InvalidDiscovery, parseWindowsDiscovery(testing.allocator, "{\"protocol\":\"openpets-ipc\",\"protocol\":1}", &discovery));
    var oversized: [max_message_bytes + 1]u8 = undefined;
    @memset(&oversized, 'x');
    try testing.expectError(error.InvalidDiscovery, parseWindowsDiscovery(testing.allocator, &oversized, &discovery));
    try testing.expectEqualStrings(fixture_token, discovery.token());
}

test "response framer assembles split responses and rejects trailing bytes" {
    var storage: [128]u8 = undefined;
    var framer = ResponseFramer.init(&storage);
    try framer.feed("{\"id\":");
    try testing.expectError(error.InvalidFrame, framer.finish());
    try framer.feed("\"a\"}\n");
    try testing.expectEqualStrings("{\"id\":\"a\"}\n", try framer.finish());
    try testing.expectError(error.InvalidFrame, framer.feed("x"));
    try testing.expectError(error.InvalidFrame, framer.finish());
    framer.reset();
    try testing.expectError(error.InvalidFrame, framer.feed("{}\n{}\n"));
    try testing.expectError(error.InvalidFrame, framer.finish());
    framer.reset();
    try testing.expectError(error.InvalidFrame, framer.feed("{}\r\n"));
    framer.reset();
    try testing.expectError(error.InvalidFrame, framer.feed("\n"));
}

test "response framer enforces storage and wire caps including the LF" {
    var storage: [max_message_bytes + 1]u8 = undefined;
    var chunk: [max_message_bytes]u8 = undefined;
    @memset(&chunk, 'x');
    chunk[chunk.len - 1] = '\n';
    var framer = ResponseFramer.init(&storage);
    try framer.feed(&chunk);
    try testing.expectEqual(max_message_bytes, (try framer.finish()).len);
    framer.reset();
    try testing.expectError(error.InvalidFrame, framer.feed(&storage));
    framer.reset();
    var small: [4]u8 = undefined;
    framer = ResponseFramer.init(&small);
    try testing.expectError(error.InvalidFrame, framer.feed("abcd"));
    framer.reset();
    try framer.feed("abc\n");
    try testing.expectEqualStrings("abc\n", try framer.finish());
}

// Read-only transaction gate. The OS adapter is deliberately not implemented
// here: it must establish trust on actual handles, not just parse path strings.
pub const ProbeKind = enum { hello, status };
pub const TransportError = error{ Unavailable, Untrusted, TimedOut, Canceled, IoFailure };
pub const ProbeError = TransportError || error{ InvalidDiscovery, InvalidId, InvalidToken, InvalidLease, NoSpaceLeft, InvalidFrame, InvalidResponse, MismatchedId, OutOfMemory, InvalidProgress };

/// All callbacks run on a worker, never on the Pulse UI thread.
/// Deadlines use the same monotonic clock as now_ms, in milliseconds.
/// read_trusted_discovery must validate owner, ACL and reparse safety on the
/// opened file and its parent path, and detect oversized input (not truncate).
/// connect_verified must open a local pipe, verify its server PID and trusted
/// process identity on the opened connection before returning success.
/// A failed connect must clean up its own partial handles. A successful one
/// transfers one connection to the transaction until close. No reconnects.
/// I/O must honor the absolute deadline, cancel and drain pending operations
/// before returning, and never retain passed slices. read returns zero on EOF.
/// close must be nonblocking after I/O has drained, and must release all
/// connection-owned handles. No callback may log credentials or wire bytes.
/// This contract is a test seam, not proof of Windows authentication.
pub const ProbeTransport = struct {
    context: *anyopaque,
    now_ms: *const fn (*anyopaque) u64,
    read_trusted_discovery: *const fn (*anyopaque, []u8, u64) TransportError!usize,
    connect_verified: *const fn (*anyopaque, []const u8, u32, u64) TransportError!void,
    write: *const fn (*anyopaque, []const u8, u64) TransportError!usize,
    read: *const fn (*anyopaque, []u8, u64) TransportError!usize,
    close: *const fn (*anyopaque) void,

    fn checkDeadline(self: ProbeTransport, deadline: u64) TransportError!void {
        if (self.now_ms(self.context) >= deadline) return error.TimedOut;
    }
};

pub const connect_budget_ms: u64 = 2000;
pub const response_budget_ms: u64 = 3000;

/// One reusable, caller-owned workspace per in-flight probe. No allocation
/// proportional to peer-supplied sizes. Do not share concurrently.
pub const ProbeWorkspace = struct {
    discovery: [max_message_bytes]u8,
    response: [max_message_bytes]u8,
    request: [1024]u8,
    chunk: [1024]u8,
    parse_scratch: [64 * 1024]u8,

    pub fn clear(self: *ProbeWorkspace) void {
        @memset(&self.discovery, 0);
        @memset(&self.response, 0);
        @memset(&self.request, 0);
        @memset(&self.chunk, 0);
        @memset(&self.parse_scratch, 0);
    }
};

/// One hello or status exchange. Never acquires a lease, mutates a pet,
/// launches a process, falls back to TCP, or retries an ambiguous request.
/// Discovery and connect share a 2s budget; writing and reading share a
/// further 3s budget. Partial progress never refreshes either deadline.
/// Only the adapter can enforce time limits within a blocking OS call.
/// Caller provides workspace and a fresh request ID for every transaction.
pub fn probe(transport: ProbeTransport, workspace: *ProbeWorkspace, id: []const u8, kind: ProbeKind) ProbeError!Response {
    defer workspace.clear();
    if (!safeAtom(id, 1, 120)) return error.InvalidId;

    const connect_deadline = transport.now_ms(transport.context) +| connect_budget_ms;
    try transport.checkDeadline(connect_deadline);
    const discovery_len = try transport.read_trusted_discovery(transport.context, &workspace.discovery, connect_deadline);
    try transport.checkDeadline(connect_deadline);
    if (discovery_len == 0 or discovery_len > workspace.discovery.len) return error.InvalidDiscovery;

    var discovery: WindowsDiscovery = undefined;
    var discovery_allocator = std.heap.FixedBufferAllocator.init(&workspace.parse_scratch);
    try parseWindowsDiscovery(discovery_allocator.allocator(), workspace.discovery[0..discovery_len], &discovery);
    defer discovery.clear();
    @memset(&workspace.discovery, 0);
    @memset(&workspace.parse_scratch, 0);

    try transport.checkDeadline(connect_deadline);
    try transport.connect_verified(transport.context, discovery.endpoint(), discovery.pid, connect_deadline);
    defer transport.close(transport.context);
    try transport.checkDeadline(connect_deadline);

    const request: Request = switch (kind) {
        .hello => .hello,
        .status => .status,
    };
    const message = try encode(&workspace.request, id, discovery.token(), request);
    discovery.clear();
    const response_deadline = transport.now_ms(transport.context) +| response_budget_ms;

    var sent: usize = 0;
    while (sent < message.len) {
        try transport.checkDeadline(response_deadline);
        const written = try transport.write(transport.context, message[sent..], response_deadline);
        try transport.checkDeadline(response_deadline);
        if (written == 0 or written > message.len - sent) return error.InvalidProgress;
        sent += written;
    }
    @memset(&workspace.request, 0);

    var framer = ResponseFramer.init(&workspace.response);
    while (true) {
        try transport.checkDeadline(response_deadline);
        const received = try transport.read(transport.context, &workspace.chunk, response_deadline);
        try transport.checkDeadline(response_deadline);
        if (received > workspace.chunk.len) return error.InvalidProgress;
        if (received == 0) break;
        try framer.feed(workspace.chunk[0..received]);
    }

    var response_allocator = std.heap.FixedBufferAllocator.init(&workspace.parse_scratch);
    const result = try decode(response_allocator.allocator(), try framer.finish(), id, request);
    try transport.checkDeadline(response_deadline);
    return result;
}

const ProbeMock = struct {
    const Scenario = enum {
        success,
        untrusted_file,
        untrusted_peer,
        late_connect,
        zero_write,
        invalid_write_count,
        canceled_write,
        late_read,
        invalid_read_count,
        truncated,
        trailing_bytes,
        wrong_id,
        rejected,
    };

    scenario: Scenario = .success,
    clock: u64 = 100,
    connected: bool = false,
    connects: usize = 0,
    closes: usize = 0,
    writes: usize = 0,
    reads: usize = 0,
    sent: [1024]u8 = undefined,
    sent_len: usize = 0,
    read_offset: usize = 0,

    const hello_response = "{\"id\":\"probe-1\",\"ok\":true,\"result\":{\"ok\":true,\"protocol\":\"openpets-ipc\",\"protocolVersion\":1}}\n";
    const status_response = "{\"id\":\"probe-1\",\"ok\":true,\"result\":{\"ok\":true,\"protocolVersion\":1,\"appRunning\":true,\"paused\":false,\"defaultPetVisible\":true}}\n";

    fn fromContext(ctx: *anyopaque) *ProbeMock {
        return @ptrCast(@alignCast(ctx));
    }

    fn now(ctx: *anyopaque) u64 {
        return fromContext(ctx).clock;
    }

    fn readDiscovery(ctx: *anyopaque, buffer: []u8, deadline: u64) TransportError!usize {
        const self = fromContext(ctx);
        if (self.scenario == .untrusted_file) return error.Untrusted;
        if (self.clock >= deadline) return error.TimedOut;
        @memcpy(buffer[0..discovery_fixture.len], discovery_fixture);
        return discovery_fixture.len;
    }

    fn connect(ctx: *anyopaque, endpoint: []const u8, pid: u32, deadline: u64) TransportError!void {
        const self = fromContext(ctx);
        self.connects += 1;
        if (self.scenario == .untrusted_peer or pid != 42 or !std.mem.eql(u8, endpoint, pipe_prefix ++ "0123456789abcdef-42")) return error.Untrusted;
        self.connected = true;
        if (self.scenario == .late_connect) self.clock = deadline;
    }

    fn writeChunk(ctx: *anyopaque, bytes: []const u8, deadline: u64) TransportError!usize {
        const self = fromContext(ctx);
        if (!self.connected) return error.IoFailure;
        if (self.clock >= deadline) return error.TimedOut;
        self.writes += 1;
        switch (self.scenario) {
            .zero_write => return 0,
            .invalid_write_count => return bytes.len + 1,
            .canceled_write => return error.Canceled,
            else => {},
        }
        const count = @min(bytes.len, 7);
        if (count > self.sent.len - self.sent_len) return error.IoFailure;
        @memcpy(self.sent[self.sent_len..][0..count], bytes[0..count]);
        self.sent_len += count;
        return count;
    }

    fn readChunk(ctx: *anyopaque, bytes: []u8, deadline: u64) TransportError!usize {
        const self = fromContext(ctx);
        if (!self.connected) return error.IoFailure;
        if (self.clock >= deadline) return error.TimedOut;
        self.reads += 1;
        if (self.scenario == .invalid_read_count) return bytes.len + 1;
        if (self.scenario == .late_read) self.clock = deadline;
        const is_status = std.mem.indexOf(u8, self.sent[0..self.sent_len], "\"method\":\"status\"") != null;
        const response: []const u8 = switch (self.scenario) {
            .truncated => hello_response[0 .. hello_response.len - 1],
            .trailing_bytes => hello_response ++ "x",
            .wrong_id => "{\"id\":\"different\",\"ok\":true,\"result\":{\"ok\":true,\"protocol\":\"openpets-ipc\",\"protocolVersion\":1}}\n",
            .rejected => "{\"id\":null,\"ok\":false,\"error\":{\"code\":\"invalid_token\",\"message\":\"rejected\"}}\n",
            else => if (is_status) status_response else hello_response,
        };
        const count = @min(@min(bytes.len, 9), response.len - self.read_offset);
        @memcpy(bytes[0..count], response[self.read_offset..][0..count]);
        self.read_offset += count;
        return count;
    }

    fn close(ctx: *anyopaque) void {
        const self = fromContext(ctx);
        self.connected = false;
        self.closes += 1;
        @memset(&self.sent, 0);
        self.sent_len = 0;
    }

    fn transport(self: *ProbeMock) ProbeTransport {
        return .{
            .context = self,
            .now_ms = now,
            .read_trusted_discovery = readDiscovery,
            .connect_verified = connect,
            .write = writeChunk,
            .read = readChunk,
            .close = close,
        };
    }
};

test "read-only probe handles partial writes and reads and closes once" {
    var workspace: ProbeWorkspace = undefined;
    var mock: ProbeMock = .{};
    try testing.expect((try probe(mock.transport(), &workspace, "probe-1", .hello)) == .hello);
    try testing.expect(mock.writes > 1 and mock.reads > 1);
    try testing.expectEqual(@as(usize, 1), mock.closes);
    try testing.expect(!mock.connected);
    for (workspace.request) |byte| try testing.expectEqual(@as(u8, 0), byte);
    for (workspace.discovery) |byte| try testing.expectEqual(@as(u8, 0), byte);
    for (workspace.parse_scratch) |byte| try testing.expectEqual(@as(u8, 0), byte);

    mock = .{};
    const response = try probe(mock.transport(), &workspace, "probe-1", .status);
    try testing.expect(response.status.running and response.status.visible and !response.status.paused);
    try testing.expectEqual(@as(usize, 1), mock.closes);
}

test "probe never writes credentials on untrusted discovery or connection" {
    var workspace: ProbeWorkspace = undefined;
    var mock: ProbeMock = .{ .scenario = .untrusted_file };
    try testing.expectError(error.Untrusted, probe(mock.transport(), &workspace, "probe-1", .hello));
    try testing.expectEqual(@as(usize, 0), mock.connects);
    try testing.expectEqual(@as(usize, 0), mock.writes);
    try testing.expectEqual(@as(usize, 0), mock.closes);

    mock = .{ .scenario = .untrusted_peer };
    try testing.expectError(error.Untrusted, probe(mock.transport(), &workspace, "probe-1", .hello));
    try testing.expectEqual(@as(usize, 1), mock.connects);
    try testing.expectEqual(@as(usize, 0), mock.writes);
    try testing.expectEqual(@as(usize, 0), mock.closes);
}

test "probe cleans up on timeouts cancellation and invalid adapter progress" {
    var workspace: ProbeWorkspace = undefined;
    const cases = [_]struct { scenario: ProbeMock.Scenario, expected: ProbeError }{
        .{ .scenario = .late_connect, .expected = error.TimedOut },
        .{ .scenario = .zero_write, .expected = error.InvalidProgress },
        .{ .scenario = .invalid_write_count, .expected = error.InvalidProgress },
        .{ .scenario = .canceled_write, .expected = error.Canceled },
        .{ .scenario = .late_read, .expected = error.TimedOut },
        .{ .scenario = .invalid_read_count, .expected = error.InvalidProgress },
    };
    for (cases) |case| {
        var mock: ProbeMock = .{ .scenario = case.scenario };
        try testing.expectError(case.expected, probe(mock.transport(), &workspace, "probe-1", .hello));
        try testing.expectEqual(@as(usize, 1), mock.closes);
        try testing.expect(!mock.connected);
        for (workspace.request) |byte| try testing.expectEqual(@as(u8, 0), byte);
    }
}

test "probe rejects truncated extra and mismatched responses without retries" {
    var workspace: ProbeWorkspace = undefined;
    const cases = [_]struct { scenario: ProbeMock.Scenario, expected: ProbeError }{
        .{ .scenario = .truncated, .expected = error.InvalidFrame },
        .{ .scenario = .trailing_bytes, .expected = error.InvalidFrame },
        .{ .scenario = .wrong_id, .expected = error.MismatchedId },
    };
    for (cases) |case| {
        var mock: ProbeMock = .{ .scenario = case.scenario };
        try testing.expectError(case.expected, probe(mock.transport(), &workspace, "probe-1", .hello));
        try testing.expectEqual(@as(usize, 1), mock.connects);
        try testing.expectEqual(@as(usize, 1), mock.closes);
    }
    var mock: ProbeMock = .{ .scenario = .rejected };
    try testing.expect((try probe(mock.transport(), &workspace, "probe-1", .hello)) == .rejected);
    try testing.expectEqual(@as(usize, 1), mock.closes);
}
