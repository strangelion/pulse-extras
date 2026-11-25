# VCS candidate: deferred real-host acceptance runbook

Status: **NOT VERIFIED — do not release**. Code supports a default locked
candidate and an explicitly provisioned reviewed-session candidate. No test
package is installed or host executed by CI. Published SDK pin v1.0.60,
installed host 1.0.61; record actual host and binary digest.

## Build and provision

- Run full regression on exact commit: zig build test, then
  zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe.
- Default build is locked. To exercise reviewed Git execution, provide a
  trusted Zig source via -Dvcs-approval-source=relative/path.zig. It must
  implement acquire(allocator) host.Error!?approval.NativeInput. See
  extensions/vcs-panel/locked_source.zig for the signature.
- Source owns I/O, immutable environment, verified manifest, verifier, probe
  and release callback until session finish. Never load arbitrary runtime code,
  use PATH, invent audit booleans, or trust a record merely because it decodes.
  Provisioning on the UI thread must be bounded and nonblocking. Perform review
  acquisition and independent audit in a trusted preparation workflow.
- Review.encode/decode is a strict PVCSRV01 bounded record format. Store only
  in an authenticated, access-controlled private store; unknown versions and
  tampered records require fresh review. No automatic migration or persistent
  trust on import. Session revocation invalidates future execution and
  discards stale output; durable revocation remains the provisioning source's
  responsibility. No supplied production auditor or persistent store.
- Reviewed session currently supports exactly one ordinary Git root, no write,
  submodule recursion, linked worktree, JJ/SVN or implicit compatibility fallback.
  Git status intentionally ignores submodules in approved mode.

## Package without touching the daily profile

Use the official pulse_ext.py from the SDK pin. Create a fresh output folder:

    python scripts/stage_vcs_test.py --pulse <pulse.exe> --tool <pulse_ext.py> --library <pulse_vcs_panel.dll> --out .local/vcs-stage-1

Inspect stage-report.json; official package verification is not real-host
acceptance. For a fresh separate extension store and profile, use:

    python <pulse_ext.py> --pulse <pulse.exe> --json install <package> --store <isolated-store> --allow-native
    python <pulse_ext.py> --pulse <pulse.exe> --json enable strangelion.vcs-test --store <isolated-store> --allow-native
    python <pulse_ext.py> --pulse <pulse.exe> --json run --store <isolated-store> --profile <new-profile>

Open the extension from Pulse's command palette. Never use the daily profile
or store, never force-unload a live DLL. Record screenshots and opt-in
diagnostic log (ABI_PROBE_LOG only in an isolated private directory).

## Required evidence

| Case | Expected |
| --- | --- |
| Default locked package | Panel opens, no tasks/CLI, lock shown |
| Reviewed package | Exact approved root only; other directories denied |
| Git clean/dirty/untracked | Correct counts; compare with same isolated CLI |
| Navigation A/B/A | Latest generation; stale data suppressed |
| Manual Check result | Eventual result even if early dispatch wake |
| Revocation while busy | Future admission denied, old result discarded |
| Changed executable/config/ACL/dependency | Fresh verification rejects |
| Missing or invalid approval | Fail closed; no PATH fallback |
| Cancel/disable/unload while busy | All owned processes/tasks/callbacks drained |
| Reopen and repeated cycles | No retained resources or growth trend |
| Large tree / quota / error | Bounded time, memory, meaningful failure |
| Failed cleanup / host shutdown | No forced unload, report blocker |
| Upgrade/rollback | Private profile intact, no unexpected files modified |

Record exact commands, fixture identity, build SHA, package hash, host
version/hash, peak and idle Private Bytes, working set, commit, handles,
threads, CPU, child-process count, final exit, log and pass/fail. Record
NOT RUN for every unexecuted case. Release requires reviewed auditor coverage,
durable trust storage, actual installed host drain, complete verification and
a separate publication decision. No signature, registry or distribution
is implied by staging.

Automated regression coverage includes session wiring and exactly-once source
release, reviewed environment drift, revoked in-flight summary discard and
future navigation denial, malformed record and package-tool failure/success.
The actual host, actual provisioned auditor and installation remain deferred.
