# VCS candidate: deferred real-host acceptance runbook

Status: **NOT VERIFIED — do not release**. Code supports a default protected Windows approval slot
and locks execution when no valid approval is present. No test
package is installed or host executed by CI. Published SDK pin v1.0.60,
installed host 1.0.61; record actual host and binary digest.

## Build and provision

- Run full regression on exact commit: zig build test, then
  zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe.
- Default build loads a Windows-user approval slot; no saved approval means locked.
  A trusted compiled provisioning override remains available for fixtures only.
  The default manager and explicit CLI no longer require rebuilding to grant.
- Use a disposable Windows user and a deliberately restricted, independently
  trusted Git bundle (at most 512 files, 256 MiB, 96 KiB total paths, 12 levels). Stock Git for
  Windows installations generally exceed this profile; do not bypass checks.
  An isolated Pulse store/profile alone does not isolate HKCU.
- Prepare an existing private neutral directory containing exactly one empty
  pulse-git-global-empty.conf, and an ordinary Git root with no nested Git,
  symlinks/reparse points/hard links, active hooks, submodules or unsupported
  index/config features. Root ACLs must permit mutation only by the explicitly
  trusted process user, SYSTEM and local Administrators. Existing ancestor
  directories may grant unrelated sibling creation but not delete-child,
  rename, ACL/owner or other mutation rights; actual tree entries remain
  strictly checked. The actual OS Windows directory is a trusted platform
  dependency and must match the OS API, not an injected environment value.
- Run the explicit approval tool with the built DLL:

      python scripts/vcs_approval.py --dll <pulse_vcs_panel.dll> approve --git <git.exe> --installation <bundle-root> --repo <repo-root> --neutral <neutral-directory>

  Inspect paths, every installation file digest and reviewed evidence; type
  the exact confirmation token. The tool does not create or modify the
  repository or installation. Native inspection and confirmation independently
  recheck inventory, local identity, ACLs, config, index and environment.
- Approval is stored as a bounded DPAPI-protected single HKCU value in
  Software\Strangelion\PulseExtras\VcsTest\v1. No plaintext approval file or
  automatic migration. Revocation overwrites that value with a tombstone.
  Windows user/admin code remains trusted; DPAPI is not protection against
  arbitrary same-user code, administrators, rollback of the user's registry,
  or OS compromise. Registry write persistence follows Windows hive semantics.
- Revoke from the native panel or:

      python scripts/vcs_approval.py --dll <pulse_vcs_panel.dll> revoke

  Other active sessions recheck the exact saved record before/after each
  audit and reject replaced/revoked approval. An already running command is
  not rolled back. Explicit cancellation and host task drain still apply.
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
actual installed host drain and scoped trust-storage validation, complete verification and
a separate publication decision. No signature, registry or distribution
is implied by staging.

Automated regression coverage includes session wiring and exactly-once source
release, reviewed environment drift, revoked in-flight summary discard and
future navigation denial, malformed record and package-tool failure/success.
The actual host, actual provisioned auditor and installation remain deferred.
