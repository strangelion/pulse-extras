//! Transport-independent, single-file receive contract.
//! No filesystem, sockets, allocation or Pulse calls. The worker must stage
//! each accepted chunk successfully before reporting it here, and commit
//! the staged file only after verification. This is not a wire protocol.

const std = @import("std");

pub const max_file_bytes: u64 = 1024 * 1024 * 1024 * 1024;
pub const max_chunk_bytes: usize = 256 * 1024;
pub const Digest = [32]u8;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const State = enum {
    awaiting_approval,
    receiving,
    verified,
    completed,
    declined,
    cancelled,
    failed,

    pub fn terminal(self: State) bool {
        return switch (self) {
            .completed, .declined, .cancelled, .failed => true,
            else => false,
        };
    }
};

pub const Receive = struct {
    state: State = .awaiting_approval,
    expected_bytes: u64,
    expected_digest: Digest,
    received_bytes: u64 = 0,
    hash: Sha256,

    pub fn init(size: u64, expected: Digest) error{TooLarge}!Receive {
        if (size > max_file_bytes) return error.TooLarge;
        return .{
            .expected_bytes = size,
            .expected_digest = expected,
            .hash = Sha256.init(.{}),
        };
    }

    pub fn approve(self: *Receive, accepted: bool) error{State}!void {
        if (self.state != .awaiting_approval) return error.State;
        self.state = if (accepted) .receiving else .declined;
    }

    /// Report bytes successfully written to a private staging file. Invalid
    /// chunks fail the entire receive; no later chunk may rescue that state.
    pub fn staged(self: *Receive, offset: u64, bytes: []const u8) error{ State, InvalidChunk }!void {
        if (self.state != .receiving) return error.State;
        if (bytes.len == 0 or bytes.len > max_chunk_bytes or
            offset != self.received_bytes or bytes.len > self.expected_bytes - self.received_bytes)
        {
            self.state = .failed;
            return error.InvalidChunk;
        }
        self.hash.update(bytes);
        self.received_bytes += bytes.len;
    }

    /// Verification alone never claims a successful filesystem commit.
    pub fn verify(self: *Receive) error{ State, SizeMismatch, DigestMismatch }!void {
        if (self.state != .receiving) return error.State;
        if (self.received_bytes != self.expected_bytes) {
            self.state = .failed;
            return error.SizeMismatch;
        }
        var actual: Digest = undefined;
        self.hash.final(&actual);
        if (!std.mem.eql(u8, &actual, &self.expected_digest)) {
            self.state = .failed;
            return error.DigestMismatch;
        }
        self.state = .verified;
    }

    /// Only call with the result of a successful no-overwrite staged commit.
    pub fn committed(self: *Receive, success: bool) error{State}!void {
        if (self.state != .verified) return error.State;
        self.state = if (success) .completed else .failed;
    }

    pub fn cancel(self: *Receive) void {
        if (!self.state.terminal()) self.state = .cancelled;
    }

    pub fn fail(self: *Receive) void {
        if (!self.state.terminal()) self.state = .failed;
    }
};

fn digest(bytes: []const u8) Digest {
    var result: Digest = undefined;
    Sha256.hash(bytes, &result, .{});
    return result;
}

test "explicit approval and verification precede commit" {
    var receive = try Receive.init(6, digest("abcdef"));
    try std.testing.expectError(error.State, receive.staged(0, "abc"));
    try std.testing.expectError(error.State, receive.committed(true));
    try receive.approve(true);
    try receive.staged(0, "abc");
    try receive.staged(3, "def");
    try receive.verify();
    try std.testing.expectEqual(State.verified, receive.state);
    try receive.committed(true);
    try std.testing.expectEqual(State.completed, receive.state);
    receive.cancel();
    try std.testing.expectEqual(State.completed, receive.state);
}

test "declined and cancelled receives cannot restart" {
    var declined = try Receive.init(1, digest("x"));
    try declined.approve(false);
    try std.testing.expectError(error.State, declined.approve(true));
    try std.testing.expectError(error.State, declined.staged(0, "x"));
    var cancelled = try Receive.init(1, digest("x"));
    try cancelled.approve(true);
    cancelled.cancel();
    try std.testing.expectError(error.State, cancelled.verify());
    try std.testing.expectEqual(State.cancelled, cancelled.state);
}

test "size mismatch and corrupt bytes prevent publication" {
    var short = try Receive.init(2, digest("ab"));
    try short.approve(true);
    try short.staged(0, "a");
    try std.testing.expectError(error.SizeMismatch, short.verify());
    var corrupt = try Receive.init(2, digest("ab"));
    try corrupt.approve(true);
    try corrupt.staged(0, "ac");
    try std.testing.expectError(error.DigestMismatch, corrupt.verify());
    try std.testing.expectError(error.State, corrupt.committed(true));
    try std.testing.expectEqual(State.failed, corrupt.state);
}

test "out of order and oversized chunks fail closed" {
    var out_of_order = try Receive.init(2, digest("ab"));
    try out_of_order.approve(true);
    try std.testing.expectError(error.InvalidChunk, out_of_order.staged(1, "a"));
    try std.testing.expectError(error.State, out_of_order.staged(0, "ab"));
    var excess = try Receive.init(1, digest("a"));
    try excess.approve(true);
    try std.testing.expectError(error.InvalidChunk, excess.staged(0, "ab"));
    try std.testing.expectError(error.TooLarge, Receive.init(max_file_bytes + 1, digest("")));
}

test "empty file and failed destination commit" {
    var receive = try Receive.init(0, digest(""));
    try receive.approve(true);
    try receive.verify();
    try receive.committed(false);
    try std.testing.expectEqual(State.failed, receive.state);
}

test "cancel after verification still prevents commit" {
    var receive = try Receive.init(0, digest(""));
    try receive.approve(true);
    try receive.verify();
    receive.cancel();
    try std.testing.expectError(error.State, receive.committed(true));
}
