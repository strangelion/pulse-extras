const std = @import("std");
const abi = @import("pulse_abi");
const raw = @import("pulse_raw");
const managed = @import("managed.zig");

pub const State = enum { running, cancelling, completed, cancelled, failed };

pub const Snapshot = struct {
    state: State = .running,
    text: [4096]u8 = undefined,
    len: usize = 0,
    done: u64 = 0,
    total: u64 = 0,
    endpoint: [96]u8 = undefined,
    endpoint_len: usize = 0,
    clipboard_sync_active: bool = false,

    pub fn listeningAddress(self: *const Snapshot) []const u8 {
        return self.endpoint[0..self.endpoint_len];
    }

    pub fn message(self: *const Snapshot) []const u8 {
        return self.text[0..self.len];
    }
};

extern fn share_desktop_prepare_default_parent() c_int;
extern "kernel32" fn CreateThread(?*anyopaque, usize, *const fn (?*anyopaque) callconv(.winapi) u32, *anyopaque, u32, ?*u32) callconv(.winapi) usize;
extern "kernel32" fn WaitForSingleObject(usize, u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(usize) callconv(.winapi) i32;
extern "kernel32" fn SwitchToThread() callconv(.winapi) i32;

pub const Task = struct {
    thread: usize = 0,
    lock: std.atomic.Mutex = .unlocked,
    cancel_requested: std.atomic.Value(bool) = .init(false),
    snapshot: Snapshot = .{},
    request: managed.Request = .{},
    decisions: managed.Decisions = .{},

    pub fn occupied(self: *const Task) bool {
        return self.thread != 0;
    }

    pub fn start(self: *Task, request: *const managed.Request, code: u32) !void {
        if (self.occupied()) return error.State;
        @memcpy(std.mem.asBytes(&self.request), std.mem.asBytes(request));
        self.snapshot = .{};
        self.cancel_requested.store(false, .release);
        self.decisions.answer.store(0, .release);
        self.decisions.display_code.store(0, .release);
        self.decisions.join_code.store(code, .release);
        self.thread = CreateThread(null, 0, &work, self, 0, null);
        if (self.thread == 0) {
            self.decisions.join_code.store(0, .release);
            return error.WorkerStart;
        }
    }

    pub fn cancel(self: *Task) void {
        self.cancel_requested.store(true, .release);
        self.decisions.display_code.store(0, .release);
    }

    pub fn poll(self: *Task) ?Snapshot {
        // A missed UI sample is harmless. Never wait for a worker on the UI thread.
        if (!self.lock.tryLock()) return null;
        defer self.lock.unlock();
        var result = self.snapshot;
        if (result.state == .running and self.cancel_requested.load(.acquire)) result.state = .cancelling;
        return result;
    }

    pub fn reap(self: *Task) bool {
        if (!self.occupied()) return true;
        if (WaitForSingleObject(self.thread, 0) != 0) return false;
        _ = CloseHandle(self.thread);
        self.thread = 0;
        return true;
    }

    fn cancelled(user: ?*anyopaque) callconv(.c) u32 {
        const self: *Task = @ptrCast(@alignCast(user orelse return 1));
        return @intFromBool(self.cancel_requested.load(.acquire));
    }

    fn report(user: ?*anyopaque, value: [*c]const raw.PulseTaskProgress) callconv(.c) abi.Status {
        const self: *Task = @ptrCast(@alignCast(user orelse return abi.error_argument));
        if (value == null) return abi.error_argument;
        const message = abi.slice(value.*.current_item) orelse return abi.error_argument;
        if (message.len > self.snapshot.text.len) return abi.error_argument;
        while (!self.lock.tryLock()) _ = SwitchToThread();
        defer self.lock.unlock();
        @memcpy(self.snapshot.text[0..message.len], message);
        self.snapshot.len = message.len;
        self.snapshot.done = value.*.completed_bytes;
        self.snapshot.total = value.*.total_bytes;
        if (std.mem.eql(u8, message, "CLIPBOARD SYNC active; cancel to stop")) self.snapshot.clipboard_sync_active = true;
        if (std.mem.startsWith(u8, message, "LISTEN ")) {
            const address = message["LISTEN ".len..];
            if (address.len <= self.snapshot.endpoint.len) {
                @memcpy(self.snapshot.endpoint[0..address.len], address);
                self.snapshot.endpoint_len = address.len;
            }
        }
        return abi.ok;
    }

    fn execute(self: *Task, ctx: *const raw.PulseTaskContext) !void {
        if (cancelled(self) != 0) return error.Cancelled;
        if (self.request.prepare_default_parent and share_desktop_prepare_default_parent() == 0) {
            const message = abi.view("无法准备 Share 的本机目录，请检查设置。");
            var progress = std.mem.zeroes(raw.PulseTaskProgress);
            progress.current_item = message;
            _ = report(self, &progress);
            return error.DefaultDirectory;
        }
        return managed.run(&self.request, ctx, &self.decisions);
    }

    fn work(user: ?*anyopaque) callconv(.winapi) u32 {
        const self: *Task = @ptrCast(@alignCast(user orelse return 1));
        const ctx: raw.PulseTaskContext = .{ .context = self, .report = report, .cancelled = cancelled };
        const result: State = if (self.execute(&ctx)) .completed else |err| if (err == error.Cancelled) .cancelled else .failed;
        while (!self.lock.tryLock()) _ = SwitchToThread();
        self.snapshot.state = result;
        self.lock.unlock();
        return 0;
    }
};
