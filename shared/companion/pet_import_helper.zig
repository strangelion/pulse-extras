//! Typed invocation of the approved companion package validator. Run only
//! on the serialized worker, not the host UI thread. No shell, inherited
//! environment or unbounded output. Roots are independently approved.
const std = @import("std");
const process = @import("pulse_process");
const fingerprint = @import("pet_fingerprint.zig");
const inventory = @import("pet_inventory.zig");

const probe_prefix = "PULSE_PACKAGE_SHA256_V1 ";
const stage_prefix = "PULSE_PACKAGE_STAGED_V1 ";

fn nibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        else => error.InvalidHelperOutput,
    };
}

pub fn parseDigest(output: []const u8, prefix: []const u8) !fingerprint.Digest {
    const line = std.mem.trimEnd(u8, output, "\r\n");
    if (line.len != prefix.len + 64 or !std.mem.startsWith(u8, line, prefix)) return error.InvalidHelperOutput;
    var digest: fingerprint.Digest = undefined;
    for (0..32) |i| digest[i] = (try nibble(line[prefix.len + 2 * i])) * 16 + try nibble(line[prefix.len + 2 * i + 1]);
    return digest;
}

pub const Helper = struct {
    runner: *process.Runner,
    exe: []const u8,
    cwd: []const u8,
    asset_root: []const u8,
    environ: *const std.process.Environ.Map,

    fn run(self: *Helper, argv: []const []const u8, prefix: []const u8) !fingerprint.Digest {
        // Caller configures the runner with approved executable and Windows
        // job tree containment before handing it to this adapter.
        if (self.runner.policy != .approved_local or self.runner.tree_policy != .windows_job) return error.UnapprovedExecutable;
        var result = try self.runner.run(.{
            .argv = argv,
            .cwd = self.cwd,
            .environ_map = self.environ,
            .timeout_ns = 60 * std.time.ns_per_s,
            .stdout_limit = 256,
            .stderr_limit = 16 * 1024,
        });
        defer result.deinit();
        if (!result.succeeded()) return error.PackageRejected;
        return parseDigest(result.stdout, prefix);
    }

    pub fn probe(self: *Helper, source: []const u8, source_id: []const u8) !fingerprint.Digest {
        if (!inventory.validSource(source_id)) return error.Invalid;
        return self.run(&.{ self.exe, "--fingerprint-package", source, source_id }, probe_prefix);
    }

    pub fn stage(self: *Helper, source: []const u8, source_id: []const u8, id: u64, digest: fingerprint.Digest) !void {
        if (!inventory.validSource(source_id) or id == 0) return error.Invalid;
        var buf: [16]u8 = undefined;
        const id_hex = try std.fmt.bufPrint(&buf, "{x:0>16}", .{id});
        const hex = fingerprint.hex(digest);
        const actual = try self.run(&.{ self.exe, "--fingerprint-package", source, source_id, "--expected-sha256", &hex, "--stage-root", self.asset_root, id_hex }, stage_prefix);
        if (!std.mem.eql(u8, &actual, &digest)) return error.InvalidHelperOutput;
    }
};

test "parse exact bounded machine record, reject malformed and trailing output" {
    const hex = "abababababababababababababababababababababababababababababababab";
    const value = try parseDigest(probe_prefix ++ hex ++ "\r\n", probe_prefix);
    const expected: fingerprint.Digest = @splat(0xab);
    try std.testing.expectEqualSlices(u8, &expected, &value);
    try std.testing.expectError(error.InvalidHelperOutput, parseDigest(stage_prefix ++ hex, probe_prefix));
    try std.testing.expectError(error.InvalidHelperOutput, parseDigest(probe_prefix ++ hex ++ "\nextra", probe_prefix));
    try std.testing.expectError(error.InvalidHelperOutput, parseDigest(probe_prefix ++ "g" ++ hex[1..], probe_prefix));
}

test "helper refuses an unapproved runner before spawning" {
    var runner = process.Runner.init(std.testing.allocator, std.testing.io);
    var environ = std.process.Environ.Map.init(std.testing.allocator);
    defer environ.deinit();
    var helper: Helper = .{ .runner = &runner, .exe = "unapproved", .cwd = "", .asset_root = "", .environ = &environ };
    try std.testing.expectError(error.UnapprovedExecutable, helper.probe("source", "cat"));
    try std.testing.expectError(error.UnapprovedExecutable, helper.stage("source", "cat", 1, @splat(0)));
    try runner.checkDrained();
}
