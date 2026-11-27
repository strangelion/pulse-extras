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

const FindData = extern struct {
    attributes: u32,
    creation_low: u32,
    creation_high: u32,
    access_low: u32,
    access_high: u32,
    write_low: u32,
    write_high: u32,
    size_high: u32,
    size_low: u32,
    reserved0: u32,
    reserved1: u32,
    name: [260]u16,
    alternate: [14]u16,
};

extern "kernel32" fn FindFirstFileW(path: [*:0]const u16, data: *FindData) callconv(.winapi) ?Handle;
extern "kernel32" fn FindNextFileW(handle: Handle, data: *FindData) callconv(.winapi) i32;
extern "kernel32" fn FindClose(handle: Handle) callconv(.winapi) i32;
extern "kernel32" fn GetSystemWindowsDirectoryW(buffer: [*]u16, size: u32) callconv(.winapi) u32;
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

extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorW(text: [*:0]const u16, revision: u32, descriptor: *?*anyopaque, size: ?*u32) callconv(.winapi) i32;
extern "advapi32" fn ConvertSidToStringSidW(sid: *const anyopaque, text: *?[*:0]u16) callconv(.winapi) i32;
extern "advapi32" fn SetSecurityInfo(handle: Handle, object_type: u32, information: u32, owner: ?*anyopaque, group: ?*anyopaque, dacl: ?*anyopaque, sacl: ?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn GetSecurityInfo(handle: Handle, object_type: u32, information: u32, owner: *?*anyopaque, group: ?*?*anyopaque, dacl: *?*anyopaque, sacl: ?*?*anyopaque, descriptor: *?*anyopaque) callconv(.winapi) u32;
extern "advapi32" fn IsValidSecurityDescriptor(descriptor: *const anyopaque) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityDescriptorDacl(descriptor: *const anyopaque, present: *i32, dacl: *?*anyopaque, defaulted: *i32) callconv(.winapi) i32;
extern "advapi32" fn GetSecurityDescriptorControl(descriptor: *const anyopaque, control: *u16, revision: *u32) callconv(.winapi) i32;
extern "advapi32" fn IsValidAcl(acl: *const anyopaque) callconv(.winapi) i32;
extern "advapi32" fn IsValidSid(sid: *const anyopaque) callconv(.winapi) i32;
extern "advapi32" fn GetLengthSid(sid: *const anyopaque) callconv(.winapi) u32;
extern "advapi32" fn OpenProcessToken(process: Handle, access: u32, token: *?Handle) callconv(.winapi) i32;
extern "advapi32" fn GetTokenInformation(token: Handle, class: u32, info: *anyopaque, capacity: u32, actual: *u32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) Handle;
extern "kernel32" fn LocalFree(memory: *anyopaque) callconv(.winapi) ?*anyopaque;

const Error = contract.Error;

pub const max_acl_bytes = 16 * 1024;
pub const max_aces = 256;
pub const max_principals = 8;

pub const Sid = struct {
    bytes: [68]u8 = undefined,
    len: u8 = 0,

    pub fn init(bytes: []const u8) Error!Sid {
        if (bytes.len < 8 or bytes[0] != 1 or bytes[1] > 15 or bytes.len != 8 + @as(usize, bytes[1]) * 4) return error.Permission;
        var result: Sid = .{ .len = @intCast(bytes.len) };
        @memcpy(result.bytes[0..bytes.len], bytes);
        return result;
    }

    pub fn slice(self: *const Sid) []const u8 {
        return self.bytes[0..self.len];
    }

    fn fromNative(ptr: *const anyopaque) Error!Sid {
        if (IsValidSid(ptr) == 0) return error.Permission;
        const len = GetLengthSid(ptr);
        if (len < 8 or len > 68) return error.Permission;
        const bytes: [*]const u8 = @ptrCast(ptr);
        return Sid.init(bytes[0..len]);
    }
};

/// Immutable explicit principal set. Never implicitly trust the current
/// user, BUILTIN Administrators, SYSTEM, or a principal found in a DACL.
pub const Principals = struct {
    entries: [max_principals]Sid = undefined,
    len: usize = 0,

    pub fn add(self: *Principals, sid: Sid) Error!void {
        if (sid.len < 8 or sid.len > sid.bytes.len) return error.Permission;
        _ = try Sid.init(sid.slice());
        if (self.contains(sid.slice())) return;
        if (self.len >= max_principals) return error.ResourceLimit;
        self.entries[self.len] = sid;
        self.len += 1;
    }

    fn contains(self: *const Principals, sid: []const u8) bool {
        if (self.len > max_principals) return false;
        for (self.entries[0..self.len]) |*entry| {
            if (entry.len <= entry.bytes.len and std.mem.eql(u8, entry.slice(), sid)) return true;
        }
        return false;
    }

    fn hashInto(self: *const Principals, hash: *Sha256) Error!void {
        if (self.len == 0 or self.len > max_principals) return error.Permission;
        hash.update(&.{@intCast(self.len)});
        for (self.entries[0..self.len]) |*entry| {
            if (entry.len < 8 or entry.len > entry.bytes.len) return error.Permission;
            _ = try Sid.init(entry.slice());
            hash.update(&.{entry.len});
            hash.update(entry.slice());
        }
    }
};

/// TokenUser is an identity observation, NOT group expansion, impersonation
/// analysis, effective-access evaluation or authorization.
pub fn currentProcessUser() Error!Sid {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    var token: ?Handle = null;
    if (OpenProcessToken(GetCurrentProcess(), 0x8, &token) == 0) return error.Permission;
    const handle = token orelse return error.Permission;
    defer _ = CloseHandle(handle);
    const TokenUser = extern struct { sid: ?*anyopaque, attributes: u32 };
    var buffer: [1024]u8 align(@alignOf(TokenUser)) = undefined;
    var actual: u32 = 0;
    if (GetTokenInformation(handle, 1, &buffer, buffer.len, &actual) == 0 or actual < @sizeOf(TokenUser) or actual > buffer.len) return error.Permission;
    const info: *const TokenUser = @ptrCast(&buffer);
    const sid = info.sid orelse return error.Permission;
    const start = @intFromPtr(&buffer);
    const address = @intFromPtr(sid);
    if (address < start or address - start > actual - 8) return error.Permission;
    const offset = address - start;
    const len = 8 + @as(usize, buffer[offset + 1]) * 4;
    if (len > actual - offset) return error.Permission;
    return Sid.init(buffer[offset..][0..len]);
}

// Rights known not to modify a file/directory: GENERIC_READ/EXECUTE,
// SYNCHRONIZE, READ_CONTROL, READ_DATA, READ_EA, EXECUTE, READ_ATTRIBUTES.
// Unknown rights, generic write/all, delete, add-child and ownership changes
// are conservatively treated as mutation. Inheritance flags do not relax this.
const read_only_mask: u32 = 0xa01200a9;

/// Parse the bounded simple ACL subset, even on non-Windows test targets.
/// Unknown ACE types (object/callback/conditional/etc.) fail closed. Deny
/// ACEs never relax an allow ACE, even if a full access check would deny it.
/// A null DACL must be rejected by the caller, not treated as an empty one.
fn inspectAcl(bytes: []const u8, owner: Sid, principals: *const Principals, hash: *Sha256) Error!void {
    return inspectAclRole(bytes, owner, principals, hash, false);
}

fn inspectAclRole(bytes: []const u8, owner: Sid, principals: *const Principals, hash: *Sha256, ancestor: bool) Error!void {
    if (owner.len < 8 or owner.len > owner.bytes.len or !principals.contains(owner.slice())) return error.Permission;
    if (bytes.len < 8 or bytes.len > max_acl_bytes or (bytes[0] != 2 and bytes[0] != 4)) return error.Permission;
    if (std.mem.readInt(u16, bytes[2..4], .little) != bytes.len) return error.Permission;
    const count = std.mem.readInt(u16, bytes[4..6], .little);
    if (count > max_aces) return error.ResourceLimit;
    hash.update(&.{ @intFromBool(ancestor), owner.len });
    hash.update(owner.slice());
    hash.update(bytes[0..8]);
    var offset: usize = 8;
    for (0..count) |_| {
        if (bytes.len - offset < 8) return error.Permission;
        const ace = bytes[offset..];
        const size = std.mem.readInt(u16, ace[2..4], .little);
        if (size < 16 or size > ace.len or size % 4 != 0) return error.Permission;
        // ACCESS_ALLOWED_ACE / ACCESS_DENIED_ACE only.
        if (ace[0] != 0 and ace[0] != 1) return error.Permission;
        // Only ordinary inheritance flags; reject unknown/audit flags.
        if (ace[1] & 0xe0 != 0) return error.Permission;
        const sid = try Sid.init(ace[8..size]);
        const mask = std.mem.readInt(u32, ace[4..8], .little);
        // Inherit-only entries do not grant rights on this object. Every
        // actual descendant is independently checked. Existing ancestors
        // may allow creation of unrelated siblings, but never deletion,
        // rename, owner/DACL/attribute changes or generic write/all.
        const allowed = read_only_mask | if (ancestor) @as(u32, 0x6) else 0;
        if (ace[0] == 0 and ace[1] & 0x08 == 0 and mask & ~allowed != 0 and !principals.contains(sid.slice())) return error.Permission;
        hash.update(ace[0..size]);
        offset += size;
    }
    // ACLs may contain unused capacity. Do not hash uninitialized padding.
}

const AclWalk = struct {
    principals: *const Principals,
    hash: *Sha256,

    fn inspect(self: *AclWalk, opened: Opened) Error!void {
        return self.inspectRole(opened, false);
    }

    fn inspectRole(self: *AclWalk, opened: Opened, ancestor: bool) Error!void {
        var owner: ?*anyopaque = null;
        var dacl: ?*anyopaque = null;
        var descriptor: ?*anyopaque = null;
        // SE_FILE_OBJECT, OWNER_SECURITY_INFORMATION | DACL_SECURITY_INFORMATION.
        const status = GetSecurityInfo(opened.handle, 1, 5, &owner, null, &dacl, null, &descriptor);
        defer if (descriptor) |memory| {
            _ = LocalFree(memory);
        };
        if (status != 0) return error.Permission;
        const sd = descriptor orelse return error.Permission;
        if (IsValidSecurityDescriptor(sd) == 0) return error.Permission;
        var present: i32 = 0;
        var defaulted: i32 = 0;
        var actual: ?*anyopaque = null;
        if (GetSecurityDescriptorDacl(sd, &present, &actual, &defaulted) == 0 or present == 0 or actual == null or actual != dacl) return error.Permission;
        const acl = actual.?;
        if (IsValidAcl(acl) == 0) return error.Permission;
        const bytes: [*]const u8 = @ptrCast(acl);
        const size = std.mem.readInt(u16, bytes[2..4], .little);
        if (size < 8 or size > max_acl_bytes) return error.Permission;
        var control: u16 = 0;
        var revision: u32 = 0;
        if (GetSecurityDescriptorControl(sd, &control, &revision) == 0 or revision != 1) return error.Permission;
        var flags: [2]u8 = undefined;
        std.mem.writeInt(u16, &flags, control, .little);
        FileIdentity.from(opened.info).hashInto(self.hash);
        self.hash.update(&flags);
        try inspectAclRole(bytes[0..size], try Sid.fromNative(owner orelse return error.Permission), self.principals, self.hash, ancestor);
    }
};

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

fn openOne(path: *const Wide, is_directory: bool, read_contents: bool, read_security: bool, allow_tool_hardlinks: bool) Error!Opened {
    const access: u32 = (if (read_contents) @as(u32, 0x80000000) else 0x80) | (if (read_security) @as(u32, 0x20000) else 0);
    // Read-only file content observation excludes concurrent writers during
    // this open; directory observation does not lock the filesystem tree.
    const share: u32 = if (read_contents) 1 else 7;
    const handle = CreateFileW(path.z(), access, share, null, 3, 0x00200000 | 0x02000000, null) orelse return error.Permission;
    if (@intFromPtr(handle) == std.math.maxInt(usize)) return error.Permission;
    errdefer _ = CloseHandle(handle);
    var info: FileInfo = undefined;
    if (GetFileInformationByHandle(handle, &info) == 0) return error.Permission;
    if (info.attributes & reparse_attribute != 0 or (info.attributes & directory_attribute != 0) != is_directory) return error.Permission;
    if (!is_directory and (info.links == 0 or (!allow_tool_hardlinks and info.links != 1))) return error.Permission;
    if (!canonicalName(handle, path)) return error.Permission;
    return .{ .handle = handle, .info = info };
}

/// Inspect every lexical ancestor separately with OPEN_REPARSE_POINT, not
/// just the final object. Fixed local volume and exact normalized DOS name.
/// There is still a race between component opens and eventual CLI launch.
fn openChecked(path: []const u8, is_directory: bool, read_contents: bool) Error!Opened {
    return walkChecked(path, is_directory, read_contents, null);
}

fn walkChecked(path: []const u8, is_directory: bool, read_contents: bool, audit: ?*AclWalk) Error!Opened {
    return walkWithToolLinks(path, is_directory, read_contents, audit, false);
}

fn walkWithToolLinks(path: []const u8, is_directory: bool, read_contents: bool, audit: ?*AclWalk, allow_tool_hardlinks: bool) Error!Opened {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    if (!approval.strictPath(path) or path.len <= 3) return error.Permission;
    var wide = try Wide.init(path);
    const root = [_:0]u16{ wide.buffer[0], ':', '\\' };
    if (GetDriveTypeW(&root) != 3) return error.Permission;
    var root_wide: Wide = .{ .len = 3 };
    @memcpy(root_wide.buffer[0..3], root[0..3]);
    root_wide.buffer[3] = 0;
    const root_file = try openOne(&root_wide, true, false, audit != null, false);
    const volume = root_file.info.volume;
    {
        defer root_file.close();
        if (audit) |walk| try walk.inspectRole(root_file, true);
    }
    var components: usize = 1;
    for (3..wide.len) |i| {
        if (wide.buffer[i] != '\\') continue;
        if (i == 3 or wide.buffer[i - 1] == '\\' or components >= max_components) return error.Permission;
        components += 1;
        const original_len = wide.len;
        wide.buffer[i] = 0;
        wide.len = i;
        const parent = try openOne(&wide, true, false, audit != null, false);
        const same_volume = parent.info.volume == volume;
        {
            defer parent.close();
            if (audit) |walk| try walk.inspectRole(parent, true);
        }
        wide.buffer[i] = '\\';
        wide.len = original_len;
        if (!same_volume) return error.Permission;
    }
    const opened = try openOne(&wide, is_directory, read_contents, audit != null, allow_tool_hardlinks);
    errdefer opened.close();
    if (opened.info.volume != volume) return error.Permission;
    if (audit) |walk| try walk.inspect(opened);
    return opened;
}

/// Local session tool candidate only. The user trusts the installation,
/// and the caller still pins the observed identity and executable SHA-256.
/// Git for Windows ships hardlinked executables. Do not use this exception
/// for repository metadata, strict stored grants or generic file reads.
pub fn observeSessionToolIdentity(path: []const u8) Error!FileIdentity {
    const opened = try walkWithToolLinks(path, false, false, null, true);
    defer opened.close();
    return FileIdentity.from(opened.info);
}

pub fn observeIdentity(path: []const u8, is_directory: bool) Error!FileIdentity {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    const opened = try openChecked(path, is_directory, false);
    defer opened.close();
    return FileIdentity.from(opened.info);
}

/// Verify a live local target without following a reparse point. Missing
/// leaf is allowed only when its exact ordinary parent exists; this permits
/// inspecting deleted versioned files without admitting external targets.
pub fn observeLocalTarget(path: []const u8) Error!void {
    return observeTarget(path, false);
}

pub fn observeFileTarget(path: []const u8) Error!void {
    return observeTarget(path, true);
}

fn observeTarget(path: []const u8, file_only: bool) Error!void {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    const parent = std.fs.path.dirname(path) orelse return error.Permission;
    _ = try observeIdentity(parent, true);
    const wide = try Wide.init(path);
    const attrs = GetFileAttributesW(wide.z());
    if (attrs == invalid_attributes) {
        if (GetLastError() == 2) return;
        return error.Permission;
    }
    if (attrs & reparse_attribute != 0 or (file_only and attrs & directory_attribute != 0)) return error.Permission;
    _ = try observeIdentity(path, attrs & directory_attribute != 0);
}

/// Fail closed on inaccessible, aliased or present targets. Only an ordinary
/// existing parent and ERROR_FILE_NOT_FOUND prove this optional leaf absent.
pub fn requireAbsent(path: []const u8) Error!void {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    const parent = std.fs.path.dirname(path) orelse return error.Permission;
    _ = try observeIdentity(parent, true);
    const wide = try Wide.init(path);
    if (GetFileAttributesW(wide.z()) != invalid_attributes or GetLastError() != 2) return error.Permission;
}

pub fn validateHgRequirements(bytes: []const u8) Error!void {
    if (bytes.len == 0 or bytes.len > 4096) return error.Permission;
    var lines = std.mem.tokenizeAny(u8, bytes, "\r\n");
    while (lines.next()) |line| {
        const known = [_][]const u8{ "share-safe", "store", "fncache", "dotencode", "revlogv1", "generaldelta", "sparserevlog", "revlog-compression-zstd", "dirstate-v2", "persistent-nodemap", "bookmarksinstore" };
        for (known) |requirement| {
            if (std.mem.eql(u8, line, requirement)) break;
        } else return error.Unsupported;
    }
}

/// Small fixed-size local metadata preview. No config interpretation, links,
/// remote volumes, writes or process execution. The caller treats bytes as
/// untrusted display data; this does not establish authorization evidence.
pub fn readPreviewFile(path: []const u8, buffer: []u8) Error![]const u8 {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    if (buffer.len == 0 or buffer.len > 4096) return error.ResourceLimit;
    const opened = try openChecked(path, false, true);
    defer opened.close();
    const size = opened.info.size_low;
    if (opened.info.size_high != 0 or size == 0 or size > buffer.len) return error.ResourceLimit;
    var read: u32 = 0;
    if (ReadFile(opened.handle, buffer.ptr, size, &read, null) == 0 or read != size) return error.Permission;
    var extra: [1]u8 = undefined;
    if (ReadFile(opened.handle, &extra, 1, &read, null) == 0 or read != 0) return error.Permission;
    return buffer[0..size];
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
    var global_buffer: [identity.max_path_bytes]u8 = undefined;
    const global = try join(grant.neutral_cwd.slice(), approval.global_config_name, &global_buffer);
    const empty = try openChecked(global, false, true);
    defer empty.close();
    if (empty.info.size_high != 0 or empty.info.size_low != 0) return error.Permission;
    FileIdentity.from(empty.info).hashInto(&install);
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

/// Audit the exact selected paths and their ancestors. No directory scan,
/// no effective-access guarantee, no claim about objects not listed here.
/// In particular, installation DLLs/helpers and repository subtree still
/// require the independent auditor. Windows root ACLs may be too permissive
/// for this initial conservative policy, in which case it refuses admission.
pub fn aclEvidence(grant: *const approval.Grant, principals: *const Principals, environment: *const std.process.Environ.Map) Error!Observation {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    const user = try currentProcessUser();
    if (!principals.contains(user.slice())) return error.Permission;
    var install = Sha256.init(.{});
    install.update("pulse-win-acl-install-v1");
    try principals.hashInto(&install);
    install.update(&.{user.len});
    install.update(user.slice());
    var install_walk: AclWalk = .{ .principals = principals, .hash = &install };
    (try walkChecked(grant.executable.slice(), false, false, &install_walk)).close();
    (try walkChecked(grant.neutral_cwd.slice(), true, false, &install_walk)).close();
    var global_buffer: [identity.max_path_bytes]u8 = undefined;
    const global = try join(grant.neutral_cwd.slice(), approval.global_config_name, &global_buffer);
    const global_file = try walkChecked(global, false, true, &install_walk);
    defer global_file.close();
    if (global_file.info.size_high != 0 or global_file.info.size_low != 0) return error.Permission;
    // Hash presence and exact value as well as ACLs of controlled directories.
    for ([_][]const u8{ "SystemRoot", "WINDIR", "TEMP", "TMP" }) |key| {
        install.update(key);
        if (environment.get(key)) |value| {
            install.update(&.{1});
            if (std.mem.eql(u8, key, "SystemRoot") or std.mem.eql(u8, key, "WINDIR")) {
                // The real OS system directory is part of the explicitly
                // trusted Windows boundary, not an arbitrary environment path.
                var system_buffer: [identity.max_path_bytes]u8 = undefined;
                const system = try systemDirectory(&system_buffer);
                if (!std.mem.eql(u8, value, system)) return error.Permission;
                (try observeIdentity(value, true)).hashInto(&install);
            } else {
                (try walkChecked(value, true, false, &install_walk)).close();
            }
            install.update(value);
        } else {
            install.update(&.{0});
        }
    }
    var repo = Sha256.init(.{});
    repo.update("pulse-win-acl-repo-v1");
    try principals.hashInto(&repo);
    var repo_walk: AclWalk = .{ .principals = principals, .hash = &repo };
    (try walkChecked(grant.root.slice(), true, false, &repo_walk)).close();
    (try walkChecked(grant.metadata.slice(), true, false, &repo_walk)).close();
    var buffer: [identity.max_path_bytes]u8 = undefined;
    for ([_][]const u8{ "objects", "objects\\info", "refs" }) |suffix| {
        (try walkChecked(try join(grant.metadata.slice(), suffix, &buffer), true, false, &repo_walk)).close();
    }
    (try walkChecked(try join(grant.metadata.slice(), "config", &buffer), false, false, &repo_walk)).close();
    return .{ .installation = install.finalResult(), .repository = repo.finalResult() };
}

fn mixObservations(local: Observation, acl: Observation) Observation {
    var install = Sha256.init(.{});
    install.update("pulse-win-observations-install-v1");
    install.update(&local.installation);
    install.update(&acl.installation);
    var repo = Sha256.init(.{});
    repo.update("pulse-win-observations-repo-v1");
    repo.update(&local.repository);
    repo.update(&acl.repository);
    return .{ .installation = install.finalResult(), .repository = repo.finalResult() };
}

pub const max_install_files = 512;
pub const max_install_path_bytes = 96 * 1024;
pub const max_install_bytes: u64 = 256 * 1024 * 1024;

/// Explicit finite installation dependency inventory. The independent auditor
/// supplies the list and approved digests; this module does not discover DLL
/// search paths or infer completeness from directory contents. Keep immutable
/// and at a stable address until all verifier users have drained.
pub const InstallationManifest = struct {
    const Entry = struct {
        offset: u32,
        length: u16,
        digest: approval.Digest,
    };

    root: identity.Path,
    entries: [max_install_files]Entry = undefined,
    paths: [max_install_path_bytes]u8 = undefined,
    len: usize = 0,
    used: usize = 0,

    fn pathFor(self: *const InstallationManifest, entry: *const Entry) Error![]const u8 {
        const offset: usize = entry.offset;
        const length: usize = entry.length;
        if (self.used > self.paths.len or offset > self.used or length == 0 or length > self.used - offset or length > identity.max_path_bytes) return error.Permission;
        return self.paths[offset..][0..length];
    }

    pub fn init(root: []const u8) Error!InstallationManifest {
        if (!approval.strictPath(root)) return error.Permission;
        return .{ .root = identity.Path.init(root) catch return error.Permission };
    }

    pub fn containsPath(self: *const InstallationManifest, path: []const u8) bool {
        const root = self.root.slice();
        return path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == std.fs.path.sep;
    }

    pub fn add(self: *InstallationManifest, path: []const u8, digest: approval.Digest) Error!void {
        if (!approval.strictPath(path) or !self.containsPath(path)) return error.Permission;
        if (self.len >= max_install_files or self.used > self.paths.len or path.len > self.paths.len - self.used) return error.ResourceLimit;
        for (self.entries[0..self.len]) |*entry| {
            if (std.ascii.eqlIgnoreCase(try self.pathFor(entry), path)) return error.Permission;
        }
        @memcpy(self.paths[self.used..][0..path.len], path);
        self.entries[self.len] = .{ .offset = @intCast(self.used), .length = @intCast(path.len), .digest = digest };
        self.used += path.len;
        self.len += 1;
    }

    pub fn validate(self: *const InstallationManifest, grant: *const approval.Grant) Error!void {
        if (self.len == 0 or self.len > max_install_files or !approval.strictPath(self.root.slice())) return error.Permission;
        if (self.root.eql(grant.root.slice()) or self.containsPath(grant.root.slice()) or self.root.eql(grant.neutral_cwd.slice()) or self.containsPath(grant.neutral_cwd.slice())) return error.Permission;
        const installation = self.root.slice();
        for ([_][]const u8{ grant.root.slice(), grant.neutral_cwd.slice() }) |other| {
            if (installation.len > other.len and std.mem.startsWith(u8, installation, other) and installation[other.len] == std.fs.path.sep) return error.Permission;
        }
        var found = false;
        var offset: usize = 0;
        for (self.entries[0..self.len], 0..) |*entry, i| {
            const path = try self.pathFor(entry);
            if (entry.offset != offset or !approval.strictPath(path) or !self.containsPath(path)) return error.Permission;
            offset += path.len;
            for (self.entries[0..i]) |*prior| {
                if (std.ascii.eqlIgnoreCase(try self.pathFor(prior), path)) return error.Permission;
            }
            if (std.mem.eql(u8, path, grant.executable.slice())) {
                if (!std.mem.eql(u8, &entry.digest, &grant.executable_digest)) return error.Permission;
                found = true;
            }
        }
        if (!found or offset != self.used) return error.Permission;
    }

    /// Audit root and each listed file's ancestors, then hash from the checked
    /// file handle with write sharing denied. Handles close before child spawn;
    /// this is not a race-free guarantee against later file replacement.
    pub fn observe(self: *const InstallationManifest, grant: *const approval.Grant, principals: *const Principals) Error!approval.Digest {
        if (comptime builtin.os.tag != .windows) return error.Unsupported;
        try self.validate(grant);
        var hash = Sha256.init(.{});
        hash.update("pulse-win-install-manifest-v2");
        try principals.hashInto(&hash);
        var walk: AclWalk = .{ .principals = principals, .hash = &hash };
        (try walkChecked(self.root.slice(), true, false, &walk)).close();
        var count: [2]u8 = undefined;
        std.mem.writeInt(u16, &count, @intCast(self.len), .little);
        hash.update(&count);
        var remaining = max_install_bytes;
        for (self.entries[0..self.len]) |*entry| {
            const path = try self.pathFor(entry);
            const opened = try walkChecked(path, false, true, &walk);
            defer opened.close();
            const actual = try digestOpened(opened, &remaining);
            if (!std.mem.eql(u8, &actual, &entry.digest)) return error.Permission;
            var length: [2]u8 = undefined;
            std.mem.writeInt(u16, &length, entry.length, .little);
            hash.update(&length);
            hash.update(path);
            hash.update(&actual);
        }
        return hash.finalResult();
    }
};

fn digestOpened(opened: Opened, remaining: *u64) Error!approval.Digest {
    const size = (@as(u64, opened.info.size_high) << 32) | opened.info.size_low;
    if (size > remaining.*) return error.ResourceLimit;
    var hash = Sha256.init(.{});
    var bytes: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < size) {
        const wanted: u32 = @intCast(@min(size - offset, bytes.len));
        var read: u32 = 0;
        if (ReadFile(opened.handle, &bytes, wanted, &read, null) == 0 or read != wanted) return error.Permission;
        hash.update(bytes[0..read]);
        offset += read;
    }
    var read: u32 = 0;
    if (ReadFile(opened.handle, &bytes, 1, &read, null) == 0 or read != 0) return error.Permission;
    remaining.* -= size;
    return hash.finalResult();
}

/// OS directory, not a user-controlled SystemRoot environment variable.
pub fn systemDirectory(buffer: []u8) Error![]const u8 {
    if (comptime builtin.os.tag != .windows) return error.Unsupported;
    var wide: [identity.max_path_bytes + 1]u16 = undefined;
    const len = GetSystemWindowsDirectoryW(&wide, wide.len);
    if (len == 0 or len >= wide.len or buffer.len == 0 or buffer.len > std.math.maxInt(i32)) return error.Permission;
    const size = WideCharToMultiByte(65001, 0x80, &wide, @intCast(len), buffer.ptr, @intCast(buffer.len), null, null);
    if (size <= 0) return error.Permission;
    const result = buffer[0..@intCast(size)];
    if (!approval.strictPath(result)) return error.Permission;
    return result;
}

pub const max_audit_nodes = 2048;
pub const max_audit_depth = 12;

const TreeKind = enum { installation, repository, neutral };

fn forbiddenRepoName(name: []const u8, parent: []const u8, root: []const u8, is_dir: bool) bool {
    if (std.ascii.eqlIgnoreCase(name, ".git")) return !std.mem.eql(u8, parent, root) or !is_dir;
    for ([_][]const u8{ ".gitmodules", ".gitattributes", "commondir", "gitdir", "config.worktree", "alternates", "http-alternates", "grafts", "attributes", "modules", "worktrees", "replace", "fsmonitor" }) |value| {
        if (std.ascii.eqlIgnoreCase(name, value)) return true;
    }
    if (name.len >= "sharedindex.".len and std.ascii.eqlIgnoreCase(name[0.."sharedindex.".len], "sharedindex.")) return true;
    if (std.ascii.eqlIgnoreCase(std.fs.path.basename(parent), "hooks")) {
        if (is_dir or !std.mem.endsWith(u8, name, ".sample")) return true;
    }
    return false;
}

/// Independent bounded inventory/ACL walk. Reject all reparse points, hard
/// links, untrusted mutation ACLs, nested repositories, redirectors and
/// active hooks in the supported profile. Installation inventory must match
/// every regular file, not merely contain git.exe. This accepts a deliberately
/// narrow, explicitly trusted distribution; it is not an Authenticode check.
/// Windows/its loader and the explicitly approved user/admin principals form
/// the OS trust boundary. No filesystem traversal is race-free.
const TreeAudit = struct {
    kind: TreeKind,
    root: []const u8,
    manifest: *const InstallationManifest,
    principals: *const Principals,
    remaining: usize = max_audit_nodes,
    seen_files: usize = 0,

    fn walk(self: *TreeAudit, path: []const u8, depth: usize) Error!void {
        if (depth >= max_audit_depth) return error.ResourceLimit;
        var scratch_hash = Sha256.init(.{});
        var acl: AclWalk = .{ .principals = self.principals, .hash = &scratch_hash };
        const dir = try walkChecked(path, true, false, &acl);
        defer dir.close();
        var pattern: [identity.max_path_bytes]u8 = undefined;
        const wildcard = try join(path, "*", &pattern);
        const wide = try Wide.init(wildcard);
        var data: FindData = undefined;
        const handle = FindFirstFileW(wide.z(), &data) orelse return error.Permission;
        if (@intFromPtr(handle) == std.math.maxInt(usize)) {
            if (GetLastError() == 2) return;
            return error.Permission;
        }
        defer _ = FindClose(handle);
        while (true) {
            const end = std.mem.indexOfScalar(u16, &data.name, 0) orelse return error.Permission;
            var name_buffer: [1024]u8 = undefined;
            if (end == 0) return error.Permission;
            const count = WideCharToMultiByte(65001, 0x80, &data.name, @intCast(end), &name_buffer, name_buffer.len, null, null);
            if (count <= 0) return error.Permission;
            const name = name_buffer[0..@intCast(count)];
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                if (self.remaining == 0) return error.ResourceLimit;
                self.remaining -= 1;
                if (data.attributes & reparse_attribute != 0) return error.Permission;
                const is_dir = data.attributes & directory_attribute != 0;
                if (self.kind == .repository and forbiddenRepoName(name, path, self.root, is_dir)) return error.Permission;
                if (self.kind == .neutral and (is_dir or !std.mem.eql(u8, name, approval.global_config_name))) return error.Permission;
                var child_buffer: [identity.max_path_bytes]u8 = undefined;
                const child = try join(path, name, &child_buffer);
                if (!approval.strictPath(child)) return error.Permission;
                if (is_dir) {
                    try self.walk(child, depth + 1);
                } else {
                    const file = try walkChecked(child, false, false, &acl);
                    file.close();
                    self.seen_files += 1;
                    if (self.kind == .installation) {
                        var found = false;
                        for (self.manifest.entries[0..self.manifest.len]) |*entry| {
                            if (std.mem.eql(u8, try self.manifest.pathFor(entry), child)) found = true;
                        }
                        if (!found) return error.Permission;
                    }
                }
            }
            if (FindNextFileW(handle, &data) == 0) {
                if (GetLastError() != 18) return error.Permission;
                break;
            }
        }
    }
};

/// The index can refer to gitlinks even without .gitmodules. Accept only
/// ordinary SHA-1 v2/v3 entries, with regular-file modes and safe paths.
/// Reject sparse/split/fsmonitor/unknown extensions. TREE cache is passive.
fn validateIndex(bytes: []const u8) Error!void {
    if (bytes.len < 32 or !std.mem.eql(u8, bytes[0..4], "DIRC")) return error.Permission;
    const version = std.mem.readInt(u32, bytes[4..8], .big);
    if (version != 2 and version != 3) return error.Permission;
    const entries = std.mem.readInt(u32, bytes[8..12], .big);
    if (entries > max_audit_nodes * 4) return error.ResourceLimit;
    const end = bytes.len - 20;
    var cursor: usize = 12;
    for (0..entries) |_| {
        const start = cursor;
        if (end - cursor < 62) return error.Permission;
        const mode = std.mem.readInt(u32, bytes[cursor + 24 ..][0..4], .big);
        if (mode != 0o100644 and mode != 0o100755) return error.Permission;
        const flags = std.mem.readInt(u16, bytes[cursor + 60 ..][0..2], .big);
        // Extended flags can request skip-worktree/intent-to-add. Not in this profile.
        if (flags & 0x4000 != 0) return error.Permission;
        cursor += 62;
        const len = std.mem.indexOfScalar(u8, bytes[cursor..end], 0) orelse return error.Permission;
        if (len == 0 or len > identity.max_path_bytes or (flags & 0x0fff != 0x0fff and flags & 0x0fff != len)) return error.Permission;
        const path = bytes[cursor..][0..len];
        if (!std.unicode.utf8ValidateSlice(path) or std.mem.indexOfAny(u8, path, "\\:") != null) return error.Permission;
        var parts = std.mem.splitScalar(u8, path, '/');
        while (parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.ascii.eqlIgnoreCase(part, ".git") or part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.Permission;
            for (part) |byte| {
                if (byte < 0x20 or byte == 0x7f) return error.Permission;
            }
        }
        cursor += len + 1;
        const aligned = start + ((cursor - start + 7) & ~@as(usize, 7));
        if (aligned > end) return error.Permission;
        for (bytes[cursor..aligned]) |padding| {
            if (padding != 0) return error.Permission;
        }
        cursor = aligned;
    }
    while (cursor < end) {
        if (end - cursor < 8 or !std.mem.eql(u8, bytes[cursor..][0..4], "TREE")) return error.Permission;
        const length = std.mem.readInt(u32, bytes[cursor + 4 ..][0..4], .big);
        cursor += 8;
        if (length > end - cursor) return error.Permission;
        cursor += length;
    }
}

fn auditIndex(grant: *const approval.Grant) Error!void {
    var buffer: [identity.max_path_bytes]u8 = undefined;
    const path = try join(grant.metadata.slice(), "index", &buffer);
    const wide = try Wide.init(path);
    if (GetFileAttributesW(wide.z()) == invalid_attributes) {
        if (GetLastError() == 2) return;
        return error.Permission;
    }
    const file = try openChecked(path, false, true);
    defer file.close();
    if (file.info.size_high != 0 or file.info.size_low > 8 * 1024 * 1024) return error.ResourceLimit;
    const bytes = std.heap.page_allocator.alloc(u8, file.info.size_low) catch return error.OutOfMemory;
    defer std.heap.page_allocator.free(bytes);
    var count: u32 = 0;
    if (ReadFile(file.handle, bytes.ptr, @intCast(bytes.len), &count, null) == 0 or count != bytes.len) return error.Permission;
    var extra: [1]u8 = undefined;
    if (ReadFile(file.handle, &extra, 1, &count, null) == 0 or count != 0) return error.Permission;
    try validateIndex(bytes);
}

/// This is the concrete independent auditor for the restricted ordinary-Git
/// profile. Approval of executable provenance is an explicit operator action;
/// this code checks inventory coverage, filesystem boundaries and the exact
/// isolated environment. Digests do not bind mutable ordinary worktree data.
pub const RestrictedAuditor = struct {
    principals: *const Principals,
    manifest: *const InstallationManifest,

    pub fn adapter(self: *RestrictedAuditor) approval.Verifier {
        return .{ .ctx = self, .inspect = &inspect };
    }

    fn inspect(user: *anyopaque, grant: *const approval.Grant, environment: *const std.process.Environ.Map) Error!approval.Evidence {
        if (comptime builtin.os.tag != .windows) return error.Unsupported;
        const self: *RestrictedAuditor = @ptrCast(@alignCast(user));
        try self.manifest.validate(grant);
        var system_buffer: [identity.max_path_bytes]u8 = undefined;
        const system = try systemDirectory(&system_buffer);
        for ([_][]const u8{ "SystemRoot", "WINDIR" }) |key| {
            if (!std.mem.eql(u8, environment.get(key) orelse return error.Permission, system)) return error.Permission;
        }
        for ([_][]const u8{ "HOME", "XDG_CONFIG_HOME", "TEMP", "TMP" }) |key| {
            if (!std.mem.eql(u8, environment.get(key) orelse return error.Permission, grant.neutral_cwd.slice())) return error.Permission;
        }
        if (!std.mem.eql(u8, environment.get("GIT_ATTR_NOSYSTEM") orelse return error.Permission, "1")) return error.Permission;
        var installation: TreeAudit = .{ .kind = .installation, .root = self.manifest.root.slice(), .manifest = self.manifest, .principals = self.principals };
        try installation.walk(installation.root, 0);
        if (installation.seen_files != self.manifest.len) return error.Permission;
        var repository: TreeAudit = .{ .kind = .repository, .root = grant.root.slice(), .manifest = self.manifest, .principals = self.principals };
        try repository.walk(repository.root, 0);
        var neutral: TreeAudit = .{ .kind = .neutral, .root = grant.neutral_cwd.slice(), .manifest = self.manifest, .principals = self.principals };
        try neutral.walk(neutral.root, 0);
        if (neutral.seen_files != 1) return error.Permission;
        try auditIndex(grant);
        // The underlying Verifier additionally checks config grammar, file IDs,
        // parent ACLs, empty global config and every manifest content digest.
        var install_hash = Sha256.init(.{});
        install_hash.update("pulse-restricted-install-v1");
        install_hash.update(self.manifest.root.slice());
        var repo_hash = Sha256.init(.{});
        repo_hash.update("pulse-restricted-repository-v1");
        repo_hash.update(grant.root.slice());
        return .{
            .installation_digest = install_hash.finalResult(),
            .repository_digest = repo_hash.finalResult(),
            .local_identity_verified = true,
            .installation_verified = true,
            .repository_configuration_verified = true,
            .neutral_environment_verified = true,
            .ordinary_metadata_verified = true,
        };
    }
};

pub const Verifier = struct {
    auditor: approval.Verifier,
    principals: *const Principals,
    installation: *const InstallationManifest,

    pub fn adapter(self: *Verifier) approval.Verifier {
        return .{ .ctx = self, .inspect = &inspect };
    }

    fn inspect(user: *anyopaque, grant: *const approval.Grant, environment: *const std.process.Environ.Map) Error!approval.Evidence {
        const self: *Verifier = @ptrCast(@alignCast(user));
        const audit = try self.auditor.inspect(self.auditor.ctx, grant, environment);
        if (!audit.local_identity_verified or !audit.installation_verified or !audit.repository_configuration_verified or !audit.neutral_environment_verified or !audit.ordinary_metadata_verified) return error.Permission;
        const local = try collect(grant);
        const acl = try aclEvidence(grant, self.principals, environment);
        var observations = mixObservations(local, acl);
        const install = try self.installation.observe(grant, self.principals);
        var hash = Sha256.init(.{});
        hash.update("pulse-win-install-complete-list-v1");
        hash.update(&observations.installation);
        hash.update(&install);
        observations.installation = hash.finalResult();
        return combine(observations, audit);
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
    const tool_identity = try observeSessionToolIdentity(path);
    const alias_identity = try observeSessionToolIdentity(alias);
    try std.testing.expectEqual(tool_identity, alias_identity);
}

const system_sid = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 5, 18, 0, 0, 0 };
const everyone_sid = [_]u8{ 1, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0 };

fn fixtureAcl(kind: u8, mask: u32, sid: [12]u8) [28]u8 {
    var bytes: [28]u8 = @splat(0);
    bytes[0] = 2;
    std.mem.writeInt(u16, bytes[2..4], bytes.len, .little);
    std.mem.writeInt(u16, bytes[4..6], 1, .little);
    bytes[8] = kind;
    std.mem.writeInt(u16, bytes[10..12], 20, .little);
    std.mem.writeInt(u32, bytes[12..16], mask, .little);
    @memcpy(bytes[16..28], &sid);
    return bytes;
}

test "ACL rejects untrusted mutation and permits only known read rights" {
    const owner = try Sid.init(&system_sid);
    var principals: Principals = .{};
    try principals.add(owner);
    var hash = Sha256.init(.{});
    try inspectAcl(&fixtureAcl(0, read_only_mask, everyone_sid), owner, &principals, &hash);
    for ([_]u32{ 2, 4, 0x40, 0x10000, 0x40000, 0x80000, 0x40000000, 0x10000000, 0x02000000 }) |mask| {
        try std.testing.expectError(error.Permission, inspectAcl(&fixtureAcl(0, mask, everyone_sid), owner, &principals, &hash));
    }
    try inspectAcl(&fixtureAcl(0, 0x10000000, system_sid), owner, &principals, &hash);
    try inspectAcl(&fixtureAcl(1, 2, everyone_sid), owner, &principals, &hash);
    try std.testing.expectError(error.Permission, inspectAcl(&fixtureAcl(0, 1, everyone_sid), try Sid.init(&everyone_sid), &principals, &hash));
}

test "ACL rejects unknown or malformed ACE and unapproved owner" {
    const owner = try Sid.init(&system_sid);
    var principals: Principals = .{};
    var hash = Sha256.init(.{});
    try std.testing.expectError(error.Permission, inspectAcl(&fixtureAcl(0, 1, system_sid), owner, &principals, &hash));
    try principals.add(owner);
    try std.testing.expectError(error.Permission, inspectAcl(&fixtureAcl(5, 1, system_sid), owner, &principals, &hash));
    var bytes = fixtureAcl(0, 1, system_sid);
    bytes[10] = 32;
    try std.testing.expectError(error.Permission, inspectAcl(&bytes, owner, &principals, &hash));
    bytes = fixtureAcl(0, 1, system_sid);
    bytes[17] = 15;
    try std.testing.expectError(error.Permission, inspectAcl(&bytes, owner, &principals, &hash));
    try std.testing.expectError(error.Permission, Sid.init(&.{ 1, 1, 0 }));
}

test "ACL fingerprints reflect permission changes and principal sets" {
    const owner = try Sid.init(&system_sid);
    var principals: Principals = .{};
    try principals.add(owner);
    var a = Sha256.init(.{});
    var b = Sha256.init(.{});
    try inspectAcl(&fixtureAcl(0, 1, everyone_sid), owner, &principals, &a);
    try inspectAcl(&fixtureAcl(0, 0x80, everyone_sid), owner, &principals, &b);
    try std.testing.expect(!std.mem.eql(u8, &a.finalResult(), &b.finalResult()));
    try principals.add(owner);
    try std.testing.expectEqual(@as(usize, 1), principals.len);
}

test "Windows process token user is an owned SID, not implicit approval" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    const user = try currentProcessUser();
    const repeated = try currentProcessUser();
    try std.testing.expectEqualSlices(u8, user.slice(), repeated.slice());
    var principals: Principals = .{};
    try std.testing.expect(!principals.contains(user.slice()));
    try principals.add(user);
    try std.testing.expect(principals.contains(user.slice()));
}

/// Test-only fixture helpers. The production verifier never changes a DACL.
fn fixtureOwner(handle: Handle) !Sid {
    var owner: ?*anyopaque = null;
    var dacl: ?*anyopaque = null;
    var descriptor: ?*anyopaque = null;
    const status = GetSecurityInfo(handle, 1, 5, &owner, null, &dacl, null, &descriptor);
    defer if (descriptor) |memory| {
        _ = LocalFree(memory);
    };
    if (status != 0) return error.TestUnexpectedResult;
    return Sid.fromNative(owner orelse return error.TestUnexpectedResult);
}

fn fixtureSetDacl(handle: Handle, text: []const u8) !void {
    const wide = try Wide.init(text);
    var descriptor: ?*anyopaque = null;
    if (ConvertStringSecurityDescriptorToSecurityDescriptorW(wide.z(), 1, &descriptor, null) == 0) return error.TestUnexpectedResult;
    const sd = descriptor orelse return error.TestUnexpectedResult;
    defer _ = LocalFree(sd);
    var present: i32 = 0;
    var defaulted: i32 = 0;
    var dacl: ?*anyopaque = null;
    if (GetSecurityDescriptorDacl(sd, &present, &dacl, &defaulted) == 0 or present == 0) return error.TestUnexpectedResult;
    // Protected DACL, only the private test file is affected.
    if (SetSecurityInfo(handle, 1, 0x80000004, null, null, dacl, null) != 0) return error.TestUnexpectedResult;
}

test "Windows native DACL rejects added untrusted write grant" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "acl-fixture", .{ .exclusive = true });
    file.close(io);
    var cwd: [identity.max_path_bytes]u8 = undefined;
    var path_buffer: [identity.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}\\.zig-cache\\tmp\\{s}\\acl-fixture", .{ try currentDirectory(&cwd), tmp.sub_path });
    const wide = try Wide.init(path);
    const handle = CreateFileW(wide.z(), 0x60080, 7, null, 3, 0x00200000, null) orelse return error.TestUnexpectedResult;
    if (@intFromPtr(handle) == std.math.maxInt(usize)) return error.TestUnexpectedResult;
    defer _ = CloseHandle(handle);
    var info: FileInfo = undefined;
    if (GetFileInformationByHandle(handle, &info) == 0) return error.TestUnexpectedResult;
    const opened: Opened = .{ .handle = handle, .info = info };
    const user = try currentProcessUser();
    var principals: Principals = .{};
    try principals.add(user);
    try principals.add(try fixtureOwner(handle));
    var native_sid: ?[*:0]u16 = null;
    if (ConvertSidToStringSidW(user.slice().ptr, &native_sid) == 0) return error.TestUnexpectedResult;
    const sid_string = native_sid orelse return error.TestUnexpectedResult;
    defer _ = LocalFree(@ptrCast(sid_string));
    var sid_buffer: [256]u8 = undefined;
    const len = WideCharToMultiByte(65001, 0x80, sid_string, @intCast(std.mem.len(sid_string)), &sid_buffer, sid_buffer.len, null, null);
    if (len <= 0) return error.TestUnexpectedResult;
    const sid = sid_buffer[0..@intCast(len)];
    var sddl_buffer: [512]u8 = undefined;
    var safe_buffer: [512]u8 = undefined;
    const safe = try std.fmt.bufPrint(&safe_buffer, "D:P(A;;FA;;;{s})(A;;FR;;;WD)", .{sid});
    try fixtureSetDacl(handle, safe);
    defer fixtureSetDacl(handle, safe) catch {};
    var first = Sha256.init(.{});
    var walk: AclWalk = .{ .principals = &principals, .hash = &first };
    try walk.inspect(opened);
    const changed = try std.fmt.bufPrint(&sddl_buffer, "D:P(A;;FA;;;{s})(A;;FW;;;WD)", .{sid});
    try fixtureSetDacl(handle, changed);
    try std.testing.expectError(error.Permission, walk.inspect(opened));
    // Restore restrictive permissions before the temporary directory cleanup.
    try fixtureSetDacl(handle, safe);
}

test "installation manifest requires exact executable digest and disjoint bounded root" {
    const install = if (builtin.os.tag == .windows) "C:\\tools" else "/tools";
    const exe = if (builtin.os.tag == .windows) "C:\\tools\\git.exe" else "/tools/git";
    const dependency = if (builtin.os.tag == .windows) "C:\\tools\\helper.dll" else "/tools/helper.so";
    const outside = if (builtin.os.tag == .windows) "C:\\tools-other\\helper.dll" else "/tools-other/helper.so";
    const root = if (builtin.os.tag == .windows) "C:\\work\\repo" else "/work/repo";
    const neutral = if (builtin.os.tag == .windows) "C:\\neutral" else "/neutral";
    const grant = try approval.Grant.init(exe, @splat(1), root, neutral, @splat(2), @splat(3));
    var manifest = try InstallationManifest.init(install);
    try manifest.add(dependency, @splat(4));
    try std.testing.expectError(error.Permission, manifest.validate(&grant));
    try std.testing.expectError(error.Permission, manifest.add(outside, @splat(4)));
    try manifest.add(exe, @splat(1));
    try manifest.validate(&grant);
    try std.testing.expectError(error.Permission, manifest.add(exe, @splat(1)));
    manifest.entries[1].digest = @splat(9);
    try std.testing.expectError(error.Permission, manifest.validate(&grant));
}

test "Windows dependency digest uses checked handle and bounded total budget" {
    if (comptime builtin.os.tag != .windows) return error.SkipZigTest;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const file = try tmp.dir.createFile(io, "dependency.bin", .{ .exclusive = true });
    try file.writeStreamingAll(io, "abc");
    file.close(io);
    var cwd: [identity.max_path_bytes]u8 = undefined;
    var path_buffer: [identity.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&path_buffer, "{s}\\.zig-cache\\tmp\\{s}\\dependency.bin", .{ try currentDirectory(&cwd), tmp.sub_path });
    var expected: approval.Digest = undefined;
    Sha256.hash("abc", &expected, .{});
    {
        const opened = try openChecked(path, false, true);
        defer opened.close();
        var remaining: u64 = 2;
        try std.testing.expectError(error.ResourceLimit, digestOpened(opened, &remaining));
        remaining = 3;
        try std.testing.expectEqualSlices(u8, &expected, &(try digestOpened(opened, &remaining)));
        try std.testing.expectEqual(@as(u64, 0), remaining);
    }
    const changed = try tmp.dir.createFile(io, "dependency.bin", .{});
    try changed.writeStreamingAll(io, "xyz");
    changed.close(io);
    const opened = try openChecked(path, false, true);
    defer opened.close();
    var remaining: u64 = 3;
    try std.testing.expect(!std.mem.eql(u8, &expected, &(try digestOpened(opened, &remaining))));
}

test "restricted audit rejects nested Git and executable metadata" {
    try std.testing.expect(forbiddenRepoName(".git", "other", "root", true));
    try std.testing.expect(!forbiddenRepoName(".git", "root", "root", true));
    try std.testing.expect(forbiddenRepoName(".GITMODULES", "root", "root", false));
    try std.testing.expect(forbiddenRepoName("pre-commit", "hooks", "root", false));
    try std.testing.expect(!forbiddenRepoName("pre-commit.sample", "hooks", "root", false));
    var index: [32]u8 = @splat(0);
    @memcpy(index[0..4], "DIRC");
    std.mem.writeInt(u32, index[4..8], 2, .big);
    try validateIndex(&index);
    std.mem.writeInt(u32, index[4..8], 4, .big);
    try std.testing.expectError(error.Permission, validateIndex(&index));
}

test "ancestor ACL allows only unrelated sibling creation and not deletion" {
    const owner = try Sid.init(&system_sid);
    var principals: Principals = .{};
    try principals.add(owner);
    var hash = Sha256.init(.{});
    try inspectAclRole(&fixtureAcl(0, 0x6, everyone_sid), owner, &principals, &hash, true);
    try std.testing.expectError(error.Permission, inspectAclRole(&fixtureAcl(0, 0x46, everyone_sid), owner, &principals, &hash, true));
    try std.testing.expectError(error.Permission, inspectAcl(&fixtureAcl(0, 0x6, everyone_sid), owner, &principals, &hash));
    var inherited = fixtureAcl(0, 0x10000000, everyone_sid);
    inherited[9] = 0x08;
    try inspectAcl(&inherited, owner, &principals, &hash);
    inherited[9] = 0x10;
    try std.testing.expectError(error.Permission, inspectAcl(&inherited, owner, &principals, &hash));
}

test "Mercurial ordinary store requirements reject shared and remote formats" {
    try validateHgRequirements("share-safe\n");
    try validateHgRequirements("revlogv1\nstore\nfncache\ngeneraldelta\n");
    try std.testing.expectError(error.Unsupported, validateHgRequirements("share-safe\nshared\n"));
    try std.testing.expectError(error.Unsupported, validateHgRequirements("remotefilelog\n"));
}
