# VCS installed acceptance runbook

Status (2026-11-26): **P2A/P2B candidate; full installed acceptance NOT VERIFIED**.
Unsigned preview `vcs/v1.0.0` is published at df5009c; its locked onboarding
was reported difficult to use. The newer main candidate contains metadata
preview, session trust, settings and bookmarks. The earlier 81b2ad1 code CI passed; later stage candidates and installed
packages must be checked separately. No CI fixture is actual Pulse
UI acceptance. Published SDK pin v1.0.60; recorded installed host 1.0.61.
The authoritative stages and exit gates are in [roadmap](roadmap.md#p2--first-real-vcs-extension).
This document defines execution and evidence, not a second development plan.

## Build and provision the strict saved Git profile (separate from ordinary onboarding)

- Run full regression on exact commit: zig build test, then
  zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe.
- The default build can load a Windows-user strict approval slot; without
  it, supported hosts use non-executing metadata preview and explicit
  local-session consent. A trusted compiled provisioning override is for
  fixtures only. The following Python process is for strict-profile testing,
  not a mandatory ordinary-user setup step.
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
| No saved grant, supported host | Metadata discovery only until explicit consent; no CLI; missing dispatch degrades to lock |
| Reviewed package | Exact approved root only; other directories denied |
| Git clean/dirty/untracked | Correct counts; compare with same isolated CLI |
| Navigation A/B/A | Latest generation; stale data suppressed |
| Manual Check result | Eventual result even if early dispatch wake |
| Revocation while busy | Future admission denied, old result discarded |
| Changed executable/config/ACL/dependency | Fresh verification rejects |
| Missing or invalid approval | No implicit CLI admission; candidate discovery and explicit separate local-session review only |
| Cancel/disable/unload while busy | All owned processes/tasks/callbacks drained |
| Reopen and repeated cycles | No retained resources or growth trend |
| Large tree / quota / error | Bounded time, memory, meaningful failure |
| Failed cleanup / host shutdown | No forced unload, report blocker |
| Upgrade/rollback | Private profile intact, no unexpected files modified |

Record exact commands, fixture identity, build SHA, package hash, host
version/hash, peak and idle Private Bytes, working set, commit, handles,
threads, CPU, child-process count, final exit, log and pass/fail. Record
NOT RUN for every unexecuted case. Stable release requires the applicable reviewed trust coverage,
actual installed host drain and scoped trust-storage validation, complete verification and
a separate publication decision. Explicit unsigned preview is a separate test channel; No signature, registry or distribution
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
following references or worktree redirects. Bounded non-executing PATH candidate discovery and a literal bounded origin
hint are permitted; no executable launch, evaluation of config includes or
rewrites, approval write, status counts or repository mutation occurs in this mode. Nearest markers are presented as discovery, not proof of
valid repository identity. Missing dispatch keeps the locked legacy model.
The existing reviewed single-root Git path remains unchanged; native
local-session consent and CLI policies now exist for Git/JJ/SVN. Persistent
multi-root grants and actual installed onboarding acceptance remain open. Verify real host rendering and navigation
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

## Stage-specific installed acceptance register (mandatory; current status)

The roadmap defines the complete delivery scope. Record these cases against
the exact package/source/host, expected result, actual observation and evidence
path. All rows below remain NOT VERIFIED unless an exact run is supplied.
A user can exercise one consolidated package checklist per completed source
stage rather than reinstalling after each subtask.

| Stage | Case group | Required result | Current evidence |
| --- | --- | --- | --- |
| P2A | First install, right-click empty/file/folder, reopen | One reachable panel; no duplicate; current/selected scope clearly distinguished | Native C fixtures only; NOT VERIFIED |
| P2A | Native tool settings: detect, manual, supported browse, save/reset, restart | Correct separate paths, explicit consent; no execution on save; validated version on probe | Source candidate; NOT VERIFIED |
| P2A | Ordinary Git for Windows, including hardlinks; clean/dirty/untracked/rename/conflict | Correct query, identity/digest checked; no implicit trust | d3dff85 Windows fixture failed on hardlink; 81b2ad1 full regression passed; actual Pulse NOT VERIFIED |
| P2A | JJ standalone/colocated and SVN ordinary Windows working copy | Correct provider-specific summary, no JJ auto snapshot, no unintended SVN server request | Prior provider CI; Windows SVN local-session case NOT VERIFIED (CI provisioner added; exact new run required) |
| P2A | Missing tool, invalid version/path, non-repo, declined/revoked consent, rapid navigation | Honest error/unknown; no stale output or unauthorized command | Mock/unit coverage; NOT VERIFIED |
| P2A | Cancel, close/reopen, disable while busy, exit, older host, theme/DPI/resize and locale | Drain without deadlock, visible fallback, no UI freeze | NOT VERIFIED |
| P2B | Add/current/manual/edit/remove/relink/search/favorite, migration/restart and conflict | Durable independent project records; record removal never deletes repo | Initial bounded bookmarks source; full workflow pending |
| P2B | Project jump, provider switch, nested/colocated workspace and stale root | Correct target and isolated cache; supported navigation fallback | NOT VERIFIED |
| P2B | Persistent multi-root review/revoke/changed tool/root, concurrent windows | Explicit independent grants, revalidation, no cross-project admission | Not implemented |
| P3A | Changed files/history/file and revision diff/refs for Git/JJ/SVN | Correct paged provider semantics, bounds and no implicit write/network | Not implemented |
| P3B | Canonical remote pages, external clients, optional API/offline/revocation | Explicit safe handoff, no credential leakage; local use independent of login | Initial browser bookmark links source; remaining pending |
| R4 | Upgrade/rollback/uninstall, coexistence, repeated cycles/soak/resources | Correct private data, independent owners, measured plateau | NOT VERIFIED |

For each stage, close code + relevant fixtures + full CI first, then exercise
one combined installed artifact; record skipped cases individually. When the
host is not available, report a consolidated list of precise remaining cases
and mark the stage BLOCKED/NOT RUN, not COMPLETE. Do not require the strict
auditor's Python setup for ordinary P2A local-session testing. Do not change
ordinary user profiles or disable antivirus/security products for acceptance.

### P2A consolidated onboarding regression

The candidate now persists an explicit Auto/English/Chinese locale in package
settings; Auto uses the Windows user UI primary language (Chinese -> Chinese,
all other languages -> English). The review and status model displays the
bounded tool version only after the approved version probe and current resolver
handoff, not from discovery or a saved path. Version display is invalidated on
navigation, refresh, revoke and clear. The native settings page retains unrelated
unsaved tool drafts when saving another field and rejects writes on failed model
updates; stale picker requests and conflict replies are covered by fixtures.

CI provisions SlikSVN 1.14.5 on Windows from the vendor archive with a pinned
SHA-256 and administrative extraction into RUNNER_TEMP (no third-party install
script), then requires a local svnadmin repository and modified/untracked working
copy. The test is mandatory on Windows VCS/full lanes, not an optional skip.
This candidate needs exact-source regression and actual host acceptance; the
existing 1.0.0 preview is unchanged. No exact-file picker ABI was available in
the pinned public SDK, so the verified folder picker plus manual absolute path
remains the supported route. Check result remains a deliberate fallback when
the dispatch wake precedes host task terminal publication.

Windows SVN provisioning correction: run 45848217684 failed before the tests
because the vendor download returned HTTP 403. The versioned Chocolatey
package contains the vendor ZIP; extract that exact member, verify the
published inner SHA-256 (corrected transcription), and execute only the
verified vendor MSI's administrative extraction. Never run the community
install script. The new mandatory Windows lane remains unverified until
its actual result; Ubuntu and Companion lanes passed the earlier run.

### P2B project library checkpoint

The project UI precedes tool settings on the one supported settings page.
Old two-line records load without mutation; an explicit edit writes V2 with
stable key, optional name/tags/provider hint, favorite and monotonic recency
(order of accepted navigation, not a timestamp). 64 records, 12 visible rows;
case-folded ASCII search and exact/conservative lexical duplicate check.
Explicit edit binds key and settings version; relink changes only the record,
not the filesystem or any grant. New ID collision after relink is handled by
allocating another bounded key. No automatic scan or authorization on startup.
Navigation uses public pulse.directories parent snapshot/list/open_entry with
files.readDirectory/files.open declarations and exact folder, no reparse entry.
Cancellation is best effort, not rollback; a host routing refusal or missing
path has a visible manual-path fallback. Record last-open order only after
host accepts the action. Physical alias identity, independently protected
persistent multi-root consent and per-provider cache remain pending; no stage
completion claim. Actual installed UI, migration, navigation and lifecycle
must be verified with the whole candidate package.

Explicit local-session reset now offers a fresh repository/provider review in
the same panel after tasks release. The old grant is revoked and local Runner,
I/O and identity pins are retired before returning to non-executing preview.
Busy reset refuses rather than silently racing a worker; cancel/Check then
retry. The strict persisted Git grant remains separate. This is session
switching, not persistent multi-root trust or a per-project cache.

Run 45849966532 reached the extracted, checksum-verified vendor executable;
its exact `1.14.5-SlikSvn` version suffix was rejected by the earlier numeric-only
comparison. Accept the pinned distribution spelling and no other release;
mandatory SVN query results are still pending.

### P2B durable local trust and deferred final acceptance

Owner decision: advance code stages after exact required CI and consolidate
all actual Pulse tests in the final round. P2A 4d53927 / 45850831284 full CI
passed (Windows 686/686 including required SVN); actual host remains DEFERRED.

The project library is independent of consent. The local review now offers
session-only, remember, use previously saved exact approval, revoke selected
root/provider, and revoke all local approvals. The dedicated HKCU DPAPI v1
namespace is distinct from strict saved Git and project settings. Records pin
exact root/provider/tool path, observed root/marker/executable identities and
SHA-256 executable digest. Bounded slots refuse live collisions; a nonblocking
named mutex serializes explicit mutations; a monotonic epoch revokes all
without enumerating paths. Reuse requires explicit selection, valid current
identity and exact digest before any CLI, and the record/epoch is rechecked
before each admitted command. Closing/reset does not erase persistent consent;
explicit revoke does. Saved consent assumes trusted user, installation,
repository configuration and dependencies; not a sandbox, not full config or
TOCTOU audit, not protection against arbitrary same-user/admin code. No automatic
approval on bookmark save/navigation. No bulk grant creation. Review and revoke
are by selected repository/provider; no enumeration dashboard yet.

An eight-entry bounded owner cache uses workspace/provider and revalidated
identity/digest fingerprint. Data is always labeled stale on reuse and never
skips a fresh policy decision or summary. Clear on explicit revoke and close;
no cross-provider or cross-identity reuse. Physical alias deduplication and
selected-folder right-click contribution remain pending; do not claim P2B
complete until the remaining workflow and exact regression pass.

Saved-record format v2 additionally carries a random per-approval nonce. A
revoke followed by an explicit new save does not revive a session holding the
old nonce. Capture the global epoch at explicit consent, not at delayed worker
start; epoch changes therefore invalidate pending approvals. Permission failure
in the saved-trust status path discards any stale cached snapshot. This is
command admission revalidation, not an atomic process-launch sandbox.

### Selected folder and local project identity candidate

Use the same VCS context action on one selected ordinary directory. A fresh
selection revision and exact direct-child path must match the menu snapshot;
files, multiple selection and empty selection keep current-directory behavior.
The public directory route opens only an exact non-reparse folder entry.
The selected path populates the project form, but neither adds a record nor
creates a grant without separate explicit actions. If the settings page or
navigation interface cannot be used, manually open the directory and use the
existing project form. When adding or relinking, Check pending task result
completes the asynchronous identity check and version-checked save. Verify
duplicate rejection, changed selection, refusal/missing target, two windows,
cancel/deactivate during validation, unchanged missing-root metadata edit,
no repository mutations and no execution grants. Existing unobservable roots
are not certified unique. No HOST PASS or new release is claimed.

Selected-folder follow-up run [45919918480](https://github.com/strangelion/pulse-extras/actions/runs/45919918480) failed compilation (C selection entry pointer and shadowed callback name); both errors were corrected and [a387067 / 45922243671](https://github.com/strangelion/pulse-extras/actions/runs/45922243671) passed all required lanes. The identity worker now has explicit cancel, suppresses even raced completed results, and retains the immutable input through failed task release. Added deterministic identity fixtures for alias, missing root, cancel/release failure, and successful versioned write. These fixtures are not real filesystem alias or installed host evidence; exact new CI remains required.

### Scoped saved-record inspection

Current-root metadata preview reads the bounded DPAPI slot for each detected
Git/JJ/SVN scope without launching a tool. An expired epoch or a collision
with another scope reveals no record/path; malformed or unreadable data
is shown as unavailable. A recorded path is explicitly NOT revalidated.
Review uses the saved path when no explicit/configured path takes precedence;
use the existing scope revoke action even if the executable is missing.
Reuse still performs the full pin/digest/epoch/nonce checks. Refresh to
observe changes from another window. Revoke-all remains the fallback for
missing markers or unreadable scopes. No enumeration of all grants or
changes to the strict approval store. Verify per-provider isolation, missing
executable, stale navigation, concurrent revoke, and no CLI on inspect/revoke.
The fixture exercises scoped review and revoke without CLI authorization;
[8b94fb4 / 45923906700](https://github.com/strangelion/pulse-extras/actions/runs/45923906700) passed full CI. Actual Windows persistence and host UI remain deferred. Project open order
is shown as the host settings version of accepted navigation, not a timestamp.

### Project-library approval management, including missing roots

Select a saved project in settings, choose Inspect selected project saved
approvals, then Check pending task result. The exact stored root and three
provider records are shown without checking the filesystem or invoking CLI.
Keep the same row selected and choose the specific provider revoke action;
changes of row, path or settings version reject the request. Check pending
result to observe the durable operation; revoke is not a rollback of a
running command. Inspect again after a failed/unknown result. Matching saved
sessions in this instance are locally locked; another instance rechecks the
store before subsequent command admission. Removing a bookmark is not
revoking a grant and never deletes repository files. All-record enumeration
and unobservable aliases remain intentionally unsupported; use revoke-all
when no specific scope is available. Verify missing/moved root, distinct
providers, concurrent windows, failure/release and installed restart in the
consolidated acceptance. Mocked scope fixtures are not registry or host proof.

### P3A file status candidate acceptance

P2B code gate passed at [147449b / 45925323667](https://github.com/strangelion/pulse-extras/actions/runs/45925323667). For P3A, verify the bounded eight-row file display in Git, JJ and SVN, Git rename source/XY, JJ recorded-only label, SVN property/tree conflict and per-entry revision. Exercise >64 paths, oversized/invalid paths, search, previous/next, refresh, navigation, cancellation, revoke and stale snapshot. Counts must not be reduced to retained rows; paging/search may not execute CLI. History, file selection, diff, refs and native installed UI remain open. New source regression required.

### Consolidated P3A local workspace acceptance

Status code gate passed at 5bfdaa3 / 45926890194. For the advanced candidate,
exercise all Git history/file history (offset and revision selection),
revision info/content, staged/working/revision diff, refs/worktrees; JJ
recorded operation pin and ancestry/file history, revision info/content/diff,
bookmarks/workspaces/operations with unchanged operation log; SVN local info,
properties, BASE and working diff on complete-pristine versions. On newer
SVN and server-history requests the explicit unsupported state is expected.
Use real fixture tracked/renamed/deleted/untracked/property-conflict data;
reject traversal, options, glob/revset injection, external paths/reparse,
binary/invalid encoding/large output, filter and promisor configuration.
Verify old saved records are still inspectable and revocable but require
fresh review to authorize the extended local read policy. Single selected-file
right-click must only populate the path, reject changed selection, and not
launch file history/diff before explicit user action and current consent.
Verify rapid project switching, cancellation, failed task release, close/
revoke and simultaneous windows. Native memory Diff not available on the
public pin; use bounded own view. No installed acceptance or release claimed;
exact new CI required.

### P3B candidate acceptance

P3A code gate passed 378e540 / 45929366805; installed test remains deferred.
For P3B, inspect a project with multiple local remotes, choose one, reload
v2/v3 records and verify provenance, edit/relink/remove without carrying
detected provenance to a different root. Reject raw credential URLs,
unsupported schemes, reserved GitLab routes, redirects and oversized
configs; no .git indirection or include traversal. Open GitHub/GitLab/
Bitbucket repository/issues/review/CI pages and GitHub/GitLab releases;
Bitbucket releases are unsupported, and disabled/private pages may fail.
Verify exact saved client executable, selection and settings version
review, cancel/confirm, unavailable/missing/reparse executable/root,
Unicode/spaces, no shell and no handle leak. VS Code and TortoiseSVN
are the only implemented external adapters. Exercise explicit GitHub public
GET, wrong repository, private/404, 403/429, redirects, offline/timeouts,
oversized and malformed JSON, five-minute expiry, cancellation, selection
change, settings update and unload during a task. No actual account
credential or private endpoint test is authorized; no remote write.
Tests are candidate fixtures; live transport/client/host NOT RUN.
The integration cancel control discards any raced response after terminal
release; it cannot undo an already launched user-owned app/browser. Verify
that selection changes and failed release do not publish metadata, and that
manual/legacy versus locally detected addresses are visible in the table.
Check the matching local summary alongside public metadata, including
unknown/not-queried counts, different project selection, missing panel and
settings reload. Confirm exact external invocation is shown before launch.
CI must pass the independent Windows-header ABI assertions; live HTTP and
actual external clients remain final installed acceptance items.
