//! Explicit forge and external desktop handoffs. Never execute repository
//! configuration, reuse VCS credentials, resolve arbitrary URLs or log raw
//! remote responses. Desktop applications are user-owned, not CLI helpers.
const std = @import("std");
const builtin = @import("builtin");
const contract = @import("vcs_provider");
const identity = @import("vcs_identity");
const approval = @import("vcs_approval");
const evidence = @import("vcs_windows_evidence");

pub const Page = enum { repository, issues, reviews, ci, releases };
pub const pages = [_]Page{ .repository, .issues, .reviews, .ci, .releases };

pub fn pageUrl(base: []const u8, page: Page) ?contract.Text {
    const canonical = contract.repositoryWebUrl(base) orelse return null;
    if (!canonical.eql(base)) return null;
    const suffix: []const u8 = if (std.mem.startsWith(u8, base, "https://github.com/")) switch (page) {
        .repository => "",
        .issues => "/issues",
        .reviews => "/pulls",
        .ci => "/actions",
        .releases => "/releases",
    } else if (std.mem.startsWith(u8, base, "https://gitlab.com/")) switch (page) {
        .repository => "",
        .issues => "/-/issues",
        .reviews => "/-/merge_requests",
        .ci => "/-/pipelines",
        .releases => "/-/releases",
    } else if (std.mem.startsWith(u8, base, "https://bitbucket.org/")) switch (page) {
        .repository => "",
        .issues => "/issues",
        .reviews => "/pull-requests",
        .ci => "/pipelines",
        .releases => return null, // Downloads are not a release inventory.
    } else return null;
    var buffer: [contract.Text.capacity]u8 = undefined;
    return contract.Text.init(std.fmt.bufPrint(&buffer, "{s}{s}", .{ base, suffix }) catch return null) catch null;
}

pub const Remotes = struct {
    pub const capacity = 6;
    pub const Row = struct { name: contract.Text, url: contract.Text };
    rows: [capacity]Row = undefined,
    count: usize = 0,
    omitted: usize = 0,

    fn add(self: *Remotes, name: []const u8, raw_url: []const u8) void {
        const url = contract.repositoryWebUrl(raw_url) orelse {
            self.omitted += 1;
            return;
        };
        for (self.rows[0..self.count]) |row| {
            if (row.name.eql(name) and row.url.eql(url.slice())) return;
        }
        if (self.count == capacity) {
            self.omitted += 1;
            return;
        }
        self.rows[self.count] = .{ .name = contract.Text.init(name) catch return, .url = url };
        self.count += 1;
    }
};

/// Literal subset of the ordinary .git/config file. No includes, escapes,
/// URL rewriting, .git indirection, credentials or raw rejected URLs.
pub fn parseRemotes(bytes: []const u8) Remotes {
    var result: Remotes = .{};
    var name: []const u8 = "";
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#' or line[0] == ';') continue;
        if (line[0] == '[') {
            name = "";
            const prefix = "[remote \"";
            if (line.len <= prefix.len + 2 or !std.ascii.eqlIgnoreCase(line[0..prefix.len], prefix) or !std.mem.endsWith(u8, line, "\"]")) continue;
            const candidate = line[prefix.len .. line.len - 2];
            if (candidate.len > 64) continue;
            var valid = true;
            for (candidate) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_' and c != '.') valid = false;
            }
            if (valid) name = candidate;
            continue;
        }
        if (name.len == 0) continue;
        const equals = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        if (!std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..equals], " \t"), "url")) continue;
        result.add(name, std.mem.trim(u8, line[equals + 1 ..], " \t"));
    }
    return result;
}

pub fn inspectRemotes(root: []const u8) !Remotes {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    _ = try evidence.observeIdentity(root, true);
    var path: [identity.max_path_bytes]u8 = undefined;
    const config = try std.fmt.bufPrint(&path, "{s}\\.git\\config", .{root});
    var bytes: [4096]u8 = undefined;
    return parseRemotes(try evidence.readPreviewFile(config, &bytes));
}

pub const Client = enum {
    vscode,
    tortoise_svn,

    pub fn name(self: Client) []const u8 {
        return switch (self) {
            .vscode => "VS Code",
            .tortoise_svn => "TortoiseSVN",
        };
    }

    pub fn executable(self: Client) []const u8 {
        return switch (self) {
            .vscode => "Code.exe",
            .tortoise_svn => "TortoiseProc.exe",
        };
    }
};

fn quoteSafe(path: []const u8) bool {
    if (!approval.strictPath(path)) return false;
    for (path) |byte| {
        if (std.mem.indexOfScalar(u8, "\"<>|*?", byte) != null) return false;
    }
    return true;
}

pub fn clientPath(client: Client, value: []const u8) !?identity.Path {
    if (value.len == 0) return null;
    if (value.len > 1024 or !quoteSafe(value) or !std.ascii.eqlIgnoreCase(std.fs.path.basename(value), client.executable())) return error.InvalidClient;
    return identity.Path.init(value);
}

pub fn commandLine(client: Client, executable: []const u8, root: []const u8, kind: ?identity.Kind, buffer: []u8) ![]const u8 {
    if ((try clientPath(client, executable)) == null or !quoteSafe(root)) return error.InvalidClient;
    if (client == .tortoise_svn and kind != .svn) return error.InvalidClient;
    return switch (client) {
        .vscode => std.fmt.bufPrint(buffer, "\"{s}\" --new-window \"{s}\"", .{ executable, root }),
        .tortoise_svn => std.fmt.bufPrint(buffer, "\"{s}\" /command:repostatus /path:\"{s}\"", .{ executable, root }),
    };
}

const Handle = std.os.windows.HANDLE;
const StartupInfo = extern struct {
    cb: u32,
    reserved: ?[*:0]u16,
    desktop: ?[*:0]u16,
    title: ?[*:0]u16,
    x: u32,
    y: u32,
    x_size: u32,
    y_size: u32,
    x_chars: u32,
    y_chars: u32,
    fill: u32,
    flags: u32,
    show: u16,
    reserved_size: u16,
    reserved_bytes: ?[*]u8,
    stdin_handle: ?Handle,
    stdout_handle: ?Handle,
    stderr_handle: ?Handle,
};
const ProcessInfo = extern struct { process: Handle, thread: Handle, pid: u32, tid: u32 };
extern "kernel32" fn CreateProcessW([*:0]const u16, [*:0]u16, ?*anyopaque, ?*anyopaque, i32, u32, ?*anyopaque, [*:0]const u16, *StartupInfo, *ProcessInfo) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) i32;
extern "kernel32" fn MultiByteToWideChar(u32, u32, [*]const u8, i32, [*]u16, i32) callconv(.winapi) i32;

fn wide(value: []const u8, buffer: []u16) ![:0]u16 {
    if (value.len == 0 or buffer.len < 2 or !std.unicode.utf8ValidateSlice(value) or std.mem.indexOfScalar(u8, value, 0) != null) return error.InvalidText;
    const n = MultiByteToWideChar(65001, 8, value.ptr, @intCast(value.len), buffer.ptr, @intCast(buffer.len - 1));
    if (n <= 0) return error.InvalidText;
    const len: usize = @intCast(n);
    buffer[len] = 0;
    return buffer[0..len :0];
}

pub fn launchClient(client: Client, exe: []const u8, root: []const u8, kind: ?identity.Kind) !void {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedPlatform;
    var command: [2 * identity.max_path_bytes + 128]u8 = undefined;
    const text = try commandLine(client, exe, root, kind, &command);
    _ = try evidence.observeSessionToolIdentity(exe);
    _ = try evidence.observeIdentity(root, true);
    if (client == .tortoise_svn) {
        var marker: [identity.max_path_bytes]u8 = undefined;
        _ = try evidence.observeIdentity(try std.fmt.bufPrint(&marker, "{s}\\.svn", .{root}), true);
    }
    const parent = std.fs.path.dirname(exe) orelse return error.InvalidClient;
    var app: [identity.max_path_bytes + 1]u16 = undefined;
    var cwd: [identity.max_path_bytes + 1]u16 = undefined;
    var args: [command.len + 1]u16 = undefined;
    const app_name = try wide(exe, &app);
    const cwd_name = try wide(parent, &cwd);
    const command_name = try wide(text, &args);
    var startup = std.mem.zeroes(StartupInfo);
    startup.cb = @sizeOf(StartupInfo);
    var process: ProcessInfo = undefined;
    // No cmd.exe, PATH lookup, inherited handles, arbitrary flags or wait.
    // These are explicitly launched desktop applications, not plugin-owned
    // workers; the user controls their lifetime after successful handoff.
    if (CreateProcessW(app_name.ptr, command_name.ptr, null, null, 0, 0, null, cwd_name.ptr, &startup, &process) == 0) return error.LaunchFailed;
    _ = CloseHandle(process.thread);
    _ = CloseHandle(process.process);
}

comptime {
    if (builtin.cpu.arch == .x86_64 and builtin.os.tag == .windows) {
        if (@sizeOf(StartupInfo) != 104 or @sizeOf(ProcessInfo) != 24) @compileError("Windows process handoff ABI mismatch");
    }
}

pub const Metadata = struct {
    pub const Status = enum { ready, forbidden_or_limited, not_found, redirected, http_error, offline, invalid, too_large, cancelled };
    status: Status,
    stars: u64 = 0,
    forks: u64 = 0,
    open_items: u64 = 0,
    branch: contract.Text = .{},
    archived: bool = false,
    fetched_ms: u64 = 0,
};

pub fn githubPath(base: []const u8, buffer: []u8) ?[]const u8 {
    const prefix = "https://github.com/";
    const canonical = contract.repositoryWebUrl(base) orelse return null;
    if (!canonical.eql(base) or !std.mem.startsWith(u8, base, prefix)) return null;
    return std.fmt.bufPrint(buffer, "/repos/{s}", .{base[prefix.len..]}) catch null;
}

pub fn httpStatus(code: u32) Metadata.Status {
    return switch (code) {
        200 => .ready,
        301...399 => .redirected,
        401, 403, 429 => .forbidden_or_limited,
        404 => .not_found,
        else => .http_error,
    };
}

pub fn parseMetadata(base: []const u8, body: []const u8) Metadata {
    if (body.len > 64 * 1024) return .{ .status = .too_large };
    var endpoint: [contract.Text.capacity + 16]u8 = undefined;
    _ = githubPath(base, &endpoint) orelse return .{ .status = .invalid };
    const Wire = struct {
        html_url: []const u8,
        private: bool,
        stargazers_count: u64,
        forks_count: u64,
        open_issues_count: u64,
        default_branch: []const u8,
        archived: bool,
    };
    const parsed = std.json.parseFromSlice(Wire, std.heap.page_allocator, body, .{ .ignore_unknown_fields = true }) catch return .{ .status = .invalid };
    defer parsed.deinit();
    const value = parsed.value;
    if (value.private or !std.ascii.eqlIgnoreCase(value.html_url, base)) return .{ .status = .invalid };
    for (value.default_branch) |c| {
        if (c < 0x20 or c == 0x7f) return .{ .status = .invalid };
    }
    const branch = contract.Text.init(value.default_branch) catch return .{ .status = .invalid };
    return .{ .status = .ready, .stars = value.stargazers_count, .forks = value.forks_count, .open_items = value.open_issues_count, .branch = branch, .archived = value.archived };
}

extern "kernel32" fn LoadLibraryExW([*:0]const u16, ?*anyopaque, u32) callconv(.winapi) usize;
extern "kernel32" fn GetProcAddress(usize, [*:0]const u8) callconv(.winapi) ?*const anyopaque;
extern "kernel32" fn FreeLibrary(usize) callconv(.winapi) c_int;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;

pub fn nowMs() u64 {
    if (comptime builtin.os.tag == .windows) return GetTickCount64();
    return 0;
}

pub const CancelFn = *const fn (?*anyopaque) callconv(.c) u32;

const Http = struct {
    const H = *anyopaque;
    open: *const fn ([*:0]const u16, u32, ?[*:0]const u16, ?[*:0]const u16, u32) callconv(.winapi) ?H,
    connect: *const fn (H, [*:0]const u16, u16, u32) callconv(.winapi) ?H,
    request: *const fn (H, [*:0]const u16, [*:0]const u16, ?[*:0]const u16, ?[*:0]const u16, ?*anyopaque, u32) callconv(.winapi) ?H,
    option: *const fn (H, u32, *const anyopaque, u32) callconv(.winapi) i32,
    timeouts: *const fn (H, i32, i32, i32, i32) callconv(.winapi) i32,
    send: *const fn (H, [*:0]const u16, u32, ?*anyopaque, u32, u32, usize) callconv(.winapi) i32,
    receive: *const fn (H, ?*anyopaque) callconv(.winapi) i32,
    headers: *const fn (H, u32, ?[*:0]const u16, *anyopaque, *u32, ?*u32) callconv(.winapi) i32,
    read: *const fn (H, [*]u8, u32, *u32) callconv(.winapi) i32,
    close: *const fn (H) callconv(.winapi) i32,

    fn load(lib: usize) ?Http {
        return .{
            .open = @ptrCast(GetProcAddress(lib, "WinHttpOpen") orelse return null),
            .connect = @ptrCast(GetProcAddress(lib, "WinHttpConnect") orelse return null),
            .request = @ptrCast(GetProcAddress(lib, "WinHttpOpenRequest") orelse return null),
            .option = @ptrCast(GetProcAddress(lib, "WinHttpSetOption") orelse return null),
            .timeouts = @ptrCast(GetProcAddress(lib, "WinHttpSetTimeouts") orelse return null),
            .send = @ptrCast(GetProcAddress(lib, "WinHttpSendRequest") orelse return null),
            .receive = @ptrCast(GetProcAddress(lib, "WinHttpReceiveResponse") orelse return null),
            .headers = @ptrCast(GetProcAddress(lib, "WinHttpQueryHeaders") orelse return null),
            .read = @ptrCast(GetProcAddress(lib, "WinHttpReadData") orelse return null),
            .close = @ptrCast(GetProcAddress(lib, "WinHttpCloseHandle") orelse return null),
        };
    }
};

/// One explicit public repository GET. No cookies, auth, redirects, proxy
/// auto-discovery, token, local paths, raw payload persistence or polling.
/// Each blocking call has a finite timeout; cancellation checked between
/// calls and read chunks. Certificate verification is WinHTTP's default.
pub fn fetchMetadata(base: []const u8, cancelled: CancelFn, context: ?*anyopaque) Metadata {
    if (comptime builtin.os.tag != .windows) return .{ .status = .offline };
    var endpoint: [contract.Text.capacity + 16]u8 = undefined;
    const path = githubPath(base, &endpoint) orelse return .{ .status = .invalid };
    var wide_path: [endpoint.len + 1]u16 = undefined;
    const target = wide(path, &wide_path) catch return .{ .status = .invalid };
    const lib = LoadLibraryExW(std.unicode.wtf8ToWtf16LeStringLiteral("winhttp.dll"), null, 0x800);
    if (lib == 0) return .{ .status = .offline };
    defer _ = FreeLibrary(lib);
    const http = Http.load(lib) orelse return .{ .status = .offline };
    const start = nowMs();
    const session = http.open(std.unicode.wtf8ToWtf16LeStringLiteral("PulseExtras-VCS/1"), 1, null, null, 0) orelse return .{ .status = .offline };
    defer _ = http.close(session);
    if (http.timeouts(session, 4000, 4000, 4000, 4000) == 0) return .{ .status = .offline };
    const connection = http.connect(session, std.unicode.wtf8ToWtf16LeStringLiteral("api.github.com"), 443, 0) orelse return .{ .status = .offline };
    defer _ = http.close(connection);
    const request = http.request(connection, std.unicode.wtf8ToWtf16LeStringLiteral("GET"), target.ptr, null, null, null, 0x00800000) orelse return .{ .status = .offline };
    defer _ = http.close(request);
    // WINHTTP_OPTION_DISABLE_FEATURE: cookies | redirects | authentication.
    const disabled: u32 = 1 | 2 | 4;
    if (http.option(request, 63, &disabled, @sizeOf(u32)) == 0) return .{ .status = .offline };
    if (cancelled(context) != 0) return .{ .status = .cancelled };
    const headers = std.unicode.wtf8ToWtf16LeStringLiteral("Accept: application/vnd.github+json\r\n");
    if (http.send(request, headers, @intCast(headers.len), null, 0, 0, 0) == 0) return .{ .status = .offline };
    if (cancelled(context) != 0) return .{ .status = .cancelled };
    if (http.receive(request, null) == 0) return .{ .status = .offline };
    var code: u32 = 0;
    var size: u32 = @sizeOf(u32);
    if (http.headers(request, 0x20000000 | 19, null, &code, &size, null) == 0) return .{ .status = .offline };
    const state = httpStatus(code);
    if (state != .ready) return .{ .status = state };
    var body: [64 * 1024 + 1]u8 = undefined;
    var used: usize = 0;
    while (used < body.len) {
        if (cancelled(context) != 0) return .{ .status = .cancelled };
        if (nowMs() -| start > 20000) return .{ .status = .offline };
        var read_count: u32 = 0;
        const count: u32 = @intCast(@min(4096, body.len - used));
        if (http.read(request, body[used..].ptr, count, &read_count) == 0 or read_count > count) return .{ .status = .offline };
        if (read_count == 0) {
            var result = parseMetadata(base, body[0..used]);
            result.fetched_ms = nowMs();
            return result;
        }
        used += read_count;
    }
    return .{ .status = .too_large };
}

test "forge page vocabulary never accepts arbitrary routes or credentials" {
    const base = "https://github.com/owner/repo";
    try std.testing.expect(pageUrl(base, .reviews).?.eql("https://github.com/owner/repo/pulls"));
    try std.testing.expect(pageUrl("https://gitlab.com/group/sub/repo", .ci).?.eql("https://gitlab.com/group/sub/repo/-/pipelines"));
    try std.testing.expect(pageUrl("https://bitbucket.org/owner/repo", .releases) == null);
    for ([_][]const u8{ "https://token@github.com/a/b", "https://github.com/a/b?token=x", "https://gitlab.com/a/b/-/issues", "https://github.com.evil/a/b" }) |bad| try std.testing.expect(pageUrl(bad, .repository) == null);
}

test "literal remote discovery retains multiple choices but never credentials" {
    const remotes = parseRemotes("[remote \"origin\"]\nurl = git@github.com:a/b.git\n[remote \"upstream\"]\nurl = https://gitlab.com/g/p.git\nurl = https://token@github.com/a/b\n[include]\npath = other\n");
    try std.testing.expectEqual(@as(usize, 2), remotes.count);
    try std.testing.expectEqual(@as(usize, 1), remotes.omitted);
    try std.testing.expect(remotes.rows[0].url.eql("https://github.com/a/b"));
    try std.testing.expect(remotes.rows[1].name.eql("upstream"));
}

test "client command lines accept only reviewed absolute paths and fixed flags" {
    const exe = if (builtin.os.tag == .windows) "C:\\Programs\\Code.exe" else "/opt/Code.exe";
    const root = if (builtin.os.tag == .windows) "C:\\work\\repo name" else "/work/repo name";
    var bytes: [512]u8 = undefined;
    const line = try commandLine(.vscode, exe, root, .git, &bytes);
    try std.testing.expect(std.mem.indexOf(u8, line, " --new-window \"") != null);
    try std.testing.expectError(error.InvalidClient, commandLine(.tortoise_svn, exe, root, .git, &bytes));
    try std.testing.expectError(error.InvalidClient, commandLine(.vscode, "cmd.exe", root, .git, &bytes));
    try std.testing.expectError(error.InvalidClient, commandLine(.vscode, exe, "--user-data-dir", .git, &bytes));
}

test "anonymous GitHub metadata accepts only matching public typed response" {
    const base = "https://github.com/a/b";
    const json = "{\"html_url\":\"https://github.com/a/b\",\"private\":false,\"stargazers_count\":4,\"forks_count\":2,\"open_issues_count\":3,\"default_branch\":\"main\",\"archived\":false}";
    const result = parseMetadata(base, json);
    try std.testing.expectEqual(Metadata.Status.ready, result.status);
    try std.testing.expectEqual(@as(u64, 4), result.stars);
    try std.testing.expectEqual(Metadata.Status.invalid, parseMetadata("https://github.com/a/c", json).status);
    try std.testing.expectEqual(Metadata.Status.invalid, parseMetadata(base, "{}").status);
    const oversized: [64 * 1024 + 1]u8 = @splat('x');
    try std.testing.expectEqual(Metadata.Status.too_large, parseMetadata(base, &oversized).status);
    try std.testing.expectEqual(Metadata.Status.forbidden_or_limited, httpStatus(429));
    try std.testing.expectEqual(Metadata.Status.redirected, httpStatus(301));
    var endpoint: [128]u8 = undefined;
    try std.testing.expectEqualStrings("/repos/a/b", githubPath(base, &endpoint).?);
    try std.testing.expect(githubPath("https://gitlab.com/a/b", &endpoint) == null);
}
