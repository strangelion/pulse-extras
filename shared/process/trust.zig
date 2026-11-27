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
    return validateEnvironmentInternal(map, null);
}

/// Only the dedicated isolated Git profile may select a global config file.
/// The caller must supply an audited, pre-existing empty regular file in the
/// neutral directory. Never create or truncate it as part of command admission.
pub const git_global_config_name = "pulse-git-global-empty.conf";
pub const max_git_config_path_bytes = 2048;

pub fn gitGlobalConfigPath(cwd: []const u8, buffer: []u8) error{UnapprovedEnvironment}![]const u8 {
    if (!localAbsolute(cwd) or cwd.len == 0 or cwd.len >= max_git_config_path_bytes or std.mem.indexOfScalar(u8, cwd, 0) != null) return error.UnapprovedEnvironment;
    if (cwd[cwd.len - 1] == std.fs.path.sep or (builtin.os.tag == .windows and cwd[cwd.len - 1] == '/')) return error.UnapprovedEnvironment;
    const path = std.fmt.bufPrint(buffer, "{s}" ++ std.fs.path.sep_str ++ git_global_config_name, .{cwd}) catch return error.UnapprovedEnvironment;
    if (path.len > max_git_config_path_bytes) return error.UnapprovedEnvironment;
    return path;
}

pub fn validateGitEnvironment(map: *const std.process.Environ.Map, cwd: []const u8) error{UnapprovedEnvironment}!void {
    var buffer: [max_git_config_path_bytes]u8 = undefined;
    const expected = try gitGlobalConfigPath(cwd, &buffer);
    try validateEnvironmentInternal(map, expected);
    for ([_][]const u8{ "HOME", "XDG_CONFIG_HOME" }) |key| {
        if (map.get(key)) |value| {
            if (!std.mem.eql(u8, value, cwd)) return error.UnapprovedEnvironment;
        }
    }
    for ([_][]const u8{ "GIT_CONFIG_NOSYSTEM", "GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS", "GIT_CONFIG_GLOBAL" }, [_][]const u8{ "1", "0", "0", expected }) |key, value| {
        if (!std.mem.eql(u8, map.get(key) orelse return error.UnapprovedEnvironment, value)) return error.UnapprovedEnvironment;
    }
}

pub fn verifyEmptyGitConfig(io: std.Io, cwd: []const u8) !void {
    var buffer: [max_git_config_path_bytes]u8 = undefined;
    const path = try gitGlobalConfigPath(cwd, &buffer);
    const file = try std.Io.Dir.openFileAbsolute(io, path, .{ .follow_symlinks = false });
    defer file.close(io);
    const stat = try file.stat(io);
    if (stat.kind != .file or stat.size != 0) return error.UnapprovedEnvironment;
}

fn validateEnvironmentInternal(map: *const std.process.Environ.Map, git_global: ?[]const u8) error{UnapprovedEnvironment}!void {
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
            (std.mem.eql(u8, key, "GIT_OPTIONAL_LOCKS") and std.mem.eql(u8, value, "0")) or
            (std.mem.eql(u8, key, "GIT_CONFIG_NOSYSTEM") and std.mem.eql(u8, value, "1")) or
            (std.mem.eql(u8, key, "GIT_NO_LAZY_FETCH") and std.mem.eql(u8, value, "1")) or
            (std.mem.eql(u8, key, "HGPLAIN") and std.mem.eql(u8, value, "1")) or
            (std.mem.eql(u8, key, "HGRCPATH") and value.len == 0) or
            (std.mem.eql(u8, key, "HGRCSKIPREPO") and std.mem.eql(u8, value, "1")) or
            (std.mem.eql(u8, key, "HGENCODING") and std.mem.eql(u8, value, "UTF-8")) or
            (std.mem.eql(u8, key, "GIT_CONFIG_GLOBAL") and git_global != null and std.mem.eql(u8, value, git_global.?)) or
            (git_global != null and (std.mem.eql(u8, key, "HOME") or std.mem.eql(u8, key, "XDG_CONFIG_HOME"))) or
            (git_global != null and std.mem.eql(u8, key, "GIT_ATTR_NOSYSTEM") and std.mem.eql(u8, value, "1"));
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

test "system Git configuration can only be disabled with an exact value" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("GIT_CONFIG_NOSYSTEM", "1");
    try validateEnvironment(&map);
    try map.put("GIT_CONFIG_NOSYSTEM", "0");
    try std.testing.expectError(error.UnapprovedEnvironment, validateEnvironment(&map));
    try map.put("GIT_CONFIG_NOSYSTEM", "1");
    try map.put("GIT_CONFIG_GLOBAL", "unapproved");
    try std.testing.expectError(error.UnapprovedEnvironment, validateEnvironment(&map));
}

test "isolated Git environment requires exact controls and fixed global file" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    const cwd = if (builtin.os.tag == .windows) "C:\\neutral" else "/neutral";
    var buffer: [max_git_config_path_bytes]u8 = undefined;
    const path = try gitGlobalConfigPath(cwd, &buffer);
    try map.put("GIT_CONFIG_GLOBAL", path);
    try map.put("GIT_CONFIG_NOSYSTEM", "1");
    try map.put("GIT_OPTIONAL_LOCKS", "0");
    try std.testing.expectError(error.UnapprovedEnvironment, validateGitEnvironment(&map, cwd));
    try map.put("GIT_TERMINAL_PROMPT", "0");
    try validateGitEnvironment(&map, cwd);
    try std.testing.expectError(error.UnapprovedEnvironment, validateEnvironment(&map));
    try map.put("GIT_CONFIG_GLOBAL", "other.conf");
    try std.testing.expectError(error.UnapprovedEnvironment, validateGitEnvironment(&map, cwd));
    try map.put("GIT_CONFIG_GLOBAL", path);
    try map.put("GIT_CONFIG_COUNT", "1");
    try std.testing.expectError(error.UnapprovedEnvironment, validateGitEnvironment(&map, cwd));
}

test "approved environment admits only the exact no lazy fetch value" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("GIT_NO_LAZY_FETCH", "1");
    try validateEnvironment(&map);
    for ([_][]const u8{ "0", "", "false" }) |value| {
        try map.put("GIT_NO_LAZY_FETCH", value);
        try std.testing.expectError(error.UnapprovedEnvironment, validateEnvironment(&map));
    }
}

test "Mercurial controlled environment permits only fixed isolation values" {
    var map = std.process.Environ.Map.init(std.testing.allocator);
    defer map.deinit();
    try map.put("HGPLAIN", "1");
    try map.put("HGRCPATH", "");
    try map.put("HGRCSKIPREPO", "1");
    try map.put("HGENCODING", "UTF-8");
    try validateEnvironment(&map);
    try map.put("HGRCPATH", "unreviewed-config");
    try std.testing.expectError(error.UnapprovedEnvironment, validateEnvironment(&map));
}
