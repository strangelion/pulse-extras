//! One explicitly requested, digest-pinned CLI child in a private job.
//! Launch and network work run off the UI thread.
const std = @import("std");
const builtin = @import("builtin");
const config = @import("share_config");
const raw = @import("pulse_raw");

pub const Mode = enum { discover, send, receive, identity_init, identity_show, peer_add, peer_list, peer_revoke, private_init, recovery_list, interfaces, pair_host, pair_join, device_prepare };
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
    advertise: bool = false,
    routed: bool = false,
    quic: bool = false,
    batch: bool = false,
    queue_action: []const u8 = "",
    queue_id: Field = .{},
    sync_clipboard: bool = false,
    root_service: bool = false,
    root_connect: bool = false,
    clipboard_receive: bool = false,
    browse: bool = false,
    channels: Field = .{},
    sources: Field = .{},
    resume_path: Field = .{},
    clipboard: Field = .{},
    delivery: Field = .{},
    remote_path: Field = .{},
    browse_offset: Field = .{},
    prepare_default_parent: bool = false,
    prepare_spool: bool = false,
    allowed_source: Field = .{},
    bind: Field = .{},
    peer: Field = .{},
    store: Field = .{},
    paired: Field = .{},
    source: Field = .{},
    destination: Field = .{},
    spool: Field = .{},
    port: Field = .{},
    fingerprint: Field = .{},

    pub fn validate(self: *const Request) !void {
        switch (self.mode) {
            .interfaces => return,
            .device_prepare => {
                if (self.store.len == 0 or self.spool.len == 0) return error.InvalidInput;
                return;
            },
            .identity_init, .identity_show, .peer_list, .private_init, .recovery_list => {
                if (self.store.len == 0) return error.InvalidInput;
                return;
            },
            .peer_add, .peer_revoke => {
                if (self.store.len == 0 or self.paired.len == 0) return error.InvalidInput;
                if (self.mode == .peer_add) {
                    if (self.fingerprint.len != 64) return error.InvalidInput;
                    for (self.fingerprint.slice()) |ch| {
                        if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f') or (ch >= 'A' and ch <= 'F'))) return error.InvalidInput;
                    }
                }
                return;
            },
            else => {},
        }
        if (self.queue_action.len != 0 and !std.mem.eql(u8, self.queue_action, "enqueue")) {
            if (self.mode != .send or self.store.len == 0) return error.InvalidInput;
            return;
        }
        if (self.quic and (self.advertise or (self.mode != .send and self.mode != .receive))) return error.InvalidInput;
        if (self.routed and (self.advertise or (self.mode != .send and self.mode != .receive and !pairingMode(self.mode)))) return error.InvalidInput;
        if (self.routed and ((self.mode == .receive and !self.root_connect) or self.mode == .pair_host or self.root_service) and self.allowed_source.len == 0) return error.InvalidInput;
        if (self.bind.len == 0) return error.InvalidInput;
        if (self.mode == .discover) return;
        if (self.store.len == 0 or self.paired.len == 0) return error.InvalidInput;
        if (self.batch and (self.advertise or (self.mode != .send and self.mode != .receive))) return error.InvalidInput;
        if (self.batch and self.channels.len != 0) {
            const n = std.fmt.parseInt(u8, self.channels.slice(), 10) catch return error.InvalidInput;
            if (n > 32) return error.InvalidInput;
        }
        if (self.mode == .send and ((!self.root_service and self.peer.len == 0) or (self.source.len == 0 and self.sources.len == 0 and self.clipboard.len == 0))) return error.InvalidInput;
        if (self.mode == .pair_host and self.port.len == 0) return error.InvalidInput;
        if (self.mode == .pair_join and self.peer.len == 0) return error.InvalidInput;
        if (self.root_service and self.port.len == 0) return error.InvalidInput;
        if (self.root_connect and self.peer.len == 0) return error.InvalidInput;
        if (self.mode == .receive and !self.sync_clipboard and (self.destination.len == 0 or self.spool.len == 0)) return error.InvalidInput;
        if (self.mode == .receive and self.sync_clipboard and self.clipboard.len == 0) return error.InvalidInput;
    }
};

pub fn configured() bool {
    return config.lan_sha256.len == 64 and config.local_sha256.len == 64 and config.worker_sha256.len == 64;
}

pub fn pairingConfigured() bool {
    return configured() and config.pake_sha256.len == 64;
}

pub fn pairingMode(mode: Mode) bool {
    return mode == .pair_host or mode == .pair_join;
}

pub fn parseCode(value: []const u8) !u32 {
    if (value.len != 8) return error.InvalidInput;
    for (value) |c| if (!std.ascii.isDigit(c)) return error.InvalidInput;
    // Zero denotes no code; 00000000 is a valid code.
    return (try std.fmt.parseInt(u32, value, 10)) + 1;
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
extern "kernel32" fn GetLongPathNameW([*:0]const u16, [*]u16, u32) callconv(.winapi) u32;
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
extern "kernel32" fn CreatePipe(*Handle, *Handle, *const Security, u32) callconv(.winapi) i32;
extern "kernel32" fn SetHandleInformation(Handle, u32, u32) callconv(.winapi) i32;
extern "kernel32" fn PeekNamedPipe(Handle, ?*anyopaque, u32, ?*u32, *u32, ?*u32) callconv(.winapi) i32;
extern "kernel32" fn WriteFile(Handle, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
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
    if (GetFileType(file) != 1 or GetFileInformationByHandle(file, &info) == 0) return error.ImageIdentity;
    if (info.attributes & 0x410 != 0 or info.links != 1) return error.ImageNotOrdinary;
    if (info.high != 0 or info.low == 0 or info.low > 256 * 1024 * 1024) return error.ImageSize;
    const expected_path = std.mem.sliceTo(path, 0);
    var actual: [1032]u16 = undefined;
    const n = GetFinalPathNameByHandleW(file, &actual, actual.len, 0);
    if (n == 0 or n >= actual.len) return error.ImagePathRead;
    if (n != expected_path.len + 4 or
        !std.mem.eql(u16, actual[0..4], std.unicode.wtf8ToWtf16LeStringLiteral("\\\\?\\")) or
        CompareStringOrdinal(actual[4..n].ptr, @intCast(expected_path.len), expected_path.ptr, @intCast(expected_path.len), 1) != 2) return error.ImagePathMismatch;
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

fn moduleRoot(anchor: *const anyopaque, out: *Path) ![]const u16 {
    var module: Handle = 0;
    if (GetModuleHandleExW(6, anchor, &module) == 0) return error.ModulePath;
    var module_path: Path = @splat(0);
    const length = GetModuleFileNameW(module, &module_path, module_path.len);
    if (length < 4 or length >= module_path.len) return error.ModulePath;
    // Expand DOS 8.3 aliases, but retain directory junctions in the expected
    // path so the later open-handle final-path check still detects redirects.
    const n = GetLongPathNameW(&module_path, out, out.len);
    if (n < 4 or n >= out.len or out[1] != ':' or out[2] != '\\') return error.ModulePath;
    const drive = [_:0]u16{ out[0], ':', '\\' };
    if (GetDriveTypeW(&drive) != 3) return error.ModulePath;
    const split = std.mem.lastIndexOfScalar(u16, out[0..n], '\\') orelse return error.ModulePath;
    return out[0 .. split + 1];
}

pub fn launchDesktop(digest: []const u8, source: []const u8, ctx: *const raw.PulseTaskContext) !void {
    if (comptime builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.UnsupportedPlatform;
    if (source.len == 0 or source.len > 4096 or cancelled(ctx)) return error.Cancelled;
    var module_path: Path = undefined;
    const root = try moduleRoot(@ptrCast(&launchDesktop), &module_path);
    const image = try sibling(root, "pulse-share-desktop.exe");
    const image_pin = try pin(&image, digest);
    defer _ = CloseHandle(image_pin);
    const security: Security = .{};
    var reader: Handle = 0;
    var writer: Handle = 0;
    if (CreatePipe(&reader, &writer, &security, 8192) == 0) return error.Pipe;
    defer _ = CloseHandle(reader);
    defer _ = CloseHandle(writer);
    if (SetHandleInformation(writer, 1, 0) == 0) return error.Pipe;
    // Fill the entire bounded frame before starting the reader. No stdout,
    // file paths, settings or secrets are inherited outside this one pipe.
    var written: u32 = 0;
    if (WriteFile(writer, source.ptr, @intCast(source.len), &written, null) == 0 or written != source.len) return error.Pipe;

    var size: usize = 0;
    _ = InitializeProcThreadAttributeList(null, 1, 0, &size);
    if (size == 0 or size > 65536) return error.Attributes;
    const storage = try std.heap.page_allocator.alignedAlloc(u8, .of(usize), size);
    defer std.heap.page_allocator.free(storage);
    const attrs: *anyopaque = @ptrCast(storage.ptr);
    if (InitializeProcThreadAttributeList(attrs, 1, 0, &size) == 0) return error.Attributes;
    defer DeleteProcThreadAttributeList(attrs);
    if (UpdateProcThreadAttribute(attrs, 0, 0x00020002, &reader, @sizeOf(Handle), null, null) == 0) return error.Attributes;

    var command: Command = .{};
    try command.wide(std.mem.sliceTo(&image, 0));
    var pipe_text: [32]u8 = undefined;
    try command.pair("--handoff", try std.fmt.bufPrint(&pipe_text, "{x}", .{reader}));
    var cwd: Path = @splat(0);
    const cwd_len = GetSystemDirectoryW(&cwd, cwd.len);
    if (cwd_len == 0 or cwd_len >= cwd.len) return error.SystemDirectory;
    if (cancelled(ctx)) return error.Cancelled;
    var startup: StartupEx = .{ .attributes = attrs };
    var child: Process = .{};
    if (CreateProcessW(&image, &command.data, null, null, 1, 0x00080000, null, &cwd, &startup, &child) == 0) return error.Spawn;
    // The visible desktop product owns its tasks even if Pulse exits.
    _ = CloseHandle(child.thread);
    _ = CloseHandle(child.process);
}

pub fn readHandoff(handle_text: []const u8, out: []u8) ![]const u8 {
    const handle = try std.fmt.parseInt(Handle, handle_text, 16);
    if (handle == 0 or handle == invalid or GetFileType(handle) != 3) return error.Pipe;
    defer _ = CloseHandle(handle);
    var available: u32 = 0;
    if (PeekNamedPipe(handle, null, 0, null, &available, null) == 0 or available == 0 or available > out.len) return error.Pipe;
    var count: u32 = 0;
    if (ReadFile(handle, out.ptr, available, &count, null) == 0 or count != available) return error.Pipe;
    return out[0..count];
}

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

// UI writes only an answer for the exact prompt generation shown by Refresh.
// Host task owns all pipe handles and never invokes UI functions.
pub const Decisions = struct {
    answer: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    join_code: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    display_code: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

    pub fn submit(self: *Decisions, generation: u32, yes: bool) void {
        self.answer.store(generation * 2 + @as(u32, if (yes) 1 else 0), .release);
    }
};

const Output = struct {
    line: [4096]u8 = undefined,
    len: usize = 0,
    generation: u32 = 0,
    waiting: bool = false,
    inventory: [3000]u8 = undefined,
    inventory_len: usize = 0,
    inventory_truncated: bool = false,
    had_report: bool = false,
    child_cancelled: bool = false,
    done_bytes: u64 = 0,
    total_bytes: u64 = 0,

    fn report(self: *Output, ctx: *const raw.PulseTaskContext, msg: []const u8) void {
        self.had_report = true;
        var p = std.mem.zeroes(raw.PulseTaskProgress);
        p.size = @sizeOf(raw.PulseTaskProgress);
        p.percent = std.math.maxInt(u32);
        p.completed_bytes = self.done_bytes;
        p.total_bytes = self.total_bytes;
        p.current_item = .{ .data = msg.ptr, .length = @intCast(msg.len) };
        if (ctx.report) |send| _ = send(ctx.context, &p);
    }

    fn writeAnswer(input: Handle, bytes: []const u8) !void {
        var n: u32 = 0;
        if (WriteFile(input, bytes.ptr, @intCast(bytes.len), &n, null) == 0 or n != bytes.len) return error.PromptWrite;
    }

    fn consume(self: *Output, byte: u8, input: Handle, request: *const Request, ctx: *const raw.PulseTaskContext, decisions: *Decisions) !void {
        if (byte == '\r') return;
        if (byte != '\n') {
            if (self.len == self.line.len) return error.OutputLimit;
            self.line[self.len] = byte;
            self.len += 1;
            return;
        }
        const line = self.line[0..self.len];
        defer self.len = 0;
        if (!std.unicode.utf8ValidateSlice(line)) return error.OutputEncoding;
        self.child_cancelled = std.mem.eql(u8, line, "Pulse Share: context canceled");
        if (std.mem.startsWith(u8, line, "PAIRCODE ")) {
            defer @memset(self.line[0..self.len], 0);
            if (request.mode != .pair_host) return error.OutputProtocol;
            if (std.mem.eql(u8, line, "PAIRCODE CLEAR")) {
                decisions.display_code.store(0, .release);
            } else {
                var parts = std.mem.splitScalar(u8, line[9..], ' ');
                const code = try parseCode(parts.next() orelse return error.OutputProtocol);
                const seconds = std.fmt.parseInt(u32, parts.next() orelse return error.OutputProtocol, 10) catch return error.OutputProtocol;
                if (parts.next() != null or seconds == 0 or seconds > 60) return error.OutputProtocol;
                decisions.display_code.store((@as(u64, seconds) << 32) | code, .release);
            }
            return;
        }
        if (std.mem.eql(u8, line, "PAIRINPUT")) {
            if (request.mode != .pair_join or cancelled(ctx)) return error.OutputProtocol;
            const code = decisions.join_code.swap(0, .acq_rel);
            if (code == 0 or code > 100000000) return error.OutputProtocol;
            var secret: [9]u8 = undefined;
            defer @memset(&secret, 0);
            const answer = try std.fmt.bufPrint(&secret, "{d:0>8}\n", .{code - 1});
            return writeAnswer(input, answer);
        }
        if (std.mem.startsWith(u8, line, "Enter the other device's full fingerprint") and request.mode == .peer_add) {
            var pin_line: [65]u8 = undefined;
            @memcpy(pin_line[0..64], request.fingerprint.slice());
            pin_line[64] = '\n';
            return writeAnswer(input, &pin_line);
        }
        if (std.mem.startsWith(u8, line, "PROGRESS ")) {
            var parts = std.mem.splitScalar(u8, line[9..], ' ');
            const done = std.fmt.parseInt(u64, parts.next() orelse return error.OutputProtocol, 10) catch return error.OutputProtocol;
            const total = std.fmt.parseInt(u64, parts.next() orelse return error.OutputProtocol, 10) catch return error.OutputProtocol;
            if (parts.next() != null or done > total or done < self.done_bytes or total < self.total_bytes or total > 1024 * 1024 * 1024 * @as(u64, 1024)) return error.OutputProtocol;
            self.done_bytes = done;
            self.total_bytes = total;
            self.report(ctx, line);
            return;
        }
        if (std.mem.startsWith(u8, line, "OFFER ") or std.mem.startsWith(u8, line, "Trust ") or std.mem.startsWith(u8, line, "Revoke ")) {
            if (self.waiting or self.generation >= 16) return error.PromptProtocol;
            self.generation += 1;
            self.waiting = true;
            var msg: [4096]u8 = undefined;
            var prefix_buf: [24]u8 = undefined;
            const prefix = try std.fmt.bufPrint(&prefix_buf, "PROMPT {d} ", .{self.generation});
            var fit = @min(line.len, msg.len - prefix.len);
            while (fit > 0 and !std.unicode.utf8ValidateSlice(line[0..fit])) fit -= 1;
            @memcpy(msg[0..prefix.len], prefix);
            @memcpy(msg[prefix.len..][0..fit], line[0..fit]);
            self.report(ctx, msg[0 .. prefix.len + fit]);
        } else if (!self.waiting and line.len != 0) {
            if (request.mode == .discover or request.mode == .peer_list or request.mode == .recovery_list or request.mode == .interfaces or std.mem.eql(u8, request.queue_action, "list") or (request.browse and request.mode == .receive and request.remote_path.len == 0)) {
                if (!self.inventory_truncated and line.len + 2 + 32 <= self.inventory.len - self.inventory_len) {
                    @memcpy(self.inventory[self.inventory_len..][0..line.len], line);
                    self.inventory_len += line.len;
                    self.inventory[self.inventory_len] = '\r';
                    self.inventory[self.inventory_len + 1] = '\n';
                    self.inventory_len += 2;
                } else if (!self.inventory_truncated) {
                    const note = "[inventory truncated]\r\n";
                    @memcpy(self.inventory[self.inventory_len..][0..note.len], note);
                    self.inventory_len += note.len;
                    self.inventory_truncated = true;
                }
                self.report(ctx, self.inventory[0..self.inventory_len]);
            } else self.report(ctx, line);
        }
    }

    fn pump(self: *Output, output: Handle, input: Handle, request: *const Request, ctx: *const raw.PulseTaskContext, decisions: *Decisions) !void {
        // Bound work per tick. The child cannot block the UI or allocate
        // unbounded output in the host; on protocol error the job is drained.
        var available: u32 = 0;
        if (PeekNamedPipe(output, null, 0, null, &available, null) != 0 and available != 0) {
            var bytes: [4096]u8 = undefined;
            var got: u32 = 0;
            if (ReadFile(output, &bytes, @min(available, @as(u32, bytes.len)), &got, null) == 0) return error.OutputRead;
            defer @memset(bytes[0..got], 0);
            for (bytes[0..got]) |byte| try self.consume(byte, input, request, ctx, decisions);
        }
        if (self.waiting and !cancelled(ctx)) {
            const answer = decisions.answer.load(.acquire);
            if (answer >= 2 and answer / 2 == self.generation) {
                try writeAnswer(input, if (answer & 1 != 0) "yes\n" else "no\n");
                self.waiting = false;
                self.report(ctx, "Confirmation sent / 已提交确认");
            }
        }
    }
};

pub fn run(request: *const Request, ctx: *const raw.PulseTaskContext, decisions: *Decisions) !void {
    if (comptime builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.UnsupportedPlatform;
    var output: Output = .{};
    defer {
        decisions.join_code.store(0, .release);
        decisions.display_code.store(0, .release);
        @memset(&output.line, 0);
    }
    runInner(request, ctx, decisions, &output) catch |err| {
        if (err != error.ChildFailed or !output.had_report) output.report(ctx, @errorName(err));
        return err;
    };
}

fn runInner(request: *const Request, ctx: *const raw.PulseTaskContext, decisions: *Decisions, output: *Output) !void {
    if (comptime builtin.os.tag != .windows or builtin.cpu.arch != .x86_64) return error.UnsupportedPlatform;
    try request.validate();
    if (!configured()) return error.Unconfigured;
    if (cancelled(ctx)) return error.Cancelled;
    var module_path: Path = undefined;
    const root = try moduleRoot(@ptrCast(&run), &module_path);
    const lan = try sibling(root, "pulse-share-lan.exe");
    const local = try sibling(root, "pulse-share-local.exe");
    const worker = try sibling(root, "pulse-share-worker.exe");
    const lan_pin = try pin(&lan, config.lan_sha256);
    defer _ = CloseHandle(lan_pin);
    const local_pin = try pin(&local, config.local_sha256);
    defer _ = CloseHandle(local_pin);
    const worker_pin = try pin(&worker, config.worker_sha256);
    defer _ = CloseHandle(worker_pin);
    var pake: Path = @splat(0);
    var pake_pin: Handle = 0;
    defer if (pake_pin != 0) {
        _ = CloseHandle(pake_pin);
    };
    if (pairingMode(request.mode)) {
        if (!pairingConfigured()) return error.Unconfigured;
        pake = try sibling(root, "pulse-share-pake.exe");
        pake_pin = try pin(&pake, config.pake_sha256);
    }
    const security: Security = .{};
    const event = CreateEventW(&security, 1, 0, null);
    if (event == 0) return error.Event;
    defer _ = CloseHandle(event);
    var command: Command = .{};
    try command.wide(std.mem.sliceTo(&lan, 0));
    var handle_text: [32]u8 = undefined;
    try command.pair("--managed-cancel-handle", try std.fmt.bufPrint(&handle_text, "{x}", .{event}));
    try command.arg(switch (request.mode) {
        .identity_init => "identity-init",
        .identity_show => "identity-show",
        .peer_add => "peer-add",
        .peer_list => "peer-list",
        .peer_revoke => "peer-revoke",
        .private_init => "private-init",
        .recovery_list => "recovery-list",
        .pair_host => "pair-host",
        .pair_join => "pair-join",
        .device_prepare => "device-prepare",
        else => @tagName(request.mode),
    });
    switch (request.mode) {
        .discover, .send, .receive, .pair_host, .pair_join => try command.pair("--bind", request.bind.slice()),
        else => {},
    }
    if (request.routed) try command.arg("--routed");
    if (request.quic) try command.arg("--quic");
    if (request.queue_action.len != 0) {
        try command.pair("--queue-action", request.queue_action);
        if (request.queue_id.len != 0) try command.pair("--queue-id", request.queue_id.slice());
        if (request.browse_offset.len != 0) try command.pair("--queue-offset", request.browse_offset.slice());
    }
    if (request.sync_clipboard) try command.arg("--sync-clipboard");
    if (request.batch) {
        try command.arg("--batch");
        if (request.channels.len != 0) try command.pair("--channels", request.channels.slice());
    }
    switch (request.mode) {
        .discover, .interfaces => {},
        .device_prepare => {
            try command.pair("--store", request.store.slice());
            try command.pair("--spool", request.spool.slice());
        },
        .pair_host, .pair_join => {
            try command.pair("--store", request.store.slice());
            try command.pair("--name", request.paired.slice());
            try command.arg("--pake");
            try command.wide(std.mem.sliceTo(&pake, 0));
            if (request.mode == .pair_host) {
                if (request.advertise) try command.arg("--advertise");
                try command.pair("--port", request.port.slice());
                if (request.routed) try command.pair("--allowed-source", request.allowed_source.slice());
            } else {
                try command.pair("--peer", request.peer.slice());
            }
        },
        .identity_init, .identity_show, .peer_list, .private_init, .recovery_list => try command.pair("--store", request.store.slice()),
        .peer_add, .peer_revoke => {
            try command.pair("--store", request.store.slice());
            try command.pair("--name", request.paired.slice());
        },
        .send => {
            try command.pair("--peer", request.peer.slice());
            if (request.root_service) {
                try command.arg("--root-service");
                try command.pair("--port", request.port.slice());
                if (request.routed) try command.pair("--allowed-source", request.allowed_source.slice());
            }
            if (request.batch) {
                if (request.sources.len != 0) try command.pair("--sources", request.sources.slice());
                if (request.clipboard.len != 0) try command.pair("--clipboard", request.clipboard.slice());
                if (request.browse) try command.arg("--share-root");
            } else try command.pair("--source", request.source.slice());
            try command.pair("--store", request.store.slice());
            try command.pair("--paired", request.paired.slice());
        },
        .receive => {
            if (request.root_connect) {
                try command.arg("--root-connect");
                try command.pair("--peer", request.peer.slice());
            }
            if (request.batch) {
                if (request.resume_path.len != 0) try command.pair("--resume", request.resume_path.slice());
                if (request.clipboard_receive) {
                    try command.arg("--accept-clipboard");
                    if (request.clipboard.len != 0) try command.pair("--clipboard-type", request.clipboard.slice());
                }
                if (request.delivery.len != 0) try command.pair("--delivery", request.delivery.slice());
                if (request.browse) {
                    try command.arg("--browse");
                    if (request.remote_path.len != 0) try command.pair("--remote-path", request.remote_path.slice());
                    if (request.browse_offset.len != 0) try command.pair("--browse-offset", request.browse_offset.slice());
                }
            }
            if (request.advertise) try command.arg("--advertise");
            if (request.routed and !request.root_connect) try command.pair("--allowed-source", request.allowed_source.slice());
            try command.pair("--port", if (request.port.len == 0) "0" else request.port.slice());
            try command.pair("--directory", request.destination.slice());
            try command.pair("--spool", request.spool.slice());
            if (request.prepare_spool) try command.arg("--prepare-spool");
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
    var input_read: Handle = 0;
    var input_write: Handle = 0;
    var output_read: Handle = 0;
    var output_write: Handle = 0;
    defer if (input_read != 0) {
        _ = CloseHandle(input_read);
    };
    defer if (input_write != 0) {
        _ = CloseHandle(input_write);
    };
    defer if (output_read != 0) {
        _ = CloseHandle(output_read);
    };
    defer if (output_write != 0) {
        _ = CloseHandle(output_write);
    };
    if (CreatePipe(&input_read, &input_write, &security, 4096) == 0 or
        CreatePipe(&output_read, &output_write, &security, 8192) == 0) return error.Pipe;
    if (SetHandleInformation(input_write, 1, 0) == 0 or SetHandleInformation(output_read, 1, 0) == 0) return error.Pipe;
    const handles = [_]Handle{ event, input_read, output_write };
    if (UpdateProcThreadAttribute(attrs, 0, 0x00020002, &handles, @sizeOf(@TypeOf(handles)), null, null) == 0) return error.Attributes;
    var si: StartupEx = .{ .attributes = attrs };
    si.base.flags = 0x100;
    si.base.stdin = input_read;
    si.base.stdout = output_write;
    si.base.stderr = output_write;
    var cwd: Path = @splat(0);
    const cwd_len = GetSystemDirectoryW(&cwd, cwd.len);
    if (cwd_len == 0 or cwd_len >= cwd.len) return error.SystemDirectory;
    var child: Process = .{};
    if (cancelled(ctx)) return error.Cancelled;
    if (CreateProcessW(&lan, &command.data, null, null, 1, 0x00080000 | 4 | 0x08000000, null, &cwd, &si, &child) == 0) return error.Spawn;
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
    _ = CloseHandle(input_read);
    input_read = 0;
    _ = CloseHandle(output_write);
    output_write = 0;
    const start = GetTickCount64();
    var stop_at: ?u64 = null;
    while (true) {
        output.pump(output_read, input_write, request, ctx, decisions) catch |err| {
            if (!drain(job)) return error.Drain;
            return err;
        };
        const wait = WaitForSingleObject(child.process, 100);
        if (wait == 0) {
            for (0..16) |_| {
                var available: u32 = 0;
                if (PeekNamedPipe(output_read, null, 0, null, &available, null) == 0 or available == 0) break;
                output.pump(output_read, input_write, request, ctx, decisions) catch |err| {
                    if (!drain(job)) return error.Drain;
                    return err;
                };
            }
            break;
        }
        if (wait != 258) {
            if (!drain(job)) return error.Drain;
            return error.Wait;
        }
        const now = GetTickCount64();
        const long_lived = request.sync_clipboard or request.root_service;
        if (stop_at == null and (cancelled(ctx) or (!long_lived and now -% start >= 40 * 60 * 1000))) {
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
    if (stop_at != null or cancelled(ctx)) {
        if (output.child_cancelled and (pairingMode(request.mode) or request.mode == .discover or request.sync_clipboard or request.root_service))
            return error.Cancelled;
        return error.CancelUncertain;
    }
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

test "decision generation and bounded request admission" {
    var decisions: Decisions = .{};
    decisions.submit(1, true);
    try std.testing.expectEqual(@as(u32, 3), decisions.answer.load(.acquire));
    decisions.submit(2, false);
    try std.testing.expectEqual(@as(u32, 4), decisions.answer.load(.acquire));
    var request: Request = .{ .mode = .peer_add };
    try request.store.set("C:\\private");
    try request.paired.set("peer");
    try request.fingerprint.set("invalid");
    try std.testing.expectError(error.InvalidInput, request.validate());
    try request.fingerprint.set("0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef");
    try request.validate();
}

test "pair code exact digits and routed receive admission" {
    try std.testing.expectEqual(@as(u32, 1), try parseCode("00000000"));
    try std.testing.expectEqual(@as(u32, 100000000), try parseCode("99999999"));
    try std.testing.expectError(error.InvalidInput, parseCode("12 45678"));
    var request: Request = .{ .mode = .receive, .routed = true };
    try request.bind.set("100.64.1.1");
    try request.store.set("C:\\private");
    try request.paired.set("peer");
    try request.destination.set("C:\\received");
    try request.spool.set("C:\\spool");
    try request.port.set("0");
    try std.testing.expectError(error.InvalidInput, request.validate());
    try request.allowed_source.set("100.64.1.2");
    try request.validate();
    request.advertise = true;
    try std.testing.expectError(error.InvalidInput, request.validate());
}
