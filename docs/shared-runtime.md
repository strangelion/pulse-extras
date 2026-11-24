# Shared Runtime / 共享内存与资源管理运行时

Status: **design and implementation requirements**, not an implemented runtime.
This document is the common contract for every Pulse Extras product extension.
It belongs to P1.5 and does not replace the provider contract, public SDK or
release design. Build the minimum needed by VCS first, then evolve from measured
requirements of other products. No empty modules, custom GC or speculative framework.

## 1. Decisions and dependency direction

Zig 0.17.1, Windows x64 MSVC native DLLs; use the pinned compiler's actual
standard-library source. Zig has explicit allocation and cleanup rather than
automatic heap GC or a borrow checker. ReleaseSafe checks selected errors but
does not prevent every use-after-free, data race, allocation failure, panic or crash.

Share implementation, **not process-wide mutable state**. Use internal Zig
modules compiled into each DLL (or static linking where useful). Each plugin
instance owns its own runtime/session/tasks/allocator/budgets. Small probes and
synchronous functions can use a minimal scope; do not force a worker pool or a
heap allocation into an otherwise allocation-free path. Every product must
follow this contract and reuse applicable tested primitives rather than invent
another scheduler, allocator wrapper, cancellation model or process manager.

No additional mandatory DLL, service, installed dependency, background process
or hot-swappable global memory manager. DLL-local state is not actually global
across independent DLLs. Per-instance budgets do not enforce a host-wide limit;
several plugins can run concurrently. Track aggregate measurements in multi-plugin
acceptance. Consider an optional shared out-of-process service only if evidence
shows real duplicate heavyweight work and the host/registry support the design.
It would require a separately reviewed protocol, version negotiation, authentication,
failure recovery, privacy, ownership, resource policy and lifecycle. Never share
raw heap pointers, allocator objects or Zig ABI across DLLs/processes.

```text
extensions/<product>       business policy, UI, operation-specific limits
    -> shared/runtime      lifecycle, task ownership, cancellation, scopes
    -> shared/process      bounded argv, process tree and I/O (existing module)
    -> shared/memory       budget, scoped allocation and diagnostics
    -> std / platform adapters
shared/pulse               public SDK wrappers; borrowed/owned boundary
shared/diagnostics         bounded redacted local diagnostics
```

Exact file names may evolve. Keep one dependency direction, no cycles and no
provider-specific logic inside the runtime. Reuse shared/process rather than
introducing a second subprocess implementation. Introduce common cache policy or
worker primitives when actual consumers share them; do not replace the VCS cache
with a generic abstraction before correctness tests exist.

## 2. Scope, ownership and lifetime

| Scope | Owner | Release condition |
| --- | --- | --- |
| Instance | DLL entry/destroy | Host callbacks and tasks drained; destroy completes |
| Activation/session | activate/deactivate | No new tasks; callbacks and workers quiescent |
| Panel/subscription | UI owner thread | Close/unsubscribe acknowledged under SDK contract |
| Task | runtime job | Completion/failure/cancellation followed by actual worker exit |
| Temporary arena | one task or bounded parse phase | All consumers complete; reset/deinit by owner |
| Snapshot/cache | session/cache owner | Eviction, replacement, invalidation or session shutdown, after readers release |
| External resource | explicit handle owner | Matching close/release/terminate-and-reap as appropriate |

Use explicit init/deinit, defer and errdefer; reverse-order rollback on partial
initialization. Cleanup must be valid on all success, error, OOM, cancellation
and partially activated paths. Never allocate with one allocator and free with
another; distinguish owned, borrowed and transferred buffers. Copy borrowed SDK
data before the callback returns, according to the precise header contract.
Respect SDK thread affinity, callback lifetime and synchronous-copy rules.
Do not store slices into temporary arenas in cache, host callbacks or pending jobs.
Cross-thread publication transfers ownership or makes a bounded owned copy.
Do not confuse an atomic generation counter with synchronization or memory lifetime.

Prefer standard allocators and small wrappers over a new allocator implementation:

- Long-lived instance/session objects: explicit owned allocator with matching frees.
- Short-lived task/parsing objects: ArenaAllocator where useful, deinit after task
  completion; retained capacity must have a measured upper bound. Never use an
  unbounded process-lifetime arena. For streaming/long jobs reset phase-local arenas
  only after no consumers remain.
- Fixed small objects: stack or FixedBufferAllocator within measured stack budgets.
  No unbounded recursion or enormous stack arrays. Oversized requests fail safely.
- Pool/reuse buffers only if profiling justifies it. Reclaim retained capacity on idle,
  memory pressure or session close according to bounded policy; avoid frequent
  global trim cycles. No forced host working-set trimming or attempts to free host memory.
- Test owned logic with std.testing.allocator and standard allocation-failure tools
  where supported by the pinned version; inject failure at every meaningful allocation.

## 3. Resource accounting and limits

Provide one common budget policy with product-specific profiles rather than a
single arbitrary limit for every workload. Account for live allocations, peak
allocations, reserved/retained bytes where observable, task count, queue length,
handles, threads, process children, cache entries/bytes, file descriptors, output,
temporary disk and elapsed time. Counters use checked arithmetic and thread-safe
reservation/release; reserve before allocating or queueing, roll back on failure,
and avoid accounting overhead or double-counting allocations shared across scopes.
Allocation wrappers must correctly implement alloc, resize, remap and free as
required by the pinned stdlib, including failed resize/remap; test alignment,
overflow, concurrency and zero-length behavior. Do not claim byte-perfect OS memory
measurement from allocator counters.

Require explicit finite defaults, validate configuration and reject unsafe values.
Record the rationale and baseline for each product. Define task cap, session cap,
cache cap, stdout/stderr caps, concurrent jobs, pending queue, timeout, temp storage,
retention and maximum parsed sizes/depth. Use checked multiply/add before allocation.
Budget exhaustion returns a typed error or explicit bounded partial result; do not
abort Pulse, silently truncate a successful result, or retry indefinitely. Apply
backpressure, cancel obsolete jobs, evict safe unpinned entries, or stream/page
instead of loading an entire object. No automatic fallback to an untracked allocator.

Initial existing VCS limits (not a measured overall memory guarantee): process request
defaults stdout 4 MiB, stderr 1 MiB, timeout 10 seconds; snapshot cache has 8 entries.
Provider-specific overrides and other allocations must be audited. A zero timeout
currently maps to no timeout; production interactive work must have a finite deadline.
Choose actual aggregate budgets after measuring small and large workloads; do not
promote arbitrary example thresholds to universal limits.

Third-party native libraries, OS allocations, child processes, memory-mapped files,
GPU resources and driver caches may bypass a Zig allocator budget. Use supported
library limits/allocation callbacks, checked input dimensions/decompression ratios,
streaming, process-level quotas or worker isolation as appropriate. Report untracked
resources explicitly. Never claim a budget is a security sandbox or a hard total
process limit. Job Objects control owned processes/resources but not filesystem or
network access.

## 4. Runtime, cancellation and DLL lifecycle

The current shared/process/run.zig has a DLL-local static std.Io.Threaded/shared_io,
uses page_allocator and Runner.deinit is a no-op. This is an outstanding lifetime
risk, not a proven leak or crash. Inspect actual Zig 0.17.1 std.Io.Threaded requirements,
including any process-wide state, before choosing explicit ownership/injection. Do
not create uncontrolled independent process-wide facilities just because the source
is linked into different DLLs. No background execution after unload. Refactor with
the real process runner, not a parallel unused module.

State machine: uninitialized -> initialized -> active -> stopping -> inactive;
destroy is terminal, including partially initialized and failed-activation cases.
Reactivation creates a fresh generation/session. Only supported transitions allowed;
stop is idempotent under the defined owner/thread rules. New work must be rejected
once stopping begins. Use structured task handles, finite queue and concurrency,
cancellation tokens, deadlines, generation IDs and ownership of results. No detached
threads or raw callback userdata without a lifetime contract. Cancellation is a
request, not proof of completion; stale results are safely disposed of.

Shutdown protocol (adapt order to the exact SDK contracts and dependencies):

1. Transition to stopping, reject new work, invalidate pending generations.
2. Unsubscribe/disable new host callbacks and UI events; retain userdata while any
   callback remains reachable. Use the SDK-specific acknowledgment/drain rules.
3. Cancel queued/running tasks, interrupt supported blocking I/O, terminate and reap
   only owned child processes/trees using verified mechanisms. Close owned pipes and
   handles in the safe dependency order.
4. Drain and join workers and in-flight callbacks; ensure no worker waits for UI
   dispatch while the UI thread is joining it. Prevent self-join/deadlocks. No
   arbitrary force-kill of threads or timeout-based free of live data.
5. Close remaining UI/models and release results, task arenas, cache, session
   resources and owned I/O runtime after all their users stop.
6. Release instance/allocator in destroy only when no reachable callback/thread or
   module reference remains. Return across the C ABI only according to the official
   lifetime contract.

The host destroy callback returns void, not a veto of unload. Do not rely on being
able to decline unload, leak userdata forever, pin the DLL, or return early when
a thread still executes its code. Design cancellable finite operations and prove
safe drain within the host's actual lifecycle contract before enabling a feature.
If safety cannot be proven, move the risky work into a separately managed process
or leave the feature disabled; escalate unresolved SDK limitations upstream.
A hung in-process native library cannot be safely made cancellable by killing its
thread. Separate profile is not OS-level isolation.

Process runner: trusted absolute executable and argv; controlled environment/cwd,
noninteractive operation, output caps and finite deadline; distinguish launch
failure, exit status, timeout, cancel, truncation, OOM and permission failure.
Windows process-tree ownership (e.g. Job Object) must handle launch/assignment races,
descendant escape, pipe EOF and failure cleanup; verify POSIX test behavior separately.
Never terminate processes not owned by the job. Avoid unbounded spinlocks or UI waits.

## 5. Cache, logging and resource pressure

Use bounded cache entry/byte limits, appropriate keys, explicit ownership and TTL/LRU
where useful. VCS keys include provider/repo/workspace, canonical identity and query
parameters; verify request generation atomically with publication. Coalesce refreshes
and avoid polling when inactive/closed. Cache invalidation/eviction must not free live
reader data. Distinguish missing, unknown, stale, partial and actual zero/empty.
Do not keep expired data indefinitely, silently refresh with writes, or retain user
files as generic cache content. Each product specifies what may persist.

Diagnostics opt-in/local by default: per-instance/job IDs, current/peak tracked bytes,
active allocations, worker/queue/child/handle counts, truncation, cancellation and
cleanup failures; redact paths/secrets as needed, no file contents or environment
dumps. Bounded rotating logs and age/size policy; cleanup only verified project-owned
temporary/cache files with path confinement. No log per allocation in release mode,
no periodic wakeups when idle. Never hide leaks, failures or incomplete cleanup.
Expose concise diagnostics through the product's supported UI/diagnostic output.
Do not implement telemetry or an always-running global dashboard by default.

## 6. Product-specific policy

| Product | Main limits and additional defenses |
| --- | --- |
| VCS | CLI output, path lengths, history/diff paging, process trees, cache generations |
| Convert | dimensions/pixel counts, codec working sets, streaming, output staging, temp disk, cancellation |
| Inspect | PE/archive bounds, integer arithmetic, recursion, hostile parser input, read-only mapping |
| Data | array shape/dtype overflow, compression ratios, SQLite query/row/time limits, bounded page cache |
| DevKit | trusted toolchains, subprocesses, environment, project-local config, no automatic execution |
| Compare | directory depth/count, traversal/reparse cycles, streaming hash buffers, handle limits |
| Companion | bounded decoded assets, frame/animation budget, visibility pause, actual authorized events and idle CPU |
| Forge | bounded repair jobs, generated code/build scripts untrusted, verified OS containment, network/secret controls |

Every plugin declares actual resource limits and unsupported cases before publishing.
Forge and other high-risk untrusted execution must follow [Forge security](forge-architecture.md);
a shared allocator or process manager cannot provide a security sandbox.

## 7. Verification and acceptance

Ordinary full CI (Windows/Linux) for any shared runtime, memory or process change.
Preserve scope policy in [testing](testing.md). Add deterministic tests as primitives
are used; avoid expensive stress/fuzz/model calls on every ordinary change.

| Test class | Required invariant |
| --- | --- |
| Ownership and partial init | all tracked allocations/handles released on all completed paths |
| Allocation failure | fail each relevant allocation; rollback correct, no panic or leaked reservation |
| Budget and arithmetic | concurrent reservation, resize/remap, oversize/overflow/zero cases, caps never bypassed |
| Cancellation and timeout | finite teardown, no leaked child/pipe/worker, no unrelated process terminated |
| Lifecycle | repeated init/activate/deactivate/reactivate/destroy, close during query, no callback into freed state |
| Stale result/cache | no stale publication, cross-provider collision, dangling reader or unbounded retention |
| Input robustness | malformed/truncated, Unicode/long path, oversized output, malformed archives/arrays |
| Multi-plugin | independent state, deactivate/unload one while another stays active, mixed released runtime revisions |
| Native host | actual package load/close/disable/exit/upgrade/rollback with SDK rules and recorded logs |

Use deterministic fixtures for required CI, including failure injection. Add actual
DLL load/unload harness coverage for runtime consumers and actual Pulse acceptance;
a C harness is not proof of UI or security. Manual/opt-in deep tests: sustained
navigation, large inputs, long soak, fuzzing, repeated cycles, resource pressure,
multiple simultaneous plugins, isolated worker crash and recovery. Do not mark
unrun tests passed. Use additional native memory diagnostics/guard pages/sanitizer
tools only when supported for this Zig/target; record limits, not fictitious coverage.

Measure tracked live allocations, reservations and peak, process Private Bytes,
commit, working set, handle/thread counts, child memory, latency, temp disk and
idle CPU before/after repeated cycles. Separate allocator-retained memory from
leaks; compare against baseline/steady-state plateau, do not demand OS working set
return exactly to its starting value. Scope-level live owned allocation/handle
counts must return to their documented baseline after drain. Track per-plugin
and host aggregate separately. Establish reproducible measurement and justified
thresholds before claiming performance or regression limits.

## 8. Iteration, distribution and compatibility

Maintain a single internal shared runtime source/API revision. Initially track
the source commit and relevant module hashes in build/release metadata; adopt an
independent SemVer runtime package/API version only when it solves a real
compatibility need. This is not a second public Pulse ABI and not a separate
user-installed extension. Runtime fixes reach packages when rebuilt and released,
not when source changes in Git. Never replace a loaded runtime/DLL in place.
Keep each product version independent and record the bundled runtime revision,
toolchain and SDK pin in build evidence. Older installed packages retain their
old runtime; report which released versions are affected by a defect and publish
updates for all affected consumers after full CI and host acceptance. Do not force
unaffected packages to update. Mixed runtime revisions must coexist without sharing
mutable objects, allocator memory or private process-global settings. For an urgent
security issue use the official release/registry revocation process where applicable.

Change process: reproduce -> add failing regression -> minimal shared fix ->
run all affected consumers/full CI -> measure overhead -> update this contract and
changelog/evidence -> rebuild affected packages -> signed independent release.
Review compatibility and failure paths before refactoring; avoid a big-bang rewrite,
premature object pools, always-on monitoring, unused abstraction or new external
dependency. Follow [release design](release.md).

## 9. Staged delivery

RT0 (P1.5): audit actual owners and callback lifetimes; fix process runtime
initialization/drain, task cleanup and bounded allocation using existing tests;
add failure and timeout/cancellation/descendant regressions. Establish VCS budget
and safe cache publication. Preserve currently green baseline.

RT1 (P2): first actual VCS panel consumes applicable shared runtime; real-host
lifecycle, resource plateau and bounded queue/cache tests. No general-purpose
framework required before the first usable package.

RT2: as each product arrives, reuse the same primitives, add only measured needs
(e.g. codec/streaming resources, additional worker isolation). Run cross-product
and mixed-version tests; maintain version/affected-package tracking and acceptance.

RT3: Forge untrusted author worker containment and optional specialized resource
instrumentation, after actual runtime/package foundations. Any separate broker
or dynamically shared runtime is a new design review, not an assumed next step.

Do not create placeholder directories or claim the above is implemented. The
shared runtime is a continuously maintained foundation, not a separately shipped
GC. Completion of RT0/RT1 means actual consumers and evidence, not merely
additional files or passing mock tests.
