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

Verify VCS Binding against real pulse.ui.model: all three command subscriptions survive updates by ID; panel close invalidates userdata; failed close retains resources; user-closed panel update STATE disables commands; stop with a running task does not release provider/Runner storage early. No native entry or automatic completion delivery certified by these mock tests.

Context navigation gate (NOT VERIFIED): verify callback owner-thread affinity and serialization, initial get/subscribe ordering, directory/loading/virtual-view transitions, subscription removal on attachment loss, no callbacks after successful unsubscribe, resolver approval before any command, and stale selection rejection under rapid A/B/A navigation. The mailbox is not an automatic resolver or completion scheduler. Do not certify panel unload or package installation from mock coverage.

Worker resolver gate (NOT VERIFIED): verify owner serialization, one resolver-or-summary task at a time, navigation during approved tool probing/resolution, cancellation and terminal/release failures, stop while policy work executes, and no tool invocation without independent installation/configuration/metadata approval. Discovery's lexical local path check is not an ACL, mount, reparse-point or canonical identity boundary. Actual product approval policy, automatic owner delivery and native extension unload remain required.

Dispatch gate (NOT VERIFIED): public tasks.h has no terminal subscription. Pinned tasks_adapter.cpp publishes terminal state during host Poll after worker return, so a dispatch wake can precede that publication even if posted successfully. Verify owner callback affinity, inline-before-post-return, queue-full and stop suppression, cancellation of retained token and no callback/userdata access after destroy. Explicit owner pump is still the fallback; do not describe this bounded hint as guaranteed completion delivery or add a busy repost loop. A documented host terminal event or supported delayed owner scheduler is needed for a stronger guarantee.

Ordinary Git approval gate (NOT VERIFIED): implement an independently reviewed verifier of canonical local identities, drive/mount/reparse and ACL boundaries, all installation/helper/configuration dependencies and neutral environment; compare approved fingerprints before CLI admission. Test real grant acquisition, changed executable/config, malicious configuration, metadata redirection, linked worktree denial and positive approved-tool execution. Exact argv/hash checking does not eliminate TOCTOU. Native UI, persistence, linked worktree and JJ/SVN authorization remain deferred.

Windows evidence follow-up (NOT VERIFIED): run isolated reparse/junction, hardlink, alternate-volume, inaccessible ancestor/config, renamed path, config replacement and real Git fixtures. Current observations are bounded and read-only but component handles are not held through process creation; check/open/execute races remain. Independent ACL/installation/helper/global configuration and complete metadata/worktree audit are mandatory, and no auditor or grant acquisition UI is supplied here.

A Windows CI fixture now covers ordinary config file observations and hard-link rejection; it is not yet a verified real-host acceptance result.

Windows ACL gate (NOT VERIFIED): validate real owner/DACL handles for controlled directories and files, null/absent DACLs, inherited grants, unexpected ACE types, untrusted create/delete-child and owner changes, and token/impersonation/privilege behavior. The strict allowlist may reject common volume roots; do not relax it without measured and reviewed replacement semantics. Complete independent audit of installation DLLs/helpers, repository subtree and global/system config still required. GIT_CONFIG_NOSYSTEM=1 is only an allowed exact environment value; real Git isolation and positive approved launch remain unverified.
