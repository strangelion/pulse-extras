//! One explicitly requested, digest-pinned CLI child in a private job.
//! Runs only inside a host-owned task, never in a UI callback.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("share_config");
const raw = @import("pulse_raw");

pub const Mode = enum { discover, send, receive };
pub const Field = struct {
    bytes: [2048]u8 = @splat(0),
    len: usize = 0,

    pub fn slice(self: *const Field) []const u8 {
        return self.bytes[0..self.len];
    }

    pub fn set(self: *Field, value: []const u8) !void {
        if (value.len >= self.bytes.len or !std.unicode.utf8ValidateSlice(value)) return error.InvalidInput;
        for (value) |c| if (c < 32 or c == 127 or c == '"') return error.InvalidInput;
        @memcpy(self.bytes[0..value.len], value);
        self.len = value.len;
    }
};

pub const Request = struct {
    mode: Mode = .discover,
    bind: Field = .{},
    peer: Field = .{},
    store: Field = .{},
    paired: Field = .{},
    source: Field = .{},
    destination: Field = .{},
    spool: Field = .{},
    port: Field = .{},

    pub fn validate(self: *const Request) !void {
        if (self.bind.len == 0) return error.InvalidInput;
        if (self.mode == .discover) return;
        if (self.store.len == 0 or self.paired.len == 0) return error.InvalidInput;
        if (self.mode == .send and (self.peer.len == 0 or self.source.len == 0)) return error.InvalidInput;
        if (self.mode == .receive and (self.destination.len == 0 or self.spool.len == 0 or self.port.len == 0)) return error.InvalidInput;
    }
};

pub fn configured() bool {
    return config.lan_sha256.len == 64 and config.local_sha256.len == 64 and config.worker_sha256.len == 64;
}

const Handle = usize;
const invalid: Handle = std.math.maxInt(usize);
const Info = extern struct {
    attributes: u32,
    creation: [2]u32,
    access: [2]u32,
    write: [2]u32,
    volume: u32,
    high: u32,
    low: u32,
    links: u32,
    index_high: u32,
    index_low: u32,
};
const Security = extern struct { size: u32 = @sizeOf(Security), descriptor: ?*anyopaque = null, inherit: i32 = 1 };
const Startup = extern struct {
    cb: u32 = @sizeOf(StartupEx),
    reserved: ?[*:0]u16 = null,
    desktop: ?[*:0]u16 = null,
    title: ?[*:0]u16 = null,
    x: u32 = 0,
    y: u32 = 0,
    x_size: u32 = 0,
    y_size: u32 = 0,
    x_chars: u32 = 0,
    y_chars: u32 = 0,
    fill: u32 = 0,
    flags: u32 = 0,
    show: u16 = 0,
    reserved_size: u16 = 0,
    reserved2: ?*anyopaque = null,
    stdin: Handle = 0,
    stdout: Handle = 0,
    stderr: Handle = 0,
};
const StartupEx = extern struct { base: Startup = .{}, attributes: ?*anyopaque = null };
const Process = extern struct { process: Handle = 0, thread: Handle = 0, pid: u32 = 0, tid: u32 = 0 };
const BasicLimits = extern struct {
    per_process_time: i64 = 0,
    per_job_time: i64 = 0,
    flags: u32 = 0,
    min_working_set: usize = 0,
    max_working_set: usize = 0,
    active_process_limit: u32 = 0,
    affinity: usize = 0,
    priority_class: u32 = 0,
    scheduling_class: u32 = 0,
};
const Limits = extern struct {
    basic: BasicLimits = .{},
    io: [6]u64 = @splat(0),
    process_memory: usize = 0,
    job_memory: usize = 0,
    peak_process_memory: usize = 0,
    peak_job_memory: usize = 0,
};
const Accounting = extern struct {
    user: i64 = 0,
    kernel: i64 = 0,
    period_user: i64 = 0,
    period_kernel: i64 = 0,
    page_faults: u32 = 0,
    total: u32 = 0,
    active: u32 = 0,
    terminated: u32 = 0,
};

extern "kernel32" fn GetModuleHandleExW(u32, *const anyopaque, *Handle) callconv(.winapi) i32;
extern "kernel32" fn GetModuleFileNameW(Handle, [*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn GetSystemDirectoryW([*]u16, u32) callconv(.winapi) u32;
extern "kernel32" fn GetDriveTypeW([*:0]const u16) callconv(.winapi) u32;
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, Handle) callconv(.winapi) Handle;
extern "kernel32" fn GetFileInformationByHandle(Handle, *Info) callconv(.winapi) i32;
extern "kernel32" fn GetFinalPathNameByHandleW(Handle, [*]u16, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn CompareStringOrdinal([*]const u16, i32, [*]const u16, i32, i32) callconv(.winapi) i32;
extern "kernel32" fn GetFileType(Handle) callconv(.winapi) u32;
extern "kernel32" fn ReadFile(Handle, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(Handle) callconv(.winapi) i32;
extern "kernel32" fn CreateEventW(*const Security, i32, i32, ?[*:0]const u16) callconv(.winapi) Handle;
extern "kernel32" fn SetEvent(Handle) callconv(.winapi) i32;
extern "kernel32" fn InitializeProcThreadAttributeList(?*anyopaque, u32, u32, *usize) callconv(.winapi) i32;
extern "kernel32" fn UpdateProcThreadAttribute(*anyopaque, u32, usize, *const anyopaque, usize, ?*anyopaque, ?*usize) callconv(.winapi) i32;
extern "kernel32" fn DeleteProcThreadAttributeList(*anyopaque) callconv(.winapi) void;
extern "kernel32" fn CreateProcessW([*:0]const u16, [*:0]u16, ?*anyopaque, ?*anyopaque, i32, u32, ?*anyopaque, [*:0]const u16, *StartupEx, *Process) callconv(.winapi) i32;
extern "kernel32" fn CreateJobObjectW(?*anyopaque, ?[*:0]const u16) callconv(.winapi) Handle;
extern "kernel32" fn SetInformationJobObject(Handle, i32, *const anyopaque, u32) callconv(.winapi) i32;
extern "kernel32" fn QueryInformationJobObject(Handle, i32, *anyopaque, u32, ?*u32) callconv(.winapi) i32;
extern "kernel32" fn AssignProcessToJobObject(Handle, Handle) callconv(.winapi) i32;
extern "kernel32" fn TerminateJobObject(Handle, u32) callconv(.winapi) i32;
extern "kernel32" fn TerminateProcess(Handle, u32) callconv(.winapi) i32;
extern "kernel32" fn ResumeThread(Handle) callconv(.winapi) u32;
extern "kernel32" fn WaitForSingleObject(Handle, u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(Handle, *u32) callconv(.winapi) i32;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn Sleep(u32) callconv(.winapi) void;

const Path = [1024:0]u16;
fn sibling(root: []const u16, comptime leaf: []const u8) !Path {
    const tail = std.unicode.wtf8ToWtf16LeStringLiteral(leaf);
    if (root.len + tail.len >= 1024) return error.InvalidPath;
    var result: Path = @splat(0);
    @memcpy(result[0..root.len], root);
    @memcpy(result[root.len..][0..tail.len], tail);
    return result;
}

fn pin(path: *const Path, hex: []const u8) !Handle {
    if (hex.len != 64) return error.Unconfigured;
    var expected: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, hex);
    const file = CreateFileW(path, 0x80000000, 1, null, 3, 0x00200000, 0);
    if (file == invalid or file == 0) return error.ImageOpen;
    errdefer _ = CloseHandle(file);
    var info: Info = undefined;
    if (GetFileType(file) != 1 or GetFileInformationByHandle(file, &info) == 0 or
        info.attributes & 0x410 != 0 or info.links != 1 or info.high != 0 or
        info.low == 0 or info.low > 256 * 1024 * 1024) return error.ImageIdentity;
    const expected_path = std.mem.sliceTo(path, 0);
    var actual: [1032]u16 = undefined;
    const n = GetFinalPathNameByHandleW(file, &actual, actual.len, 0);
    if (n != expected_path.len + 4 or n >= actual.len or
        !std.mem.eql(u16, actual[0..4], std.unicode.wtf8ToWtf16LeStringLiteral("\\\\?\\")) or
        CompareStringOrdinal(actual[4..n].ptr, @intCast(expected_path.len), expected_path.ptr, @intCast(expected_path.len), 1) != 2) return error.ImageIdentity;
    var hash = std.crypto.hash.sha2.Sha256.init(.{});
    var buffer: [16384]u8 = undefined;
    var remaining = info.low;
    while (remaining != 0) {
        const want: u32 = @min(remaining, buffer.len);
        var got: u32 = 0;
        if (ReadFile(file, &buffer, want, &got, null) == 0 or got != want) return error.ImageRead;
        hash.update(buffer[0..got]);
        remaining -= got;
    }
    const digest = hash.finalResult();
    if (!std.mem.eql(u8, &digest, &expected)) return error.ImageDigest;
    return file;
}

const Command = struct {
    data: [16384:0]u16 = @splat(0),
    len: usize = 0,

    fn put(self: *Command, ch: u16) !void {
        if (self.len >= 16383) return error.ArgumentsTooLong;
        self.data[self.len] = ch;
        self.len += 1;
    }

    // All args quoted; reject quotes/control characters. Double trailing
    // backslashes so the Windows argv parser cannot merge arguments.
    fn wide(self: *Command, value: []const u16) !void {
        if (self.len != 0) try self.put(' ');
        try self.put('"');
        var trailing: usize = 0;
        for (value) |ch| {
            if (ch < 32 or ch == '"') return error.InvalidInput;
            try self.put(ch);
            trailing = if (ch == '\\') trailing + 1 else 0;
        }
        for (0..trailing) |_| try self.put('\\');
        try self.put('"');
        self.data[self.len] = 0;
    }

    fn arg(self: *Command, value: []const u8) !void {
        var wide_buffer: [4096]u16 = undefined;
        const n = try std.unicode.utf8ToUtf16Le(&wide_buffer, value);
        try self.wide(wide_buffer[0..n]);
    }

    fn pair(self: *Command, key: []const u8, value: []const u8) !void {
        try self.arg(key);
        try self.arg(value);
    }
};

fn cancelled(ctx: *const raw.PulseTaskContext) bool {
    return if (ctx.cancelled) |check| check(ctx.context) != 0 else true;
}

fn drain(job: Handle) bool {
    var accounting: Accounting = .{};
    if (QueryInformationJobObject(job, 1, &accounting, @sizeOf(Accounting), null) == 0) return false;
    if (accounting.active == 0) return true;
    if (TerminateJobObject(job, 1) == 0) return false;
    const start = GetTickCount64();
    while (GetTickCount64() -% start < 5000) {
        if (QueryInformationJobObject(job, 1, &accounting, @sizeOf(Accounting), null) == 0) return false;
        if (accounting.active == 0) return true;
        Sleep(20);
    }
    return false;
}

pub fn run(request: *const Request, ctx: *const raw.PulseTaskContext) !void {
    if (comptime builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.UnsupportedPlatform;
    try request.validate();
    if (!configured()) return error.Unconfigured;
    if (cancelled(ctx)) return error.Cancelled;
    var module: Handle = 0;
    if (GetModuleHandleExW(6, @ptrCast(&run), &module) == 0) return error.ModulePath;
    var module_path: Path = @splat(0);
    const n = GetModuleFileNameW(module, &module_path, module_path.len);
    if (n < 4 or n >= module_path.len or module_path[1] != ':' or module_path[2] != '\\') return error.ModulePath;
    const drive = [_:0]u16{ module_path[0], ':', '\\' };
    if (GetDriveTypeW(&drive) != 3) return error.ModulePath;
    const split = std.mem.lastIndexOfScalar(u16, module_path[0..n], '\\') orelse return error.ModulePath;
    const root = module_path[0 .. split + 1];
    const lan = try sibling(root, "pulse-share-lan.exe");
    const local = try sibling(root, "pulse-share-local.exe");
    const worker = try sibling(root, "pulse-share-worker.exe");
    const lan_pin = try pin(&lan, config.lan_sha256);
    defer _ = CloseHandle(lan_pin);
    const local_pin = try pin(&local, config.local_sha256);
    defer _ = CloseHandle(local_pin);
    const worker_pin = try pin(&worker, config.worker_sha256);
    defer _ = CloseHandle(worker_pin);
    const security: Security = .{};
    const event = CreateEventW(&security, 1, 0, null);
    if (event == 0) return error.Event;
    defer _ = CloseHandle(event);
    var command: Command = .{};
    try command.wide(std.mem.sliceTo(&lan, 0));
    var handle_text: [32]u8 = undefined;
    try command.pair("--managed-cancel-handle", try std.fmt.bufPrint(&handle_text, "{x}", .{event}));
    try command.arg(@tagName(request.mode));
    try command.pair("--bind", request.bind.slice());
    switch (request.mode) {
        .discover => {},
        .send => {
            try command.pair("--peer", request.peer.slice());
            try command.pair("--source", request.source.slice());
            try command.pair("--store", request.store.slice());
            try command.pair("--paired", request.paired.slice());
        },
        .receive => {
            try command.pair("--port", request.port.slice());
            try command.pair("--directory", request.destination.slice());
            try command.pair("--spool", request.spool.slice());
            try command.arg("--supervisor");
            try command.wide(std.mem.sliceTo(&local, 0));
            try command.pair("--supervisor-sha256", config.local_sha256);
            try command.arg("--worker");
            try command.wide(std.mem.sliceTo(&worker, 0));
            try command.pair("--worker-sha256", config.worker_sha256);
            try command.pair("--store", request.store.slice());
            try command.pair("--paired", request.paired.slice());
        },
    }
    const job = CreateJobObjectW(null, null);
    if (job == 0) return error.Job;
    defer _ = CloseHandle(job);
    const limits: Limits = .{
        .basic = .{ .flags = 0x2000 | 0x8 | 0x100 | 0x200, .active_process_limit = 3 },
        .process_memory = 384 * 1024 * 1024,
        .job_memory = 512 * 1024 * 1024,
    };
    if (SetInformationJobObject(job, 9, &limits, @sizeOf(Limits)) == 0) return error.Job;
    var size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &size);
    if (size == 0 or size > 65536) return error.Attributes;
    const storage = try std.heap.page_allocator.alignedAlloc(u8, .of(usize), size);
    defer std.heap.page_allocator.free(storage);
    const attrs: *anyopaque = @ptrCast(storage.ptr);
    if (InitializeProcThreadAttributeList(attrs, 1, 0, &size) == 0) return error.Attributes;
    defer DeleteProcThreadAttributeList(attrs);
    if (UpdateProcThreadAttribute(attrs, 0, 0x00020002, &event, @sizeOf(Handle), null, null) == 0) return error.Attributes;
    var si: StartupEx = .{ .attributes = attrs };
    var cwd: Path = @splat(0);
    const cwd_len = GetSystemDirectoryW(&cwd, cwd.len);
    if (cwd_len == 0 or cwd_len >= cwd.len) return error.SystemDirectory;
    var child: Process = .{};
    if (cancelled(ctx)) return error.Cancelled;
    if (CreateProcessW(&lan, &command.data, null, null, 1, 0x00080000 | 4 | 16, null, &cwd, &si, &child) == 0) return error.Spawn;
    defer _ = CloseHandle(child.thread);
    defer _ = CloseHandle(child.process);
    if (AssignProcessToJobObject(job, child.process) == 0) {
        if (TerminateProcess(child.process, 1) == 0 or WaitForSingleObject(child.process, 5000) != 0) return error.Drain;
        return error.Job;
    }
    if (ResumeThread(child.thread) == std.math.maxInt(u32)) {
        if (!drain(job)) return error.Drain;
        return error.Spawn;
    }
    const start = GetTickCount64();
    var stop_at: ?u64 = null;
    while (true) {
        const wait = WaitForSingleObject(child.process, 100);
        if (wait == 0) break;
        if (wait != 258) {
            if (!drain(job)) return error.Drain;
            return error.Wait;
        }
        const now = GetTickCount64();
        if (stop_at == null and (cancelled(ctx) or now -% start >= 40 * 60 * 1000)) {
            if (SetEvent(event) == 0) {
                if (!drain(job)) return error.Drain;
                return error.CancelUncertain;
            }
            stop_at = now;
        }
        if (stop_at) |stop| if (now -% stop >= 10000) {
            if (!drain(job)) return error.Drain;
            return error.CancelUncertain;
        };
    }
    var exit: u32 = 0;
    const got_exit = GetExitCodeProcess(child.process, &exit) != 0;
    if (!drain(job)) return error.Drain;
    if (!got_exit) return error.Wait;
    if (exit == 0) return;
    if (stop_at != null or cancelled(ctx)) return error.CancelUncertain;
    return error.ChildFailed;
}

test "bounded fields and request admission" {
    var request: Request = .{};
    try std.testing.expectError(error.InvalidInput, request.validate());
    try request.bind.set("127.0.0.1");
    try request.validate();
    request.mode = .send;
    try std.testing.expectError(error.InvalidInput, request.validate());
    try std.testing.expectError(error.InvalidInput, request.source.set("bad\"name"));
    try request.source.set("C:\\中文.bin");
    try request.store.set("C:\\private");
    try request.paired.set("laptop");
    try request.peer.set("127.0.0.1:1234");
    try request.validate();
}

test "command quoting preserves trailing slash and rejects quotes" {
    var command: Command = .{};
    try command.arg("C:\\a b\\");
    try command.arg("--bind");
    try std.testing.expectEqualSlices(u16, std.unicode.wtf8ToWtf16LeStringLiteral("\"C:\\a b\\\\\" \"--bind\""), command.data[0..command.len]);
    try std.testing.expectError(error.InvalidInput, command.arg("a\"b"));
}
