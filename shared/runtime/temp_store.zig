//! Explicit session-owned temporary file store. Caller supplies an already
//! private directory handle, not a user-selected directory. Never scans,
//! deletes recursively, follows arbitrary paths, or removes preexisting files.
//! Exclusive create, bounded file count and conservative byte accounting.
//! External writers must not modify the directory or its files.

const std = @import("std");

pub const Store = struct {
    const capacity = 8;
    const Entry = struct {
        id: u64,
        file: ?std.Io.File,
        reserved: usize = 0,
        sealed: bool = false,
        failed: bool = false,
    };
    io: std.Io,
    dir: std.Io.Dir,
    limit: usize,
    used: usize = 0,
    next_id: u64 = 1,
    entries: [capacity]?Entry = @splat(null),

    pub fn init(io: std.Io, private_dir: std.Io.Dir, byte_limit: usize) Store {
        return .{ .io = io, .dir = private_dir, .limit = byte_limit };
    }

    fn name(id: u64, buffer: []u8) []const u8 {
        return std.fmt.bufPrint(buffer, "pulse-runtime-{d}.tmp", .{id}) catch unreachable;
    }

    pub fn create(self: *Store) !u64 {
        for (&self.entries) |*slot| {
            if (slot.* != null) continue;
            if (self.next_id == std.math.maxInt(u64)) return error.ResourceLimit;
            const id = self.next_id;
            self.next_id += 1;
            var buffer: [64]u8 = undefined;
            const file = try self.dir.createFile(self.io, name(id, &buffer), .{ .exclusive = true, .read = true });
            slot.* = .{ .id = id, .file = file };
            return id;
        }
        return error.ResourceLimit;
    }

    fn find(self: *Store, id: u64) ?*Entry {
        for (&self.entries) |*slot| {
            if (slot.*) |*entry| {
                if (entry.id == id) return entry;
            }
        }
        return null;
    }

    pub fn append(self: *Store, id: u64, bytes: []const u8) !void {
        const entry = self.find(id) orelse return error.NotOwned;
        const file = entry.file orelse return error.Closed;
        if (entry.sealed or entry.failed) return error.Closed;
        if (bytes.len > self.limit - self.used) return error.ResourceLimit;
        // A failed write might be partial; conservatively retain the charge
        // until deletion instead of assuming no disk space was consumed.
        self.used += bytes.len;
        entry.reserved += bytes.len;
        file.writeStreamingAll(self.io, bytes) catch |err| {
            entry.failed = true;
            return err;
        };
    }

    /// Borrow the owned file for positional reads after transfer completes.
    /// The borrower must not close or mutate it; owner outlives all readers.
    pub fn seal(self: *Store, id: u64) !std.Io.File {
        const entry = self.find(id) orelse return error.NotOwned;
        const file = entry.file orelse return error.Closed;
        if (entry.failed) return error.Closed;
        entry.sealed = true;
        return file;
    }

    pub fn remove(self: *Store, id: u64) !void {
        for (&self.entries) |*slot| {
            const entry = if (slot.*) |*value| value else continue;
            if (entry.id != id) continue;
            if (entry.file) |file| file.close(self.io);
            entry.file = null;
            var buffer: [64]u8 = undefined;
            self.dir.deleteFile(self.io, name(id, &buffer)) catch |err| switch (err) {
                error.FileNotFound => {},
                else => return err,
            };
            self.used -= entry.reserved;
            slot.* = null;
            return;
        }
        return error.NotOwned;
    }

    /// Attempt every owned entry even when one deletion fails; retain failed
    /// entries for retry and report failure. Directory ownership is external.
    pub fn cleanup(self: *Store) error{CleanupFailed}!void {
        var failed = false;
        for (&self.entries) |*slot| {
            const id = if (slot.*) |value| value.id else continue;
            self.remove(id) catch {
                failed = true;
            };
        }
        if (failed) return error.CleanupFailed;
    }

    /// Replace an owned temporary snapshot only after a complete new write.
    /// Both files count against the quota during the replacement. On old-file
    /// deletion failure retain both entries and return the new id explicitly.
    pub const Rotation = struct {
        current: u64,
        retired: ?u64 = null,
    };

    pub fn rotate(self: *Store, previous: ?u64, bytes: []const u8) !Rotation {
        if (previous) |id| {
            if (self.find(id) == null) return error.NotOwned;
        }
        if (bytes.len > self.limit - self.used) return error.ResourceLimit;
        const current = try self.create();
        errdefer self.remove(current) catch {};
        try self.append(current, bytes);
        if (previous) |id| {
            self.remove(id) catch return .{ .current = current, .retired = id };
        }
        return .{ .current = current };
    }

    pub fn checkDrained(self: *const Store) error{OutstandingFiles}!void {
        for (self.entries) |entry| {
            if (entry != null) return error.OutstandingFiles;
        }
        if (self.used != 0) return error.OutstandingFiles;
    }
};

test "temporary store enforces limits and cleans only its own files" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    const external = try tmp.dir.createFile(io, "pulse-runtime-1.tmp", .{ .exclusive = true });
    try external.writeStreamingAll(io, "keep");
    external.close(io);
    var store = Store.init(io, tmp.dir, 8);
    defer store.cleanup() catch {};
    try std.testing.expectError(error.PathAlreadyExists, store.create());
    const id = try store.create();
    try store.append(id, "12345678");
    try std.testing.expectError(error.ResourceLimit, store.append(id, "9"));
    try std.testing.expectError(error.NotOwned, store.remove(1));
    try std.testing.expectError(error.OutstandingFiles, store.checkDrained());
    try store.cleanup();
    try store.checkDrained();
    const preserved = try tmp.dir.openFile(io, "pulse-runtime-1.tmp", .{});
    defer preserved.close(io);
    var bytes: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try preserved.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings("keep", &bytes);
}

test "rotation preserves old snapshot on admission failure and returns quota on success" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var store = Store.init(std.testing.io, tmp.dir, 8);
    defer store.cleanup() catch {};
    const initial = try store.rotate(null, "old");
    try std.testing.expectError(error.ResourceLimit, store.rotate(initial.current, "123456"));
    try std.testing.expectEqual(@as(usize, 3), store.used);
    const replacement = try store.rotate(initial.current, "new!");
    try std.testing.expect(replacement.retired == null);
    try std.testing.expectError(error.NotOwned, store.remove(initial.current));
    try std.testing.expectEqual(@as(usize, 4), store.used);
    try store.cleanup();
    try store.checkDrained();
}

test "sealed temporary files retain quota and reject further writes" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const io = std.testing.io;
    var store = Store.init(io, tmp.dir, 4);
    defer store.cleanup() catch {};
    const id = try store.create();
    try store.append(id, "data");
    const borrowed = try store.seal(id);
    try std.testing.expectError(error.Closed, store.append(id, "x"));
    var bytes: [4]u8 = undefined;
    try std.testing.expectEqual(@as(usize, 4), try borrowed.readPositionalAll(io, &bytes, 0));
    try std.testing.expectEqualStrings("data", &bytes);
    try std.testing.expectEqual(@as(usize, 4), store.used);
    try std.testing.expectError(error.OutstandingFiles, store.checkDrained());
    // The borrowed handle is no longer used; only the store closes it.
    try store.remove(id);
    try std.testing.expectError(error.NotOwned, store.seal(id));
    try store.checkDrained();
}
