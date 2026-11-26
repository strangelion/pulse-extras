//! Host-independent VCS summary orchestration. Whole-provider queries run on
//! one worker, not each command in a separate task. Navigation coalesces to
//! one latest request. Only the owner publishes into the cache.
//! Caller owns provider contexts, Runner and I/O; keep them stable and
//! exclusively reserved until queued/active work drains. Do not access the
//! Runner's diagnostics or provider state concurrently. No host callbacks.
//! startNext/await/cancel are explicit; blocking joins are not UI callbacks.

const std = @import("std");
const identity = @import("vcs_identity");
const contract = @import("vcs_provider");
const snapshot = @import("vcs_snapshot");
const latest = @import("runtime_latest_task");
const Group = @import("runtime_group").Group;
const capabilities = @import("vcs_capabilities");
const detect = @import("vcs_detect");

const Request = struct {
    provider: contract.Provider,
    workspace: identity.Workspace,
    generation: u64,
};

fn summarize(request: Request) contract.Error!contract.Snapshot {
    return request.provider.summarize(&request.workspace);
}

const Slot = latest.LatestTask(Request, contract.Error!contract.Snapshot, summarize);
const Cache = snapshot.Cache(contract.Snapshot);

pub const Session = struct {
    slot: Slot,
    cache: Cache,

    pub const Publication = union(enum) {
        published,
        discarded,
        failed: contract.Error,
    };

    pub fn init(io: std.Io, ttl_ms: i64, now: *const fn () i64) Session {
        return .{ .slot = Slot.init(io), .cache = Cache.init(ttl_ms, now) };
    }

    pub fn initWithGroup(io: std.Io, ttl_ms: i64, now: *const fn () i64, group: *Group) Session {
        return .{ .slot = Slot.initWithGroup(io, group), .cache = Cache.init(ttl_ms, now) };
    }

    pub fn request(self: *Session, provider: contract.Provider, workspace: *const identity.Workspace) error{ Stopped, Unsupported, ResourceBusy }!Slot.Admission {
        if (self.slot.state != .active) return error.Stopped;
        if (provider.kind != workspace.kind or !provider.supports(.status)) return error.Unsupported;
        const generation = self.cache.currentGeneration() +% 1;
        const admission = try self.slot.submit(.{ .provider = provider, .workspace = workspace.*, .generation = generation });
        _ = self.cache.beginRequest();
        self.cache.markStale(workspace);
        return admission;
    }

    pub fn hasActive(self: *const Session) bool {
        return self.slot.running != null;
    }

    pub fn hasQueued(self: *const Session) bool {
        return self.slot.queued != null;
    }

    pub fn startNext(self: *Session) error{ Stopped, Busy, ResourceBusy, ConcurrencyUnavailable }!bool {
        return self.slot.startNext();
    }

    pub fn lookup(self: *Session, workspace: *const identity.Workspace) Cache.Lookup {
        return self.cache.get(workspace);
    }

    pub fn awaitActive(self: *Session) error{NoActiveTask}!Publication {
        const completion = try self.slot.awaitActive();
        if (self.slot.state != .active or !self.cache.isCurrent(completion.input.generation)) return .discarded;
        const value = completion.result catch |err| return .{ .failed = err };
        const actual = value.workspace orelse return .{ .failed = error.Parse };
        const expected = &completion.input.workspace;
        if (actual.kind != expected.kind or !actual.root.eql(expected.root.slice()) or !actual.repository_root.eql(expected.repository_root.slice())) return .{ .failed = error.Parse };
        self.cache.put(expected, completion.input.generation, value) catch return .discarded;
        return .published;
    }

    /// Never publish a cancelled or raced result. Newer queued work retains
    /// its generation and may be started explicitly after this join.
    pub fn cancelActive(self: *Session) error{NoActiveTask}!void {
        const completion = try self.slot.cancelActive();
        if (self.cache.isCurrent(completion.input.generation)) _ = self.cache.beginRequest();
    }

    pub fn invalidate(self: *Session) void {
        self.slot.clearQueued();
        self.cache.ageAll();
    }

    pub fn requestStop(self: *Session) void {
        self.slot.requestStop();
        self.cache.invalidateAll();
    }

    pub fn finishStop(self: *Session) error{ NotStopping, Busy }!void {
        try self.slot.finishStop();
    }

    /// Must run off UI thread; provider and runner must still be alive.
    pub fn shutdown(self: *Session) void {
        self.requestStop();
        self.slot.shutdown();
    }
};

fn clock() i64 {
    return 1000;
}

const Fake = struct {
    fail: bool = false,

    fn detectImpl(_: *anyopaque, _: []const u8, _: *detect.Result) void {}

    fn summarizeImpl(ctx: *anyopaque, workspace: *const identity.Workspace) contract.Error!contract.Snapshot {
        const self: *Fake = @ptrCast(@alignCast(ctx));
        if (self.fail) return error.Parse;
        return .{ .availability = .ready, .workspace = workspace.* };
    }

    fn provider(self: *Fake, kind: identity.Kind) contract.Provider {
        var set: capabilities.Set = .empty;
        set.insert(.status);
        return .{
            .kind = kind,
            .display_name = "test",
            .capabilities = set,
            .vtable = .{ .detect = detectImpl, .summarize = summarizeImpl },
            .ctx = self,
        };
    }
};

test "navigation discards older results and publishes only newest workspace" {
    var fake: Fake = .{};
    var session = Session.init(std.testing.io, 500, clock);
    defer session.shutdown();
    const a = try identity.Workspace.init(.git, "a", "a");
    const b = try identity.Workspace.init(.git, "b", "b");
    const c = try identity.Workspace.init(.jj, "c", "c");
    _ = try session.request(fake.provider(.git), &a);
    try std.testing.expect(try session.startNext());
    _ = try session.request(fake.provider(.git), &b);
    try std.testing.expectEqual(Slot.Admission.replaced, try session.request(fake.provider(.jj), &c));
    try std.testing.expect((try session.awaitActive()) == .discarded);
    try std.testing.expect(session.lookup(&a) == .missing);
    try std.testing.expect(try session.startNext());
    try std.testing.expect((try session.awaitActive()) == .published);
    try std.testing.expect(session.lookup(&b) == .missing);
    try std.testing.expectEqual(identity.Kind.jj, session.lookup(&c).fresh.workspace.?.kind);
}

test "failed refresh retains only stale data and invalidation drops results" {
    var fake: Fake = .{};
    var session = Session.init(std.testing.io, 500, clock);
    defer session.shutdown();
    const key = try identity.Workspace.init(.git, "repo", "repo");
    try std.testing.expectError(error.Unsupported, session.request(fake.provider(.svn), &key));
    _ = try session.request(fake.provider(.git), &key);
    _ = try session.startNext();
    try std.testing.expect((try session.awaitActive()) == .published);
    fake.fail = true;
    _ = try session.request(fake.provider(.git), &key);
    try std.testing.expect(session.lookup(&key) == .stale);
    _ = try session.startNext();
    const result = try session.awaitActive();
    try std.testing.expect(result == .failed);
    try std.testing.expect(result.failed == error.Parse);
    try std.testing.expect(session.lookup(&key) == .stale);
    fake.fail = false;
    _ = try session.request(fake.provider(.git), &key);
    _ = try session.startNext();
    session.invalidate();
    try std.testing.expect((try session.awaitActive()) == .discarded);
    try std.testing.expect(session.lookup(&key) == .stale);
}

test "cancel preserves newer queued work and stopping prevents publication" {
    var fake: Fake = .{};
    var session = Session.init(std.testing.io, 500, clock);
    defer session.shutdown();
    const first = try identity.Workspace.init(.git, "first", "first");
    const latest_key = try identity.Workspace.init(.git, "latest", "latest");
    _ = try session.request(fake.provider(.git), &first);
    _ = try session.startNext();
    _ = try session.request(fake.provider(.git), &latest_key);
    try session.cancelActive();
    try std.testing.expect(try session.startNext());
    try std.testing.expect((try session.awaitActive()) == .published);
    try std.testing.expect(session.lookup(&latest_key) == .fresh);
    _ = try session.request(fake.provider(.git), &first);
    _ = try session.startNext();
    session.requestStop();
    try std.testing.expectError(error.Busy, session.finishStop());
    try std.testing.expect((try session.awaitActive()) == .discarded);
    try session.finishStop();
    try std.testing.expect(session.lookup(&latest_key) == .missing);
    try std.testing.expectError(error.Stopped, session.request(fake.provider(.git), &first));
}

test "two sessions share admission quotas without invalidating rejected requests" {
    var fake: Fake = .{};
    var group = Group.init(std.testing.allocator, 0, 1, 1);
    var first = Session.initWithGroup(std.testing.io, 500, clock, &group);
    var second = Session.initWithGroup(std.testing.io, 500, clock, &group);
    defer first.shutdown();
    defer second.shutdown();
    const a = try identity.Workspace.init(.git, "a", "a");
    const b = try identity.Workspace.init(.jj, "b", "b");
    _ = try first.request(fake.provider(.git), &a);
    try std.testing.expectError(error.ResourceBusy, second.request(fake.provider(.jj), &b));
    try std.testing.expectEqual(@as(u64, 0), second.cache.currentGeneration());
    try std.testing.expect(try first.startNext());
    _ = try second.request(fake.provider(.jj), &b);
    try std.testing.expectError(error.ResourceBusy, second.startNext());
    try std.testing.expect((try first.awaitActive()) == .published);
    try std.testing.expect(try second.startNext());
    try std.testing.expect((try second.awaitActive()) == .published);
    first.shutdown();
    try std.testing.expect(second.lookup(&b) == .fresh);
    second.shutdown();
    try group.checkDrained();
}
