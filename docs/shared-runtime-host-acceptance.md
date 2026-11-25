# Shared Runtime: deferred real-host acceptance

Status: **NOT VERIFIED**. CI exercises standalone Windows/Linux code and repository fixtures. It does not prove safe integration with the actual Pulse host. This checklist is deferred by request, not waived. Do not ship a production VCS panel or mark the checks passed without evidence.

## Prerequisites

- Record exact Pulse build, SDK preview/ABI, Windows build, architecture, Zig pin, commit, package hash and installed extension versions.
- Use an isolated extension store/profile, disposable repositories and private temp directory. Never test destructive operations on user data.
- Verify the supported host SDK interfaces, callback lifetime, UI dispatch and disable/unload contract; no private host hooks.
- Full Windows and Ubuntu CI including Regression gate, mandatory real VCS fixtures and Windows Job Object tests must pass first.

## Host test matrix

| Check | Procedure | Pass condition |
| --- | --- | --- |
| Activation rollback | Inject failure at each registration/mount/subscription step | No dangling callback, model or task; repeat enable works |
| Navigation | Rapidly switch directories, Git/JJ colocated, SVN and non-repository directories | Latest generation only; no stale result presented as fresh; UI remains responsive |
| Busy shutdown | Close panel/disable/exit while querying and while cancellation races completion | No new admission; join and callback drain before userdata/DLL destruction |
| Tree lifecycle | Run controlled fixtures with descendants, inherited pipes, output overflow, timeout/cancel and parent exit | Owned job active count reaches zero; no unrelated termination; containment fault blocks success |
| Multiple addons | Activate two actual consumers with independent resource domains; stop one while other runs | Other tasks and data remain valid; no shared-owner destruction |
| Shared service feasibility | Measure duplicate workers/caches and verify official supported distribution/ABI before proposing cross-DLL coordination | No hidden global state or mandatory DLL/service; independent fallback |
| Resource plateau | Record baseline and repeated open/query/close/disable cycles, idle and load; sample Private Bytes, commit, working set, handles, threads, child count, CPU and GPU where applicable | No monotonically growing retained resources; tracked counters drain; actual peaks/plateau reported |
| Fault injection | OOM, missing CLI, changed executable, denied directory access, failed cleanup, malformed output, blocked Job assignment | Typed failure; no automatic unsafe fallback or fabricated success |
| Disk/log lifecycle | Use private per-session directory, quota exhaustion, rotation, interrupted write, deletion denial, restart | No overwrite or deletion of unrelated files; failures retained/reported; no unchecked crash scavenging |
| Upgrade/rollback | Install compatible and incompatible versions, disable/uninstall and return to prior package | No stale callback or orphan worker; user configuration preserved |

Attach logs, exact commands, resource samples and pass/fail per case. For not-run cases retain NOT VERIFIED and reason. Do not force-unload on timeout. A failed drain is a release blocker, not a reason to leak or detach a thread.

## Non-host gates still required

CI must validate the actual latest revision, not an earlier green ancestor. Approved-local is a bounded path/digest check, not a race-free trust boundary or sandbox. Do not auto-approve PATH or untrusted VCS configuration. Persistent crash recovery requires an independently established private directory ownership and crash-safe manifest/lock; absent proof, retain unknown files and report them rather than delete by prefix. Current session rotation is not a crash journal. Cross-DLL aggregate runtime is not implemented.

Historical blocker: Windows CI 45453154189 canceled during aggregate tests. The revised cleanup ordering and isolated Job Object tests passed in full CI 45514152046 at 2759b51, which was merged into main. Real-host acceptance remains NOT VERIFIED. New candidate code must be verified independently.

Host-owned task follow-up: verify actual tasks.create/get/cancel/release ordering, queued cancellation without work, completion before create returns, terminal observation and dispatch callback before post returns; measure task cancel latency with real CLI and prove no callbacks/work survive unload. Explicitly record NOT VERIFIED until the native extension is integrated. The new host-query bridge does not yet implement automatic completion delivery or immediate cancellation of an in-flight provider command.

UI controller candidate adds fixed refresh/cancel/check-result commands and one active/one latest selection. Actual host subscription, owner-event pump delivery, task eviction/teardown behavior and automatic completion notification remain NOT VERIFIED. Do not add an unbounded dispatch retry loop or UI-thread blocking wait to make a demo appear complete.
