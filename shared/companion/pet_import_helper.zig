//! Typed invocation of the approved companion package validator. Run only
//! on the serialized worker, not the host UI thread. No shell, inherited
//! environment or unbounded output. Roots are independently approved.
const std = @import("std");
const process = @import("pulse_process");
const fingerprint = @import("pet_fingerprint.zig");
const inventory = @import("pet_inventory.zig");

const probe_prefix = "PULSE_PACKAGE_FINGERPRINT_V2 ";
const stage_prefix = "PULSE_PACKAGE_STAGED_V2 ";

fn nibble(ch: u8) !u8 {
    return switch (ch) {
        '0'...'9' => ch - '0',
        'a'...'f' => ch - 'a' + 10,
        else => error.InvalidHelperOutput,
    };
}

pub fn parseDigest(output: []const u8, prefix: []const u8) !fingerprint.Pair {
    const line = std.mem.trimEnd(u8, output, "\r\n");
    if (line.len != prefix.len + 193 or !std.mem.startsWith(u8, line, prefix) or line[prefix.len + 64] != ':') return error.InvalidHelperOutput;
    var digest: fingerprint.Pair = undefined;
    for (0..32) |i| digest.primary[i] = (try nibble(line[prefix.len + 2 * i])) * 16 + try nibble(line[prefix.len + 2 * i + 1]);
    for (0..64) |i| digest.secondary[i] = (try nibble(line[prefix.len + 65 + 2 * i])) * 16 + try nibble(line[prefix.len + 65 + 2 * i + 1]);
    return digest;
}

pub const Detail = struct {
    name: [320]u8 = @splat(0),
    name_len: usize = 0,
    description: [2000]u8 = @splat(0),
    description_len: usize = 0,
    version: u8 = 0,
    activities: u8 = 0,
    outfits: u8 = 0,
    rules: u8 = 0,
};

fn decodeText(encoded: []const u8, out: []u8) !usize {
    if (encoded.len == 0 or encoded.len % 2 != 0 or encoded.len / 2 > out.len) return error.InvalidHelperOutput;
    const len = encoded.len / 2;
    for (out[0..len], 0..) |*byte, n| {
        byte.* = (try nibble(encoded[2 * n])) * 16 + try nibble(encoded[2 * n + 1]);
        if (byte.* < 32 or byte.* == 127) return error.InvalidHelperOutput;
    }
    if (!std.unicode.utf8ValidateSlice(out[0..len])) return error.InvalidHelperOutput;
    return len;
}

pub fn parseDetail(output: []const u8) !Detail {
    var fields = std.mem.splitScalar(u8, std.mem.trimEnd(u8, output, "\r\n"), ' ');
    if (!std.mem.eql(u8, fields.next() orelse return error.InvalidHelperOutput, "PULSE_PACKAGE_DETAIL_V1")) return error.InvalidHelperOutput;
    var values: [4]u8 = undefined;
    for (&values) |*value| {
        const text = fields.next() orelse return error.InvalidHelperOutput;
        value.* = std.fmt.parseInt(u8, text, 10) catch return error.InvalidHelperOutput;
    }
    if ((values[0] != 1 and values[0] != 2) or values[1] > 16 or values[2] > 16 or values[3] > 32) return error.InvalidHelperOutput;
    var result: Detail = .{ .version = values[0], .activities = values[1], .outfits = values[2], .rules = values[3] };
    result.name_len = try decodeText(fields.next() orelse return error.InvalidHelperOutput, &result.name);
    result.description_len = try decodeText(fields.next() orelse return error.InvalidHelperOutput, &result.description);
    if (fields.next() != null) return error.InvalidHelperOutput;
    return result;
}

// Map only fixed diagnostics emitted by the digest-pinned helper. Never
// forward raw stderr (which may contain local paths or untrusted text).
// Keep an unrecognized failure distinct from a diagnosed validation stage.

// Extract the numeric Win32 code that follows a coded marker prefix.
fn codedError(line: []const u8, prefix: []const u8) ?u16 {
    if (!std.mem.startsWith(u8, line, prefix)) return null;
    const rest = line[prefix.len..];
    var end: usize = 0;
    while (end < rest.len and rest[end] >= '0' and rest[end] <= '9') : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseInt(u16, rest[0..end], 10) catch null;
}

fn rejection(stderr: []const u8) anyerror {
    const reasons = [_]struct { marker: []const u8, reason: anyerror }{
        .{ .marker = "Package import failed at stage-verification (pending directory retained).", .reason = error.PackageStageVerificationFailed },
        .{ .marker = "Package stage: root normalization failed.", .reason = error.PackageStageRootInvalid },
        .{ .marker = "Package stage: root pin failed.", .reason = error.PackageStageRootPinFailed },
        .{ .marker = "Package stage: final path occupied or inaccessible.", .reason = error.PackageStageFinalPathBlocked },
        .{ .marker = "Package stage: pending directory creation failed (Win32 ", .reason = error.PackageStagePendingCreateFailed },
        .{ .marker = "Package stage: pending path already exists.", .reason = error.PackageStagePendingExists },
        .{ .marker = "Package stage: outfits directory creation failed (Win32 ", .reason = error.PackageStageSubdirCreateFailed },
        .{ .marker = "Package stage: activities directory creation failed (Win32 ", .reason = error.PackageStageSubdirCreateFailed },
        .{ .marker = "Package import failed at stage-copy (pending directory may remain).", .reason = error.PackageStageCopyFailed },
        .{ .marker = "Package import failed at stage-publish (Win32 ", .reason = error.PackageStagePublishFailed },
        .{ .marker = "Package path: expected a bounded local DOS directory.", .reason = error.PackagePathInvalid },
        .{ .marker = "Package path: long-name normalization failed.", .reason = error.PackagePathNormalizationFailed },
        .{ .marker = "Package admission failed at root.", .reason = error.PackageRootRejected },
        .{ .marker = "Package admission failed at metadata-open.", .reason = error.PackageMetadataOpenFailed },
        .{ .marker = "Package admission failed at metadata-read.", .reason = error.PackageMetadataReadFailed },
        .{ .marker = "Package admission failed at metadata-parse.", .reason = error.PackageMetadataInvalid },
        .{ .marker = "Package admission failed at base-open.", .reason = error.PackageAtlasOpenFailed },
        .{ .marker = "Package admission failed at base-read.", .reason = error.PackageAtlasReadFailed },
        .{ .marker = "Package admission failed at base-header.", .reason = error.PackageAtlasHeaderInvalid },
        .{ .marker = "Package admission failed at outfit-inventory.", .reason = error.PackageOutfitInventoryInvalid },
        .{ .marker = "Package admission failed at outfit-read.", .reason = error.PackageOutfitReadFailed },
        .{ .marker = "Package admission failed at outfit-header.", .reason = error.PackageOutfitHeaderInvalid },
        .{ .marker = "Package admission failed at activity-inventory.", .reason = error.PackageActivityInventoryInvalid },
        .{ .marker = "Package admission failed at activity-read.", .reason = error.PackageActivityReadFailed },
        .{ .marker = "Package admission failed at activity-size.", .reason = error.PackageActivitySizeExceeded },
        .{ .marker = "Package admission failed at activity-header.", .reason = error.PackageActivityHeaderInvalid },
        .{ .marker = "Package admission failed at fingerprint.", .reason = error.PackageFingerprintFailed },
        .{ .marker = "Package admission failed at fingerprint-mismatch.", .reason = error.PackageFingerprintMismatch },
    };
    // Stage failures take precedence over nested admission failures.
    for (reasons) |item| {
        var lines = std.mem.splitScalar(u8, stderr, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimEnd(u8, line, "\r");
            if (std.mem.eql(u8, trimmed, item.marker)) return item.reason;
            if ((item.reason == error.PackageStagePublishFailed or
                item.reason == error.PackageStagePendingCreateFailed or
                item.reason == error.PackageStageSubdirCreateFailed) and
                std.mem.startsWith(u8, trimmed, item.marker))
            {
                // ERROR_ACCESS_DENIED on a private-root create is distinct: a
                // security product or policy blocked an unsigned helper.
                if ((item.reason == error.PackageStagePendingCreateFailed or
                    item.reason == error.PackageStageSubdirCreateFailed) and
                    codedError(trimmed, item.marker) == 5) return error.PackageStageAccessDenied;
                return item.reason;
            }
        }
    }
    return error.PackageRejected;
}

fn requireSuccess(result: *const process.Outcome) !void {
    if (result.succeeded()) return;
    if (result.status != .exited) return error.PackageHelperDidNotExit;
    return rejection(result.stderr);
}

pub const Helper = struct {
    runner: *process.Runner,
    exe: []const u8,
    cwd: []const u8,
    asset_root: []const u8,
    environ: *const std.process.Environ.Map,

    fn run(self: *Helper, argv: []const []const u8, prefix: []const u8) !fingerprint.Pair {
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
        try requireSuccess(&result);
        return parseDigest(result.stdout, prefix);
    }

    pub fn probe(self: *Helper, source: []const u8, source_id: []const u8) !fingerprint.Pair {
        if (!inventory.validSource(source_id)) return error.Invalid;
        return self.run(&.{ self.exe, "--fingerprint-package-v2", source, source_id }, probe_prefix);
    }

    pub fn describe(self: *Helper, source: []const u8, source_id: []const u8, digest: fingerprint.Pair) !Detail {
        if (!inventory.validSource(source_id) or self.runner.policy != .approved_local or self.runner.tree_policy != .windows_job) return error.UnapprovedExecutable;
        const hex = fingerprint.pairHex(digest);
        var result = try self.runner.run(.{
            .argv = &.{ self.exe, "--describe-package-v1", source, source_id, "--expected-fingerprint", &hex },
            .cwd = self.cwd,
            .environ_map = self.environ,
            .timeout_ns = 60 * std.time.ns_per_s,
            .stdout_limit = 5000,
            .stderr_limit = 16 * 1024,
        });
        defer result.deinit();
        try requireSuccess(&result);
        return parseDetail(result.stdout);
    }

    pub fn stage(self: *Helper, source: []const u8, source_id: []const u8, id: u64, digest: fingerprint.Pair) !void {
        if (!inventory.validSource(source_id) or id == 0) return error.Invalid;
        var buf: [16]u8 = undefined;
        const id_hex = try std.fmt.bufPrint(&buf, "{x:0>16}", .{id});
        const hex = fingerprint.pairHex(digest);
        const actual = try self.run(&.{ self.exe, "--fingerprint-package-v2", source, source_id, "--expected-fingerprint", &hex, "--stage-root", self.asset_root, id_hex }, stage_prefix);
        if (!std.meta.eql(actual, digest)) return error.InvalidHelperOutput;
    }
};

test "parse exact bounded machine record, reject malformed and trailing output" {
    const expected: fingerprint.Pair = .{ .primary = @splat(0xab), .secondary = @splat(0xcd) };
    const hex = comptime fingerprint.pairHex(expected);
    const value = try parseDigest(probe_prefix ++ hex ++ "\r\n", probe_prefix);
    try std.testing.expect(std.meta.eql(expected, value));
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
    try std.testing.expectError(error.UnapprovedExecutable, helper.stage("source", "cat", 1, .{ .primary = @splat(0), .secondary = @splat(0) }));
    try runner.checkDrained();
}

test "detail protocol accepts bounded Unicode and rejects unsafe fields" {
    const detail = try parseDetail("PULSE_PACKAGE_DETAIL_V1 2 1 2 3 e78cab 436174\r\n");
    try std.testing.expectEqualStrings("猫", detail.name[0..detail.name_len]);
    try std.testing.expectEqualStrings("Cat", detail.description[0..detail.description_len]);
    try std.testing.expectEqual(@as(u8, 2), detail.version);
    try std.testing.expectError(error.InvalidHelperOutput, parseDetail("PULSE_PACKAGE_DETAIL_V1 3 0 0 0 61 62"));
    try std.testing.expectError(error.InvalidHelperOutput, parseDetail("PULSE_PACKAGE_DETAIL_V1 2 0 17 0 61 62"));
    try std.testing.expectError(error.InvalidHelperOutput, parseDetail("PULSE_PACKAGE_DETAIL_V1 2 0 0 0 00 62"));
    try std.testing.expectError(error.InvalidHelperOutput, parseDetail("PULSE_PACKAGE_DETAIL_V1 2 0 0 0 61 ff"));
    try std.testing.expectError(error.InvalidHelperOutput, parseDetail("PULSE_PACKAGE_DETAIL_V1 2 0 0 0 61 62 extra"));
}

test "helper rejection diagnostics preserve known stages and never forward raw stderr" {
    try std.testing.expectEqual(error.PackageMetadataInvalid, rejection("Package admission failed at metadata-parse.\r\nClassic package rejected: metadata, path, inventory or WebP header.\n"));
    try std.testing.expectEqual(error.PackageAtlasHeaderInvalid, rejection("Package admission failed at base-header.\n"));
    try std.testing.expectEqual(error.PackageStageRootPinFailed, rejection("Package stage: root pin failed.\nPackage import failed at stage-copy (pending directory may remain).\n"));
    try std.testing.expectEqual(error.PackageStagePendingCreateFailed, rejection("Package stage: pending directory creation failed (Win32 3).\nPackage import failed at stage-copy (pending directory may remain).\n"));
    try std.testing.expectEqual(error.PackageStageAccessDenied, rejection("Package stage: pending directory creation failed (Win32 5).\nPackage import failed at stage-copy (pending directory may remain).\n"));
    try std.testing.expectEqual(error.PackageStageAccessDenied, rejection("Package stage: outfits directory creation failed (Win32 5).\n"));
    try std.testing.expectEqual(error.PackageStagePendingExists, rejection("Package stage: pending path already exists.\n"));
    try std.testing.expectEqual(error.PackageStageSubdirCreateFailed, rejection("Package stage: outfits directory creation failed (Win32 3).\n"));
    try std.testing.expectEqual(error.PackageStageVerificationFailed, rejection("Package admission failed at metadata-open.\nPackage import failed at stage-verification (pending directory retained).\n"));
    try std.testing.expectEqual(error.PackageStagePublishFailed, rejection("Package import failed at stage-publish (Win32 5; pending directory retained).\n"));
    try std.testing.expectEqual(error.PackageRejected, rejection("arbitrary private path or unsupported output"));
    try std.testing.expectEqual(error.PackageRejected, rejection("prefix Package admission failed at metadata-parse.\n"));
}
