//! User-scoped Windows approval manager for the restricted read-only profile.
//! One explicit slot in the acceptance namespace, no PATH or ambient config.
//! DPAPI and HKCU protect against other ordinary users, not arbitrary code
//! already executing as this user or administrators. These are trusted
//! principals. The CLI's explicit confirmation is the authorization action.

const std = @import("std");
const builtin = @import("builtin");
const approval = @import("vcs_approval");
const identity = @import("vcs_identity");
const evidence = @import("vcs_windows_evidence");
const contract = @import("vcs_provider");
const detect = @import("vcs_detect");
const host = @import("pulse_host");
const process = @import("pulse_process");
const host_query = @import("vcs_host_query");
const capabilities = @import("vcs_capabilities");

const Sha256 = std.crypto.hash.sha2.Sha256;
const max_input: usize = 128 * 1024;
const max_plain: usize = max_input + approval.Review.record_max_bytes + 12;
const max_sealed: usize = max_plain + 16 * 1024;
const input_magic = "PVCSIN01";
const store_magic = "PVCSST01";
const subkey = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Strangelion\\PulseExtras\\VcsTest\\v1");
const value_name = std.unicode.utf8ToUtf16LeStringLiteral("Approval");
const hkcu: usize = @bitCast(@as(isize, -2147483647));
const allocator = std.heap.page_allocator;

const Blob = extern struct { length: u32, data: ?[*]u8 };
extern "advapi32" fn RegGetValueW(key: usize, sub: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: *u32) callconv(.winapi) i32;
extern "advapi32" fn RegSetKeyValueW(key: usize, sub: [*:0]const u16, value: [*:0]const u16, kind: u32, data: *const anyopaque, size: u32) callconv(.winapi) i32;
extern "crypt32" fn CryptProtectData(input: *const Blob, description: ?[*:0]const u16, entropy: ?*const Blob, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: u32, output: *Blob) callconv(.winapi) i32;
extern "crypt32" fn CryptUnprotectData(input: *const Blob, description: ?*?[*:0]u16, entropy: ?*const Blob, reserved: ?*anyopaque, prompt: ?*anyopaque, flags: u32, output: *Blob) callconv(.winapi) i32;
extern "kernel32" fn LocalFree(memory: *anyopaque) callconv(.winapi) ?*anyopaque;

const Error = contract.Error;

fn hostError(err: Error) host.Error {
    return switch (err) {
        error.Permission => error.Permission,
        error.Unsupported => error.Unavailable,
        error.Parse => error.Argument,
        error.OutOfMemory => error.Initialization,
        else => error.State,
    };
}

fn blob(bytes: []const u8) Blob {
    return .{ .length = @intCast(bytes.len), .data = @constCast(bytes.ptr) };
}

fn transform(bytes: []const u8, decrypt: bool) Error![]u8 {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    const input = blob(bytes);
    const entropy = blob("pulse-extras-vcs-test-user-approval-v1");
    var output: Blob = .{ .length = 0, .data = null };
    const ok = if (decrypt)
        CryptUnprotectData(&input, null, &entropy, null, null, 1, &output)
    else
        CryptProtectData(&input, null, &entropy, null, null, 1, &output);
    defer if (output.data) |ptr| {
        _ = LocalFree(@ptrCast(ptr));
    };
    if (ok == 0 or output.length == 0 or output.length > (if (decrypt) max_plain else max_sealed)) return error.Permission;
    const data = output.data orelse return error.Permission;
    return allocator.dupe(u8, data[0..output.length]) catch return error.OutOfMemory;
}

/// Read one bounded registry value; an absent value or tombstone is no grant.
/// Malformed or inaccessible records are an error, not a reason to auto-trust.
fn load() Error!?[]u8 {
    if (comptime builtin.os.tag != .windows) return null;
    const sealed = allocator.alloc(u8, max_sealed) catch return error.OutOfMemory;
    defer allocator.free(sealed);
    var length: u32 = @intCast(sealed.len);
    const status = RegGetValueW(hkcu, subkey, value_name, 8, null, sealed.ptr, &length);
    if (status == 2) return null;
    if (status != 0 or length == 0 or length > sealed.len) return error.Permission;
    if (length == 1 and sealed[0] == 0) return null;
    return try transform(sealed[0..length], true);
}

fn write(bytes: []const u8) Error!void {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    if (bytes.len == 0 or bytes.len > max_sealed) return error.Permission;
    // Single value update: no partial multi-file manifest or stale backup.
    // Registry persistence follows Windows hive durability, not an fsync claim.
    if (RegSetKeyValueW(hkcu, subkey, value_name, 3, bytes.ptr, @intCast(bytes.len)) != 0) return error.Permission;
}

fn revokeRecord(_: *anyopaque) Error!void {
    try write(&.{0});
}

pub fn revokeSaved() host.Error!void {
    write(&.{0}) catch |err| return hostError(err);
}

const Reader = struct {
    bytes: []const u8,
    offset: usize = 0,

    fn take(self: *Reader, length: usize) Error![]const u8 {
        if (length > self.bytes.len - self.offset) return error.Parse;
        const value = self.bytes[self.offset..][0..length];
        self.offset += length;
        return value;
    }

    fn number(self: *Reader) Error!u16 {
        return std.mem.readInt(u16, (try self.take(2))[0..2], .little);
    }

    fn path(self: *Reader) Error![]const u8 {
        const length = try self.number();
        const value = try self.take(length);
        if (!approval.strictPath(value)) return error.Parse;
        return value;
    }
};

const Stored = struct {
    input: []const u8,
    review: []const u8,

    fn parse(bytes: []const u8) Error!Stored {
        if (bytes.len < 12 or bytes.len > max_plain or !std.mem.eql(u8, bytes[0..8], store_magic)) return error.Parse;
        const length = std.mem.readInt(u32, bytes[8..12], .little);
        if (length == 0 or length > max_input or length >= bytes.len - 12) return error.Parse;
        const result: Stored = .{ .input = bytes[12..][0..length], .review = bytes[12 + length ..] };
        if (result.review.len > approval.Review.record_max_bytes) return error.Parse;
        return result;
    }

    fn encode(input: []const u8, review: []const u8) Error![]u8 {
        if (input.len == 0 or input.len > max_input or review.len == 0 or review.len > approval.Review.record_max_bytes) return error.Parse;
        const bytes = allocator.alloc(u8, 12 + input.len + review.len) catch return error.OutOfMemory;
        @memcpy(bytes[0..8], store_magic);
        std.mem.writeInt(u32, bytes[8..12], @intCast(input.len), .little);
        @memcpy(bytes[12..][0..input.len], input);
        @memcpy(bytes[12 + input.len ..], review);
        return bytes;
    }
};

const Session = struct {
    environment: std.process.Environ.Map,
    grant: approval.Grant = undefined,
    manifest: evidence.InstallationManifest = undefined,
    principals: evidence.Principals = .{},
    audit: evidence.RestrictedAuditor = undefined,
    verifier: evidence.Verifier = undefined,
    record_digest: ?approval.Digest = null,
    io: ?std.Io.Threaded = null,

    fn create(input: []const u8) Error!*Session {
        if (comptime builtin.os.tag != .windows) return error.Unsupported;
        const self = allocator.create(Session) catch return error.OutOfMemory;
        self.* = .{ .environment = std.process.Environ.Map.init(allocator) };
        errdefer self.destroy();
        try self.decode(input);
        try self.principals.add(try evidence.currentProcessUser());
        // Explicit OS trust boundary: local SYSTEM and Administrators.
        // Never admit Everyone, Authenticated Users or BUILTIN Users.
        try self.principals.add(try evidence.Sid.init(&.{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 }));
        try self.principals.add(try evidence.Sid.init(&.{ 1, 2, 0, 0, 0, 0, 0, 5, 32, 0, 0, 0, 32, 2, 0, 0 }));
        var system_buffer: [identity.max_path_bytes]u8 = undefined;
        const system = try evidence.systemDirectory(&system_buffer);
        var global_buffer: [identity.max_path_bytes]u8 = undefined;
        const cwd = self.grant.neutral_cwd.slice();
        const global = process.gitGlobalConfigPath(cwd, &global_buffer) catch return error.Permission;
        for ([_][]const u8{ "SystemRoot", "WINDIR", "TEMP", "TMP", "HOME", "XDG_CONFIG_HOME", "GIT_ATTR_NOSYSTEM", "GIT_CONFIG_NOSYSTEM", "GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS", "GIT_CONFIG_GLOBAL", "LANG", "LC_ALL" }, [_][]const u8{ system, system, cwd, cwd, cwd, cwd, "1", "1", "0", "0", global, "C", "C" }) |key, value| {
            self.environment.put(key, value) catch return error.OutOfMemory;
        }
        self.audit = .{ .principals = &self.principals, .manifest = &self.manifest };
        self.verifier = .{ .auditor = self.audit.adapter(), .principals = &self.principals, .installation = &self.manifest };
        return self;
    }

    fn decode(self: *Session, bytes: []const u8) Error!void {
        if (bytes.len < 8 or bytes.len > max_input) return error.Parse;
        var reader: Reader = .{ .bytes = bytes };
        if (!std.mem.eql(u8, try reader.take(8), input_magic)) return error.Parse;
        const executable = try reader.path();
        const root = try reader.path();
        const neutral = try reader.path();
        const installation = try reader.path();
        const digest: approval.Digest = (try reader.take(32))[0..32].*;
        self.grant = approval.Grant.init(executable, digest, root, neutral, @splat(0), @splat(0)) catch return error.Permission;
        self.manifest = try evidence.InstallationManifest.init(installation);
        const count = try reader.number();
        if (count == 0 or count > evidence.max_install_files) return error.ResourceLimit;
        for (0..count) |_| {
            const path = try reader.path();
            const hash: approval.Digest = (try reader.take(32))[0..32].*;
            try self.manifest.add(path, hash);
        }
        if (reader.offset != bytes.len) return error.Parse;
        try self.manifest.validate(&self.grant);
    }

    fn checkRecord(self: *Session) Error!void {
        const expected = self.record_digest orelse return;
        const current = (try load()) orelse return error.Permission;
        defer allocator.free(current);
        var actual: approval.Digest = undefined;
        Sha256.hash(current, &actual, .{});
        if (!std.mem.eql(u8, &actual, &expected)) return error.Permission;
    }

    fn inspectLive(user: *anyopaque, grant: *const approval.Grant, environment: *const std.process.Environ.Map) Error!approval.Evidence {
        const self: *Session = @ptrCast(@alignCast(user));
        try self.checkRecord();
        const verifier = self.verifier.adapter();
        const actual = try verifier.inspect(verifier.ctx, grant, environment);
        try self.checkRecord();
        return actual;
    }

    fn lookup(_: *anyopaque, path: []const u8) detect.EntryType {
        _ = evidence.observeIdentity(path, true) catch return .missing;
        return .directory;
    }

    fn destroy(self: *Session) void {
        if (self.io) |*threaded| threaded.deinit();
        self.environment.deinit();
        allocator.destroy(self);
    }

    fn release(user: *anyopaque) void {
        const self: *Session = @ptrCast(@alignCast(user));
        self.destroy();
    }
};

fn reviewMatches(candidate: *const approval.Grant, review: *const approval.Review) bool {
    const grant = &review.grant;
    return candidate.root.eql(grant.root.slice()) and candidate.executable.eql(grant.executable.slice()) and candidate.neutral_cwd.eql(grant.neutral_cwd.slice()) and std.mem.eql(u8, &candidate.executable_digest, &grant.executable_digest);
}

pub fn inspect(input: []const u8, output: []u8) host.Error!usize {
    const self = Session.create(input) catch |err| return hostError(err);
    defer self.destroy();
    const grant = &self.grant;
    const review = approval.Review.inspect(grant.executable.slice(), grant.executable_digest, grant.root.slice(), grant.neutral_cwd.slice(), self.verifier.adapter(), &self.environment) catch |err| return hostError(err);
    const record = review.encode(output) catch |err| return hostError(err);
    return record.len;
}

pub fn confirm(input: []const u8, record: []const u8) host.Error!void {
    const self = Session.create(input) catch |err| return hostError(err);
    defer self.destroy();
    const review = approval.Review.decode(record) catch |err| return hostError(err);
    if (!reviewMatches(&self.grant, &review)) return error.Permission;
    _ = review.confirm(self.verifier.adapter(), &self.environment) catch |err| return hostError(err);
    const plain = Stored.encode(input, record) catch |err| return hostError(err);
    defer allocator.free(plain);
    const sealed = transform(plain, false) catch |err| return hostError(err);
    defer allocator.free(sealed);
    write(sealed) catch |err| return hostError(err);
}

/// Activation performs bounded registry read/decryption/parse only. Full
/// filesystem and executable evidence is refreshed on the host worker
/// before any command. No automatic grant or ambient environment import.
pub fn acquire(_: std.mem.Allocator) host.Error!?approval.NativeInput {
    if (comptime builtin.os.tag != .windows) return null;
    const plain = (load() catch |err| return hostError(err)) orelse return null;
    defer allocator.free(plain);
    const stored = Stored.parse(plain) catch |err| return hostError(err);
    const self = Session.create(stored.input) catch |err| return hostError(err);
    errdefer self.destroy();
    const review = approval.Review.decode(stored.review) catch |err| return hostError(err);
    if (!reviewMatches(&self.grant, &review)) return error.Permission;
    var hash: approval.Digest = undefined;
    Sha256.hash(plain, &hash, .{});
    self.record_digest = hash;
    self.io = if (comptime @TypeOf(std.Io.Threaded.init) == fn (std.mem.Allocator) std.Io.Threaded)
        std.Io.Threaded.init(allocator)
    else
        std.Io.Threaded.init(allocator, .{});
    return .{
        .review = review,
        .verifier = .{ .ctx = self, .inspect = &Session.inspectLive },
        .environment = &self.environment,
        .probe = .{ .ctx = self, .lookup = &Session.lookup },
        .io = self.io.?.io(),
        .release_ctx = self,
        .release = &Session.release,
        .revoke_persistent = &revokeRecord,
    };
}

// No CLI, PATH search, config parsing, repository writes or network access.
// The existing resolver/query slots own all worker lifetimes.
pub fn configurePreview(binding: *host_query.Binding) host.Error!void {
    try binding.configureMetadataPreview(.{ .ctx = binding, .resolve = &resolvePreview });
}

fn previewLookup(_: *anyopaque, path: []const u8) detect.EntryType {
    const name = std.fs.path.basename(path);
    if (!std.mem.eql(u8, name, ".git") and !std.mem.eql(u8, name, ".jj") and !std.mem.eql(u8, name, ".svn")) return .missing;
    _ = evidence.observeIdentity(path, true) catch {
        // A Git worktree marker can be a file. Never follow its contents.
        if (!std.mem.eql(u8, name, ".git")) return .missing;
        _ = evidence.observeIdentity(path, false) catch return .missing;
        return .file;
    };
    return .directory;
}

fn detectPreview(user: *anyopaque, path: []const u8, out: *detect.Result) void {
    out.* = if (approval.strictPath(path)) detect.detect(path, .{ .ctx = user, .lookup = &previewLookup }) else .{};
}

fn nearestCandidate(result: *const detect.Result) ?detect.Candidate {
    var nearest: ?detect.Candidate = null;
    for (result.slice()) |candidate| {
        if (candidate.kind != .git and candidate.kind != .jj and candidate.kind != .svn) continue;
        if (nearest) |current| {
            if (candidate.root.len <= current.root.len) continue;
        }
        nearest = candidate;
    }
    return nearest;
}

fn resolvePreview(user: *anyopaque, directory: *const identity.Path) Error!?host_query.Resolved {
    if (!approval.strictPath(directory.slice())) return error.Permission;
    _ = try evidence.observeIdentity(directory.slice(), true);
    var found: detect.Result = .{};
    detectPreview(user, directory.slice(), &found);
    const candidate = nearestCandidate(&found) orelse return null;
    const workspace = identity.Workspace.init(candidate.kind, candidate.root.slice(), candidate.root.slice()) catch return error.Parse;
    var set: capabilities.Set = .empty;
    // Internal summary slot only: the panel explicitly distinguishes marker
    // inspection from a measured status. Never expose write capabilities.
    set.insert(.status);
    return .{
        .provider = .{
            .kind = candidate.kind,
            .display_name = candidate.kind.displayName(),
            .capabilities = set,
            .vtable = &preview_vtable,
            .ctx = user,
        },
        .workspace = workspace,
    };
}

const preview_vtable: contract.VTable = .{ .detect = &detectPreview, .summarize = &summarizePreview };

fn parsePreviewHead(bytes: []const u8, snapshot: *contract.Snapshot) void {
    const line = std.mem.trimEnd(u8, bytes, "\r\n");
    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, line, prefix)) {
        const name = line[prefix.len..];
        if (name.len == 0) return;
        for (name) |byte| if (byte <= 0x20 or byte == 0x7f) return;
        snapshot.reference = contract.Text.init(name) catch return;
    } else if (line.len == 40 or line.len == 64) {
        for (line) |byte| if (!std.ascii.isHex(byte)) return;
        snapshot.revision = identity.RevisionId.init(.git, line) catch return;
    }
}

fn summarizePreview(user: *anyopaque, workspace: *const identity.Workspace) Error!contract.Snapshot {
    var found: detect.Result = .{};
    detectPreview(user, workspace.root.slice(), &found);
    const current = found.find(workspace.kind) orelse return error.Stale;
    if (!current.root.eql(workspace.root.slice())) return error.Stale;
    var snapshot: contract.Snapshot = .{ .workspace = workspace.*, .availability = .not_queried };
    var labels: [96]u8 = undefined;
    var used: usize = 0;
    for ([_]identity.Kind{ .git, .jj, .svn }) |kind| {
        if (found.find(kind)) |candidate| {
            if (!candidate.root.eql(workspace.root.slice())) continue;
            const name = kind.displayName();
            if (used != 0) {
                @memcpy(labels[used..][0..3], " + ");
                used += 3;
            }
            @memcpy(labels[used..][0..name.len], name);
            used += name.len;
        }
    }
    var detail: [contract.Text.capacity]u8 = undefined;
    const description = std.fmt.bufPrint(&detail, "Repository markers: {s}. Working-copy status not queried.", .{labels[0..used]}) catch return error.ResourceLimit;
    snapshot.detail = contract.Text.init(description) catch return error.Parse;
    if (workspace.kind == .git) {
        var path: [identity.max_path_bytes]u8 = undefined;
        const head_path = std.fmt.bufPrint(&path, "{s}\\.git\\HEAD", .{workspace.root.slice()}) catch return snapshot;
        var bytes: [512]u8 = undefined;
        const head = evidence.readPreviewFile(head_path, &bytes) catch return snapshot;
        parsePreviewHead(head, &snapshot);
    }
    return snapshot;
}

test "metadata preview parses HEAD without following a reference or inventing status" {
    var snapshot: contract.Snapshot = .{ .availability = .not_queried };
    parsePreviewHead("ref: refs/heads/main\n", &snapshot);
    try std.testing.expectEqualStrings("main", snapshot.reference.slice());
    try std.testing.expect(snapshot.revision == null);
    try std.testing.expectEqual(contract.Availability.not_queried, snapshot.counts.modified);
    snapshot = .{};
    parsePreviewHead("0123456789abcdef0123456789abcdef01234567\r\n", &snapshot);
    try std.testing.expect(snapshot.revision != null);
    snapshot = .{};
    parsePreviewHead("ref: refs/heads/bad\nname\n", &snapshot);
    try std.testing.expect(snapshot.reference.slice().len == 0 and snapshot.revision == null);
    parsePreviewHead("gitdir: C:\\other", &snapshot);
    try std.testing.expect(snapshot.reference.slice().len == 0 and snapshot.revision == null);
}

test "metadata preview chooses nearest root and retains all colocated markers" {
    var result: detect.Result = .{};
    result.add(.{ .kind = .git, .root = try identity.Path.init("root") });
    result.add(.{ .kind = .jj, .root = try identity.Path.init("root/child") });
    result.add(.{ .kind = .svn, .root = try identity.Path.init("root/child") });
    const nearest = nearestCandidate(&result) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(identity.Kind.jj, nearest.kind);
    try std.testing.expect(result.find(.svn) != null);
    try std.testing.expect(nearestCandidate(&.{}) == null);
}

test "stored record rejects unknown schema truncation and oversized input" {
    const encoded = try Stored.encode("input", "review");
    defer allocator.free(encoded);
    const parsed = try Stored.parse(encoded);
    try std.testing.expectEqualStrings("input", parsed.input);
    try std.testing.expectEqualStrings("review", parsed.review);
    try std.testing.expectError(error.Parse, Stored.parse(encoded[0..12]));
    encoded[7] = '2';
    try std.testing.expectError(error.Parse, Stored.parse(encoded));
    var reader: Reader = .{ .bytes = "a" };
    try std.testing.expectError(error.Parse, reader.number());
}

test "Windows DPAPI approval envelope round trip rejects tampering without writing registry" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const original = "test approval record";
    const sealed = try transform(original, false);
    defer allocator.free(sealed);
    const restored = try transform(sealed, true);
    defer allocator.free(restored);
    try std.testing.expectEqualStrings(original, restored);
    sealed[sealed.len - 1] ^= 0x80;
    try std.testing.expectError(error.Permission, transform(sealed, true));
}
