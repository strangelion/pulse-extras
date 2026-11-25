//! Windows local filesystem observations for the ordinary Git grant.
//! No recursive walks, shell, executable invocation or file writes.
//! A successful observation is NOT an ACL or full Git configuration audit.
//! Compose with an independent auditor; absent evidence must fail closed.

const std = @import("std");
const builtin = @import("builtin");
const identity = @import("vcs_identity");
const approval = @import("vcs_approval");
const contract = @import("vcs_provider");
const Sha256 = std.crypto.hash.sha2.Sha256;
const Handle = std.os.windows.HANDLE;

pub const max_config_bytes = 16 * 1024;
pub const max_components = 64;
const invalid_attributes: u32 = 0xffffffff;
const directory_attribute: u32 = 0x10;
const reparse_attribute: u32 = 0x400;

const FileInfo = extern struct {
    attributes: u32,
    creation_low: u32,
    creation_high: u32,
    access_low: u32,
    access_high: u32,
    write_low: u32,
    write_high: u32,
    volume: u32,
    size_high: u32,
    size_low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};

extern "kernel32" fn GetDriveTypeW(root: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, flags: u32, template: ?Handle) callconv(.winapi) ?Handle;
extern "kernel32" fn GetFileInformationByHandle(handle: Handle, info: *FileInfo) callconv(.winapi) i32;
extern "kernel32" fn GetFinalPathNameByHandleW(handle: Handle, path: [*]u16, capacity: u32, flags: u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn ReadFile(handle: Handle, buffer: [*]u8, size: u32, actual: *u32, overlapped: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn MultiByteToWideChar(codepage: u32, flags: u32, input: [*]const u8, input_len: i32, output: [*]u16, output_len: i32) callconv(.winapi) i32;
extern "kernel32" fn CreateHardLinkW(new_path: [*:0]const u16, existing: [*:0]const u16, reserved: ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentDirectoryW(capacity: u32, path: [*]u16) callconv(.winapi) u32;
extern "kernel32" fn WideCharToMultiByte(codepage: u32, flags: u32, input: [*]const u16, input_len: i32, output: [*]u8, output_len: i32, default_char: ?*const u8, used_default: ?*i32) callconv(.winapi) i32;

const Error = contract.Error;

pub const FileIdentity = struct {
    volume: u32,
    index: u64,

    fn from(info: FileInfo) FileIdentity {
        return .{ .volume = info.volume, .index = (@as(u64, info.index_high) << 32) | info.index_low };
    }

    fn hashInto(self: FileIdentity, hash: *Sha256) void {
        var bytes: [12]u8 = undefined;
        std.mem.writeInt(u32, bytes[0..4], self.volume, .little);
        std.mem.writeInt(u64, bytes[4..12], self.index, .little);
        hash.update(&bytes);
    }
};

const Wide = struct {
    buffer: [identity.max_path_bytes + 1]u16 = undefined,
    len: usize = 0,

    fn init(path: []const u8) Error!Wide {
        if (!std.unicode.utf8ValidateSlice(path) or path.len == 0 or path.len > identity.max_path_bytes) return error.Permission;
        var value: Wide = .{};
        const len = MultiByteToWideChar(65001, 8, path.ptr, @intCast(path.len), &value.buffer, identity.max_path_bytes);
        if (len <= 0) return error.Permission;
        value.len = @intCast(len);
        value.buffer[value.len] = 0;
        return value;
    }

    fn z(self: *const Wide) [*:0]const u16 {
        return self.buffer[0..self.len :0].ptr;
    }
};

const Opened = struct {
    handle: Handle,
    info: FileInfo,

    fn close(self: Opened) void {
        _ = CloseHandle(self.handle);
    }
};

fn canonicalName(handle: Handle, expected: *const Wide) bool {
    var final: [identity.max_path_bytes + 8]u16 = undefined;
    const len = GetFinalPathNameByHandleW(handle, &final, final.len, 0);
    const prefix = [_]u16{ '\\', '\\', '?', '\\' };
    if (len != expected.len + prefix.len or len >= final.len) return false;
    return std.mem.eql(u16, final[0..prefix.len], &prefix) and std.mem.eql(u16, final[prefix.len..len], expected.buffer[0..expected.len]);
}

fn openOne(path: *const Wide, is_directory: bool, read_contents: bool) Error!Opened {
    const access: u32 = if (read_contents) 0x80000000 else 0x80;
    // Read-only file content observation excludes concurrent writers during
    // this open; directory observation does not lock the filesystem tree.
    const share: u32 = if (read_contents) 1 else 7;
    const handle = CreateFileW(path.z(), access, share, null, 3, 0x00200000 | 0x02000000, null) orelse return error.Permission;
    if (@intFromPtr(handle) == std.math.maxInt(usize)) return error.Permission;
    errdefer _ = CloseHandle(handle);
    var info: FileInfo = undefined;
    if (GetFileInformationByHandle(handle, &info) == 0) return error.Permission;
    if (info.attributes & reparse_attribute != 0 or (info.attributes & directory_attribute != 0) != is_directory) return error.Permission;
    if (!is_directory and info.links != 1) return error.Permission;
    if (!canonicalName(handle, path)) return error.Permission;
    return .{ .handle = handle, .info = info };
}

/// Inspect every lexical ancestor separately with OPEN_REPARSE_POINT, not
/// just the final object. Fixed local volume and exact normalized DOS name.
/// There is still a race between component opens and eventual CLI launch.
fn openChecked(path: []const u8, is_directory: bool, read_contents: bool) Error!Opened {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    if (!approval.strictPath(path) or path.len <= 3) return error.Permission;
    var wide = try Wide.init(path);
    const root = [_:0]u16{ wide.buffer[0], ':', '\\' };
    if (GetDriveTypeW(&root) != 3) return error.Permission;
    var root_wide: Wide = .{ .len = 3 };
    @memcpy(root_wide.buffer[0..3], root[0..3]);
    root_wide.buffer[3] = 0;
    const root_file = try openOne(&root_wide, true, false);
    const volume = root_file.info.volume;
    root_file.close();
    var components: usize = 1;
    for (3..wide.len) |i| {
        if (wide.buffer[i] != '\\') continue;
        if (i == 3 or wide.buffer[i - 1] == '\\' or components >= max_components) return error.Permission;
        components += 1;
        const original_len = wide.len;
        wide.buffer[i] = 0;
        wide.len = i;
        const parent = try openOne(&wide, true, false);
        const same_volume = parent.info.volume == volume;
        parent.close();
        wide.buffer[i] = '\\';
        wide.len = original_len;
        if (!same_volume) return error.Permission;
    }
    const opened = try openOne(&wide, is_directory, read_contents);
    errdefer opened.close();
    if (opened.info.volume != volume) return error.Permission;
    return opened;
}

pub fn observeIdentity(path: []const u8, is_directory: bool) Error!FileIdentity {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    const opened = try openChecked(path, is_directory, false);
    defer opened.close();
    return FileIdentity.from(opened.info);
}

fn join(base: []const u8, suffix: []const u8, buffer: []u8) Error![]const u8 {
    return std.fmt.bufPrint(buffer, "{s}\\{s}", .{ base, suffix }) catch return error.ResourceLimit;
}

/// Only a tiny, explicitly understood Git config grammar is accepted.
/// Unknown sections, values, duplicate keys, quoting, escapes, includes and
/// inline comments fail closed. This is not a general Git config parser.
pub fn validateConfig(bytes: []const u8) Error!void {
    if (bytes.len == 0 or bytes.len > max_config_bytes or !std.unicode.utf8ValidateSlice(bytes)) return error.Permission;
    var in_core = false;
    var keys: u8 = 0;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw| {
        for (raw, 0..) |byte, index| {
            if (byte == '\r' and index + 1 != raw.len) return error.Permission;
            if (byte == 0 or (byte < 0x20 and byte != '\t' and byte != '\r') or byte == 0x7f) return error.Permission;
        }
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (line[0] == '#' or line[0] == ';') {
            // A continuation can change the next logical line.
            if (std.mem.indexOfScalar(u8, line, '\\') != null) return error.Permission;
            continue;
        }
        if (std.ascii.eqlIgnoreCase(line, "[core]")) {
            if (in_core) return error.Permission;
            in_core = true;
            continue;
        }
        if (!in_core) return error.Permission;
        const split = std.mem.indexOfScalar(u8, line, '=') orelse return error.Permission;
        const key = std.mem.trim(u8, line[0..split], " \t");
        const value = std.mem.trim(u8, line[split + 1 ..], " \t");
        const bit: u8 = if (std.ascii.eqlIgnoreCase(key, "repositoryformatversion")) 1 else if (std.ascii.eqlIgnoreCase(key, "bare")) 2 else if (std.ascii.eqlIgnoreCase(key, "filemode")) 4 else if (std.ascii.eqlIgnoreCase(key, "logallrefupdates")) 8 else if (std.ascii.eqlIgnoreCase(key, "ignorecase")) 16 else if (std.ascii.eqlIgnoreCase(key, "symlinks")) 32 else return error.Permission;
        if (keys & bit != 0) return error.Permission;
        keys |= bit;
        if (bit == 1) {
            if (!std.mem.eql(u8, value, "0")) return error.Permission;
        } else if (bit == 2) {
            if (!std.ascii.eqlIgnoreCase(value, "false")) return error.Permission;
        } else if (!std.ascii.eqlIgnoreCase(value, "false") and !std.ascii.eqlIgnoreCase(value, "true")) return error.Permission;
    }
    if (keys & 3 != 3) return error.Permission;
}

fn absent(path: []const u8) Error!void {
    const wide = try Wide.init(path);
    if (GetFileAttributesW(wide.z()) != invalid_attributes) return error.Permission;
    // Parent paths have already been checked. Do not equate access denied
    // or arbitrary path errors with absence.
    if (GetLastError() != 2) return error.Permission;
}

fn configDigest(path: []const u8) Error!approval.Digest {
    const opened = try openChecked(path, false, true);
    defer opened.close();
    const size = opened.info.size_low;
    if (opened.info.size_high != 0 or size == 0 or size > max_config_bytes) return error.Permission;
    var bytes: [max_config_bytes]u8 = undefined;
    var read: u32 = 0;
    if (ReadFile(opened.handle, &bytes, size, &read, null) == 0 or read != size) return error.Permission;
    try validateConfig(bytes[0..read]);
    var extra: [1]u8 = undefined;
    if (ReadFile(opened.handle, &extra, 1, &read, null) == 0 or read != 0) return error.Permission;
    var hash = Sha256.init(.{});
    FileIdentity.from(opened.info).hashInto(&hash);
    hash.update(bytes[0..size]);
    return hash.finalResult();
}

pub const Observation = struct {
    installation: approval.Digest,
    repository: approval.Digest,
};

/// Collect a bounded set of concrete local identities and config bytes.
/// The auditor must separately account for system/global config, helpers,
/// executable dependencies, ACLs, worktree subtree and all omitted paths.
pub fn collect(grant: *const approval.Grant) Error!Observation {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    var install = Sha256.init(.{});
    install.update("pulse-win-install-v1");
    (try observeIdentity(grant.executable.slice(), false)).hashInto(&install);
    (try observeIdentity(grant.neutral_cwd.slice(), true)).hashInto(&install);
    var repo = Sha256.init(.{});
    repo.update("pulse-win-repo-v1");
    (try observeIdentity(grant.root.slice(), true)).hashInto(&repo);
    (try observeIdentity(grant.metadata.slice(), true)).hashInto(&repo);
    var buffer: [identity.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "objects", "objects\\info", "refs" }) |suffix| {
        (try observeIdentity(try join(grant.metadata.slice(), suffix, &buffer), true)).hashInto(&repo);
    }
    for ([_][]const u8{ "commondir", "gitdir", "config.worktree", "objects\\info\\alternates", "objects\\info\\http-alternates" }) |suffix| {
        try absent(try join(grant.metadata.slice(), suffix, &buffer));
    }
    try absent(try join(grant.root.slice(), ".gitmodules", &buffer));
    repo.update(&(try configDigest(try join(grant.metadata.slice(), "config", &buffer))));
    return .{ .installation = install.finalResult(), .repository = repo.finalResult() };
}

/// Compose local observations with independent audited fingerprints.
/// All auditor flags must still be present; this component never manufactures
/// approval flags. The same composition is required when acquiring a grant.
pub fn combine(local: Observation, audited: approval.Evidence) approval.Evidence {
    var result = audited;
    var install = Sha256.init(.{});
    install.update("pulse-combined-install-v1");
    install.update(&local.installation);
    install.update(&audited.installation_digest);
    result.installation_digest = install.finalResult();
    var repo = Sha256.init(.{});
    repo.update("pulse-combined-repo-v1");
    repo.update(&local.repository);
    repo.update(&audited.repository_digest);
    result.repository_digest = repo.finalResult();
    return result;
}

pub const Verifier = struct {
    auditor: approval.Verifier,

    pub fn adapter(self: *Verifier) approval.Verifier {
        return .{ .ctx = self, .inspect = &inspect };
    }

    fn inspect(user: *anyopaque, grant: *const approval.Grant, environment: *const std.process.Environ.Map) Error!approval.Evidence {
        const self: *Verifier = @ptrCast(@alignCast(user));
        const audit = try self.auditor.inspect(self.auditor.ctx, grant, environment);
        if (!audit.local_identity_verified or !audit.installation_verified or !audit.repository_configuration_verified or !audit.neutral_environment_verified or !audit.ordinary_metadata_verified) return error.Permission;
        return combine(try collect(grant), audit);
    }
};

test "strict config accepts ordinary init and rejects unsupported semantics" {
    try validateConfig("[core]\r\n\trepositoryformatversion = 0\r\n\tfilemode = false\r\n\tbare = false\r\n\tlogallrefupdates = true\r\n\tignorecase = true\r\n");
    for ([_][]const u8{
        "[core]\nrepositoryformatversion=0\nbare=true\n",
        "[core]\nrepositoryformatversion=1\nbare=false\n",
        "[core]\nrepositoryformatversion=0\nbare=false\n[include]\npath=other\n",
        "[core]\nrepositoryformatversion=0\nbare=false\nfsmonitor=true\n",
        "[core]\nrepositoryformatversion=0\nbare=false\nworktree=other\n",
        "[core]\nrepositoryformatversion=0\nbare=false\nbare=false\n",
        "[core]\nrepositoryformatversion=0\nbare=false\nfilemode=\"false\"\n",
        "[core]\nrepositoryformatversion=0\nbare=false\n# continuation\\\n",
        "[core]\nrepositoryformatversion=0\nbare=false\x00\n",
    }) |value| {
        try std.testing.expectError(error.Permission, validateConfig(value));
    }
}

test "composition never upgrades audit flags and changes with local evidence" {
    const audit: approval.Evidence = .{ .installation_digest = @splat(1), .repository_digest = @splat(2) };
    const first = combine(.{ .installation = @splat(3), .repository = @splat(4) }, audit);
    const second = combine(.{ .installation = @splat(3), .repository = @splat(5) }, audit);
    try std.testing.expect(!first.local_identity_verified);
    try std.testing.expect(!first.repository_configuration_verified);
    try std.testing.expectEqualSlices(u8, &first.installation_digest, &second.installation_digest);
    try std.testing.expect(!std.mem.eql(u8, &first.repository_digest, &second.repository_digest));
}

fn currentDirectory(buffer: []u8) ![]const u8 {
    var wide: [identity.max_path_bytes + 1]u16 = undefined;
    const len = GetCurrentDirectoryW(wide.len, &wide);
    if (len == 0 or len >= wide.len) return error.TestUnexpectedResult;
    const size = WideCharToMultiByte(65001, 0x80, &wide, @intCast(len), buffer.ptr, @intCast(buffer.len), null, null);
    if (size <= 0) return error.TestUnexpectedResult;
    return buffer[0..@intCast(size)];
}

test "Windows checked handle observation uses real local directory" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    try std.testing.expectEqual(@as(usize, 52), @sizeOf(FileInfo));
    var bytes: [identity.max_path_bytes]u8 = undefined;
    const path = try currentDirectory(&bytes);
    const first = try observeIdentity(path, true);
    const second = try observeIdentity(path, true);
    try std.testing.expectEqual(first, second);
    try std.testing.expectError(error.Permission, observeIdentity(path, false));
    try std.testing.expectError(error.Permission, observeIdentity("\\\\server\\share\\file", false));
    try std.testing.expectError(error.Permission, observeIdentity("C:\\a\\..\\b", true));
}

test "Windows config bytes are read by checked handle and hardlinks are denied" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const initial = try tmp.dir.createFile(io, "config", .{ .exclusive = true });
    try initial.writeStreamingAll(io, "[core]\nrepositoryformatversion=0\nbare=false\n");
    initial.close(io);
    var cwd: [identity.max_path_bytes]u8 = undefined;
    var path_buffer: [identity.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}\\.zig-cache\\tmp\\{s}\\config", .{ try currentDirectory(&cwd), tmp.sub_path });
    const first = try configDigest(path);
    try std.testing.expectEqualSlices(u8, &first, &(try configDigest(path)));
    try std.testing.expectError(error.Permission, absent(path));
    const updated = try tmp.dir.createFile(io, "config", .{});
    try updated.writeStreamingAll(io, "[core]\nrepositoryformatversion=0\nbare=false\nfilemode=false\n");
    updated.close(io);
    const second = try configDigest(path);
    try std.testing.expect(!std.mem.eql(u8, &first, &second));
    var alias_buffer: [identity.max_path_bytes]u8 = undefined;
    const alias = try std.fmt.bufPrint(&alias_buffer, "{s}\\.zig-cache\\tmp\\{s}\\alias", .{ try currentDirectory(&cwd), tmp.sub_path });
    try absent(alias);
    const alias_wide = try Wide.init(alias);
    const config_wide = try Wide.init(path);
    if (CreateHardLinkW(alias_wide.z(), config_wide.z(), null) == 0) return error.TestUnexpectedResult;
    try std.testing.expectError(error.Permission, configDigest(path));
    try std.testing.expectError(error.Permission, observeIdentity(alias, false));
}
