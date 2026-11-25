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
pub const global_config_name = run.git_global_config_name;

pub fn strictPath(path: []const u8) bool {
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

fn completeEvidence(evidence: Evidence) bool {
    return evidence.local_identity_verified and evidence.installation_verified and evidence.repository_configuration_verified and evidence.neutral_environment_verified and evidence.ordinary_metadata_verified;
}

/// Immutable, in-memory review candidate, not automatic approval. The
/// verifier must independently inspect selected paths; never echo the input
/// grant's fingerprints as proof. Caller shows exact paths and fingerprints
/// to the trusted approver, then explicitly confirms this same candidate.
/// No filesystem writes, process spawn, persistent grant or UI callback here.
pub const Review = struct {
    grant: Grant,
    environment_digest: Digest,

    pub fn inspect(executable: []const u8, executable_digest: Digest, root: []const u8, neutral_cwd: []const u8, verifier: Verifier, environment: *const std.process.Environ.Map) contract.Error!Review {
        var candidate = Grant.init(executable, executable_digest, root, neutral_cwd, @splat(0), @splat(0)) catch return error.Permission;
        const environment_digest = try environmentDigest(environment, neutral_cwd);
        const evidence = try verifier.inspect(verifier.ctx, &candidate, environment);
        if (!completeEvidence(evidence)) return error.Permission;
        candidate.installation_digest = evidence.installation_digest;
        candidate.repository_digest = evidence.repository_digest;
        return .{ .grant = candidate, .environment_digest = environment_digest };
    }

    /// Confirmation is not a second discovery pass that silently approves
    /// changes. Reinspect, compare the reviewed evidence, and reject drift.
    pub fn confirm(self: *const Review, verifier: Verifier, environment: *const std.process.Environ.Map) contract.Error!Grant {
        const actual_environment = try environmentDigest(environment, self.grant.neutral_cwd.slice());
        if (!equal(&actual_environment, &self.environment_digest)) return error.Permission;
        const evidence = try verifier.inspect(verifier.ctx, &self.grant, environment);
        if (!completeEvidence(evidence) or !equal(&evidence.installation_digest, &self.grant.installation_digest) or !equal(&evidence.repository_digest, &self.grant.repository_digest)) return error.Permission;
        return self.grant;
    }

    pub const record_max_bytes = 142 + 3 * identity.max_path_bytes;
    const record_magic = "PVCSRV01";

    /// Bounded portable record; a caller must store/authenticate it in its
    /// private trusted store. Decode alone NEVER grants approval. Unknown
    /// schema versions are refused, never silently migrated to permission.
    pub fn encode(self: *const Review, buffer: []u8) contract.Error![]const u8 {
        const paths = [_][]const u8{ self.grant.executable.slice(), self.grant.root.slice(), self.grant.neutral_cwd.slice() };
        const size = 142 + paths[0].len + paths[1].len + paths[2].len;
        if (size > record_max_bytes or size > buffer.len) return error.ResourceLimit;
        @memcpy(buffer[0..8], record_magic);
        @memcpy(buffer[8..40], &self.grant.executable_digest);
        @memcpy(buffer[40..72], &self.grant.installation_digest);
        @memcpy(buffer[72..104], &self.grant.repository_digest);
        @memcpy(buffer[104..136], &self.environment_digest);
        var offset: usize = 142;
        for (paths, 0..) |path, i| {
            if (!strictPath(path) or path.len > identity.max_path_bytes) return error.Permission;
            std.mem.writeInt(u16, buffer[136 + i * 2 ..][0..2], @intCast(path.len), .little);
            @memcpy(buffer[offset..][0..path.len], path);
            offset += path.len;
        }
        return buffer[0..size];
    }

    pub fn decode(bytes: []const u8) contract.Error!Review {
        if (bytes.len < 142 or bytes.len > record_max_bytes or !equal(bytes[0..8], record_magic)) return error.Parse;
        var offset: usize = 142;
        var paths: [3][]const u8 = undefined;
        for (&paths, 0..) |*path, i| {
            const length = std.mem.readInt(u16, bytes[136 + i * 2 ..][0..2], .little);
            if (length == 0 or length > identity.max_path_bytes or length > bytes.len - offset) return error.Parse;
            path.* = bytes[offset..][0..length];
            offset += length;
        }
        if (offset != bytes.len) return error.Parse;
        const grant = Grant.init(paths[0], bytes[8..40].*, paths[1], paths[2], bytes[40..72].*, bytes[72..104].*) catch return error.Parse;
        return .{ .grant = grant, .environment_digest = bytes[104..136].* };
    }

    fn environmentDigest(environment: *const std.process.Environ.Map, cwd: []const u8) contract.Error!Digest {
        run.validateGitEnvironment(environment, cwd) catch return error.Permission;
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update("pulse-git-review-environment-v1");
        // The exact admitted vocabulary is finite; hash in stable order.
        for ([_][]const u8{ "SystemRoot", "WINDIR", "TEMP", "TMP", "LANG", "LC_ALL", "GIT_TERMINAL_PROMPT", "GIT_OPTIONAL_LOCKS", "GIT_CONFIG_NOSYSTEM", "GIT_CONFIG_GLOBAL" }) |key| {
            hash.update(key);
            if (environment.get(key)) |value| {
                if (value.len > 32768 or std.mem.indexOfScalar(u8, value, 0) != null) return error.ResourceLimit;
                hash.update(&.{1});
                var length: [4]u8 = undefined;
                std.mem.writeInt(u32, &length, @intCast(value.len), .little);
                hash.update(&length);
                hash.update(value);
            } else hash.update(&.{0});
        }
        return hash.finalResult();
    }
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
    reviewed_environment: ?Digest = null,
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
        if (self.reviewed_environment) |expected| {
            const actual = try Review.environmentDigest(self.environment, self.grant.neutral_cwd.slice());
            if (!equal(&actual, &expected)) return error.Permission;
        }
        const evidence = try self.verifier.inspect(self.verifier.ctx, &self.grant, self.environment);
        if (!completeEvidence(evidence)) return error.Permission;
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
        run.validateGitEnvironment(self.environment, self.grant.neutral_cwd.slice()) catch return error.Permission;
        self.runner.configureApproved(.{ .path = self.grant.executable.slice(), .digest = self.grant.executable_digest }, 10 * std.time.ns_per_s) catch return error.Io;
        self.runner.configureGitIsolation() catch return error.Permission;
        if (builtin.os.tag == .windows) self.runner.configureTree(.windows_job) catch return error.Io;
        const execution: cli.Execution = .{ .approved = .{
            .cwd = self.grant.neutral_cwd,
            .environment = self.environment,
            .gate = .{ .ctx = self, .check = &checkRequest },
        } };
        const report = cli.probeApproved(.git, &self.grant.executable, &execution, self.runner) catch |err| return switch (err) {
            error.UnsupportedVersion => error.CliTooOld,
            error.InvalidVersion => error.Parse,
            error.UnapprovedExecutable, error.UnapprovedEnvironment, error.PermissionDenied => error.Permission,
            error.SpawnFailed => error.CliMissing,
            error.TimedOut => error.Timeout,
            error.Cancelled => error.Cancelled,
            else => error.Io,
        };
        // GIT_CONFIG_GLOBAL was introduced in Git 2.32. Do not run any
        // repository command on an older version that ignores isolation.
        if (!(report.version orelse return error.Parse).atLeast(.{ .major = 2, .minor = 32 })) return error.CliTooOld;
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
        if (runner != self.runner or runner.policy != .approved_local or !runner.git_isolation) return error.UnapprovedExecutable;
        const approval = runner.approval orelse return error.UnapprovedExecutable;
        if (!equal(approval.slice(), self.grant.executable.slice()) or !equal(&approval.digest, &self.grant.executable_digest)) return error.UnapprovedExecutable;
        if (!equal(request.cwd orelse return error.UnapprovedEnvironment, self.grant.neutral_cwd.slice()) or request.environ_map != self.environment) return error.UnapprovedEnvironment;
        try run.validateGitEnvironment(self.environment, self.grant.neutral_cwd.slice());
        const exe = self.grant.executable.slice();
        const root = self.grant.root.slice();
        const version = argvEqual(request.argv, &.{ exe, "--version" });
        const identity_query = argvEqual(request.argv, &.{ exe, "--no-optional-locks", "-C", root, "rev-parse", "--path-format=absolute", "--show-toplevel", "--git-common-dir", "--absolute-git-dir" });
        const status = argvEqual(request.argv, &.{ exe, "--no-optional-locks", "-C", root, "status", "--porcelain=v2", "--branch", "-z", "--untracked-files=normal", "--ignore-submodules=all" });
        if (!version and !identity_query and !status) return error.UnapprovedExecutable;
        self.verify() catch |err| return switch (err) {
            error.Cancelled => error.Cancelled,
            error.OutOfMemory => error.OutOfMemory,
            else => error.UnapprovedExecutable,
        };
    }
};

/// Trusted provisioning input. The implementation is compiled into the
/// extension, owns I/O and immutable environment/auditor storage and must
/// authenticate any persisted review before returning it. No automatic
/// consent, no PATH discovery, and no untrusted config import.
pub const NativeInput = struct {
    review: Review,
    verifier: Verifier,
    environment: *const std.process.Environ.Map,
    probe: detect.Probe,
    io: std.Io,
    release_ctx: *anyopaque,
    release: *const fn (*anyopaque) void,
};

/// Native session retains every input until Binding drain / final destroy.
/// Initialize at the final stable address. Verification happens on the
/// host worker; never inspect files or run commands in an owner callback.
pub const NativeSession = struct {
    input: NativeInput,
    runner: run.Runner,
    policy: Policy = undefined,
    configured: bool = false,
    finished: bool = false,

    pub fn init(input: NativeInput, allocator: std.mem.Allocator) NativeSession {
        return .{ .input = input, .runner = run.Runner.init(allocator, input.io) };
    }

    pub fn configure(self: *NativeSession, binding: *host_query.Binding) host_query.HostError!void {
        if (self.configured or self.finished) return error.State;
        self.policy = Policy.init(self.input.review.grant, self.input.verifier, &self.runner, self.input.environment, self.input.probe);
        self.configured = true;
        self.policy.reviewed_environment = self.input.review.environment_digest;
        try binding.configureResolver(self.policy.resolver());
        try binding.configureRevocation(.{ .ctx = self, .revoke = &revoke });
    }

    fn revoke(user: *anyopaque) void {
        const self: *NativeSession = @ptrCast(@alignCast(user));
        self.policy.revoke();
    }

    /// Owner-safe atomic gate: do not touch worker-owned runner state.
    pub fn stopAdmission(self: *NativeSession) void {
        if (self.configured) self.policy.revoke();
    }

    /// Caller must prove host task/callback drain before stopping the Runner.
    pub fn finish(self: *NativeSession) contract.Error!void {
        if (self.finished) return;
        self.stopAdmission();
        self.runner.requestStop();
        self.runner.finishStop() catch return error.Io;
        self.finished = true;
        self.input.release(self.input.release_ctx);
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

fn configureFixtureEnvironment(environment: *std.process.Environ.Map, cwd: []const u8) !void {
    var buffer: [identity.max_path_bytes]u8 = undefined;
    try environment.put("GIT_CONFIG_GLOBAL", try run.gitGlobalConfigPath(cwd, &buffer));
    try environment.put("GIT_CONFIG_NOSYSTEM", "1");
    try environment.put("GIT_OPTIONAL_LOCKS", "0");
    try environment.put("GIT_TERMINAL_PROMPT", "0");
}

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
    try runner.configureGitIsolation();
    try configureFixtureEnvironment(&environment, policy.grant.neutral_cwd.slice());
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
    try runner.configureGitIsolation();
    try configureFixtureEnvironment(&environment, policy.grant.neutral_cwd.slice());
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

// The following integration uses actual Git and Runner, but the installation
// is supplied by the test environment and the verifier is an explicit fixture.
// It is NOT evidence of automatic or production installation approval.
fn testWindowsSpelling(path: *identity.Path) void {
    if (builtin.os.tag == .windows) {
        for (path.bytes[0..path.len]) |*byte| {
            if (byte.* == '/') byte.* = '\\';
        }
    }
}

test "real approved Git command chain rejects altered empty config and revoked grant" {
    const test_config = @import("vcs_test_config");
    const process_trust = @import("process_trust");
    const io = std.testing.io;
    var scratch: [identity.max_path_bytes + 64]u8 = undefined;
    var executable = cli.locateCandidate(io, .git, test_config.path, &scratch) orelse return cli.integrationUnavailable(.git);
    testWindowsSpelling(&executable);

    var repo = std.testing.tmpDir(.{});
    defer repo.cleanup();
    var neutral = std.testing.tmpDir(.{});
    defer neutral.cleanup();
    var relative_buffer: [identity.max_path_bytes]u8 = undefined;
    const relative = try std.fmt.bufPrint(&relative_buffer, ".zig-cache" ++ std.fs.path.sep_str ++ "tmp" ++ std.fs.path.sep_str ++ "{s}", .{repo.sub_path});
    var setup_runner = run.Runner.init(std.testing.allocator, io);
    {
        var outcome = try setup_runner.run(.{ .argv = &.{ executable.slice(), "-C", relative, "init", "--quiet", "--template=" }, .timeout_ns = 20 * std.time.ns_per_s });
        defer outcome.deinit();
        if (!outcome.succeeded()) return error.TestGitInitFailed;
    }
    var setup_fixture: Fixture = .{};
    var setup_git = git_mod.Git.init(&setup_runner, executable, .{ .ctx = &setup_fixture, .lookup = &Fixture.lookup });
    const initial = try setup_git.resolveWorkspace(relative);
    try setup_runner.checkDrained();
    var root = initial.root;
    testWindowsSpelling(&root);
    const parent = std.fs.path.dirname(root.slice()) orelse return error.TestUnexpectedResult;
    var neutral_buffer: [identity.max_path_bytes]u8 = undefined;
    const neutral_path = try std.fmt.bufPrint(&neutral_buffer, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ parent, neutral.sub_path });
    const empty = try neutral.dir.createFile(io, global_config_name, .{ .exclusive = true });
    empty.close(io);
    const work = try repo.dir.createFile(io, "untracked.txt", .{ .exclusive = true });
    try work.writeStreamingAll(io, "fixture\n");
    work.close(io);
    const digest = blk: {
        const file = try std.Io.Dir.openFileAbsolute(io, executable.slice(), .{ .follow_symlinks = false });
        defer file.close(io);
        break :blk try process_trust.digestFile(io, file);
    };

    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try configureFixtureEnvironment(&environment, neutral_path);
    if (builtin.os.tag == .windows and test_config.system_root.len != 0) {
        try environment.put("SystemRoot", test_config.system_root);
    }
    var fixture: Fixture = .{};
    var runner = run.Runner.init(std.testing.allocator, io);
    const grant = try Grant.init(executable.slice(), digest, root.slice(), neutral_path, @splat(2), @splat(3));
    var policy = Policy.init(grant, .{ .ctx = &fixture, .inspect = &Fixture.inspect }, &runner, &environment, .{ .ctx = &fixture, .lookup = &Fixture.lookup });
    const resolver = policy.resolver();
    const resolved = (try resolver.resolve(resolver.ctx, &root)) orelse return error.TestUnexpectedResult;
    try std.testing.expect(resolved.workspace.root.eql(root.slice()));
    const first = try resolved.provider.summarize(&resolved.workspace);
    try std.testing.expectEqual(contract.Availability.ready, first.availability);
    try std.testing.expectEqual(@as(u32, 1), first.changes.untracked);
    try std.testing.expectEqual(@as(usize, 3), runner.completed);
    try runner.checkDrained();

    const altered = try neutral.dir.createFile(io, global_config_name, .{});
    try altered.writeStreamingAll(io, "[core]\nfilemode = true\n");
    altered.close(io);
    try std.testing.expectError(error.Permission, resolved.provider.summarize(&resolved.workspace));
    try std.testing.expectEqual(@as(usize, 3), runner.completed);
    try runner.checkDrained();
    const restored = try neutral.dir.createFile(io, global_config_name, .{});
    restored.close(io);
    const again = try resolved.provider.summarize(&resolved.workspace);
    try std.testing.expectEqual(@as(u32, 1), again.changes.untracked);
    try std.testing.expectEqual(@as(usize, 4), runner.completed);
    fixture.changed = true;
    try std.testing.expectError(error.Permission, resolved.provider.summarize(&resolved.workspace));
    fixture.changed = false;
    policy.revoke();
    try std.testing.expectError(error.Permission, resolved.provider.summarize(&resolved.workspace));
    try std.testing.expectEqual(@as(usize, 4), runner.completed);
    try runner.checkDrained();
    runner.requestStop();
    try runner.finishStop();
}

const ReviewFixture = struct {
    changed: bool = false,
    complete: bool = true,

    fn inspect(user: *anyopaque, _: *const Grant, _: *const std.process.Environ.Map) contract.Error!Evidence {
        const self: *ReviewFixture = @ptrCast(@alignCast(user));
        return .{
            .installation_digest = @splat(42),
            .repository_digest = if (self.changed) @splat(99) else @splat(43),
            .local_identity_verified = true,
            .installation_verified = self.complete,
            .repository_configuration_verified = true,
            .neutral_environment_verified = true,
            .ordinary_metadata_verified = true,
        };
    }
};

test "review captures independent evidence and explicit confirmation rejects drift" {
    const candidate = try Fixture.makeGrant();
    var fixture: ReviewFixture = .{};
    const verifier: Verifier = .{ .ctx = &fixture, .inspect = &ReviewFixture.inspect };
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try configureFixtureEnvironment(&environment, candidate.neutral_cwd.slice());
    const review = try Review.inspect(candidate.executable.slice(), candidate.executable_digest, candidate.root.slice(), candidate.neutral_cwd.slice(), verifier, &environment);
    try std.testing.expectEqualSlices(u8, &(@as(Digest, @splat(42))), &review.grant.installation_digest);
    try std.testing.expectEqualSlices(u8, &(@as(Digest, @splat(43))), &review.grant.repository_digest);
    const confirmed = try review.confirm(verifier, &environment);
    try std.testing.expect(confirmed.root.eql(candidate.root.slice()));
    fixture.changed = true;
    try std.testing.expectError(error.Permission, review.confirm(verifier, &environment));
    fixture.changed = false;
    try environment.put("LANG", "changed");
    try std.testing.expectError(error.Permission, review.confirm(verifier, &environment));
    fixture.complete = false;
    try std.testing.expectError(error.Permission, Review.inspect(candidate.executable.slice(), candidate.executable_digest, candidate.root.slice(), candidate.neutral_cwd.slice(), verifier, &environment));
}

test "review record is versioned bounded and never imports malformed paths" {
    const grant = try Fixture.makeGrant();
    const review: Review = .{ .grant = grant, .environment_digest = @splat(9) };
    var buffer: [Review.record_max_bytes]u8 = undefined;
    const encoded = try review.encode(&buffer);
    const decoded = try Review.decode(encoded);
    try std.testing.expect(decoded.grant.root.eql(grant.root.slice()));
    try std.testing.expectEqualSlices(u8, &review.environment_digest, &decoded.environment_digest);
    try std.testing.expectError(error.Parse, Review.decode(encoded[0 .. encoded.len - 1]));
    buffer[7] = '2';
    try std.testing.expectError(error.Parse, Review.decode(encoded));
}

const NativeFixture = struct {
    releases: usize = 0,

    fn release(user: *anyopaque) void {
        const self: *NativeFixture = @ptrCast(@alignCast(user));
        self.releases += 1;
    }

    fn create(_: ?*anyopaque, _: [*c]const @import("pulse_async_host").Descriptor, _: [*c]u64) callconv(.c) @import("pulse_abi").Status {
        return @import("pulse_abi").error_permission;
    }

    fn cancel(_: ?*anyopaque, _: u64) callconv(.c) @import("pulse_abi").Status {
        return @import("pulse_abi").error_permission;
    }

    fn get(_: ?*anyopaque, _: u64, _: ?*const fn (?*anyopaque, [*c]const @import("pulse_async_host").Snapshot) callconv(.c) void, _: ?*anyopaque) callconv(.c) @import("pulse_abi").Status {
        return @import("pulse_abi").error_permission;
    }
};

test "native session connects reviewed environment and releases source exactly once" {
    const task_table = @import("pulse_async_host").TaskTable;
    const grant = try Fixture.makeGrant();
    var environment = std.process.Environ.Map.init(std.testing.allocator);
    defer environment.deinit();
    try configureFixtureEnvironment(&environment, grant.neutral_cwd.slice());
    var audit: ReviewFixture = .{};
    const verifier: Verifier = .{ .ctx = &audit, .inspect = &ReviewFixture.inspect };
    const review = try Review.inspect(grant.executable.slice(), grant.executable_digest, grant.root.slice(), grant.neutral_cwd.slice(), verifier, &environment);
    var fixture: Fixture = .{};
    var lifetime: NativeFixture = .{};
    var binding = try host_query.Binding.init(.{
        .size = @sizeOf(task_table),
        .version = 1,
        .context = &lifetime,
        .create = &NativeFixture.create,
        .cancel = &NativeFixture.cancel,
        .get = &NativeFixture.get,
        .release = &NativeFixture.cancel,
    }, .en);
    var session = NativeSession.init(.{
        .review = review,
        .verifier = verifier,
        .environment = &environment,
        .probe = .{ .ctx = &fixture, .lookup = &Fixture.lookup },
        .io = std.testing.io,
        .release_ctx = &lifetime,
        .release = &NativeFixture.release,
    }, std.testing.allocator);
    try session.configure(&binding);
    try session.policy.verify();
    try environment.put("LANG", "drift");
    try std.testing.expectError(error.Permission, session.policy.verify());
    session.stopAdmission();
    try std.testing.expectError(error.Permission, session.policy.verify());
    try binding.requestStop();
    try binding.checkDrained();
    try session.finish();
    try session.finish();
    try std.testing.expectEqual(@as(usize, 1), lifetime.releases);
}
