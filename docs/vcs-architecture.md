# VCS architecture / 版本控制架构

`strangelion.vcs` is a multi-VCS manager, not a Git panel with special cases.
Every provider speaks the same contract, but each keeps its own vocabulary and
semantics — a Subversion revision number, a Jujutsu change id and a Perforce
changelist are not modelled as a Git commit.

This document distinguishes the target contract from the implemented subset.
The capability matrix is a design target, not an implementation claim. The
[roadmap](roadmap.md#p2--first-real-vcs-extension) owns complete development
stages and exit gates; [installed acceptance](vcs-acceptance-runbook.md) owns
evidence. Historical paragraphs below record earlier candidate designs, not
current assertions that their successor implementations are absent.

## Current product boundaries (2026-11-26)

The shipped unsigned 1.0.0 preview and latest source are different. Main has
native context-menu entry, owner-thread host task/dispatch Binding, strict
single-Git protected approval and explicit local-session trust for Git/JJ/SVN,
metadata preview, independent tool settings and initial project bookmarks
with canonical browser links. These are source candidates pending exact
regression and installed acceptance; no current complete stage claim.

Keep three separate data domains:
- Tool preferences: non-executing discovery or user-entered paths; save/reset
  through versioned package-owned resources. Never imply authorization.
- Project library: local root/workspace/provider identity plus user metadata
  and sanitized optional remote links; missing paths remain records, not
  implicit scans or deletion requests. Migrate the existing bounded bookmarks
  in P2B. Remote URL is not a unique local identity.
- Execution grants: strict reviewed Git or explicit scoped session trust today;
  persistent independently revocable multi-root/provider consent in P2B.
  Revalidate tool and root identity and fixed admission; do not persist plain
  authorization as project settings or treat Job Objects as a sandbox.

P3A adds provider-native read-only file/history/diff models and commands;
P3B adds explicit browser/client handoff and optional least-scope read-only
forge API. Separate remote/network capability from local Provider behavior;
no arbitrary command templates or automatic background synchronization.
P4 mutations require their own operation-level gate.

## Layers

```text
ui/            panels, pickers, history/diff views (Pulse ui.model + ui.mount)
  |
services/      detection, registry, scheduler, refresh, cache, operation guard
  |
core/          provider contract, capabilities, identities, changes, status,
               risks, errors, operation plans
  |
providers/     git, jj, svn (P0) | hg, p4 (P1) | plastic, sapling, fossil (P2+)
  |
shared/process runner  - bounded argv execution, timeout, cancel, output caps
```

No provider is created before it has read-only behaviour and tests. Empty
provider directories or "supported" flags without an implementation are
forbidden.

## Provider contract

A provider supplies:

- `kind` — stable identifier (`git`, `jj`, `svn`, …) plus display name.
- `capabilities` — the subset of the capability set it really implements, for
  the detected CLI version and the current repository/workspace state.
- `detect` — repository/workspace markers it owns, and the nesting rules
  between them.
- `summarize` — repository identity, current reference, workspace state.
- `status` — local changes, conflicts, unknown/untracked entries.
- `history` — bounded commit/operation log pages.
- `diff` — file-level and revision-level diffs, bounded by size.
- optional `write*` operations, each returning an `OperationPlan` first.

Capability truth is a runtime answer, not a build-time promise:

```text
declared ∩ supported_by_cli_version ∩ supported_by_repo_state
        ∩ allowed_by_user_permissions ∩ reachable_server ∩ read_only_policy
```

Missing capability is reported as one of `unknown`, `unsupported`,
`not_queried`, `not_connected`, `stale`, `empty`. Providers never return an
empty list to mean "could not ask".

## Capability matrix (target)

| Capability | git | jj | svn | hg | p4 | plastic | sapling | fossil |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| repository_detection | ● | ● | ● | ● | ● | ● | ● | ● |
| workspace_detection | ● | ● | ● | ● | ● | ● | ● | ● |
| status | ● | ● | ● | ● | ● | ● | ● | ● |
| history | ● | ● | ● | ● | ● | ● | ● | ● |
| file_history | ● | ● | ● | ● | ● | ● | ● | ○ |
| diff | ● | ● | ● | ● | ● | ● | ● | ● |
| revision_content | ● | ● | ● | ● | ● | ○ | ● | ● |
| branches | ● | ○ | ● | ● | ○ | ● | ● | ● |
| bookmarks | ○ | ● | ○ | ● | ○ | ○ | ● | ○ |
| tags | ● | ● | ● | ● | ● | ● | ● | ● |
| staging | ● | ○ | ○ | ○ | ○ | ○ | ○ | ○ |
| changelists | ○ | ○ | ● | ○ | ● | ● | ○ | ○ |
| commit | ● | ● | ● | ● | ● | ● | ● | ● |
| update / pull | ● | ● | ● | ● | ● | ● | ● | ● |
| push | ● | ● | ○ | ● | ● | ● | ● | ● |
| merge | ● | ● | ● | ● | ● | ● | ● | ● |
| rebase | ● | ● | ○ | ● | ○ | ○ | ● | ○ |
| conflicts | ● | ● | ● | ● | ● | ● | ● | ● |
| shelves / stash | ● | ○ | ○ | ● | ● | ● | ○ | ○ |
| file_locking | ○ | ○ | ● | ○ | ● | ● | ○ | ○ |
| operation_history | ○ | ● | ○ | ○ | ○ | ○ | ○ | ● (timeline) |
| operation_undo | ○ | ● | ○ | ○ | ○ | ○ | ○ | ○ |
| workspaces | ● | ● | ○ | ○ | ○ | ● | ○ | ○ |
| remotes | ● | ● | ● | ● | ● | ● | ● | ● |

`●` = target for the provider, `○` = not planned (the concept does not exist or
the CLI cannot expose it). Anything marked `●` still has to pass contract tests
before it is advertised at runtime.

## Identity model

- `RepositoryIdentity` — VCS kind, canonical root (long/Unicode path, no
  case-folding assumptions), optional remote identity. A repository is not its
  URL.
- `WorkspaceIdentity` — the checked-out working copy: git worktree, jj
  workspace, svn working copy, p4 client, plastic workspace. Shares repository
  metadata with siblings; write locks are shared accordingly.
- `RevisionIdentity` — tagged union per VCS: git hash, jj change id + commit id,
  svn revision number, hg changeset, p4 changelist, plastic changeset, fossil
  artifact. Never assume 40-hex.
- `ChangeIdentity` — the local change: git index/worktree change, jj change,
  svn changelist, p4 pending changelist.

Same-root Git/JJ markers identify a colocation candidate, not proof of shared
storage. Resolve the actual workspace and Git store before grouping identities
or serialising writes; nested repositories must stay distinct.

## Detection

Marker-based, local-first, no disk-wide scans:

| VCS | markers |
| --- | --- |
| git | `.git` directory or file (worktrees, submodules) |
| jj | `.jj` directory (colocated: `.jj` + `.git`) |
| svn | `.svn` directory (1.7+ layout), `svn:externals` properties |
| hg | `.hg` directory or shared-repo file |
| p4 | `P4CONFIG`, `P4CLIENT`, client spec — never a marker file; requires the CLI and an explicit configured environment |
| plastic | workspace mapping files |
| sapling | `.sl`/`.hg` layout of the installed client |
| fossil | checkout database (`.fslckout` / `_FOSSIL_`) |

Detection walks up from the requested path (bounded), merges candidates, and
reports nested and overriding repositories. A directory can host several
workspaces; the UI must let the user choose instead of guessing.

## Risk model

| Level | Examples | Default policy |
| --- | --- | --- |
| `passive_read` | status, log, diff, cat | allowed |
| `refresh` | commands that may write VCS metadata (jj snapshot) | allowed only when proven side-effect free for the detected version, otherwise explicit user action |
| `network_read` | ls-remote queries | explicit authorization, timeout, no credentials prompts |
| `local_metadata_write` | git fetch, hg pull into store | requires an `OperationPlan` |
| `working_tree_write` | checkout, merge, revert, svn update | requires plan + confirmation |
| `remote_write` | push, submit, svn commit | requires plan + confirmation |
| `history_rewrite` | rebase, jj abandon/squash | requires plan + explicit warning |
| `destructive` | reset --hard, clean, force push | disabled by default |

Read-only mode disables every command that cannot be proven passive for the
detected CLI version. Jujutsu is the sharp edge: many query commands snapshot
the working copy. The provider must use documented passive forms and prove
invariance with tests on a dirty tree. The current test covers the provider's
`--ignore-working-copy` queries on JJ 0.46.0, not arbitrary `jj status` commands.

## Concurrency and invalidation

- One write lock per repository root; worktrees and colocated stores share it.
- Locks are advisory inside the plugin: the host, a terminal or another tool
  can still write. Plans are revalidated before execution and cancelled when
  the identity or state changed.
- Reads are coalesced and debounced; slow work runs on bounded background
  tasks and publishes results with a generation counter.
- Caches are bounded (entry count + bytes), invalidated on identity change,
  external modification, explicit refresh, and deactivation.
- Network results carry a TTL and a `stale` flag; offline is never rendered as
  an empty repository.

## Process execution

VCS is the first real consumer of the planned [Shared Runtime](shared-runtime.md). Reuse its
scoped allocation, budgets, cancellation, generation and teardown primitives; keep repository
semantics and cache identity policy in the VCS layer. Do not add a second scheduler/allocator
framework or treat an allocator limit as a host-wide memory cap.

All CLI access goes through `shared/process/run.zig`. Structured argv, timeout
and bounded output are implemented; trusted executable resolution, cancellation,
process-tree teardown, environment control and noninteractive enforcement remain
required work. The runner is not yet validated for DLL unload.

Preferred machine-readable output per provider: `git --porcelain=v2 -z`,
`jj --template`/JSON, `svn --xml`, `hg --template`/JSON, `p4 -ztag`, Plastic
XML, Sapling templates, Fossil JSON. Human/localised text is never parsed for
core logic, and malformed output is a typed error, not an empty result.

## Testing

- Contract tests are shared by all providers.
- Semantic tests per provider: missing CLI, unsupported version, normal repo,
  empty repo, nested repo, Unicode/long paths, add/modify/delete/conflict,
  rename, many files, binary files, truncated output, timeout, cancellation,
  permission denied, external change.
- Integration tests create temporary repositories with the real CLIs
  (git, jj, svn locally; hg when installed). Perforce and Plastic need a
  configured isolated test server; fixture-only tests are parser evidence,
  never "server accepted".

## Delivery order

1. Real host verification (done for commands, context, ui.model, ui.mount).
2. Provider contract, capabilities, identities, detection, process runner,
   risk model, tests.
3. Read-only Git, then Jujutsu, then Subversion — three different models prove
   the contract.
4. Runtime/cache/data hardening, actual native VCS panel and real host acceptance.
5. History, file diffs and revision previews; then Mercurial and Perforce.
6. Plastic, Sapling, Fossil, and the long tail, only with a real need.
7. Write operations, one at a time, with plan + confirmation + regression.

## Historical implementation baseline (2026-11-24)

Implemented and covered by `zig build test`:

- `shared/vcs/capabilities.zig` — declared capability set plus
  `resolve(declared, cli, state)` so the UI can degrade instead of offering a
  command that will fail.
- `shared/vcs/identity.zig` — bounded paths, per-kind revision ids, repository
  and workspace identities that keep the two roots separate.
- `shared/vcs/risk.zig` — risk levels and the default read-only policy.
- `shared/vcs/detect.zig` — injected-probe marker walk (no filesystem, no CLI),
  git worktree marker files and same-root Git/JJ colocation candidates.
- `shared/vcs/provider.zig` — vtable contract, typed errors, availability enum.
- `shared/vcs/cli.zig` — `PATH` lookup, `--version` parsing, a "present but
  unrecognised" state that is unsupported rather than guessed.
- `shared/vcs/snapshot.zig` — bounded cache with fresh/stale/missing lookups and
  generation counters for discarding in-flight results.
- `shared/vcs/providers/git.zig` — read-only `git status --porcelain=v2
  --branch -z` with `--no-optional-locks`: branch, upstream, ahead/behind, staged/modified/untracked/
  conflicted counts, detached HEAD. Parsing is unit-tested from a fixture and
  the provider is tested end to end against a temporary repository when `git`
  is installed.

- `shared/vcs/providers/jj.zig` — revision (change id, commit id, bookmarks,
  conflict flag) and diff summary through `--ignore-working-copy`. Verified on
  jj 0.46.0 that the tested summary leaves the operation log unchanged even with
  an unsnapshotted file. This is provider-query evidence, not a host-panel test. Documented degradation:
  edits that were never snapshotted are invisible, and the summary says so
  through `detail`.
- `shared/vcs/providers/svn.zig` — working-copy revision, `relative-url` and
  `svn status --xml` item counts. Ubuntu CI now tests a real local working copy
  prepared with svnadmin; Windows SVN integration remains explicitly skipped.
  No remote SVN server acceptance is claimed.

Not implemented yet: history, file diffs, Hg/P4 providers, any write operation,
and the provider panel.

### Historical baseline capabilities vs target (not current)

| Capability | Git | JJ | SVN |
| --- | --- | --- | --- |
| Marker detection | Implemented | Implemented | Implemented |
| Read-only status summary | CI verified | CI verified (recorded snapshot) | CI verified (Ubuntu local working copy) |
| History / file diff / revision preview | Pending | Pending | Pending |
| Write operations | Disabled | Disabled | Disabled |
| Native VCS panel / real host | Pending | Pending | Pending |

Baseline: [full CI run 45421511648](https://github.com/strangelion/pulse-extras/actions/runs/45421511648), commit c330c24. Known limits: cache key is currently root-only; caller generation checks are not atomic submission; Git/JJ snapshots and per-field availability need strengthening; SVN counts still need safe structured parsing and distinct semantics. The roadmap sets the implementation order and acceptance gates.

## Reuse and scope control

Follow [product scope](product-scope.md): use real Git/JJ/SVN CLIs and existing shared runner; study lazygit/jjui only for validated semantics and UX. Do not duplicate native Pulse Git status decorations or pull/push. No new source dependency or parser framework unless needed by a concrete tested feature and reviewed for license, size and maintenance.

RT0 candidate: cache keys now use provider plus repository/workspace roots, with owner-thread publication and by-value results. Canonical shared-store identity remains open. Process output caps/reservations surface ResourceLimit, not a fabricated empty snapshot or allocator OOM. Known malformed Git fields and invalid UTF-8 are rejected; SVN scheduled adds/replacements are working-copy modifications, not Git staging. Full XML validation, per-field availability, JJ operation pinning, trusted absolute CLI resolution and actual background panel lifecycle remain open. See [Shared Runtime](shared-runtime.md).

RT0 candidate: Session uses the shared latest-only task slot to execute a complete provider summary, coalesce navigation, mark the target cache entry stale during refresh, reject obsolete results, and preserve typed provider errors. Existing real Git/JJ/SVN fixture tests use this path. The caller owns all provider contexts and Runner lifetimes; joins are blocking owner operations, not Pulse UI callbacks. Actual panel completion delivery and teardown, trusted CLI policy and process-tree containment remain explicit acceptance items.

VCS Session can share a caller-owned Group for queued/running admission and aggregate allocator backing. Failed quota admission must not advance cache generation. Runner Windows tree and approved-local policies are opt-in candidates; provider-specific trusted installation/configuration adoption still requires explicit product policy. Do not silently switch compatibility mode to a security claim.

Post-merge candidate: Snapshot carries CountAvailability and optional has_conflict; consumers must not display unsupported/not_queried/unknown counts as zero. Git distinguishes known zero vs unknown ahead/behind and rejects duplicate known headers. JJ uses the resolved commit ID for diff and reports conflict presence separately from file count; full operation-pinned multi-query and working-copy freshness remain open. SVN checks bounded XML nesting/quoted attributes, counts each conflicting entry once, includes property-only modifications, rejects malformed output transactionally and never expands entities. It does not yet identify mixed revisions or implement a general XML parser. Real-host release and trusted CLI/configuration gates remain open.

Candidate: absolute PATH discovery is bounded and non-executing; approved version probe requires a configured approved Runner and explicit environment/cwd, with Windows Job Object policy. Git/JJ/SVN expose controlled execution profiles and keep fixture compatibility separate. Git resolves working tree/common metadata through rev-parse and tests linked worktrees. Command-shape floors Git 2.31/JJ 0.46/SVN 1.14 are not certification of all versions. Product trust/configuration policy, positive approved tool execution, OS canonical identity and JJ/SVN identity are still open. No host release claim.

Panel controller candidate: shared/vcs/panel.zig consumes Session on one serialized coordinator and exposes copy-owned View values; selection, queued refresh, typed failure, stale cache, clear/cancel and shutdown are separate states. Content builds actual public pulse.ui.model nodes in caller-owned bounded storage with English/Chinese labels. No UI-thread joins, automatic CLI approval, event callbacks or installable DLL yet. Existing real Git integration test now passes through Controller and checks rendered counts. Real host UI delivery, settings, provider selector wiring, approved installation/config policy and lifecycle remain release gates.

Host task candidate uses the pinned public Preview 3 tasks.h and dispatch.h from Pulse b324368. async_host validates tables, observes terminal state through synchronous get, requires successful release, and treats cancel as a signal rather than a join. Dispatch callbacks may execute before post returns; STATE on cancel is not proof of release. host_query uses one host-owned task for a whole provider summary, immutable borrowed inputs, release/acquire publication and exact workspace verification. It retains userdata through terminal/release; it does not use a nested Session future. Explicit owner poll is nonblocking with respect to work. Cancellation discards publication but is not immediate process interruption inside a provider; command deadlines still bound work. No automatic polling or completion dispatch wiring, no installable DLL, and no assertion of real-host behavior. Approved installation and repository policy remain required before any product call.

UI-owner host controller candidate: one retained Query plus one replaceable latest selection, explicit pump on owner events, stale previous data only for the same workspace/provider, discard-before-cancel, retained ownership on release failure, stop rejects new selections. Panel Content.buildInteractive declares fixed refresh/cancel/check commands; controller routes and validates them without shell strings or blocking joins. No automatic poll/dispatch loop or actual host subscription/DLL wiring yet. In-flight cancellation is still cooperative at provider boundaries; do not claim instantaneous CLI termination.

Host UI binding candidate: Binding attaches the interactive model to the public Preview 3 pulse.ui.model table, preflights create/update/subscribe/unsubscribe/close, registers the three declared commands and routes only matching panel IDs while accepting. Close disables admission before invoking the host; failed partial registration/close retains the panel and callback userdata for retry. Stop attempts both cancellation and close; a successful panel close is not a worker join. The caller supplies an independently authorized resolved workspace and stable provider. No DLL entry, automatic completion event, or real-host release claim yet.

Context navigation candidate: shared pulse.context Navigation(capacity) stores one copied directory ticket, deduplicates identical snapshots and rejects loading, malformed or oversized paths without truncation. A generation invalidates delayed resolver results, including across close/reopen. Binding.openNavigation subscribes via the public SDK; takeNavigation exposes only the latest ticket to a separately authorized resolver, and selectResolved rejects obsolete/empty tickets. Owner pump, commands and explicit render clear an old selection before publishing any result. Subscription failure/invalid ID and failed unsubscribe are not evidence of drain. Callback delivery assumes owner-thread serialization; no filesystem/CLI in the context callback, no automatic resolver/scheduler, no new worker or unbounded queue.

Worker resolver candidate: configureResolver opts Binding into a host-owned Resolution task. On an explicit owner pump it consumes only the latest valid navigation ticket after obsolete task release, and hands a successful, still-current authorized selection to the summary task only after resolver release. Resolver and summary share one serial admission domain; no nested future, independent thread, timer, automatic completion notification or implicit PATH approval. Discovery performs bounded marker lookup only for lexical local absolute directories and delegates candidate choice, installation/configuration/metadata authorization and canonical resolution to an injected policy. No product policy or OS-level trust certification is implemented. Manual navigation resolution remains available when the resolver is not configured.

The discovery-capable panel exposes cancellation before a workspace has been resolved. Explicit refresh restarts resolution and the injected authorization decision; it does not reuse a previous provider authorization indefinitely.

Dispatch wake candidate: optional Binding.configureDispatch uses the public Preview 3 dispatch table and a coalescing fixed slot shared by navigation and worker-return hints. The slot distinguishes posting, queued, inline delivery, failure and invalid token; a failed cancel retains ownership. A wake is not proof of terminal state. In pinned Pulse b324368 the host tasks adapter finalizes on its owner Poll after work returns; dispatch can therefore precede terminal publication. This candidate deliberately does not repeatedly repost, add a timer, or bypass task.get/release; a subsequent explicit check or owner event is still required when delivery is early, rejected, or queued work never enters the worker. No guaranteed automatic terminal delivery or actual native extension yet.

Ordinary Git approval candidate: shared/vcs/approval.zig supplies one explicit grant for an exact workspace root, expected .git metadata, executable digest, neutral cwd and independently approved installation/repository fingerprints. The resolver checks evidence before marker access, rejects non-directory metadata and other roots (including descendants), configures the approved Runner, probes version, compares CLI-reported identity and admits only three exact reviewed argv shapes. Evidence is rechecked before each spawn; revocation blocks future admission but does not interrupt running work. Exact grant spelling is intentional; only forward slashes in Windows CLI-reported identities are normalized before returning the original grant paths. Case, short-name and other aliases remain denied. No production OS/configuration verifier or grant acquisition UI supplied. Do not treat this as a sandbox.

Windows evidence candidate: shared/vcs/windows_evidence.zig observes fixed-drive directory/file identities via Win32 handles, checks every lexical ancestor for reparse points, requires exact normalized DOS names and same-volume traversal, rejects hard-linked regular files, and reads a bounded ordinary .git/config without executing Git. Only an intentionally narrow core config subset is accepted. Known shared-metadata/alternate markers and .gitmodules are denied. The adapter combines local fingerprints with an independent auditor's fingerprints; it never promotes missing audit flags to approval. ACLs, installation dependencies, global/system config, complete worktree/metadata traversal and race-free identity remain external audit obligations. No automatic approval, repository mutation or full verifier claim.

Windows ACL evidence candidate: the Windows verifier now requires an explicit bounded trusted SID set and observes the process TokenUser without automatically granting trust. Each selected path and ancestor is opened with READ_CONTROL; owner and non-null DACL are inspected using Win32 security APIs. A conservative basic ACE subset rejects untrusted mutation grants, unknown ACE types/flags and malformed SIDs, regardless of a possible deny ACE. ACL/identity/control fingerprints and the principal set are included in the combined observation. This can reject normal Windows volume ACLs; it is not an effective-access evaluator, token group/privilege or impersonation audit, or race-free guarantee. The independent auditor still covers installation dependencies, all other metadata/worktree paths and global Git configuration. Runner permits exact GIT_CONFIG_NOSYSTEM=1 as an optional isolation control only; no automatic global-config override or positive approved Git launch is claimed.

Isolated Git configuration candidate: the ordinary-Git Policy now requires a dedicated approved Runner isolation mode with exact GIT_CONFIG_NOSYSTEM=1, GIT_OPTIONAL_LOCKS=0, GIT_TERMINAL_PROMPT=0, and GIT_CONFIG_GLOBAL pointing to a pre-existing empty regular pulse-git-global-empty.conf in the approved neutral cwd. Generic approved Runner continues to reject GIT_CONFIG_GLOBAL; no arbitrary override or file creation/truncation. Runner checks the empty file before each spawn; Windows evidence includes its identity and ACL. Git 2.32 introduced GIT_CONFIG_GLOBAL (upstream 2.32 release notes); after version probing in the neutral cwd the Policy refuses older versions before repository operations. This is not isolation of all attributes, installation helpers, or TOCTOU. Independent evidence remains required.

Installation dependency candidate: Windows Verifier now requires a caller-owned explicit InstallationManifest under a disjoint installation root, including the approved executable and matching SHA-256. Each listed file and ancestor is inspected for canonical identity and ACL and hashed through the checked read handle before every verification; bounded to 32 files and 128 MiB aggregate content. Unlisted dependencies and DLL search order are not inferred; completeness, signer/provenance, token privileges, and all remaining installation/metadata dependencies remain independent audit obligations. No production auto-approval or native host integration.

Native candidate: extensions/vcs-panel/main.zig builds pulse_vcs_panel with public Preview 3 ABI, owner-only Binding/model/navigation and permanent execution lock. The experimental attachment has no resolver, production approval, worker admission, dispatch or package; explicit Check result repaints the copied mailbox. It cannot launch Git or auto-discover tools. Activation rollback and stop retain userdata on failed cleanup; the void host ABI cannot certify safe unload on failure. No production release or installation manifest supplied.

Pinned shutdown review: the published v1.0.60 host closes adapters before the module lifecycle callbacks and waits for task workers/terminal publication/active callbacks before FreeLibrary. Ordinary owner task release is unavailable after adapter closure; a future destroy-only cleanup path must use the documented host-owned task lifetime boundary, not blindly accept STATE during ordinary cancellation. The newer installed v1.0.61 implementation remains unverified. The locked candidate C loader now exercises successful UI/context attachment, rollback and host-first invalidation without task admission; no package or production approval yet.

Grant acquisition now has an explicit Review.inspect/confirm API: initial inspection captures independent evidence without automatic approval; confirmation compares unchanged installation/repository fingerprints and the bounded deterministic admitted environment digest. The caller must independently audit and present exact paths/fingerprints; confirmation is not a substitute for user consent. Policy still revalidates before each command. Final host destroy retirement is separate from ordinary stop; it relies on the SDK boundary, never on a generic STATE response. The native candidate remains locked until a production authorization source and actual-host verification are supplied.

Native reviewed-session integration candidate: a compile-time trusted provisioning source supplies one independently reviewed immutable NativeInput, Runner, Policy and worker-side resolver. The default source supplies no input and stays locked. Review records have a bounded versioned codec, not authenticated storage; the session revoke action suppresses new admissions, clears publication, and remains locked for that instance. Approved Git ignores submodule recursion. The external production auditor, authenticated persistent storage/durable revocation and user-facing acquisition flow remain deployment blockers; no automatic trust or source fallback. See vcs-acceptance-runbook.md.

Default approval manager: a Windows HKCU single-slot DPAPI record is acquired without command execution, and a separate explicit CLI performs bounded inspection, presents full inventory/fingerprints, requires a typed confirmation token and rechecks evidence before storing. The concrete restricted auditor enumerates installation, worktree and neutral tree, checks ACLs/identity, rejects unsupported Git index/config/metadata, and combines exact file digests. Each command also rechecks the current saved record; native revoke writes a tombstone, locks the session even on persistence failure, and displays the approved root. No arbitrary same-user-code protection, publisher signature, general Git distribution support, or race-free process boundary is claimed. See vcs-acceptance-runbook.md.

Installation inventory uses a packed bounded path arena (512 files, 96 KiB path bytes, 256 MiB contents). Existing ancestor ACLs can allow sibling creation only; all actual selected directories/files still require strict mutation ACLs, and inherit-only ACEs are not effective permissions on the current object. The OS API's exact system Windows directory is an explicit trusted platform dependency. These compatibility adjustments do not permit arbitrary PATH or untrusted target writes.

Project V2 records are bounded optimistic writes (one key per bookmark),
including user metadata and navigation order; legacy V1 is read-compatible.
Stable record identity is independent of mutable root or forge URL. The native
project-first settings surface uses paged rows and explicit selection/edit
version checks. Directory jump uses the pinned pulse.directories API on host
workers and existing snapshot entry routing, never arbitrary shell execution.
Lexical duplicate checks are supplemented by explicit background fixed-drive
identity observation on add/relink. Persistent local grants are kept in a
separate DPAPI namespace and revalidated on command admission. Current-root
preview can observe at most three saved records without CLI execution;
observed metadata does not establish grant validity. Explicit selected-project
scope inspection/revoke also works without a live root or marker. The owner
checks the reviewed record/version and locally invalidates matching saved
session admission and cache. The durable worker outcome remains separate.
Real host acceptance, unobservable physical aliases and all-store grant
enumeration remain limitations.

### P3A file status candidate

The existing status worker now returns a bounded display-only file arena in
its owned snapshot. Full counts remain independent of retained rows. Git
porcelain v2 retains XY and rename source; JJ summary retains the recorded
commit's compact rename expression (not an executable path); SVN local XML
retains decoded built-in entities, property/tree conflict and entry revision.
Numeric/custom entity paths are omitted, not misrepresented. Eight-row
paging and case-sensitive search do not start a process. A new navigation
clears the filter and page, and stale data is explicitly read-only. Never
construct CLI targets from these display strings. Full history, diff, refs
and file selection are not yet implemented; exact candidate CI is pending.

### P3A consolidated local workspace

The serialized host Query slot admits one immutable detail request or
summary, never both; terminal release precedes publication, cancellation
suppresses results, and navigation/refresh/revoke clears detail data instead
of putting it in the recent cache. An exact command grammar is shared by
construction and ordinary local-session admission. Full commit IDs, literal
pathspecs, JJ root-file filesets and ordinary SVN local targets are validated;
the initial recorded JJ operation pins both summary and all subsequent
details. Advanced requests return bounded text pages with explicit binary,
encoding, resource-limit and unsupported states. History rows can populate
the revision input without execution; right-click a single fresh file
populates the matching trusted workspace's path input without executing a
file query. A saved-policy fingerprint change requires explicit re-review
before old saved approvals can be used with the expanded grammar. Git
partial-clone/filters and SVN non-pristine/server history limitations are
documented in the roadmap and runbook. No host-private interface or generic
CLI. Actual installed rendering and exact new CI remain pending.
