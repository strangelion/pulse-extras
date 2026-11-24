# VCS architecture / 版本控制架构

`strangelion.vcs` is a multi-VCS manager, not a Git panel with special cases.
Every provider speaks the same contract, but each keeps its own vocabulary and
semantics — a Subversion revision number, a Jujutsu change id and a Perforce
changelist are not modelled as a Git commit.

This document is the design contract. It does not claim any provider is
implemented; the capability matrix below records the target, and
`docs/roadmap.md` records what actually shipped.

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

Colocated git+jj repositories expose one workspace with two metadata stores.
Detection reports both providers; the UI picks one primary view and the
operation guard serialises writes across both.

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
| `network_read` | fetch/ls-remote queries | allowed with timeout, no credentials prompts |
| `local_metadata_write` | svn update, hg pull into store | requires an `OperationPlan` |
| `working_tree_write` | checkout, merge, revert | requires plan + confirmation |
| `remote_write` | push, submit | requires plan + confirmation |
| `history_rewrite` | rebase, jj abandon/squash, svn commit of deletions | requires plan + explicit warning |
| `destructive` | reset --hard, clean, force push | disabled by default |

Read-only mode disables every command that cannot be proven passive for the
detected CLI version. Jujutsu is the sharp edge: many query commands snapshot
the working copy. The provider must use the documented read-only forms and
prove it with tests (`jj status` on a dirty tree must not create a new
operation, verified against the installed version's docs).

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

All CLI access goes through `shared/process/run.zig`: structured argv (never a
shell string), absolute executable resolution, timeout, cancellation, output
caps, separated stdout/stderr, explicit environment, no interactive prompts,
and no credential logging.

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
4. Mercurial, Perforce.
5. Plastic, Sapling, Fossil, and the long tail, only with a real need.
6. Write operations, one at a time, with plan + confirmation + regression.

## Implementation status (2026-11-24)

Implemented and covered by `zig build test`:

- `shared/vcs/capabilities.zig` — declared capability set plus
  `resolve(declared, cli, state)` so the UI can degrade instead of offering a
  command that will fail.
- `shared/vcs/identity.zig` — bounded paths, per-kind revision ids, repository
  and workspace identities that keep the two roots separate.
- `shared/vcs/risk.zig` — risk levels and the default read-only policy.
- `shared/vcs/detect.zig` — injected-probe marker walk (no filesystem, no CLI),
  git worktree marker files, colocated git+jj.
- `shared/vcs/provider.zig` — vtable contract, typed errors, availability enum.
- `shared/vcs/cli.zig` — `PATH` lookup, `--version` parsing, a "present but
  unrecognised" state that is unsupported rather than guessed.
- `shared/vcs/snapshot.zig` — bounded cache with fresh/stale/missing lookups and
  generation counters for discarding in-flight results.
- `shared/vcs/providers/git.zig` — read-only `git status --porcelain=v2
  --branch -z`: branch, upstream, ahead/behind, staged/modified/untracked/
  conflicted counts, detached HEAD. Parsing is unit-tested from a fixture and
  the provider is tested end to end against a temporary repository when `git`
  is installed.

- `shared/vcs/providers/jj.zig` — revision (change id, commit id, bookmarks,
  conflict flag) and diff summary through `--ignore-working-copy`. Verified on
  jj 0.46.0 that two queries leave the operation log unchanged (2 entries before
  and after), so an open panel cannot create snapshots. Documented degradation:
  edits that were never snapshotted are invisible, and the summary says so
  through `detail`.
- `shared/vcs/providers/svn.zig` — working-copy revision, `relative-url` and
  `svn status --xml` item counts. **Not verified against a real server or
  working copy on this machine** (`svn` is not installed); the integration test
  skips and only the XML parser and error mapping are covered locally.

Not implemented yet: history, file diffs, Hg/P4 providers, any write operation,
and the provider panel.
