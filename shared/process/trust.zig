//! Explicit executable approval and environment admission. Hashing is bounded
//! and rechecked before launch; pathname verification is NOT a race-free
//! security boundary. Caller must approve the installation/root ACLs and
//! configuration. No implicit PATH approval, shell, script or loader injection.

const std = @import("std");
const builtin = @import("builtin");
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const max_executable_bytes: u64 = 256 * 1024 * 1024;

pub fn localAbsolute(path: []const u8) bool {
    if (builtin.os.tag == .windows) {
        return path.len >= 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
    }
    return path.len != 0 and path[0] == '/';
}

pub const Approval = struct {
    path: []const u8,
    digest: [32]u8,

    /// Caller supplies an approved path; Runner copies it into OwnedApproval.
    /// Approval is not inferred from PATH discovery.
    pub fn verify(self: Approval, io: std.Io, requested: []const u8) !void {
        if (!localAbsolute(requested) or !std.mem.eql(u8, requested, self.path)) return error.UnapprovedExecutable;
        if (std.mem.indexOfScalar(u8, requested, 0) != null) return error.UnapprovedExecutable;
        if (builtin.os.tag == .windows and !std.ascii.endsWithIgnoreCase(requested, ".exe")) return error.UnapprovedExecutable;
        const file = try std.Io.Dir.openFileAbsolute(io, requested, .{ .follow_symlinks = false });
        defer file.close(io);
        const actual = try digestFile(io, file);
        if (!std.mem.eql(u8, &actual, &self.digest)) return error.UnapprovedExecutable;
    }
};

pub const OwnedApproval = struct {
    const capacity = 4096;
    bytes: [capacity]u8 = undefined,
    len: u16 = 0,
    digest: [32]u8,

    pub fn init(approval: Approval) error{InvalidApproval}!OwnedApproval {
        if (approval.path.len > capacity or !localAbsolute(approval.path) or std.mem.indexOfScalar(u8, approval.path, 0) != null) return error.InvalidApproval;
        var result: OwnedApproval = .{ .len = @intCast(approval.path.len), .digest = approval.digest };
        @memcpy(result.bytes[0..approval.path.len], approval.path);
        return result;
    }

    pub fn slice(self: *const OwnedApproval) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn view(self: *const OwnedApproval) Approval {
        return .{ .path = self.slice(), .digest = self.digest };
    }
};

pub fn digestFile(io: std.Io, file: std.Io.File) ![32]u8 {
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size > max_executable_bytes) return error.UnapprovedExecutable;
    var hash = Sha256.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const want: usize = @intCast(@min(stat.size - offset, buffer.len));
        const n = try file.readPositionalAll(io, buffer[0..want], offset);
        if (n != want) return error.UnapprovedExecutable;
        hash.update(buffer[0..n]);
        offset += n;
    }
    if ((try file.stat(io)).size != stat.size) return error.UnapprovedExecutable;
    return hash.finalResult();
}

/// Narrow default environment allowlist. No PATH, dynamic loader variables,
/// credential variables, shell startup, or tool configuration injection.
/// Product-specific policies require separate review, not a blacklist.
pub fn validateEnvironment(map: *const std.process.Environ.Map) error{UnapprovedEnvironment}!void {
    var iterator = map.iterator();
    while (iterator.next()) |entry| {
        const key = entry.key_ptr.*;
        const value = entry.value_ptr.*;
        const allowed = std.mem.eql(u8, key, "SystemRoot") or
            std.mem.eql(u8, key, "WINDIR") or
            std.mem.eql(u8, key, "TEMP") or
            std.mem.eql(u8, key, "TMP") or
            std.mem.eql(u8, key, "LANG") or
            std.mem.eql(u8, key, "LC_ALL") or
            (std.mem.eql(u8, key, "GIT_TERMINAL_PROMPT") and std.mem.eql(u8, value, "0")) or
            (std.mem.eql(u8, key, "GIT_OPTIONAL_LOCKS") and std.mem.eql(u8, value, "0"));
        if (!allowed) return error.UnapprovedEnvironment;
        if (std.mem.eql(u8, key, "SystemRoot") or std.mem.eql(u8, key, "WINDIR") or std.mem.eql(u8, key, "TEMP") or std.mem.eql(u8, key, "TMP")) {
            if (!localAbsolute(value)) return error.UnapprovedEnvironment;
        }
    }
}

test "digest verification reads a bounded file and detects changed contents" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "fixture.exe", .{ .read = true });
    defer file.close(io);
    try file.writeStreamingAll(io, "abc");
    var expected: [32]u8 = undefined;
    Sha256.hash("abc", &expected, .{});
    try std.testing.expectEqualSlices(u8, &expected, &(try digestFile(io, file)));
}

test "environment allowlist rejects injection and credential variables" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("GIT_TERMINAL_PROMPT", "0");
    try validateEnvironment(&map);
    try map.put("LD_PRELOAD", "unexpected");
    try std.testing.expectError(error.UnapprovedEnvironment, validateEnvironment(&map));
}

test "owned approval copies caller path" {
    const path = if (builtin.os.tag == .windows) "C:\\approved.exe" else "/approved";
    var input: [64]u8 = undefined;
    @memcpy(input[0..path.len], path);
    const owned = try OwnedApproval.init(.{ .path = input[0..path.len], .digest = @splat(0) });
    @memset(&input, 'x');
    try std.testing.expectEqualStrings(path, owned.slice());
    try std.testing.expectError(error.InvalidApproval, OwnedApproval.init(.{ .path = "relative", .digest = @splat(0) }));
}
