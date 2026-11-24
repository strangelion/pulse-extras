# Shared Runtime / 共享内存与资源管理运行时

Status: **partial RT0 implementation on the experiment branch; remaining design and acceptance gates below**.
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
Provider-specific overrides and other allocations must be audited. The RT0 candidate
rejects zero deadlines and caps outstanding output objects at eight per runner, including
zero-byte reservations. Production interactive work must have a finite deadline.
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

RT0 candidate: shared/process/run.zig removes the DLL-local static Threaded I/O
and injects a caller-owned std.Io. Tests use the stdlib test I/O owner.
The serialized runner does not own the I/O lifetime. Its logical output quota
reserves requested stdout/stderr caps during execution, then releases the
unused capacity on completion and retains only actual output bytes until
Outcome.deinit. Matching allocator buffers are freed on deinit; error paths
undo reservations. The live-outcome count still bounds zero-byte results. Default quota 16 MiB; per-request finite deadline required.
The owner must remain at a stable address until all outputs are destroyed and
checkDrained succeeds. The next RT0 candidate wraps the Runner allocator with
shared/runtime/allocator.zig: a separate 32 MiB requested-live-byte quota, with
checked alloc/resize/remap/free, coherent reservation counters and OOM rollback.
A short lock protects only accounting; the backing allocator must support its
callers' concurrency. Peak includes in-flight/failed reservations, not RSS or
allocator metadata. Runner remains serialized. requestStop closes admission;
finishStop rejects live outcomes or allocations and is idempotent after drain.
The next candidate adds a single pending std.Io.concurrent future per Runner.
Both entry paths validate bounded argv/cwd (128 arguments, 64 KiB of input
bytes), nonempty executable/cwd and embedded NULs, and explicit environment
maps (256 entries, 128 KiB of key/value bytes). Start copies argv/cwd and any
explicit environment into owned bounded allocations before submission, refuses
simultaneous live outcomes and releases inputs only after join. Null environment
still inherits; a copied environment is not a trusted environment policy. Await/cancel joins before freeing the input arena and consumes output
once. A canceled I/O operation maps to Cancelled; raced completion is freed
and reported separately. Stop closes admission, then explicit cancel/join is
required before finishStop. No detached work or extra resident pool. This is
one stdlib task's cooperative cancellation, not guaranteed OS process-tree
termination. The I/O owner must outlive the task and enforce finite concurrency.
Run/await/cancel remain unsuitable for host UI callbacks. Actual VCS provider
summary orchestration, trusted environment policy, job-object containment and
real host runtime ownership remain to be verified.
Do not create uncontrolled process-wide I/O facilities or claim DLL unload
safety before proving host callback/worker drain.

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

### Runtime check implementation (RT0 candidate)

Unit tests cover budget overflow, exact capacity, backing OOM rollback, failed and successful resize/remap, zero-byte allocations, alignment-sized allocations, independent owners, output/error cleanup, finite single-child timeout, stop/admission/drain and 12 repeated runs. These are ordinary full CI tests; no new resident service or dependency. Do not infer process-tree cleanup, true concurrency stress, cross-DLL ownership, memory safety of arbitrary native libraries, or real-host unload from them. Extend acceptance with an owned process-tree harness and actual host lifecycle before enabling asynchronous UI. For multi-plugin coordination evaluate supported host API/IPC, independent resource domains and measured duplication only after real consumers exist; no hidden global DLL state.

### Single pending job acceptance (candidate)

Reuse pinned Zig's documented `std.Io.concurrent`, `Future.await` and `Future.cancel` ([0.17.1 API](https://izrino.github.io/zig-docs/en/0.17.1/std/Io/)). Tests cover stack-backed argv copy, busy/duplicate admission, one-time outcome transfer, OOM input rollback, single-child cancellation, stopping with an outstanding job, independent runners and concurrent allocator accounting. Await and cancel are serialized owner operations; no concurrent call to the same Future. A running process may finish before cancellation, in which case discard its result without claiming it was killed. `finishStop` fails while a pending task exists. Before UI integration prove cancellation on actual Windows host, bound the whole child tree from creation, test descendants retaining inherited pipes, and implement owner-thread completion delivery. Never kill by reused PID or scan/terminate unrelated processes.

### Format and input ownership follow-up

CI 45448198471 stopped at zig fmt on shared/process/run.zig and shared/runtime/allocator.zig (extra blank lines). Remove the identified whitespace; CI now checks formatting before installing VCS tools and, on failure, prints the exact formatter diff from its disposable checkout and fails, without committing formatting changes or running tests on an altered tree. The latest candidate also validates synchronous/asynchronous request bounds before allocation/spawn, deep-copies explicit environment maps with the same bounded allocator, and drains pending futures even on test assertion failure. Do not log environment contents. A trusted environment policy, actual process-tree containment and real host acceptance remain outstanding. Previous runtime baseline 6a9083a passed Windows/Ubuntu CI 45447221739; the async candidate requires new full CI.

### RT0 resource retention and diagnostics follow-up

The Runner now returns unused stdout/stderr reservation capacity immediately
on completion (actual returned lengths remain reserved); the bounded allocator
continues accounting separately for allocated bytes. Repeated short commands
no longer each hold their entire requested output cap until their result is freed.
Owner-thread diagnostics expose state, pending flag, locked allocator snapshot,
and completed/failed admitted-execution counts and output reservations only
when no future is pending. Worker-owned counters are unavailable (null) before
join, not read concurrently or reported as zero. No secret, path, argv, payload,
logging daemon, periodic sampling or new allocation is required. Completion means
a process result was returned, not necessarily zero exit; failed counts admitted
execution errors only, not policy rejections.

Add opt-in explicit_local admission: fully qualified local executable and cwd,
explicit environment map, no drive-relative/UNC/device paths on Windows. Both
modes enforce configured finite maximum duration (initial default 5 minutes;
product profiles may choose shorter or longer), input bounds and environment
name validation. Configure only while idle. This is lexical validation, not
trusted binary identity, ACL verification, reparse containment or environment
allowlisting. Compatibility mode preserves current provider/test call sites;
production VCS adoption requires actual trusted executable resolution and
controlled environment/cwd, not automatic promotion of compatibility mode.
Process tree containment is still not implemented. Do not claim that Future
cancel or the output quota proves descendant cleanup.

### Bounded latest-only task slot and VCS consumer (RT0 candidate)

`shared/runtime/latest_task.zig` provides one running std.Io future plus one replaceable queued value. Submission replaces only the queued request; no private pool, unbounded queue, periodic timer, or inline fallback on ConcurrencyUnavailable. The caller drives start/join/cancel, owns the I/O, and keeps borrowed contexts alive until removal or join. Values must be copyable and contain no independently owned allocations/handles. Stop drops queued work; finishStop rejects active work; shutdown joins. This is deliberately latest-only, not a general conversion/write job queue. Do not drop non-idempotent operations.

`shared/vcs/session.zig` consumes the slot for whole-provider read-only summaries, not just individual commands. A new request advances cache generation and marks that key's prior result stale. Outdated, cancelled, invalidated and stopping results never publish; current errors stay typed rather than becoming clean snapshots. Verify returned workspace identity before publication. Provider and Runner lifetimes are caller-owned and exclusively reserved until work drains. Do not call Runner diagnostics concurrently while it is used by an external provider worker. Existing real Git/JJ/SVN integration fixtures now exercise session execution and preserve their original assertions. Two slot tests and three session tests cover 1,000-request coalescing, stop, invalidation, failure, cancellation race and generation behavior.

This is host-independent code. Real Pulse UI completion delivery, actual plugin lifecycle, resource plateau and mixed-plugin acceptance are explicitly deferred, not waived. Windows process-tree ownership and descendant/pipe containment remain implementation gates before exposing execution of untrusted repositories or commands in the host. Keep compatibility mode separate from trusted execution policy. No new dependency or workflow.

### RT0 remaining non-host primitives (candidate)

Optional Windows x64 tree backend: std.process.spawn with start_suspended, private unnamed Job Object with kill-on-close and 16 active-process limit, assign before ResumeThread, bounded dual-stream collection and a single monotonic deadline through descendant exit. No fallback on containment failure. Cleanup terminates and checks active-process accounting; cleanup timeout is a distinct error, not proof of cleanup. Root/descendant tests run on Windows CI. This is not a sandbox and cannot protect against arbitrary native code or job escape through external privileged services. Existing Runner direct-child mode remains the default until the new backend passes CI. Windows only; other targets reject explicit tree policy. Actual host unload remains deferred.

Approved-local execution is opt-in: explicit immutable approved path/digest, bounded streaming SHA-256 verification before spawn, no PATH-based approval, narrow environment allowlist. Verification by path is not race-free against a writable or replaceable installation and does not prove ACL/ancestor reparse safety or safe VCS config. No untrusted repository execution claim. Product approval/controlled tool configuration and stronger handle-based identity remain necessary.

Group composes a parent bounded allocator with child allocator limits and owner-thread aggregate queued/running quotas. LatestTask and VCS Session optionally consume it; fixed-capacity FifoTask rejects full admission, preserves order and reports queued cancellations explicitly. It does not silently discard write/convert tasks. Queue accounting is serialized on a single owner, not a cross-DLL global coordinator; child memory quotas use the existing allocator lock. Group outlives children; call checkDrained after all joined. No background scheduler or priority inversion claim.

Runtime event ring holds 64 typed numeric records, redacted and automatically evicted, with on-demand read only while worker-owned state is available. Temp Store uses caller-owned private directory handle, exclusive creation, eight-file cap and byte reservation before writes. Explicit cleanup attempts all owned files, retains failed deletions for retry, never recursively deletes or scans unknown files. It does not yet implement durable crash-recovery manifests or persistent rotating log export. Caller must establish exclusive directory ownership; no claim of security against other directory writers. No real Pulse host required for these tests. Host lifecycle, actual memory/CPU measurements, multiple installed plugin coordination and UI callbacks remain deferred.
