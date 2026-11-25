//! Conservative explicit approval for one ordinary Git workspace.
//! Independent OS/configuration evidence is mandatory before any CLI launch.
//! No PATH approval, linked worktree, shared metadata or compatibility fallback.
//! This is an admission policy, not a sandbox or race-free filesystem check.

const std = @import("std");
const builtin = @import("builtin");
const identity = @import("vcs_identity");
const detect = @import("vcs_detect");
const contract = @import("vcs_provider");
const cli = @import("vcs_cli");
const git_mod = @import("vcs_git");
const host_query = @import("vcs_host_query");
const run = @import("pulse_process");

pub const Digest = [32]u8;

fn strictPath(path: []const u8) bool {
    if (!cli.candidatePath(path) or !std.unicode.utf8ValidateSlice(path) or path[path.len - 1] == std.fs.path.sep) return false;
    for (path) |byte| {
        if (byte < 0x20 or byte == 0x7f) return false;
        if (builtin.os.tag == .windows and byte == '/') return false;
    }
    if (builtin.os.tag == .windows) {
        var parts = std.mem.tokenizeScalar(u8, path[3..], '\\');
        while (parts.next()) |part| {
            if (part[part.len - 1] == '.' or part[part.len - 1] == ' ') return false;
        }
    }
    return true;
}

fn equal(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}

/// Git for Windows commonly emits forward slashes. Accept only this spelling
/// difference in CLI-reported identities, not case folding or canonical aliases.
/// OS identity evidence must already have been verified independently.
fn reportedPathEqual(actual: []const u8, expected: []const u8) bool {
    if (actual.len != expected.len) return false;
    for (actual, expected) |a, b| {
        if (a == b) continue;
        if (builtin.os.tag == .windows and a == '/' and b == '\\') continue;
        return false;
    }
    return true;
}

fn within(root: []const u8, path: []const u8) bool {
    return equal(root, path) or (path.len > root.len and std.mem.startsWith(u8, path, root) and path[root.len] == std.fs.path.sep);
}

pub const Grant = struct {
    executable: identity.Path,
    executable_digest: Digest,
    root: identity.Path,
    metadata: identity.Path,
    neutral_cwd: identity.Path,
    installation_digest: Digest,
    repository_digest: Digest,

    pub fn init(executable: []const u8, executable_digest: Digest, root: []const u8, neutral_cwd: []const u8, installation_digest: Digest, repository_digest: Digest) error{InvalidGrant}!Grant {
        for ([_][]const u8{ executable, root, neutral_cwd }) |path| {
            if (!strictPath(path)) return error.InvalidGrant;
        }
        if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(executable), cli.Tool.git.exeName())) return error.InvalidGrant;
        if (within(root, neutral_cwd) or within(neutral_cwd, root) or within(root, executable)) return error.InvalidGrant;
        var buffer: [identity.max_path_bytes]u8 = undefined;
        const metadata = std.fmt.bufPrint(&buffer, "{s}" ++ std.fs.path.sep_str ++ ".git", .{root}) catch return error.InvalidGrant;
        return .{
            .executable = identity.Path.init(executable) catch return error.InvalidGrant,
            .executable_digest = executable_digest,
            .root = identity.Path.init(root) catch return error.InvalidGrant,
            .metadata = identity.Path.init(metadata) catch return error.InvalidGrant,
            .neutral_cwd = identity.Path.init(neutral_cwd) catch return error.InvalidGrant,
            .installation_digest = installation_digest,
            .repository_digest = repository_digest,
        };
    }
};

/// A trusted verifier must establish canonical local identity, ACLs, mount
/// and reparse boundaries, installation/helpers, all config/includes, object
/// redirection, ordinary metadata and neutral environment independently.
/// Digests are approved fingerprints, never inferred from marker discovery.
pub const Evidence = struct {
    installation_digest: Digest,
    repository_digest: Digest,
    local_identity_verified: bool = false,
    installation_verified: bool = false,
    repository_configuration_verified: bool = false,
    neutral_environment_verified: bool = false,
    ordinary_metadata_verified: bool = false,
};

pub const Verifier = struct {
    ctx: *anyopaque,
    inspect: *const fn (*anyopaque, *const Grant, *const std.process.Environ.Map) contract.Error!Evidence,
};

/// Stable address; worker owns runner/provider, caller owns verifier and
/// immutable environment. Replace grants only after drain. Revocation blocks
/// future admissions, not a process that has already started.
pub const Policy = struct {
    grant: Grant,
    verifier: Verifier,
    runner: *run.Runner,
    environment: *const std.process.Environ.Map,
    probe: detect.Probe,
    revoked: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    git: git_mod.Git = undefined,

    pub fn init(grant: Grant, verifier: Verifier, runner: *run.Runner, environment: *const std.process.Environ.Map, probe: detect.Probe) Policy {
        return .{ .grant = grant, .verifier = verifier, .runner = runner, .environment = environment, .probe = probe };
    }

    pub fn revoke(self: *Policy) void {
        self.revoked.store(true, .release);
    }

    pub fn resolver(self: *Policy) host_query.Resolver {
        return .{ .ctx = self, .resolve = &resolve };
    }

    fn verify(self: *Policy) contract.Error!void {
        if (self.revoked.load(.acquire)) return error.Permission;
        const evidence = try self.verifier.inspect(self.verifier.ctx, &self.grant, self.environment);
        if (!evidence.local_identity_verified or !evidence.installation_verified or !evidence.repository_configuration_verified or !evidence.neutral_environment_verified or !evidence.ordinary_metadata_verified) return error.Permission;
        if (!equal(&evidence.installation_digest, &self.grant.installation_digest) or !equal(&evidence.repository_digest, &self.grant.repository_digest)) return error.Permission;
        if (self.revoked.load(.acquire)) return error.Permission;
    }

    fn resolve(user: *anyopaque, directory: *const identity.Path) contract.Error!?host_query.Resolved {
        const self: *Policy = @ptrCast(@alignCast(user));
        if (directory.len == 0 or directory.len > identity.max_path_bytes or !strictPath(directory.slice())) return error.Permission;
        // Exact root only: do not probe unverified descendant paths.
        if (!self.grant.root.eql(directory.slice())) return error.Permission;
        try self.verify();
        if (self.probe.at(self.grant.metadata.slice()) != .directory) return error.Permission;
        self.runner.configureApproved(.{ .path = self.grant.executable.slice(), .digest = self.grant.executable_digest }, 10 * std.time.ns_per_s) catch return error.Io;
        if (builtin.os.tag == .windows) self.runner.configureTree(.windows_job) catch return error.Io;
        const execution: cli.Execution = .{ .approved = .{
            .cwd = self.grant.neutral_cwd,
            .environment = self.environment,
            .gate = .{ .ctx = self, .check = &checkRequest },
        } };
        _ = cli.probeApproved(.git, &self.grant.executable, &execution, self.runner) catch |err| return switch (err) {
            error.UnsupportedVersion => error.CliTooOld,
            error.InvalidVersion => error.Parse,
            error.UnapprovedExecutable, error.UnapprovedEnvironment, error.PermissionDenied => error.Permission,
            error.SpawnFailed => error.CliMissing,
            error.TimedOut => error.Timeout,
            error.Cancelled => error.Cancelled,
            else => error.Io,
        };
        self.git = git_mod.Git.initApproved(self.runner, self.grant.executable, self.probe, execution) catch return error.Permission;
        const reported = try self.git.resolveWorkspace(self.grant.root.slice());
        if (!self.matchesWorkspace(&reported)) return error.Permission;
        const workspace: identity.Workspace = .{ .kind = .git, .root = self.grant.root, .repository_root = self.grant.metadata };
        return .{ .provider = self.git.provider(), .workspace = workspace };
    }

    fn matchesWorkspace(self: *const Policy, workspace: *const identity.Workspace) bool {
        return workspace.kind == .git and !workspace.shared_metadata and reportedPathEqual(workspace.root.slice(), self.grant.root.slice()) and reportedPathEqual(workspace.repository_root.slice(), self.grant.metadata.slice());
    }

    fn argvEqual(actual: []const []const u8, expected: []const []const u8) bool {
        if (actual.len != expected.len) return false;
        for (actual, expected) |a, b| {
            if (!equal(a, b)) return false;
        }
        return true;
    }

    fn checkRequest(user: *anyopaque, runner: *run.Runner, request: run.Request) run.Error!void {
        const self: *Policy = @ptrCast(@alignCast(user));
        if (runner != self.runner or runner.policy != .approved_local) return error.UnapprovedExecutable;
        const approval = runner.approval orelse return error.UnapprovedExecutable;
        if (!equal(approval.slice(), self.grant.executable.slice()) or !equal(&approval.digest, &self.grant.executable_digest)) return error.UnapprovedExecutable;
        if (!equal(request.cwd orelse return error.UnapprovedEnvironment, self.grant.neutral_cwd.slice()) or request.environ_map != self.environment) return error.UnapprovedEnvironment;
        const exe = self.grant.executable.slice();
        const root = self.grant.root.slice();
        const version = argvEqual(request.argv, &.{ exe, "--version" });
        const identity_query = argvEqual(request.argv, &.{ exe, "--no-optional-locks", "-C", root, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "--absolute-git-dir" });
        const status = argvEqual(request.argv, &.{ exe, "--no-optional-locks", "-C", root, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal", "--ignore-submodules=none" });
        if (!version and !identity_query and !status) return error.UnapprovedExecutable;
        self.verify() catch |err| return switch (err) {
            error.Cancelled => error.Cancelled,
            error.OutOfMemory => error.OutOfMemory,
            else => error.UnapprovedExecutable,
        };
    }
};

const Fixture = struct {
    calls: usize = 0,
    complete: bool = true,
    changed: bool = false,
    marker: detect.EntryType = .directory,

    fn inspect(user: *anyopaque, grant: *const Grant, _: *const std.process.Environ.Map) contract.Error!Evidence {
        const self: *Fixture = @ptrCast(@alignCast(user));
        self.calls += 1;
        return .{
            .installation_digest = grant.installation_digest,
            .repository_digest = if (self.changed) @splat(99) else grant.repository_digest,
            .local_identity_verified = self.complete,
            .installation_verified = true,
            .repository_configuration_verified = true,
            .neutral_environment_verified = true,
            .ordinary_metadata_verified = true,
        };
    }

    fn lookup(user: *anyopaque, _: []const u8) detect.EntryType {
        const self: *Fixture = @ptrCast(@alignCast(user));
        return self.marker;
    }

    fn makeGrant() !Grant {
        return Grant.init(
            if (builtin.os.tag == .windows) "C:\\tools\\git.exe" else "/tools/git",
            @splat(1),
            if (builtin.os.tag == .windows) "C:\\work\\repo" else "/work/repo",
            if (builtin.os.tag == .windows) "C:\\neutral" else "/neutral",
            @splat(2),
            @splat(3),
        );
    }

    fn makePolicy(self: *Fixture, runner: *run.Runner, environment: *const std.process.Environ.Map) !Policy {
        return Policy.init(try makeGrant(), .{ .ctx = self, .inspect = &inspect }, runner, environment, .{ .ctx = self, .lookup = &lookup });
    }
};

test "grant rejects relative and overlapping paths" {
    const grant = try Fixture.makeGrant();
    try std.testing.expect(std.mem.endsWith(u8, grant.metadata.slice(), std.fs.path.sep_str ++ ".git"));
    try std.testing.expectError(error.InvalidGrant, Grant.init("git", @splat(1), grant.root.slice(), grant.neutral_cwd.slice(), @splat(2), @splat(3)));
    try std.testing.expectError(error.InvalidGrant, Grant.init(grant.executable.slice(), @splat(1), grant.root.slice(), grant.root.slice(), @splat(2), @splat(3)));
}

test "incomplete changed and revoked evidence fails closed" {
    var fixture: Fixture = .{ .complete = false };
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var policy = try fixture.makePolicy(&runner, &environment);
    try std.testing.expectError(error.Permission, policy.verify());
    fixture.complete = true;
    try policy.verify();
    fixture.changed = true;
    try std.testing.expectError(error.Permission, policy.verify());
    fixture.changed = false;
    policy.revoke();
    try std.testing.expectError(error.Permission, policy.verify());
    try std.testing.expectEqual(@as(usize, 3), fixture.calls);
    try runner.checkDrained();
}

test "guard admits exact reviewed argv and rechecks evidence" {
    var fixture: Fixture = .{};
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var policy = try fixture.makePolicy(&runner, &environment);
    const exe = policy.grant.executable.slice();
    const root = policy.grant.root.slice();
    try runner.configureApproved(.{ .path = exe, .digest = policy.grant.executable_digest }, 10 * std.time.ns_per_s);
    var request: run.Request = .{ .argv = &.{ exe, "--version" }, .cwd = policy.grant.neutral_cwd.slice(), .environ_map = &environment };
    try Policy.checkRequest(&policy, &runner, request);
    request.argv = &.{ exe, "-C", root, "reset", "--hard" };
    try std.testing.expectError(error.UnapprovedExecutable, Policy.checkRequest(&policy, &runner, request));
    request.argv = &.{ exe, "--version" };
    request.cwd = root;
    try std.testing.expectError(error.UnapprovedEnvironment, Policy.checkRequest(&policy, &runner, request));
    request.cwd = policy.grant.neutral_cwd.slice();
    fixture.changed = true;
    try std.testing.expectError(error.UnapprovedExecutable, Policy.checkRequest(&policy, &runner, request));
    try std.testing.expectEqual(@as(usize, 2), fixture.calls);
    try runner.checkDrained();
}

test "resolver rejects unapproved root and worktree before command admission" {
    var fixture: Fixture = .{ .marker = .file };
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var policy = try fixture.makePolicy(&runner, &environment);
    const unrelated = try identity.Path.init(if (builtin.os.tag == .windows) "C:\\unrelated" else "/unrelated");
    const resolver = policy.resolver();
    try std.testing.expectError(error.Permission, resolver.resolve(resolver.ctx, &unrelated));
    try std.testing.expectEqual(@as(usize, 0), fixture.calls);
    try std.testing.expectError(error.Permission, resolver.resolve(resolver.ctx, &policy.grant.root));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expect(runner.policy == .compatibility);
    try runner.checkDrained();
}

test "resolved metadata must equal ordinary approved workspace" {
    var fixture: Fixture = .{};
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    const policy = try fixture.makePolicy(&runner, &environment);
    var workspace = try identity.Workspace.init(.git, policy.grant.root.slice(), policy.grant.metadata.slice());
    try std.testing.expect(policy.matchesWorkspace(&workspace));
    workspace.shared_metadata = true;
    try std.testing.expect(!policy.matchesWorkspace(&workspace));
    workspace.shared_metadata = false;
    workspace.repository_root = policy.grant.neutral_cwd;
    try std.testing.expect(!policy.matchesWorkspace(&workspace));
}

test "reported Windows path accepts separators only and keeps exact case" {
    if (builtin.os.tag == .windows) {
        try std.testing.expect(reportedPathEqual("C:/work/repo/.git", "C:\\work\\repo\\.git"));
        try std.testing.expect(!reportedPathEqual("C:/Work/repo/.git", "C:\\work\\repo\\.git"));
        try std.testing.expect(!reportedPathEqual("C:/work/other/.git", "C:\\work\\repo\\.git"));
    } else {
        try std.testing.expect(!reportedPathEqual("/work/repo", "\\work\\repo"));
    }
}

test "configured execution gate rejects before attempting nonexistent tool" {
    var fixture: Fixture = .{ .changed = true };
    var runner = run.Runner.init(std.testing.allocator, std.testing.io);
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    var policy = try fixture.makePolicy(&runner, &environment);
    try runner.configureApproved(.{ .path = policy.grant.executable.slice(), .digest = policy.grant.executable_digest }, 10 * std.time.ns_per_s);
    if (builtin.os.tag == .windows) try runner.configureTree(.windows_job);
    const execution: cli.Execution = .{ .approved = .{
        .cwd = policy.grant.neutral_cwd,
        .environment = &environment,
        .gate = .{ .ctx = &policy, .check = &Policy.checkRequest },
    } };
    try std.testing.expectError(error.UnapprovedExecutable, execution.execute(&runner, .{ .argv = &.{ policy.grant.executable.slice(), "--version" } }));
    try std.testing.expectEqual(@as(usize, 1), fixture.calls);
    try std.testing.expectEqual(@as(usize, 0), runner.failed);
    try runner.checkDrained();
}
