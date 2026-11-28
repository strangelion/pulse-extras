//! A Git index replacement that honours Git's own exclusive index.lock.
//! The caller supplies a verified ordinary metadata directory and an isolated
//! scratch directory. Keep the transaction on the worker that opened it.
const std = @import("std");
const builtin = @import("builtin");
const process = @import("pulse_process");
const contract = @import("vcs_provider");
const approval = @import("vcs_approval");
const identity = @import("vcs_identity");
const windows = @import("vcs_windows_evidence");
const trust = @import("process_trust");
const review = @import("git_index_review.zig");

pub const image_name = "index";
const lock_name = "index.lock";
const max_index_bytes = 8 * 1024 * 1024;

pub const Digest = [32]u8;
const Sha256 = std.crypto.hash.sha2.Sha256;

pub const Action = review.Action;
pub const Plan = review.Plan;

fn fileIdentity(observed: windows.FileIdentity) [12]u8 {
    var bytes: [12]u8 = undefined;
    std.mem.writeInt(u32, bytes[0..4], observed.volume, .little);
    std.mem.writeInt(u64, bytes[4..12], observed.index, .little);
    return bytes;
}

fn stamp(observed: windows.ContentStamp) review.FileStamp {
    return .{ .identity = fileIdentity(observed.identity), .contents = observed.digest };
}

fn joined(base: []const u8, relative: []const u8) !identity.Path {
    var buffer: [identity.max_path_bytes]u8 = undefined;
    const path = try std.fmt.bufPrint(&buffer, "{s}\\{s}", .{ base, relative });
    for (buffer[base.len..path.len]) |*byte| {
        if (byte.* == '/') byte.* = '\\';
    }
    return identity.Path.init(path);
}

fn observeOptionalFile(path: []const u8, limit: u32) !?review.FileStamp {
    windows.requireAbsent(path) catch return stamp(try windows.observeFileContents(path, limit));
    return null;
}

fn readStamped(path: []const u8, buffer: []u8) !struct { text: []const u8, file: review.FileStamp } {
    const file = stamp(try windows.observeFileContents(path, @intCast(buffer.len)));
    const text = try windows.readPreviewFile(path, buffer);
    var digest: Digest = undefined;
    Sha256.hash(text, &digest, .{});
    if (!std.mem.eql(u8, &file.contents, &digest)) return error.IndexReviewChanged;
    return .{ .text = text, .file = file };
}

/// Capture the write review without running Git. The initial supported scope
/// is an ordinary local Git checkout with a loose HEAD reference or a detached
/// HEAD and a complete standalone index.
pub fn observePlan(io: std.Io, scope: Plan.Scope) !Plan {
    if (comptime builtin.os.tag != .windows) return error.UnsupportedGitProfile;
    const root = scope.root.slice();
    const tool = scope.tool.slice();
    if (!approval.strictPath(root) or !approval.strictPath(tool) or !std.ascii.eqlIgnoreCase(std.fs.path.basename(tool), "git.exe") or !contract.safeRelativePath(scope.path.slice())) return error.InvalidGitPath;
    const git = try joined(root, ".git");
    const repository_identity = fileIdentity(try windows.observeIdentity(root, true));
    const git_identity = fileIdentity(try windows.observeIdentity(git.slice(), true));
    for ([_][]const u8{ ".jj", ".svn", ".hg", ".gitmodules", ".gitattributes" }) |leaf| {
        const path = try joined(root, leaf);
        try windows.requireAbsent(path.slice());
    }
    for ([_][]const u8{ "commondir", "config.worktree", "worktrees", "modules", "shallow", "MERGE_HEAD", "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "rebase-merge", "rebase-apply", "info/attributes", "info/sparse-checkout", "objects/info/alternates", "objects/info/http-alternates", "refs/replace" }) |leaf| {
        const path = try joined(git.slice(), leaf);
        try windows.requireAbsent(path.slice());
    }
    const relative = scope.path.slice();
    for (relative, 0..) |byte, index| {
        if (byte != '/') continue;
        const parent = try joined(root, relative[0..index]);
        _ = try windows.observeIdentity(parent.slice(), true);
        for ([_][]const u8{ ".git", ".jj", ".svn", ".hg", ".gitattributes" }) |leaf| {
            const path = try joined(parent.slice(), leaf);
            try windows.requireAbsent(path.slice());
        }
    }
    const config_path = try joined(git.slice(), "config");
    var config_buffer: [4096]u8 = undefined;
    const config = try readStamped(config_path.slice(), &config_buffer);
    try windows.validateConfig(config.text);
    const head_path = try joined(git.slice(), "HEAD");
    var head_buffer: [256]u8 = undefined;
    const stored = try readStamped(head_path.slice(), &head_buffer);
    const pointer = std.mem.trimEnd(u8, stored.text, "\r\n");
    var reference: ?review.FileStamp = null;
    const commit = if (std.mem.startsWith(u8, pointer, "ref: ")) blk: {
        const target = pointer["ref: ".len..];
        if (!std.mem.startsWith(u8, target, "refs/heads/") or !contract.safeRelativePath(target)) return error.UnsupportedGitProfile;
        const branch = try joined(git.slice(), target);
        var reference_buffer: [64]u8 = undefined;
        const result = try readStamped(branch.slice(), &reference_buffer);
        reference = result.file;
        break :blk try review.parseObject(std.mem.trimEnd(u8, result.text, "\r\n"));
    } else try review.parseObject(pointer);
    const index_path = try joined(git.slice(), image_name);
    const index = stamp(try windows.observeFileContents(index_path.slice(), max_index_bytes));
    const selected_path = try joined(root, relative);
    const selected = try observeOptionalFile(selected_path.slice(), 16 * 1024 * 1024);
    if (scope.action == .stage and selected == null) return error.SelectedGitFileMissing;
    const executable_identity = fileIdentity(try windows.observeSessionToolIdentity(tool));
    const executable = try std.Io.Dir.openFileAbsolute(io, tool, .{ .follow_symlinks = false });
    defer executable.close(io);
    const tool_digest = try trust.digestFile(io, executable);
    if (!std.mem.eql(u8, &executable_identity, &fileIdentity(try windows.observeSessionToolIdentity(tool)))) return error.IndexReviewChanged;
    return .{
        .scope = scope,
        .evidence = .{
            .tool = .{ .identity = executable_identity, .contents = tool_digest },
            .repository = repository_identity,
            .metadata = git_identity,
            .config = config.file,
            .head = commit,
            .head_file = stored.file,
            .reference = reference,
            .index = index,
            .working_file = selected,
        },
    };
}

/// Apply only to an alternate index owned by the confirmed transaction.
/// The caller must already have reviewed the tool, repository configuration,
/// target file and HEAD, and must validate the proposal before publication.
pub fn editImage(runner: *process.Runner, executable: []const u8, repository: []const u8, scratch: []const u8, environment: *const std.process.Environ.Map, action: Action, path: []const u8, head: review.Object) !void {
    if (runner.policy != .approved_local or !runner.git_index_isolation) return error.UnsupportedGitProfile;
    if (comptime builtin.os.tag == .windows) {
        if (runner.tree_policy != .windows_job) return error.UnsupportedGitProfile;
    }
    if (!contract.safeRelativePath(path)) return error.InvalidGitPath;
    _ = try review.parseObject(&head);
    var hooks_buffer: [4096]u8 = undefined;
    const hooks = try std.fmt.bufPrint(&hooks_buffer, "core.hooksPath={s}" ++ std.fs.path.sep_str ++ "disabled-hooks", .{scratch});
    var source_buffer: [64]u8 = undefined;
    const source = try std.fmt.bufPrint(&source_buffer, "--source={s}", .{&head});
    var argv_buffer: [16][]const u8 = undefined;
    const prefix = [_][]const u8{ executable, "-C", repository, "--literal-pathspecs", "-c", hooks, "-c", "core.fsmonitor=false", "-c", "core.splitIndex=false" };
    const suffix: []const []const u8 = switch (action) {
        .stage => &.{ "add", "--", path },
        .unstage => &.{ "restore", "--staged", source, "--", path },
    };
    @memcpy(argv_buffer[0..prefix.len], &prefix);
    @memcpy(argv_buffer[prefix.len..][0..suffix.len], suffix);
    var outcome = try runner.run(.{
        .argv = argv_buffer[0 .. prefix.len + suffix.len],
        .cwd = scratch,
        .environ_map = environment,
        .timeout_ns = 15 * std.time.ns_per_s,
        .stdout_limit = 8192,
        .stderr_limit = 8192,
    });
    defer outcome.deinit();
    if (!outcome.succeeded()) return error.GitIndexCommandFailed;
}

pub const Cancellation = struct {
    check: *const fn (?*anyopaque) callconv(.c) u32,
    context: ?*anyopaque,
};

fn checkCancelled(cancel: ?Cancellation) !void {
    if (cancel) |value| {
        if (value.check(value.context) != 0) return error.Cancelled;
    }
}

/// The worker receives only a one-shot plan already confirmed by the owner.
/// Cancellation is honoured before publication. A successful rename is the
/// commit point and must be reported even if the host later cancels the task.
pub fn applyPlan(allocator: std.mem.Allocator, io: std.Io, plan: *const Plan, cancel: ?Cancellation) !void {
    try checkCancelled(cancel);
    const current = try observePlan(io, plan.scope);
    try plan.revalidate(&current.evidence);
    const git_path = try joined(plan.scope.root.slice(), ".git");
    const metadata = try std.Io.Dir.openDirAbsolute(io, git_path.slice(), .{ .follow_symlinks = false });
    defer metadata.close(io);
    var transaction = try Transaction.begin(io, metadata, plan.evidence.index.contents);
    const result = applyLocked(allocator, io, plan, git_path.slice(), &transaction, cancel);
    transaction.abort() catch {
        return if (result) |_| error.IndexAppliedCleanupFailed else |_| error.IndexCleanupFailed;
    };
    try result;
}

const Scratch = struct {
    name: [47]u8,
    path: identity.Path,
    dir: std.Io.Dir,

    fn create(io: std.Io, metadata: std.Io.Dir, git: []const u8) !Scratch {
        var nonce: [16]u8 = undefined;
        try io.randomSecure(&nonce);
        const name: [47]u8 = ("pulse-index-op-" ++ std.fmt.bytesToHex(nonce, .lower)).*;
        const path = try joined(git, &name);
        try metadata.createDir(io, &name, .default_dir);
        errdefer metadata.deleteDir(io, &name) catch {};
        _ = try windows.observeIdentity(path.slice(), true);
        const dir = try metadata.openDir(io, &name, .{ .follow_symlinks = false });
        return .{ .name = name, .path = path, .dir = dir };
    }

    fn cleanup(self: Scratch, io: std.Io, metadata: std.Io.Dir) !void {
        var failed = false;
        for ([_][]const u8{ image_name, lock_name, process.git_global_config_name }) |name| {
            self.dir.deleteFile(io, name) catch |err| switch (err) {
                error.FileNotFound => {},
                else => failed = true,
            };
        }
        self.dir.close(io);
        metadata.deleteDir(io, &self.name) catch {
            failed = true;
        };
        if (failed) return error.IndexCleanupFailed;
    }
};

fn applyLocked(allocator: std.mem.Allocator, io: std.Io, plan: *const Plan, git: []const u8, transaction: *Transaction, cancel: ?Cancellation) !void {
    const scratch = try Scratch.create(io, transaction.metadata, git);
    const result = prepareAndPublish(allocator, io, plan, transaction, &scratch, cancel);
    scratch.cleanup(io, transaction.metadata) catch {
        return if (result) |_| error.IndexAppliedCleanupFailed else |_| error.IndexCleanupFailed;
    };
    try result;
}

fn queryImage(runner: *process.Runner, plan: *const Plan, scratch: []const u8, env: *const std.process.Environ.Map, arguments: []const []const u8) !process.Outcome {
    const prefix = [_][]const u8{ plan.scope.tool.slice(), "-C", plan.scope.root.slice(), "--literal-pathspecs", "-c", "core.fsmonitor=false" };
    var argv: [16][]const u8 = undefined;
    @memcpy(argv[0..prefix.len], &prefix);
    @memcpy(argv[prefix.len..][0..arguments.len], arguments);
    var result = try runner.run(.{
        .argv = argv[0 .. prefix.len + arguments.len],
        .cwd = scratch,
        .environ_map = env,
        .timeout_ns = 15 * std.time.ns_per_s,
        .stdout_limit = 4 * 1024 * 1024,
        .stderr_limit = 8192,
    });
    errdefer result.deinit();
    if (!result.succeeded()) return error.GitIndexQueryFailed;
    return result;
}

fn prepareAndPublish(allocator: std.mem.Allocator, io: std.Io, plan: *const Plan, transaction: *Transaction, scratch: *const Scratch, cancel: ?Cancellation) !void {
    try transaction.prepare(scratch.dir);
    try scratch.dir.writeFile(io, .{ .sub_path = process.git_global_config_name, .data = "", .flags = .{ .exclusive = true } });
    const cwd = scratch.path.slice();
    var index_buffer: [trust.max_git_config_path_bytes]u8 = undefined;
    const index = try process.gitIndexPath(cwd, &index_buffer);
    var config_buffer: [trust.max_git_config_path_bytes]u8 = undefined;
    const config = try process.gitGlobalConfigPath(cwd, &config_buffer);
    var system_buffer: [identity.max_path_bytes]u8 = undefined;
    const system = try windows.systemDirectory(&system_buffer);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    const names = [_][]const u8{ "SystemRoot", "WINDIR", "HOME", "XDG_CONFIG_HOME", "TEMP", "TMP", "GIT_CONFIG_NOSYSTEM", "GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS", "GIT_CONFIG_GLOBAL", "GIT_INDEX_FILE", "GIT_ATTR_NOSYSTEM", "GIT_NO_LAZY_FETCH" };
    const values = [_][]const u8{ system, system, cwd, cwd, cwd, cwd, "1", "0", "0", config, index, "1", "1" };
    for (names, values) |key, value| try env.put(key, value);
    var runner = process.Runner.init(allocator, io);
    try runner.configureApproved(.{ .path = plan.scope.tool.slice(), .digest = plan.evidence.tool.contents }, 15 * std.time.ns_per_s);
    try runner.configureTree(.windows_job);
    try runner.configureGitIndexIsolation();
    const path = plan.scope.path.slice();
    const before = blk: {
        var result = try queryImage(&runner, plan, cwd, &env, &.{ "ls-files", "--stage", "-z" });
        defer result.deinit();
        break :blk try review.index(result.stdout, path);
    };
    const expected: ?review.Entry = switch (plan.scope.action) {
        .stage => blk: {
            var result = try queryImage(&runner, plan, cwd, &env, &.{ "hash-object", "--no-filters", "--", path });
            defer result.deinit();
            break :blk .{
                .object = try review.parseObject(std.mem.trimEnd(u8, result.stdout, "\r\n")),
                .mode = if (before.selected) |entry| entry.mode else .regular,
            };
        },
        .unstage => blk: {
            var result = try queryImage(&runner, plan, cwd, &env, &.{ "ls-tree", "-z", &plan.evidence.head, "--", path });
            defer result.deinit();
            break :blk try review.tree(result.stdout, path);
        },
    };
    const current = try observePlan(io, plan.scope);
    try plan.revalidate(&current.evidence);
    try checkCancelled(cancel);
    try editImage(&runner, plan.scope.tool.slice(), plan.scope.root.slice(), cwd, &env, plan.scope.action, path, plan.evidence.head);
    const approved_image = try observe(io, scratch.dir);
    {
        var result = try queryImage(&runner, plan, cwd, &env, &.{ "ls-files", "--stage", "-z" });
        defer result.deinit();
        try review.verify(before, try review.index(result.stdout, path), expected);
    }
    try runner.checkDrained();
    const final = try observePlan(io, plan.scope);
    try plan.revalidate(&final.evidence);
    try checkCancelled(cancel);
    try transaction.publish(scratch.dir, approved_image);
}

fn copyAndHash(io: std.Io, source: std.Io.File, destination: ?std.Io.File) !Digest {
    const stat = try source.stat(io);
    if (stat.kind != .file or stat.nlink != 1 or stat.size > max_index_bytes) return error.UnsupportedIndex;
    var hash = Sha256.init(.{});
    var buffer: [16 * 1024]u8 = undefined;
    var offset: u64 = 0;
    while (offset < stat.size) {
        const chunk = buffer[0..@intCast(@min(stat.size - offset, buffer.len))];
        if (try source.readPositionalAll(io, chunk, offset) != chunk.len) return error.IndexChanged;
        if (destination) |file| try file.writePositionalAll(io, chunk, offset);
        hash.update(chunk);
        offset += chunk.len;
    }
    const current = try source.stat(io);
    if (current.size != stat.size or current.nlink != stat.nlink or current.mtime.nanoseconds != stat.mtime.nanoseconds or current.ctime.nanoseconds != stat.ctime.nanoseconds) return error.IndexChanged;
    if (destination) |file| try file.setLength(io, offset);
    return hash.finalResult();
}

pub fn observe(io: std.Io, dir: std.Io.Dir) !Digest {
    const file = try dir.openFile(io, image_name, .{ .follow_symlinks = false });
    defer file.close(io);
    return copyAndHash(io, file, null);
}

pub const Transaction = struct {
    io: std.Io,
    metadata: std.Io.Dir,
    lock: ?std.Io.File,
    lock_inode: std.Io.File.INode,
    owns_lock: bool = true,
    original: Digest,

    pub fn begin(io: std.Io, metadata: std.Io.Dir, reviewed: Digest) !Transaction {
        const file = try metadata.createFile(io, lock_name, .{ .exclusive = true, .read = true });
        const stat = file.stat(io) catch {
            file.close(io);
            return error.IndexCleanupFailed;
        };
        var transaction: Transaction = .{
            .io = io,
            .metadata = metadata,
            .lock = file,
            .lock_inode = stat.inode,
            .original = reviewed,
        };
        transaction.revalidate() catch |err| {
            transaction.abort() catch return error.IndexCleanupFailed;
            return err;
        };
        return transaction;
    }

    fn checkLockName(self: *const Transaction) !void {
        const stat = try self.metadata.statFile(self.io, lock_name, .{ .follow_symlinks = false });
        if (stat.inode != self.lock_inode or stat.kind != .file or stat.nlink != 1) return error.IndexLockChanged;
    }

    fn revalidate(self: *const Transaction) !void {
        try self.checkLockName();
        if (!std.mem.eql(u8, &(try observe(self.io, self.metadata)), &self.original)) return error.IndexChanged;
    }

    /// Copy the reviewed current index. The caller owns the scratch directory
    /// and its contents, including any file Git creates beside this image.
    pub fn prepare(self: *const Transaction, scratch: std.Io.Dir) !void {
        if (self.lock == null) return error.IndexTransactionClosed;
        try self.checkLockName();
        const source = try self.metadata.openFile(self.io, image_name, .{ .follow_symlinks = false });
        defer source.close(self.io);
        const image = try scratch.createFile(self.io, image_name, .{ .exclusive = true });
        defer image.close(self.io);
        if (!std.mem.eql(u8, &(try copyAndHash(self.io, source, image)), &self.original)) return error.IndexChanged;
    }

    /// The caller checks the proposed index semantics before obtaining its
    /// digest. A changed image or real index is never published.
    pub fn publish(self: *Transaction, scratch: std.Io.Dir, approved_image: Digest) !void {
        const lock = self.lock orelse return error.IndexTransactionClosed;
        const image = try scratch.openFile(self.io, image_name, .{ .follow_symlinks = false });
        defer image.close(self.io);
        if (!std.mem.eql(u8, &(try copyAndHash(self.io, image, lock)), &approved_image)) return error.IndexChanged;
        try lock.sync(self.io);
        try self.revalidate();
        lock.close(self.io);
        self.lock = null;
        try self.checkLockName();
        try self.metadata.rename(lock_name, self.metadata, image_name, self.io);
        self.owns_lock = false;
    }

    pub fn abort(self: *Transaction) !void {
        if (self.lock) |lock| {
            lock.close(self.io);
            self.lock = null;
        }
        if (!self.owns_lock) return;
        try self.checkLockName();
        try self.metadata.deleteFile(self.io, lock_name);
        self.owns_lock = false;
    }
};

test "an existing Git writer retains its index lock" {
    const io = std.testing.io;
    var metadata = std.testing.tmpDir(.{});
    defer metadata.cleanup();
    try metadata.dir.writeFile(io, .{ .sub_path = image_name, .data = "old" });
    try metadata.dir.writeFile(io, .{ .sub_path = lock_name, .data = "other owner" });
    try std.testing.expectError(error.PathAlreadyExists, Transaction.begin(io, metadata.dir, try observe(io, metadata.dir)));
    var buffer: [32]u8 = undefined;
    try std.testing.expectEqualStrings("other owner", try metadata.dir.readFile(io, lock_name, &buffer));
}

test "publish replaces only the reviewed index and releases the lock" {
    const io = std.testing.io;
    var metadata = std.testing.tmpDir(.{});
    defer metadata.cleanup();
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try metadata.dir.writeFile(io, .{ .sub_path = image_name, .data = "reviewed" });
    const reviewed = try observe(io, metadata.dir);
    var transaction = try Transaction.begin(io, metadata.dir, reviewed);
    try transaction.prepare(scratch.dir);
    try std.testing.expectEqual(reviewed, try observe(io, scratch.dir));
    try scratch.dir.writeFile(io, .{ .sub_path = image_name, .data = "proposal" });
    const approved = try observe(io, scratch.dir);
    try std.testing.expectEqual(reviewed, try observe(io, metadata.dir));
    try transaction.publish(scratch.dir, approved);
    try transaction.abort();
    try std.testing.expectError(error.FileNotFound, metadata.dir.statFile(io, lock_name, .{}));
    try std.testing.expectEqual(approved, try observe(io, metadata.dir));
}

test "changes to the live index or scratch image cannot be published" {
    const io = std.testing.io;
    var metadata = std.testing.tmpDir(.{});
    defer metadata.cleanup();
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    try metadata.dir.writeFile(io, .{ .sub_path = image_name, .data = "reviewed" });
    const reviewed = try observe(io, metadata.dir);
    var transaction = try Transaction.begin(io, metadata.dir, reviewed);
    try transaction.prepare(scratch.dir);
    try scratch.dir.writeFile(io, .{ .sub_path = image_name, .data = "proposal" });
    const approved = try observe(io, scratch.dir);
    try scratch.dir.writeFile(io, .{ .sub_path = image_name, .data = "unreviewed" });
    try std.testing.expectError(error.IndexChanged, transaction.publish(scratch.dir, approved));
    try std.testing.expectEqual(reviewed, try observe(io, metadata.dir));
    try metadata.dir.writeFile(io, .{ .sub_path = image_name, .data = "external writer" });
    const external = try observe(io, metadata.dir);
    try std.testing.expectError(error.IndexChanged, transaction.publish(scratch.dir, try observe(io, scratch.dir)));
    try transaction.abort();
    try std.testing.expectEqual(external, try observe(io, metadata.dir));
}

fn fixtureGit(env: *const std.process.Environ.Map, cwd: []const u8, args: []const []const u8, expected: bool) ![]u8 {
    const allocator = std.testing.allocator;
    var argv: [16][]const u8 = undefined;
    argv[0..4].* = .{ "git", "-C", cwd, "--literal-pathspecs" };
    @memcpy(argv[4..][0..args.len], args);
    const result = std.process.run(allocator, std.testing.io, .{
        .argv = argv[0 .. 4 + args.len],
        .environ_map = env,
        .stdout_limit = .limited(8192),
        .stderr_limit = .limited(8192),
        .timeout = .{ .duration = .{ .raw = .fromSeconds(15), .clock = .awake } },
    }) catch |err| switch (err) {
        error.FileNotFound => return error.SkipZigTest,
        else => return err,
    };
    defer allocator.free(result.stderr);
    errdefer allocator.free(result.stdout);
    if ((result.term == .exited and result.term.exited == 0) != expected) {
        std.debug.print("Git fixture command {s}: {s}\n", .{ args[0], result.stderr });
        return error.UnexpectedFixtureResult;
    }
    return result.stdout;
}

test "Git stage and unstage publish one index entry under the native writer lock" {
    const cli = @import("vcs_cli");
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var repository = std.testing.tmpDir(.{});
    defer repository.cleanup();
    var scratch = std.testing.tmpDir(.{});
    defer scratch.cleanup();
    const base = try repository.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(base);
    const scratch_path = try scratch.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(scratch_path);
    var index_buffer: [trust.max_git_config_path_bytes]u8 = undefined;
    const index_path = try process.gitIndexPath(scratch_path, &index_buffer);
    var config_buffer: [trust.max_git_config_path_bytes]u8 = undefined;
    const config_path = try process.gitGlobalConfigPath(scratch_path, &config_buffer);
    try scratch.dir.writeFile(io, .{ .sub_path = process.git_global_config_name, .data = "" });
    var inherited = try std.testing.environ.createMap(allocator);
    defer inherited.deinit();
    var tool_path: [4096]u8 = undefined;
    const search_path = inherited.get("PATH") orelse inherited.get("Path") orelse "";
    const executable = cli.locateCandidate(io, .git, search_path, &tool_path) orelse return cli.integrationUnavailable(.git);
    const binary = try std.Io.Dir.openFileAbsolute(io, executable.slice(), .{ .follow_symlinks = false });
    defer binary.close(io);
    const digest = try trust.digestFile(io, binary);
    var runner = process.Runner.init(allocator, io);
    try runner.configureApproved(.{ .path = executable.slice(), .digest = digest }, 15 * std.time.ns_per_s);
    try runner.configureGitIndexIsolation();
    if (comptime builtin.os.tag == .windows) try runner.configureTree(.windows_job);
    var env = std.process.Environ.Map.init(allocator);
    defer env.deinit();
    if (comptime builtin.os.tag == .windows) {
        const system = inherited.get("SystemRoot") orelse return error.MissingSystemRoot;
        try env.put("SystemRoot", system);
    }
    try env.put("GIT_CONFIG_NOSYSTEM", "1");
    try env.put("GIT_CONFIG_GLOBAL", config_path);
    try env.put("GIT_ATTR_NOSYSTEM", "1");
    try env.put("GIT_TERMINAL_PROMPT", "0");
    try env.put("GIT_OPTIONAL_LOCKS", "0");
    try env.put("GIT_NO_LAZY_FETCH", "1");
    try env.put("HOME", scratch_path);
    try env.put("XDG_CONFIG_HOME", scratch_path);
    allocator.free(try fixtureGit(&env, base, &.{ "init", "-q" }, true));
    try repository.dir.writeFile(io, .{ .sub_path = "selected.txt", .data = "original\n" });
    try repository.dir.writeFile(io, .{ .sub_path = "other.txt", .data = "original\n" });
    allocator.free(try fixtureGit(&env, base, &.{ "add", "--", "selected.txt", "other.txt" }, true));
    allocator.free(try fixtureGit(&env, base, &.{ "-c", "user.name=Pulse Fixture", "-c", "user.email=fixture@example.invalid", "commit", "-qm", "base" }, true));
    try repository.dir.writeFile(io, .{ .sub_path = "selected.txt", .data = "changed\n" });
    try repository.dir.writeFile(io, .{ .sub_path = "other.txt", .data = "changed\n" });
    allocator.free(try fixtureGit(&env, base, &.{ "add", "--", "other.txt" }, true));
    const original_head = try fixtureGit(&env, base, &.{ "rev-parse", "HEAD" }, true);
    defer allocator.free(original_head);
    const other_entry = try fixtureGit(&env, base, &.{ "ls-files", "--stage", "-z", "--", "other.txt" }, true);
    defer allocator.free(other_entry);
    const selected_hash = try fixtureGit(&env, base, &.{ "hash-object", "--no-filters", "--", "selected.txt" }, true);
    defer allocator.free(selected_hash);
    const selected_head = try fixtureGit(&env, base, &.{ "ls-tree", "-z", "HEAD", "--", "selected.txt" }, true);
    defer allocator.free(selected_head);
    const expected = [_]?review.Entry{
        .{ .object = try review.parseObject(std.mem.trimEnd(u8, selected_hash, "\r\n")), .mode = .regular },
        try review.tree(selected_head, "selected.txt"),
    };
    const metadata = try repository.dir.openDir(io, ".git", .{ .follow_symlinks = false });
    defer metadata.close(io);
    const head = try review.parseObject(std.mem.trimEnd(u8, original_head, "\r\n"));
    for ([_]Action{ .stage, .unstage }, 0..) |action, index| {
        const reviewed = try observe(io, metadata);
        const before = try fixtureGit(&env, base, &.{ "ls-files", "--stage", "-z" }, true);
        defer allocator.free(before);
        if (comptime builtin.os.tag == .windows) {
            var scope: Plan.Scope = .{
                .root = try identity.Path.init(base),
                .tool = executable,
                .path = try identity.Path.init("selected.txt"),
                .action = action,
                .generation = index + 1,
            };
            for (scope.tool.bytes[0..scope.tool.len]) |*byte| if (byte.* == '/') {
                byte.* = '\\';
            };
            var pending: ?Plan = try observePlan(io, scope);
            var plan = try Plan.consume(&pending, &scope);
            try std.testing.expectEqual(reviewed, plan.evidence.index.contents);
            if (action == .stage) {
                try repository.dir.writeFile(io, .{ .sub_path = "selected.txt", .data = "external edit\n" });
                try std.testing.expectError(error.IndexReviewChanged, applyPlan(allocator, io, &plan, null));
                try std.testing.expectEqual(reviewed, try observe(io, metadata));
                try repository.dir.writeFile(io, .{ .sub_path = "selected.txt", .data = "changed\n" });
                pending = try observePlan(io, scope);
                plan = try Plan.consume(&pending, &scope);
            }
            try metadata.writeFile(io, .{ .sub_path = lock_name, .data = "other Git writer" });
            try std.testing.expectError(error.PathAlreadyExists, applyPlan(allocator, io, &plan, null));
            try metadata.deleteFile(io, lock_name);
            pending = try observePlan(io, scope);
            plan = try Plan.consume(&pending, &scope);
            try applyPlan(allocator, io, &plan, null);
        } else {
            var transaction = try Transaction.begin(io, metadata, reviewed);
            errdefer transaction.abort() catch |err| std.debug.print("Fixture lock cleanup: {t}\n", .{err});
            try transaction.prepare(scratch.dir);
            allocator.free(try fixtureGit(&env, base, &.{ "add", "--", "selected.txt" }, false));
            try env.put("GIT_INDEX_FILE", index_path);
            try editImage(&runner, executable.slice(), base, scratch_path, &env, action, "selected.txt", head);
            const after = try fixtureGit(&env, base, &.{ "ls-files", "--stage", "-z" }, true);
            defer allocator.free(after);
            try review.verify(try review.index(before, "selected.txt"), try review.index(after, "selected.txt"), expected[index]);
            _ = env.swapRemove("GIT_INDEX_FILE");
            try std.testing.expectEqual(reviewed, try observe(io, metadata));
            try transaction.publish(scratch.dir, try observe(io, scratch.dir));
            try scratch.dir.deleteFile(io, image_name);
        }
        const published = try fixtureGit(&env, base, &.{ "ls-files", "--stage", "-z" }, true);
        defer allocator.free(published);
        try review.verify(try review.index(before, "selected.txt"), try review.index(published, "selected.txt"), expected[index]);
        const staged = try fixtureGit(&env, base, &.{ "diff", "--cached", "--name-only", "-z" }, true);
        defer allocator.free(staged);
        try std.testing.expectEqualStrings(if (index == 0) "other.txt\x00selected.txt\x00" else "other.txt\x00", staged);
        const seen_other = try fixtureGit(&env, base, &.{ "ls-files", "--stage", "-z", "--", "other.txt" }, true);
        defer allocator.free(seen_other);
        try std.testing.expectEqualSlices(u8, other_entry, seen_other);
        const current_head = try fixtureGit(&env, base, &.{ "rev-parse", "HEAD" }, true);
        defer allocator.free(current_head);
        try std.testing.expectEqualSlices(u8, original_head, current_head);
        var buffer: [32]u8 = undefined;
        try std.testing.expectEqualStrings("changed\n", try repository.dir.readFile(io, "selected.txt", &buffer));
    }
    try runner.checkDrained();
}
