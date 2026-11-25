# VCS architecture / 版本控制架构

`strangelion.vcs` is a multi-VCS manager, not a Git panel with special cases.
Every provider speaks the same contract, but each keeps its own vocabulary and
semantics — a Subversion revision number, a Jujutsu change id and a Perforce
changelist are not modelled as a Git commit.

This document distinguishes the target contract from the implemented subset.
The capability matrix is a design target, not an implementation claim; see the
implementation status below and [roadmap.md](roadmap.md) for remaining work.

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

## Implementation status (2026-11-24)

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

### Current capabilities vs target

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
