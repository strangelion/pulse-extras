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

### Context-menu entry (candidate)

The VCS extension now registers the public package-local command
`vcs.open-current` during plugin entry, without opening a panel or loading a
grant. In Pulse's contributed-command menu, choose **VCS: 查看当前目录**.
It accepts a loaded directory with zero or more selected files/folders and
intentionally queries the current directory, not a selected child directory.
Enter a child directory before invoking the command if that is the target.
The public 1.0.60 command descriptor allows only file/directory kind bits;
zero-selection admission is expressed through min_selection=0, not an
unsupported background flag. Host placement is requested as sidebar; if
unavailable the existing panel remains. Repeated invocation does not create
duplicates. Closing/reopening must use the existing drain and approval path;
a busy teardown requires a retry, never forced retirement. The ordinary
activation entry remains available. No new approval, Git write operation,
registry modification or Explorer shell integration is added.

Acceptance: test the file/folder context menu and empty directory menu where
the installed host exposes contributed commands, repeated invocation, closing
and reopening, locked/no-grant operation, navigation, reviewed root admission
and independent Companion coexistence. Verify the actual menu location and
sidebar placement in installed Pulse. The independent C loader checks
entry-time registration, null/wrong-ID rejection, repeated invocation,
reopening after close and host-first shutdown; it is not actual host UI proof.

### No-grant metadata preview

On the default Windows build with the host dispatch interface, a missing or
unreadable approval now permits a separate metadata-only resolver, not CLI
execution. It observes local ordinary directory/file identities through the
existing bounded worker slots, detects Git, Jujutsu and SVN markers (including
colocated Git + JJ), and reads only an ordinary bounded Git HEAD file without
following references or worktree redirects. No PATH search, executable launch,
config interpretation, approval write, status counts or repository mutation
occurs in this mode. Nearest markers are presented as discovery, not proof of
valid repository identity. Missing dispatch keeps the locked legacy model.
The existing reviewed single-root Git path remains unchanged; normal Git
distribution onboarding, native review/consent UI, multi-root grants and
JJ/SVN CLI policy are still open. Verify real host rendering and navigation
before publishing an update. Do not advertise marker discovery as full status.

### Interactive trusted-local session (candidate)

In the no-grant metadata preview, wait for repository detection, enter the
absolute path of an installed git.exe, jj.exe or svn.exe (or leave the field
empty to use a non-executing bounded PATH candidate), then choose the
corresponding Review action. Only detected repository kinds are offered. The confirmation displays the exact copied
executable and root; consent is explicit and session-only. No PATH program
is automatically trusted. Select a provider present at the displayed root;
Git and JJ colocated markers may be selected independently. On confirmation,
the same bounded worker slots switch from metadata-only to provider queries
after the old tasks have drained. The existing strict protected Git approval
path is unchanged; this alternate mode assumes the user independently
trusts the installation, dependencies, repository and their configuration.

The local trust path pins the executable SHA-256, observed executable/root/
marker identities, fixed arguments and exact root, uses a restricted
environment, absolute executable path, neutral Windows directory and
Windows Job Object process containment. Git uses the existing no-optional-locks
status with submodules ignored, JJ uses --ignore-working-copy and SVN uses
local info/status. It does NOT sandbox filesystem/network access, audit
all dependencies/configurations or eliminate TOCTOU; do not trust arbitrary
downloads or untrusted repositories. Only ordinary fixed-drive canonical
paths and directory markers are admitted; linked Git worktrees, SVN paths
with ambiguous peg syntax and unsupported layouts fail closed. Revoke blocks
future commands; an already-running command is not rolled back. Close/reopen
for another root/tool. PATH discovery is a non-executing suggestion, not automatic approval. No
saved multi-root grant, write actions or history/diff UI are included. SVN
queries explicitly disable interactive prompts, auth-cache writes and external
working-copy traversal in status.

Acceptance still requires positive Git/JJ/SVN execution on ordinary installed
tools in real Pulse, native text input and confirmation rendering, stale
navigation/review, cancellation, revocation and teardown tests. No real-host
acceptance or stable release claim is made.

Regression includes native command admission and owner-consent lifecycle
fixtures, plus real installed Git/JJ local-trust queries in Windows CI when
the configured tool is required. SVN local-trust integration requires a
Windows SVN working-copy fixture; do not substitute Ubuntu provider tests
for that result. Closing the binding revokes future local CLI admissions
before cancellation and drain.

### Package-owned VCS settings and project bookmarks (candidate)

The independent VCS settings page uses the pinned public settings-pages and
resources interfaces. Tool paths for Git/JJ/SVN are saved independently
with the host's expected-version check; an empty path restores discovery.
The optional verified 1.0.61 folder picker fills the expected executable
name but does not save, validate a version or grant execution. A configured
path takes precedence over the non-executing PATH hint in the review only.

Projects are explicit bookmarks (up to 32, exact path keys, max 1024 UTF-8
bytes per stored record), not trusted grants. Fill the detected current VCS
root or type an absolute path; save and remove only the bookmark. An ordinary
Git metadata preview may suggest the literal origin from a bounded regular
.git/config; includes and rewrites are not evaluated. Manual remote entry
accepts only canonical GitHub/GitLab/Bitbucket repository locations, including
standard git@ SSH spellings; credentials, arbitrary hosts/schemes, queries
and fragments are refused. The explicit website button hands the canonical
HTTPS URL to the default browser on a host-owned task. No API token, network
sync, remote Git operation, custom executable launch or automatic trust.
Check task result and reopen after drain if needed. Native direct navigation
to a saved path and external desktop clients remain follow-up work.

Validate persistence across restart, concurrent settings version conflicts,
folder picker cancellation, stale selections, bookmark removal without
filesystem modification, no execution on path save and safe browser launch.
Real-host UI/ABI and picker acceptance remain required.

The local-session executable identity check accepts hardlinks (ordinary Git for
Windows installations use them), but still checks canonical local paths,
non-reparse identity and the SHA-256 before execution. The strict persisted
approval path and repository metadata inspection retain their hardlink denial.
