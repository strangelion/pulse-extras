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
const trust = @import("process_trust");
const cli = @import("vcs_cli");
const panel = @import("vcs_panel");
const git_mod = @import("vcs_git");
const jj_mod = @import("vcs_jj");
const svn_mod = @import("vcs_svn");
const hg_mod = @import("vcs_hg");
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
extern "kernel32" fn GetEnvironmentVariableW(name: [*:0]const u16, value: [*]u16, capacity: u32) callconv(.winapi) u32;
extern "kernel32" fn GetCurrentDirectoryW(capacity: u32, buffer: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn WideCharToMultiByte(codepage: u32, flags: u32, input: [*]const u16, input_len: i32, output: [*]u8, output_len: i32, default_char: ?*const u8, used_default: ?*i32) callconv(.winapi) i32;

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
    return transformWithEntropy(bytes, decrypt, "pulse-extras-vcs-test-user-approval-v1");
}

fn transformWithEntropy(bytes: []const u8, decrypt: bool, purpose: []const u8) Error![]u8 {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    const input = blob(bytes);
    const entropy = blob(purpose);
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
    if (comptime builtin.os.tag != .windows) return;
    const local = allocator.create(LocalSession) catch return error.Initialization;
    local.* = .{ .environment = std.process.Environ.Map.init(allocator) };
    errdefer {
        local.environment.deinit();
        allocator.destroy(local);
    }
    try binding.configureLocalAccess(.{ .ctx = local, .authorize = &LocalSession.authorize, .revoke = &LocalSession.revoke, .finish = &LocalSession.finish, .reset = &LocalSession.reset, .forget = &LocalSession.forget, .forget_all = &LocalSession.forgetAll, .revoke_saved = &LocalSession.revokeSavedActive });
}

// Explicit settings actions use only the selected lexical scope. They never
// require the old directory/tool to exist and never authorize execution.
pub fn inspectProjectGrant(root: *const identity.Path, kind: identity.Kind) contract.SavedHint {
    if (!approval.strictPath(root.slice()) or contract.Snapshot.previewIndex(kind) == null) return .{ .state = .unavailable };
    const scope: panel.LocalReview = .{ .root = root.*, .kind = kind, .executable = .{}, .generation = 0 };
    return SavedLocal.inspect(&scope) catch .{ .state = .unavailable };
}

pub fn forgetProjectGrant(root: *const identity.Path, kind: identity.Kind) host.Error!void {
    if (!approval.strictPath(root.slice()) or contract.Snapshot.previewIndex(kind) == null) return error.Argument;
    const scope: panel.LocalReview = .{ .root = root.*, .kind = kind, .executable = .{}, .generation = 0 };
    SavedLocal.forget(&scope) catch |err| return hostError(err);
}

// Separate DPAPI namespace from strict single-root Git audit and from the
// host's project settings. 1024 bounded slots; a live hash-slot collision
// refuses the write rather than silently replacing another root/provider.
// A monotonic epoch revokes every record atomically without enumerating paths.
const SavedLocal = struct {
    const sub = std.unicode.utf8ToUtf16LeStringLiteral("Software\\Strangelion\\PulseExtras\\VcsLocalTrust\\v1");
    const epoch_name = std.unicode.utf8ToUtf16LeStringLiteral("Epoch");
    const entropy = "pulse-extras-vcs-local-trust-v1";
    const magic = "PVCSLT02";
    const header_size = 69;
    const max_record = 2 * identity.max_path_bytes + header_size;
    const Nonce = [16]u8;

    extern "advapi32" fn SystemFunction036(*anyopaque, u32) callconv(.winapi) u8;
    const max_envelope = max_record + 4096;

    extern "kernel32" fn CreateMutexW(?*anyopaque, i32, [*:0]const u16) callconv(.winapi) ?*anyopaque;
    extern "kernel32" fn WaitForSingleObject(*anyopaque, u32) callconv(.winapi) u32;
    extern "kernel32" fn ReleaseMutex(*anyopaque) callconv(.winapi) i32;
    extern "kernel32" fn CloseHandle(*anyopaque) callconv(.winapi) i32;

    fn lock() Error!*anyopaque {
        if (comptime builtin.os.tag != .windows) return error.Unsupported;
        const mutex = CreateMutexW(null, 0, std.unicode.utf8ToUtf16LeStringLiteral("Local\\Strangelion.PulseExtras.VcsLocalTrust.v1")) orelse return error.Permission;
        const state = WaitForSingleObject(mutex, 0);
        if (state != 0 and state != 0x80) {
            _ = CloseHandle(mutex);
            return error.Permission;
        }
        return mutex;
    }

    fn unlock(mutex: *anyopaque) void {
        _ = ReleaseMutex(mutex);
        _ = CloseHandle(mutex);
    }

    fn slot(review: *const panel.LocalReview) [4:0]u16 {
        var hash = Sha256.init(.{});
        hash.update(review.root.slice());
        hash.update(&.{ 0, @backingInt(review.kind) });
        const digest = hash.finalResult();
        const chars = "0123456789abcdef";
        return .{ 'g', chars[digest[0] & 3], chars[digest[1] >> 4], chars[digest[1] & 15] };
    }

    fn epoch() Error!u64 {
        if (comptime builtin.os.tag != .windows) return error.Unsupported;
        var bytes: [8]u8 = undefined;
        var len: u32 = bytes.len;
        const status = RegGetValueW(hkcu, sub, epoch_name, 8, null, &bytes, &len);
        if (status == 2) return 0;
        if (status != 0 or len != bytes.len) return error.Permission;
        return std.mem.readInt(u64, &bytes, .little);
    }

    fn revokeAll() Error!void {
        const mutex = try lock();
        defer unlock(mutex);
        const next = std.math.add(u64, try epoch(), 1) catch return error.ResourceLimit;
        var bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &bytes, next, .little);
        if (RegSetKeyValueW(hkcu, sub, epoch_name, 3, &bytes, bytes.len) != 0) return error.Permission;
    }

    const Record = struct {
        generation: u64,
        kind: identity.Kind,
        root: []const u8,
        executable: []const u8,
        fingerprint: [32]u8,
        nonce: Nonce,

        fn parse(bytes: []const u8) Error!Record {
            if (bytes.len < header_size or bytes.len > max_record or !std.mem.eql(u8, bytes[0..8], magic)) return error.Parse;
            const kind: identity.Kind = switch (bytes[16]) {
                @backingInt(identity.Kind.git) => .git,
                @backingInt(identity.Kind.jj) => .jj,
                @backingInt(identity.Kind.svn) => .svn,
                @backingInt(identity.Kind.hg) => .hg,
                else => return error.Parse,
            };
            const root_len = std.mem.readInt(u16, bytes[17..19], .little);
            const exe_len = std.mem.readInt(u16, bytes[19..21], .little);
            if (root_len == 0 or exe_len == 0 or root_len > identity.max_path_bytes or exe_len > identity.max_path_bytes or @as(usize, root_len) + exe_len + header_size != bytes.len) return error.Parse;
            const root = bytes[header_size..][0..root_len];
            const executable = bytes[header_size + @as(usize, root_len) ..];
            if (!approval.strictPath(root) or !approval.strictPath(executable)) return error.Parse;
            return .{ .generation = std.mem.readInt(u64, bytes[8..16], .little), .kind = kind, .root = root, .executable = executable, .fingerprint = bytes[21..53].*, .nonce = bytes[53..69].* };
        }

        fn sameScope(self: Record, review: *const panel.LocalReview) bool {
            return self.kind == review.kind and review.root.eql(self.root);
        }

        fn hint(self: Record, review: *const panel.LocalReview, generation: u64) Error!contract.SavedHint {
            // Do not reveal a different project/provider occupying this slot.
            if (self.generation != generation or !self.sameScope(review)) return .{ .state = .absent };
            return .{ .state = .recorded, .executable = identity.Path.init(self.executable) catch return error.Parse };
        }

        fn matches(self: Record, review: *const panel.LocalReview, generation: u64, fingerprint: [32]u8) bool {
            return self.generation == generation and self.sameScope(review) and review.executable.eql(self.executable) and std.mem.eql(u8, &self.fingerprint, &fingerprint);
        }
    };

    fn encode(review: *const panel.LocalReview, generation: u64, fingerprint: [32]u8, nonce: Nonce, bytes: []u8) Error![]const u8 {
        const root = review.root.slice();
        const exe = review.executable.slice();
        const len = root.len + exe.len + header_size;
        if (len > bytes.len or len > max_record or !approval.strictPath(root) or !approval.strictPath(exe)) return error.Parse;
        @memcpy(bytes[0..8], magic);
        std.mem.writeInt(u64, bytes[8..16], generation, .little);
        bytes[16] = @backingInt(review.kind);
        std.mem.writeInt(u16, bytes[17..19], @intCast(root.len), .little);
        std.mem.writeInt(u16, bytes[19..21], @intCast(exe.len), .little);
        @memcpy(bytes[21..53], &fingerprint);
        @memcpy(bytes[53..69], &nonce);
        @memcpy(bytes[header_size..][0..root.len], root);
        @memcpy(bytes[header_size + root.len .. len], exe);
        const encoded = bytes[0..len];
        _ = try Record.parse(encoded);
        return encoded;
    }

    fn loadSlot(review: *const panel.LocalReview) Error!?[]u8 {
        if (comptime builtin.os.tag != .windows) return error.Unsupported;
        const name = slot(review);
        const bytes = allocator.alloc(u8, max_envelope) catch return error.OutOfMemory;
        defer allocator.free(bytes);
        var len: u32 = @intCast(bytes.len);
        const status = RegGetValueW(hkcu, sub, &name, 8, null, bytes.ptr, &len);
        if (status == 2) return null;
        if (status != 0 or len == 0 or len > bytes.len) return error.Permission;
        if (len == 1 and bytes[0] == 0) return null;
        const decoded = try transformWithEntropy(bytes[0..len], true, entropy);
        errdefer allocator.free(decoded);
        _ = try Record.parse(decoded);
        return decoded;
    }

    fn inspect(review: *const panel.LocalReview) Error!contract.SavedHint {
        const generation = try epoch();
        const bytes = (try loadSlot(review)) orelse return .{ .state = .absent };
        defer allocator.free(bytes);
        const record = try Record.parse(bytes);
        const result = try record.hint(review, generation);
        if (try epoch() != generation) return error.Permission;
        return result;
    }

    fn require(review: *const panel.LocalReview, generation: u64, fingerprint: [32]u8, expected: ?Nonce) Error!Nonce {
        if (try epoch() != generation) return error.Permission;
        const bytes = (try loadSlot(review)) orelse return error.Permission;
        defer allocator.free(bytes);
        const record = try Record.parse(bytes);
        if (!record.matches(review, generation, fingerprint) or try epoch() != generation) return error.Permission;
        if (expected) |nonce| {
            if (!std.mem.eql(u8, &nonce, &record.nonce)) return error.Permission;
        }
        return record.nonce;
    }

    fn save(review: *const panel.LocalReview, generation: u64, fingerprint: [32]u8, revoked: *const std.atomic.Value(bool)) Error!Nonce {
        const mutex = try lock();
        defer unlock(mutex);
        if (try epoch() != generation) return error.Permission;
        if (try loadSlot(review)) |previous| {
            defer allocator.free(previous);
            const record = try Record.parse(previous);
            if (record.generation == generation and !record.sameScope(review)) return error.ResourceLimit;
        }
        var nonce: Nonce = undefined;
        if (SystemFunction036(&nonce, nonce.len) == 0) return error.Permission;
        var buffer: [max_record]u8 = undefined;
        const bytes = try encode(review, generation, fingerprint, nonce, &buffer);
        const sealed = try transformWithEntropy(bytes, false, entropy);
        defer allocator.free(sealed);
        if (sealed.len > max_envelope) return error.ResourceLimit;
        const name = slot(review);
        if (revoked.load(.acquire)) return error.Permission;
        if (RegSetKeyValueW(hkcu, sub, &name, 3, sealed.ptr, @intCast(sealed.len)) != 0) return error.Permission;
        return nonce;
    }

    fn forget(review: *const panel.LocalReview) Error!void {
        const mutex = try lock();
        defer unlock(mutex);
        const bytes = (try loadSlot(review)) orelse return;
        defer allocator.free(bytes);
        const record = try Record.parse(bytes);
        if (record.generation != try epoch()) return;
        if (!record.sameScope(review)) return error.Permission;
        const name = slot(review);
        const tombstone = [_]u8{0};
        if (RegSetKeyValueW(hkcu, sub, &name, 3, &tombstone, tombstone.len) != 0) return error.Permission;
    }
};

// Separate, opt-in local trust model. This is not the restricted auditor,
// an automatic PATH grant, or a sandbox. The user's consent covers the
// selected installation, repository configuration and their dependencies.
// All external commands remain fixed, bounded and Job-contained.
const LocalSession = struct {
    environment: std.process.Environ.Map,
    review: ?panel.LocalReview = null,
    revoked: std.atomic.Value(bool) = .init(false),
    io: ?std.Io.Threaded = null,
    runner: ?process.Runner = null,
    pins: ?Pins = null,
    saved_epoch: ?u64 = null,
    saved_nonce: ?SavedLocal.Nonce = null,
    neutral: identity.Path = .{},
    git: git_mod.Git = undefined,
    jj: jj_mod.Jj = undefined,
    svn: svn_mod.Svn = undefined,
    hg: hg_mod.Hg = undefined,

    const Pins = struct {
        executable: evidence.FileIdentity,
        root: evidence.FileIdentity,
        marker: evidence.FileIdentity,
        digest: approval.Digest,
    };

    fn tool(kind: identity.Kind) ?cli.Tool {
        return switch (kind) {
            .git => .git,
            .jj => .jj,
            .svn => .svn,
            .hg => .hg,
            else => null,
        };
    }

    fn validReview(review: *const panel.LocalReview) bool {
        const selected = tool(review.kind) orelse return false;
        if (!approval.strictPath(review.root.slice()) or !approval.strictPath(review.executable.slice())) return false;
        if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(review.executable.slice()), selected.exeName())) return false;
        // SVN treats @ in a target as a peg revision. This candidate only
        // admits unambiguous ordinary local paths.
        if (review.kind == .svn and std.mem.indexOfScalar(u8, review.root.slice(), '@') != null) return false;
        return true;
    }

    fn authorize(user: *anyopaque, review: *const panel.LocalReview) host.Error!host_query.Resolver {
        const self: *LocalSession = @ptrCast(@alignCast(user));
        if (self.review != null or self.revoked.load(.acquire)) return error.State;
        if (!validReview(review)) return error.Argument;
        if (review.mode != .session) self.saved_epoch = SavedLocal.epoch() catch |err| return hostError(err);
        self.review = review.*;
        return .{ .ctx = self, .resolve = &resolve };
    }

    fn revoke(user: *anyopaque) host.Error!void {
        const self: *LocalSession = @ptrCast(@alignCast(user));
        self.revoked.store(true, .release);
    }

    fn forget(_: *anyopaque, review: *const panel.LocalReview) host.Error!void {
        SavedLocal.forget(review) catch |err| return hostError(err);
    }

    fn forgetAll(_: *anyopaque) host.Error!void {
        SavedLocal.revokeAll() catch |err| return hostError(err);
    }

    fn revokeSavedActive(user: *anyopaque) host.Error!void {
        const self: *LocalSession = @ptrCast(@alignCast(user));
        self.revoked.store(true, .release);
        const review = if (self.review) |*value| value else return error.State;
        SavedLocal.forget(review) catch |err| return hostError(err);
    }

    // Called only after both host-owned worker slots have been released.
    fn releaseResources(self: *LocalSession) host.Error!void {
        self.revoked.store(true, .release);
        if (self.runner) |*runner| {
            runner.requestStop();
            runner.finishStop() catch return error.State;
            self.runner = null;
        }
        if (self.io) |*threaded| threaded.deinit();
        self.io = null;
        self.environment.deinit();
    }

    fn reset(user: *anyopaque) host.Error!void {
        const self: *LocalSession = @ptrCast(@alignCast(user));
        try self.releaseResources();
        self.* = .{ .environment = std.process.Environ.Map.init(allocator) };
    }

    fn finish(user: *anyopaque) host.Error!void {
        const self: *LocalSession = @ptrCast(@alignCast(user));
        try self.releaseResources();
        allocator.destroy(self);
    }

    fn markerPath(review: *const panel.LocalReview, bytes: []u8) Error![]const u8 {
        const marker = switch (review.kind) {
            .git => ".git",
            .jj => ".jj",
            .svn => ".svn",
            .hg => ".hg",
            else => return error.Unsupported,
        };
        return std.fmt.bufPrint(bytes, "{s}\\{s}", .{ review.root.slice(), marker }) catch error.ResourceLimit;
    }

    fn sameId(a: evidence.FileIdentity, b: evidence.FileIdentity) bool {
        return a.volume == b.volume and a.index == b.index;
    }

    fn fingerprint(pins: Pins, review: *const panel.LocalReview) [32]u8 {
        var hash = Sha256.init(.{});
        // Domain-separate the advanced read policy from summary-only grants.
        hash.update("pulse-extras-local-read-policy-v2");
        hash.update(review.root.slice());
        hash.update(&.{ 0, @backingInt(review.kind) });
        hash.update(review.executable.slice());
        hash.update(&.{0});
        for ([_]evidence.FileIdentity{ pins.executable, pins.root, pins.marker }) |id| {
            var bytes: [12]u8 = undefined;
            std.mem.writeInt(u32, bytes[0..4], id.volume, .little);
            std.mem.writeInt(u64, bytes[4..12], id.index, .little);
            hash.update(&bytes);
        }
        hash.update(&pins.digest);
        return hash.finalResult();
    }

    fn checkSaved(self: *LocalSession, review: *const panel.LocalReview) Error!void {
        if (review.mode == .session) return;
        const generation = self.saved_epoch orelse return error.Permission;
        if (try SavedLocal.epoch() != generation) return error.Permission;
        if (review.mode == .reuse or self.saved_nonce != null) self.saved_nonce = try SavedLocal.require(review, generation, fingerprint(self.pins orelse return error.Permission, review), self.saved_nonce);
    }

    fn checkPins(self: *LocalSession, review: *const panel.LocalReview) Error!void {
        if (self.revoked.load(.acquire)) return error.Permission;
        const pins = self.pins orelse return error.Permission;
        var bytes: [identity.max_path_bytes]u8 = undefined;
        const marker = try markerPath(review, &bytes);
        if (!sameId(pins.executable, try evidence.observeSessionToolIdentity(review.executable.slice())) or
            !sameId(pins.root, try evidence.observeIdentity(review.root.slice(), true)) or
            !sameId(pins.marker, try evidence.observeIdentity(marker, true))) return error.Permission;
    }

    fn initialize(self: *LocalSession, review: *const panel.LocalReview) Error!void {
        if (self.pins != null) {
            try self.checkPins(review);
            return self.checkSaved(review);
        }
        if (self.revoked.load(.acquire)) return error.Permission;
        var path: [identity.max_path_bytes]u8 = undefined;
        const marker = try markerPath(review, &path);
        const root_id = try evidence.observeIdentity(review.root.slice(), true);
        const marker_id = try evidence.observeIdentity(marker, true);
        const exe_id = evidence.observeSessionToolIdentity(review.executable.slice()) catch return error.CliMissing;
        if (self.io == null) {
            self.io = if (comptime @TypeOf(std.Io.Threaded.init) == fn (std.mem.Allocator) std.Io.Threaded)
                std.Io.Threaded.init(allocator)
            else
                std.Io.Threaded.init(allocator, .{});
        }
        const threaded = if (self.io) |*value| value else return error.Io;
        const io = threaded.io();
        const file = std.Io.Dir.openFileAbsolute(io, review.executable.slice(), .{ .follow_symlinks = false }) catch return error.CliMissing;
        defer file.close(io);
        const digest = trust.digestFile(io, file) catch return error.Permission;
        if (!sameId(exe_id, try evidence.observeSessionToolIdentity(review.executable.slice()))) return error.Permission;
        const system = try evidence.systemDirectory(&path);
        self.neutral = identity.Path.init(system) catch return error.Permission;
        for ([_][]const u8{ "SystemRoot", "WINDIR", "LANG", "LC_ALL", "GIT_CONFIG_NOSYSTEM", "GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS", "GIT_NO_LAZY_FETCH" }, [_][]const u8{ system, system, "C", "C", "1", "0", "0", "1" }) |key, value| {
            self.environment.put(key, value) catch return error.OutOfMemory;
        }
        if (review.kind == .hg) {
            for ([_][]const u8{ "HGPLAIN", "HGRCPATH", "HGRCSKIPREPO", "HGENCODING" }, [_][]const u8{ "1", "", "1", "UTF-8" }) |key, value| {
                self.environment.put(key, value) catch return error.OutOfMemory;
            }
        }
        if (self.runner == null) self.runner = process.Runner.init(allocator, io);
        const runner = if (self.runner) |*value| value else return error.Io;
        runner.configureApproved(.{ .path = review.executable.slice(), .digest = digest }, 15 * std.time.ns_per_s) catch return error.Permission;
        runner.configureTree(.windows_job) catch return error.Io;
        self.pins = .{ .executable = exe_id, .root = root_id, .marker = marker_id, .digest = digest };
        try self.checkPins(review);
        try self.checkSaved(review);
    }

    fn argvEqual(actual: []const []const u8, expected: []const []const u8) bool {
        if (actual.len != expected.len) return false;
        for (actual, expected) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        return true;
    }

    fn allowedCommand(review: *const panel.LocalReview, argv: []const []const u8) bool {
        const exe = review.executable.slice();
        const root = review.root.slice();
        if (argvEqual(argv, &.{ exe, "--version" })) return true;
        if (contract.detailAllowed(review.kind, exe, root, argv)) return true;
        return switch (review.kind) {
            .git => argvEqual(argv, &.{ exe, "--no-optional-locks", "-C", root, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "--absolute-git-dir" }) or
                argvEqual(argv, &.{ exe, "--no-optional-locks", "-C", root, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal", "--ignore-submodules=all" }),
            .jj => blk: {
                if (argvEqual(argv, &.{ exe, "--ignore-working-copy", "--no-pager", "--color=never", "-R", root, "log", "-r", "@", "--no-graph", "-T", jj_mod.revision_template })) break :blk true;
                if (argv.len != 10 or argv[9].len != 40) break :blk false;
                for (argv[9]) |byte| {
                    if (!std.ascii.isHex(byte)) break :blk false;
                }
                break :blk argvEqual(argv[0..9], &.{ exe, "--ignore-working-copy", "--no-pager", "--color=never", "-R", root, "diff", "--summary", "-r" });
            },
            .svn => argvEqual(argv, &.{ exe, "info", "--non-interactive", "--no-auth-cache", "--show-item", "revision", root }) or
                argvEqual(argv, &.{ exe, "info", "--non-interactive", "--no-auth-cache", "--show-item", "relative-url", root }) or
                argvEqual(argv, &.{ exe, "status", "--non-interactive", "--no-auth-cache", "--ignore-externals", "--xml", "--no-ignore", root }),
            else => false,
        };
    }

    fn checkHgLayout(review: *const panel.LocalReview) Error!void {
        var path: [identity.max_path_bytes]u8 = undefined;
        var bytes: [4096]u8 = undefined;
        const root = review.root.slice();
        for ([_][]const u8{ ".hg\\sharedpath", ".hgsub", ".hgsubstate" }) |suffix| {
            const target = std.fmt.bufPrint(&path, "{s}\\{s}", .{ root, suffix }) catch return error.ResourceLimit;
            try evidence.requireAbsent(target);
        }
        const store = std.fmt.bufPrint(&path, "{s}\\.hg\\store", .{root}) catch return error.ResourceLimit;
        _ = try evidence.observeIdentity(store, true);
        for ([_][]const u8{ ".hg\\requires", ".hg\\store\\requires" }) |suffix| {
            const target = std.fmt.bufPrint(&path, "{s}\\{s}", .{ root, suffix }) catch return error.ResourceLimit;
            try evidence.validateHgRequirements(try evidence.readPreviewFile(target, &bytes));
        }
    }

    fn checkRequest(user: *anyopaque, runner: *process.Runner, request: process.Request) process.Error!void {
        const self: *LocalSession = @ptrCast(@alignCast(user));
        const review = if (self.review) |*value| value else return error.UnapprovedExecutable;
        const owned = if (self.runner) |*value| value else return error.UnapprovedExecutable;
        const pins = self.pins orelse return error.UnapprovedExecutable;
        const approved = runner.approval orelse return error.UnapprovedExecutable;
        if (runner != owned or runner.policy != .approved_local or runner.tree_policy != .windows_job or
            !std.mem.eql(u8, approved.slice(), review.executable.slice()) or !std.mem.eql(u8, &approved.digest, &pins.digest) or
            request.environ_map != &self.environment or !self.neutral.eql(request.cwd orelse return error.UnapprovedEnvironment) or
            !allowedCommand(review, request.argv)) return error.UnapprovedExecutable;
        self.checkPins(review) catch return error.UnapprovedExecutable;
        self.checkSaved(review) catch return error.UnapprovedExecutable;
        if (review.kind == .hg and !argvEqual(request.argv, &.{ review.executable.slice(), "--version" })) checkHgLayout(review) catch return error.UnapprovedExecutable;
        if (review.kind == .svn and contract.detailAllowed(.svn, review.executable.slice(), review.root.slice(), request.argv)) {
            const arg = request.argv[request.argv.len - 1];
            const target = if (std.mem.endsWith(u8, arg, "@")) arg[0 .. arg.len - 1] else arg;
            if (!review.root.eql(target)) {
                evidence.observeLocalTarget(target) catch return error.UnapprovedExecutable;
                // Do not treat a nested checkout as the approved working copy.
                const parent = std.fs.path.dirname(target) orelse return error.UnapprovedExecutable;
                var observed: detect.Result = .{};
                detectPreview(self, parent, &observed);
                const candidate = observed.find(.svn) orelse return error.UnapprovedExecutable;
                if (!candidate.root.eql(review.root.slice())) return error.UnapprovedExecutable;
            }
        }
        // Runner independently rehashes the executable immediately before spawn.
        if (self.revoked.load(.acquire)) return error.UnapprovedExecutable;
    }

    fn resolve(user: *anyopaque, directory: *const identity.Path) Error!?host_query.Resolved {
        const self: *LocalSession = @ptrCast(@alignCast(user));
        const review = if (self.review) |*value| value else return error.Permission;
        if (self.revoked.load(.acquire) or !approval.strictPath(directory.slice())) return error.Permission;
        _ = try evidence.observeIdentity(directory.slice(), true);
        var detected: detect.Result = .{};
        detectPreview(user, directory.slice(), &detected);
        const candidate = detected.find(review.kind) orelse return null;
        if (!candidate.root.eql(review.root.slice())) return error.Permission;
        try self.initialize(review);
        const runner = if (self.runner) |*value| value else return error.Io;
        const execution: cli.Execution = .{ .approved = .{
            .cwd = self.neutral,
            .environment = &self.environment,
            .gate = .{ .ctx = self, .check = &checkRequest },
        } };
        const report = cli.probeApproved(tool(review.kind) orelse return error.Unsupported, &review.executable, &execution, runner) catch |err| return switch (err) {
            error.UnsupportedVersion => error.CliTooOld,
            error.InvalidVersion => error.Parse,
            error.UnapprovedExecutable, error.UnapprovedEnvironment, error.PermissionDenied => error.Permission,
            error.SpawnFailed => error.CliMissing,
            error.TimedOut => error.Timeout,
            error.Cancelled => error.Cancelled,
            else => error.Io,
        };
        var bytes: [identity.max_path_bytes]u8 = undefined;
        const marker = try markerPath(review, &bytes);
        const workspace = identity.Workspace.init(review.kind, review.root.slice(), marker) catch return error.Parse;
        const probe: detect.Probe = .{ .ctx = self, .lookup = &previewLookup };
        const provider = switch (review.kind) {
            .git => blk: {
                self.git = git_mod.Git.initApproved(runner, review.executable, probe, execution) catch return error.Permission;
                const reported = try self.git.resolveWorkspace(review.root.slice());
                if (reported.shared_metadata or !reportedPathEqual(reported.root.slice(), review.root.slice()) or !reportedPathEqual(reported.repository_root.slice(), marker)) return error.Permission;
                break :blk self.git.provider();
            },
            .jj => blk: {
                self.jj = jj_mod.Jj.initApproved(runner, review.executable, probe, execution) catch return error.Permission;
                break :blk self.jj.provider();
            },
            .svn => blk: {
                self.svn = svn_mod.Svn.initApproved(runner, review.executable, probe, execution) catch return error.Permission;
                self.svn.detail_version = report.version;
                break :blk self.svn.provider();
            },
            .hg => blk: {
                self.hg = hg_mod.Hg.initApproved(runner, review.executable, probe, execution) catch return error.Permission;
                try self.hg.verifyRoot(&workspace);
                break :blk self.hg.provider();
            },
            else => return error.Unsupported,
        };
        if (review.mode == .remember and self.saved_nonce == null) {
            if (self.revoked.load(.acquire)) return error.Permission;
            const generation = self.saved_epoch orelse return error.Permission;
            self.saved_nonce = try SavedLocal.save(review, generation, fingerprint(self.pins orelse return error.Permission, review), &self.revoked);
        }
        try self.checkSaved(review);
        return .{ .provider = provider, .workspace = workspace, .tool_version = contract.Text.init(report.lineSlice()) catch return error.Parse, .cache_token = fingerprint(self.pins orelse return error.Permission, review) };
    }

    fn reportedPathEqual(actual: []const u8, expected: []const u8) bool {
        if (actual.len != expected.len) return false;
        for (actual, expected) |a, b| {
            if (a == b or (a == '/' and b == '\\')) continue;
            return false;
        }
        return true;
    }
};

fn previewLookup(_: *anyopaque, path: []const u8) detect.EntryType {
    const name = std.fs.path.basename(path);
    if (!std.mem.eql(u8, name, ".git") and !std.mem.eql(u8, name, ".jj") and !std.mem.eql(u8, name, ".svn") and !std.mem.eql(u8, name, ".hg")) return .missing;
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
        if (candidate.kind != .git and candidate.kind != .jj and candidate.kind != .svn and candidate.kind != .hg) continue;
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
    return .{ .provider = previewProvider(user, candidate.kind), .workspace = workspace };
}

fn previewProvider(user: *anyopaque, kind: identity.Kind) contract.Provider {
    var set: capabilities.Set = .empty;
    // Internal summary slot only: the panel explicitly distinguishes marker
    // inspection from a measured status. Never expose write capabilities.
    set.insert(.status);
    return .{
        .kind = kind,
        .display_name = kind.displayName(),
        .capabilities = set,
        .vtable = preview_vtable,
        .ctx = user,
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

// Non-executing discovery, in the existing metadata worker only. Ignore
// relative, network, reparse and malformed candidates. Bound PATH and probes;
// a found path is a suggestion, never an approval or version claim.
fn suggestTools(snapshot: *contract.Snapshot) void {
    if (comptime builtin.os.tag != .windows) return;
    const wide = allocator.alloc(u16, 32768) catch return;
    defer allocator.free(wide);
    const size = GetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("PATH"), wide.ptr, @intCast(wide.len));
    if (size == 0 or size >= wide.len) return;
    const utf8 = allocator.alloc(u8, 64 * 1024) catch return;
    defer allocator.free(utf8);
    const len = WideCharToMultiByte(65001, 0x80, wide.ptr, @intCast(size), utf8.ptr, @intCast(utf8.len), null, null);
    if (len <= 0) return;
    var parts = std.mem.splitScalar(u8, utf8[0..@intCast(len)], ';');
    var buffer: [identity.max_path_bytes]u8 = undefined;
    for (0..64) |_| {
        const raw = parts.next() orelse break;
        const directory = std.mem.trimEnd(u8, std.mem.trim(u8, raw, " \t\""), "\\");
        if (!approval.strictPath(directory)) continue;
        // Observe directory before probing entries; never enumerate or run.
        _ = evidence.observeIdentity(directory, true) catch continue;
        for ([_]identity.Kind{ .git, .jj, .svn, .hg }, 0..) |kind, index| {
            if (!snapshot.previewHas(kind) or snapshot.preview_tools[index] != null) continue;
            const selected = LocalSession.tool(kind) orelse continue;
            const path = std.fmt.bufPrint(&buffer, "{s}\\{s}", .{ directory, selected.exeName() }) catch continue;
            _ = evidence.observeSessionToolIdentity(path) catch continue;
            snapshot.preview_tools[index] = identity.Path.init(path) catch continue;
        }
    }
}

// Only a literal origin in a small regular .git/config. No include, URL
// rewrite, config evaluation, worktree traversal or remote connection.
fn previewOrigin(bytes: []const u8) ?contract.Text {
    var origin = false;
    var result: ?contract.Text = null;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            origin = std.ascii.eqlIgnoreCase(line, "[remote \"origin\"]");
            continue;
        }
        if (!origin) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..equals], " \t"), "url")) continue;
        if (result != null) return null;
        result = contract.repositoryWebUrl(std.mem.trim(u8, line[equals + 1 ..], " \t")) orelse return null;
    }
    return result;
}

test "preview remote is a literal forge hint, never credentials" {
    const remote = previewOrigin("[remote \"origin\"]\n url = git@github.com:owner/repo.git\n") orelse return error.TestUnexpectedResult;
    try std.testing.expect(remote.eql("https://github.com/owner/repo"));
    try std.testing.expect(previewOrigin("[remote \"origin\"]\n url = https://token@github.com/owner/repo\n") == null);
    try std.testing.expect(previewOrigin("[remote \"origin\"]\nurl = https://github.com/a/b\nurl = https://github.com/c/d\n") == null);
}

fn summarizePreview(user: *anyopaque, workspace: *const identity.Workspace) Error!contract.Snapshot {
    var found: detect.Result = .{};
    detectPreview(user, workspace.root.slice(), &found);
    const current = found.find(workspace.kind) orelse return error.Stale;
    if (!current.root.eql(workspace.root.slice())) return error.Stale;
    var snapshot: contract.Snapshot = .{ .workspace = workspace.*, .availability = .not_queried };
    var labels: [96]u8 = undefined;
    var used: usize = 0;
    for ([_]identity.Kind{ .git, .jj, .svn, .hg }) |kind| {
        if (found.find(kind)) |candidate| {
            if (!candidate.root.eql(workspace.root.slice())) continue;
            const index = contract.Snapshot.previewIndex(kind) orelse continue;
            snapshot.preview_kinds |= @as(u8, 1) << @as(u3, @intCast(index));
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
    suggestTools(&snapshot);
    // Only the current root and detected provider scopes, on the existing
    // metadata worker. A saved record is not a current identity/digest check.
    for ([_]identity.Kind{ .git, .jj, .svn, .hg }, 0..) |kind, index| {
        if (!snapshot.previewHas(kind)) continue;
        const scope: panel.LocalReview = .{ .root = workspace.root, .kind = kind, .executable = .{}, .generation = 0 };
        snapshot.preview_saved[index] = SavedLocal.inspect(&scope) catch .{ .state = .unavailable };
    }
    if (snapshot.previewHas(.git)) {
        var path: [identity.max_path_bytes]u8 = undefined;
        var bytes: [4096]u8 = undefined;
        if (std.fmt.bufPrint(&path, "{s}\\.git\\config", .{workspace.root.slice()})) |config_path| {
            if (evidence.readPreviewFile(config_path, &bytes)) |config| {
                snapshot.remote_web = previewOrigin(config) orelse .{};
            } else |_| {}
        } else |_| {}
    }
    if (workspace.kind == .git) {
        var path: [identity.max_path_bytes]u8 = undefined;
        const head_path = std.fmt.bufPrint(&path, "{s}\\.git\\HEAD", .{workspace.root.slice()}) catch return snapshot;
        var bytes: [512]u8 = undefined;
        const head = evidence.readPreviewFile(head_path, &bytes) catch return snapshot;
        parsePreviewHead(head, &snapshot);
    }
    return snapshot;
}

test "preview provider uses a value vtable for each supported kind" {
    var context_byte: u8 = 0;
    for ([_]identity.Kind{ .git, .jj, .svn, .hg }) |kind| {
        const provider = previewProvider(&context_byte, kind);
        try std.testing.expectEqual(kind, provider.kind);
        try std.testing.expect(provider.supports(.status));
        try std.testing.expect(provider.vtable.detect == &detectPreview);
        try std.testing.expect(provider.vtable.summarize == &summarizePreview);
        var result: detect.Result = .{};
        provider.detectInto("", &result);
        try std.testing.expectEqual(@as(u8, 0), result.len);
    }
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

test "local trust command admission is exact for each provider" {
    const root = try identity.Path.init("C:\\repo");
    var review: panel.LocalReview = .{ .root = root, .executable = try identity.Path.init("C:\\tools\\git.exe"), .kind = .git, .generation = 1 };
    const exe = review.executable.slice();
    try std.testing.expect(LocalSession.allowedCommand(&review, &.{ exe, "--version" }));
    try std.testing.expect(LocalSession.allowedCommand(&review, &.{ exe, "--no-optional-locks", "-C", root.slice(), "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal", "--ignore-submodules=all" }));
    try std.testing.expect(!LocalSession.allowedCommand(&review, &.{ exe, "-C", root.slice(), "commit" }));
    try std.testing.expect(!LocalSession.allowedCommand(&review, &.{ exe, "--no-optional-locks", "-C", "C:\\other", "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal", "--ignore-submodules=all" }));
    review.kind = .jj;
    review.executable = try identity.Path.init("C:\\tools\\jj.exe");
    try std.testing.expect(LocalSession.allowedCommand(&review, &.{ review.executable.slice(), "--ignore-working-copy", "--no-pager", "--color=never", "-R", root.slice(), "diff", "--summary", "-r", "0123456789abcdef0123456789abcdef01234567" }));
    try std.testing.expect(!LocalSession.allowedCommand(&review, &.{ review.executable.slice(), "--ignore-working-copy", "--no-pager", "--color=never", "-R", root.slice(), "diff", "--summary", "-r", "--config" }));
    review.kind = .svn;
    review.executable = try identity.Path.init("C:\\tools\\svn.exe");
    try std.testing.expect(LocalSession.allowedCommand(&review, &.{ review.executable.slice(), "status", "--non-interactive", "--no-auth-cache", "--ignore-externals", "--xml", "--no-ignore", root.slice() }));
    try std.testing.expect(!LocalSession.allowedCommand(&review, &.{ review.executable.slice(), "status", "--xml", "-u", root.slice() }));
}

fn fixtureAbsoluteRoot(sub_path: []const u8) !identity.Path {
    var wide: [identity.max_path_bytes + 1]u16 = undefined;
    const size = GetCurrentDirectoryW(wide.len, &wide);
    if (size == 0 or size >= wide.len) return error.TestUnexpectedResult;
    var utf8: [identity.max_path_bytes]u8 = undefined;
    const len = WideCharToMultiByte(65001, 0x80, &wide, @intCast(size), &utf8, utf8.len, null, null);
    if (len <= 0) return error.TestUnexpectedResult;
    var bytes: [identity.max_path_bytes]u8 = undefined;
    return identity.Path.init(try std.fmt.bufPrint(&bytes, "{s}\\.zig-cache\\tmp\\{s}", .{ utf8[0..@intCast(len)], sub_path }));
}

fn fixtureTool(selected: cli.Tool) !identity.Path {
    const config = @import("vcs_test_config");
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    var path = cli.locateCandidate(std.testing.io, selected, config.path, &scratch) orelse return cli.integrationUnavailable(selected);
    for (path.bytes[0..path.len]) |*byte| {
        if (byte.* == '/') byte.* = '\\';
    }
    return path;
}

fn exerciseLocalFixture(kind: identity.Kind, executable: identity.Path, root: identity.Path) !contract.Snapshot {
    const local = try allocator.create(LocalSession);
    local.* = .{ .environment = std.process.Environ.Map.init(allocator) };
    errdefer LocalSession.finish(local) catch {};
    const review: panel.LocalReview = .{ .root = root, .executable = executable, .kind = kind, .generation = 1 };
    const resolver = try LocalSession.authorize(local, &review);
    const resolved = (try resolver.resolve(resolver.ctx, &root)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqual(kind, resolved.provider.kind);
    try std.testing.expect(resolved.tool_version.slice().len != 0);
    const snapshot = try resolved.provider.summarize(&resolved.workspace);
    try std.testing.expectEqual(contract.Availability.ready, snapshot.availability);
    try LocalSession.revoke(local);
    try std.testing.expectError(error.Permission, resolver.resolve(resolver.ctx, &root));
    try LocalSession.finish(local);
    return snapshot;
}

test "trusted local mode queries ordinary installed Git and revokes admission" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const executable = try fixtureTool(.git);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureAbsoluteRoot(&tmp.sub_path);
    var runner = process.Runner.init(std.testing.allocator, io);
    {
        var outcome = try runner.run(.{ .argv = &.{ executable.slice(), "-C", root.slice(), "init", "--quiet", "--template=" }, .timeout_ns = 20 * std.time.ns_per_s });
        defer outcome.deinit();
        if (!outcome.succeeded()) return error.TestUnexpectedResult;
    }
    const file = try tmp.dir.createFile(io, "untracked.txt", .{ .exclusive = true });
    try file.writeStreamingAll(io, "fixture\n");
    file.close(io);
    try runner.checkDrained();
    const snapshot = try exerciseLocalFixture(.git, executable, root);
    try std.testing.expectEqual(@as(u32, 1), snapshot.changes.untracked);
}

test "trusted local mode queries ordinary installed Jujutsu without snapshotting" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const io = std.testing.io;
    const executable = try fixtureTool(.jj);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try fixtureAbsoluteRoot(&tmp.sub_path);
    var runner = process.Runner.init(std.testing.allocator, io);
    {
        var outcome = try runner.run(.{ .argv = &.{ executable.slice(), "git", "init", root.slice() }, .timeout_ns = 20 * std.time.ns_per_s });
        defer outcome.deinit();
        if (!outcome.succeeded()) return error.TestUnexpectedResult;
    }
    try runner.checkDrained();
    const snapshot = try exerciseLocalFixture(.jj, executable, root);
    try std.testing.expect(snapshot.revision != null);
    try std.testing.expectEqual(contract.Availability.not_queried, snapshot.counts.untracked);
}

test "trusted local mode queries an actual Windows SVN fixture when provisioned" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const config = @import("vcs_test_config");
    if (config.svn_working_copy.len == 0) return cli.integrationUnavailable(.svn);
    const executable = try fixtureTool(.svn);
    var root = try identity.Path.init(config.svn_working_copy);
    for (root.bytes[0..root.len]) |*byte| {
        if (byte.* == '/') byte.* = '\\';
    }
    const snapshot = try exerciseLocalFixture(.svn, executable, root);
    try std.testing.expect(snapshot.revision != null);
    try std.testing.expectEqual(@as(u32, 1), snapshot.changes.modified);
    try std.testing.expectEqual(@as(u32, 1), snapshot.changes.untracked);
    try std.testing.expectEqual(contract.Availability.ready, snapshot.counts.modified);
}

test "saved local records pin exact root provider executable identity and epoch" {
    const root = if (builtin.os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    const exe = if (builtin.os.tag == .windows) "C:\\tools\\git.exe" else "/tools/git";
    var review: panel.LocalReview = .{ .root = try identity.Path.init(root), .executable = try identity.Path.init(exe), .kind = .git, .generation = 4 };
    const digest: [32]u8 = @splat(0x5a);
    var buffer: [SavedLocal.max_record]u8 = undefined;
    const nonce: SavedLocal.Nonce = @splat(7);
    const bytes = try SavedLocal.encode(&review, 9, digest, nonce, &buffer);
    const record = try SavedLocal.Record.parse(bytes);
    try std.testing.expect(record.matches(&review, 9, digest));
    const hint = try record.hint(&review, 9);
    try std.testing.expectEqual(contract.SavedHint.State.recorded, hint.state);
    try std.testing.expect(hint.executable.?.eql(exe));
    try std.testing.expectEqual(contract.SavedHint.State.absent, (try record.hint(&review, 10)).state);
    try std.testing.expectEqualSlices(u8, &nonce, &record.nonce);
    try std.testing.expect(!record.matches(&review, 10, digest));
    try std.testing.expect(!record.matches(&review, 9, @splat(0x5b)));
    review.kind = .jj;
    try std.testing.expect(!record.matches(&review, 9, digest));
    const unrelated = try record.hint(&review, 9);
    try std.testing.expectEqual(contract.SavedHint.State.absent, unrelated.state);
    try std.testing.expect(unrelated.executable == null);
    review.kind = .git;
    try std.testing.expectError(error.Parse, SavedLocal.Record.parse(bytes[0 .. bytes.len - 1]));
    if (comptime builtin.os.tag == .windows) {
        const sealed = try transformWithEntropy(bytes, false, SavedLocal.entropy);
        defer allocator.free(sealed);
        const decoded = try transformWithEntropy(sealed, true, SavedLocal.entropy);
        defer allocator.free(decoded);
        try std.testing.expectEqualSlices(u8, bytes, decoded);
        try std.testing.expectError(error.Permission, transform(sealed, true));
    }
}

test "trusted local mode queries ordinary Mercurial and rejects repository config hook" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const config = @import("vcs_test_config");
    if (config.hg_working_copy.len == 0) return cli.integrationUnavailable(.hg);
    const executable = try fixtureTool(.hg);
    var root = try identity.Path.init(config.hg_working_copy);
    for (root.bytes[0..root.len]) |*byte| {
        if (byte.* == '/') byte.* = '\\';
    }
    const snapshot = try exerciseLocalFixture(.hg, executable, root);
    try std.testing.expect(snapshot.revision != null);
    try std.testing.expect(snapshot.changes.modified >= 2);
    try std.testing.expectEqual(@as(u32, 1), snapshot.changes.untracked);
}
