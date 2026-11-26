# Roadmap / 开发路线

## Current baseline and evidence (2026-11-26)

The repository has two independently installable **unsigned preview** releases:
[vcs/v1.0.0](https://github.com/strangelion/pulse-extras/releases/tag/vcs/v1.0.0)
and [companion/v1.0.0](https://github.com/strangelion/pulse-extras/releases/tag/companion/v1.0.0),
both targeting df5009c. These are not signed stable or official registry
releases. The user reported successful Companion import/download on the
normal installed package; exact artifact/environment evidence has not been
collected for all acceptance cases. VCS 1.0.0 exposed an impractical locked
onboarding path. Main now contains a candidate for native local-session
trust, tool settings and project bookmarks (81b2ad1), not included in 1.0.0.

- Historical SDK/runtime evidence: [c330c24 / 45421511648](https://github.com/strangelion/pulse-extras/actions/runs/45421511648), [2759b51 / 45514152046](https://github.com/strangelion/pulse-extras/actions/runs/45514152046), and [integration report](integration-report.md). Preserve those results as historical, not current certification.
- [c36b518 / 45842345131](https://github.com/strangelion/pulse-extras/actions/runs/45842345131) passed regression. [d3dff85 / 45842567147](https://github.com/strangelion/pulse-extras/actions/runs/45842567147) exposed an installed Git for Windows hardlink incompatibility. A scoped correction is in 3086c76; its intermediate syntax failure was corrected by 98a5caf. [81b2ad1 / 45844554060](https://github.com/strangelion/pulse-extras/actions/runs/45844554060) passed full regression. The consolidated P2A onboarding follow-up adds locale, approved version display, settings failure coverage and mandatory Windows SVN provisioning; it requires its own regression.
- Source implementation, automated regression, actual installed acceptance and publication are independent facts. No newer release or all-host acceptance is claimed here.

## Stage execution contract / 阶段交付规范

This roadmap is the authoritative stage order; feature architecture documents
define contracts, the acceptance runbooks define evidence. Every stage has a
usable deliverable, explicit exclusions, and an exit gate. Use the following
status vocabulary in reports: **IMPLEMENTED** (source only), **CI PASS** (exact
source and required scope), **HOST PASS** (exact installed artifact and named
cases), **BLOCKED** (specific dependency/reproduction), **NOT RUN**, **DEFERRED**.
A stage is **COMPLETE** only when its mandatory exit gate has passed.

When asked to continue, select the earliest incomplete in-scope stage and
carry it as a coherent vertical slice: review the entire stage, implement
all feasible required UI/data/runtime paths, integrate and test them, fix
regressions, update documentation and provide exact evidence. Do not stop
after one button, one provider adapter, a mock-only interface, a plan, or
a single commit when other work in that stage can be done safely. Multiple
logical commits are fine; avoid repeated blind pushes and repeated requests
for approval of routine substeps. Prefer local format/build/targeted tests
before the first push, then the required regression for the combined stage.

If a required host-only check, unavailable SDK, toolchain, security boundary
or explicit user decision prevents completion, finish other independent
work within the stage, record the precise remaining exit-gate cases and the
smallest reproducible user action, and mark BLOCKED/NOT RUN rather than
claiming completion. Do not bypass safeguards or silently expand into the
next stage. Actual publication, credentials, and destructive/remote operations
remain separately authorized. No blanket requirement to merge all code into
one huge commit; development can use a stage branch and reviewable commits.

## P0 — Zig and SDK compatibility

- [x] Pinned Zig 0.17.1, public Pulse 1.0.60 SDK / Preview 3, x64 MSVC ABI.
- [x] Reproducible generated bindings and independent Windows C loader.
- [x] Recorded isolated Pulse 1.0.61 ABI Probe load, activation, deactivation and unload; see [host evidence](host-compatibility.md).
- [x] Hello Panel command, context updates, workspace and sidebar placement verified in the recorded host run.
- [x] Hash-verified Zig archive caching; both runners demonstrated cache hits.
- [ ] Full host-header ABI proof: 56 structures compared, 25 not verifiable with available host headers.
- [ ] Registry maintainer acceptance of Zig packages, theme/DPI/resize and upgrade/rollback coverage.
- [ ] Runtime memory and latency baselines (CI timing alone is not a runtime benchmark).

## P1 — Multi-VCS foundation (implemented subset)

**Deliverable:** reusable read-only Provider/Runner/identity contract for Git,
Jujutsu (JJ), and SVN, used by the native panel, not separate unused wrappers.

- [x] Provider contract, capability/risk models, bounded identity/cache, marker detection, version probing and read-only summaries.
- [x] Git/JJ real temporary-repository fixtures on both CI OSes; SVN local fixture on Ubuntu; rename parsing, colocation candidates, JJ operation-log invariance and bounded XML tests.
- [ ] Complete installed-tool acceptance, including Windows SVN, canonical shared metadata/worktree identity, operation-consistent JJ snapshots and SVN mixed-revision semantics (carried into P2/P3 below).

**Exit gate:** per-provider positive and negative fixtures, truthful field availability,
bounded malformed inputs and actual integrated consumer coverage. The earlier
foundation is implemented; remaining provider details have named stage owners.

## P1.5 — Required hardening before background panel integration

RT0/RT1 source integration is no longer merely planned. Shared budget, allocator,
latest-only/FIFO, diagnostics, temp retention, Windows Job Object process runner,
absolute executable admission and host task/dispatch/context adapters are used by
actual products. Maintain the contracts in [Shared Runtime](shared-runtime.md) and
[shared-runtime-host-acceptance.md](shared-runtime-host-acceptance.md).

**Exit gate for any new VCS stage:** bounded memory/output, no blocking CLI or
filesystem enumeration on UI callbacks, stale-generation suppression, cancellation,
stop/release/drain and independent callback ownership; verify applicable failure
injection, malformed data, timeout/OOM, and actual unload/resource plateau at
host acceptance. No mandatory common DLL, background service, arbitrary shell
or weakening of the strict saved Git profile. Deep analysis, actual coexistence
and measured resource evidence remain open; track them in R4, not as duplicate
implementation work.

## P2 — First real VCS extension

The native DLL, right-click current-directory command, metadata preview, explicit
trusted-local session path, native tool settings and initial bookmarks exist in
source. The unsigned 1.0.0 release predates the latter improvements. P2 is **not
complete**. Finish P2A and P2B as separate complete user-facing stages, in order.
No new provider or write features until the baseline is usable.

### P2A — Daily-use onboarding and reliable status (active)

**Outcome:** a normal user installs the extension, opens the current repository
through Pulse, configures the installed tool and views correct status without a
Python script or specialized Git bundle. Git/JJ/SVN are all in scope.

Required delivery:
- One discoverable right-click/activation entry and native settings page; no
  duplicate panels. Clear loading, missing/unsupported tool, denied, stale,
  non-repository, canceled and error states. English/Chinese via a documented
  locale choice/fallback; theme, resize and DPI checks.
- Independently save/reset Git/JJ/SVN tool paths, non-executing candidate
  detection, manual entry and supported browse. Prefer an exact executable
  picker only if its public ABI is verified; the existing folder picker plus
  expected executable name is the supported fallback. Display verified tool
  version only after explicit authorization/probe; saving paths is never
  executable consent. Handle wrong filenames, unavailable tools and ordinary
  Git for Windows hardlinks with the scoped local-session policy.
- Explicit exact-tool/root/provider review, cancel, revoke and switch/reopen;
  maintain strict saved Git audit mode separately. Show same-root Git/JJ
  candidates; do not call marker discovery proof of shared storage.
- Correct complete *status summary* for Git/JJ/SVN, including unknown versus
  zero and JJ unsnapshotted-work limitation, manual refresh/Check, navigation
  coalescing and failure recovery. Positive Windows fixtures for installed
  Git/JJ/SVN; no fixture substitutions or skipped Windows SVN marked PASS.
- Tests for native settings resources, picker, path precedence, explicit consent,
  stale review, version conflicts, failure/retry, right-click and teardown.
  Fix latest CI regressions, including the hardlink regression, before closing.

**Exit:** exact-source full regression, production Windows ReleaseSafe build,
official verified package, isolated Pulse install and positive ordinary Git/JJ/SVN
queries plus non-repo/missing CLI/denial/revoke/cancel/navigation/close/reopen/
disable/exit. Record exact artifacts and results using
[vcs-acceptance-runbook.md](vcs-acceptance-runbook.md). If real-host access is
unavailable, complete code and automated work then report the missing case set
once. No claim that local trust is a filesystem/network sandbox.

### P2B — Project manager and persistent trust

**Outcome:** the project library is a primary, useful VCS entry, not a settings
appendix; users can manage multiple projects without repeatedly typing paths.

Required delivery:
- A single project library with explicit add-current/manual add, edit/remove
  (record only), name, favorite, tags/search, last-opened and provider/root/
  workspace display. Stable IDs and deduplication by verified local identity
  where available; same remote does not identify the same local workspace.
  Clear missing/moved roots, relink without deleting data. Bounded schema,
  migration of existing 32-entry bookmarks, version-conflict handling,
  recovery/upgrade and no silent overwrite. Choose larger limits based on
  storage and measured UI cost, not an unbounded list.
- Select a project and navigate to it using supported host routing, or expose
  an explicit safe fallback if no public API supports arbitrary directory
  navigation; no private host manipulation. Right-click selected directories
  can add/open the intended project with fresh selection validation.
- Provider switch for colocated Git/JJ, independent cached views per project/
  provider/workspace; refresh on navigation and explicit request, optional
  debounced file notifications only on verified host interfaces. No scanning
  all saved repositories at startup or permanent per-project polling.
- Persistent multi-project trust: separate project metadata, tool paths and
  versioned revocable grants; explicit initial review, identity/digest
  revalidation, per-project/provider scope, migration/reset, inspect/revoke
  individual or all. Store no implicit trust in bookmark settings; stale or
  changed grants fail closed. Keep same-user/admin limitations explicit.
- Reuse existing native settings/project records and safe normalized remote URL
  hints. Complete settings and project UI as one connected workflow. Regression
  for add/edit/restart/relink/selection conflicts/migration/revocation and
  concurrent windows, with bounded quotas and no filesystem mutation on remove.

**Exit:** at least Git, JJ, SVN and colocated sample projects, persisted/reopened
across host restart, correct project switching, no duplicate identities or stale
results, per-root revoke isolation, exact-source full CI and installed package
acceptance. Missing public host navigation is a documented fallback/blocker,
not a fabricated feature. No full history/diff or cloud OAuth in this stage.

## R — Shared packaging and release (after first P2 acceptance)

**Implemented:** official package composition/verification, independent SemVer,
manual selectable companion/vcs/all release workflow, unsigned previews
1.0.0 for both packages. See [release.md](release.md).
**Remaining:** R0/R1/R2 real-host lifecycle and reproducibility evidence;
R3 signing/test-key validation, protected key handling, collision/partial
recovery and upstream registry review; R4 cross-extension coexistence,
long-run leak/handle/CPU/latency and upgrade/rollback evidence, deeper static
analysis and supported Sanitizers. No registry submission without explicit
approval. Release only affected products with immutable tags and matching
full CI/artifact evidence. A user-authorized unsigned preview may be cut
for testing with exact limitations, not described as stage completion or
stable certification. Do not repeatedly publish tiny partial milestones.

## P3 — Read-only advanced functions

### P3A — Complete local read-only workspace

**Outcome:** one consistent project/status/history/diff interface for all
three primary providers, with native semantics and bounded content.

- File-level changes (path, kind, rename/conflict, staged state where
  meaningful), selection, paging, search and detail; distinguish ignored,
  untracked, unknown and recorded-only data.
- Paged history and revision details, file history, revision content and
  working/revision diff; native host text preview/diff only if a supported API
  exists, otherwise bounded own read-only view. Preserve binary/encoding/
  truncated-output errors; no external diff/filter/credential helper launched
  implicitly. Reuse actual parsers/runner and extend exact command admission,
  not generic CLI strings. Each provider implements the entire corresponding
  view or declares an accurate unsupported state.
- Git refs/tags/branches/worktrees, upstream/distance; JJ change/commit IDs,
  bookmarks/workspaces/operation log and operation-consistent queries; SVN
  revisions/properties/tree conflicts/mixed revisions, distinguish local
  working-copy information from explicitly authorized server queries.
- Right-click file/folder actions to inspect status, history and diff without
  starting unauthorized execution. Cache and pagination tied to provider,
  workspace, revision and generation. No new permanent background service.

**Exit:** native end-to-end file-to-diff and history flows for Git/JJ/SVN;
positive real fixture and negative malformed/large/binary/rename/path traversal
tests, no unreviewed mutation or network access, full CI and installed UI tests.

### P3B — Remote forge and external client integration

**Outcome:** saved projects expose verified remote and local client actions
without requiring an account for ordinary local VCS use.

- Canonical remote parsing and explicit choices for multiple remotes,
  GitHub/GitLab/Bitbucket repository pages and verified Issues/PR/MR/CI/Release
  links where supported; distinguish manually entered address from detected
  metadata. Never expose credentials in storage/UI/logs; arbitrary URL schemes,
  redirect tricks and shell interpolation refused.
- External clients (initial GitHub Desktop, VS Code, Sourcetree/GitKraken or
  TortoiseSVN as verified): capability check, separately configured installed
  path, review exact program/project and documented invocation, explicit launch
  only. No arbitrary command templates, silent install, or unsupported command
  flags. Check upstream documentation/OS behavior before implementing each
  adapter; omit unavailable options with reason.
- Optional read-only forge API, initially GitHub: public metadata without
  token where possible, optional minimum-scope user authorization, protected
  OS credential storage, revoke/logout and rate-limit/offline handling.
  Explicit allowlisted HTTPS endpoints, bounded response/pagination and
  TTL/cache; no hidden transfer of local paths, code, repository contents or
  credentials. GitLab/Bitbucket API only after their contracts are validated.
  Remote write actions remain P4 and require separate scope/confirmation.
- Project dashboard merges local and remote status without pretending cached
  or inaccessible data is current. No continuous remote polling by default.

**Exit:** local browser/client integration and API fixture tests, rate limits/
credential absence/revocation/offline/redaction/unsafe URL tests and explicit
real-host smoke with consenting account where needed. Do not mark API support
complete from a webpage link; unavailable external account tests are NOT RUN.

### P3C — Additional providers (after P3A baseline)

Mercurial first, then Perforce where justified; Sapling, Fossil and Plastic
only if demand and a supported tool contract exist. Deliver each selected
provider as a full vertical slice: detect, configure, consent, status,
changed files, history/diff/refs as semantically available, project library
and tests. No provider stubs, advertised unimplemented capabilities or
fake remote-server acceptance.

## P4 — Write operations (disabled until reviewed)

Separate local-write stage from remote/destructive stage. P4A local: Git
stage/unstage and commit, JJ bookmark/change operations and SVN local
operations where safe, each with typed operation plan, exact scope/argv,
explicit confirmation, revalidation, shared-store locking and honest
partial-failure handling. P4B network/destructive: opt-in fetch/pull/push,
merge/rebase/update and other risky actions only after individual security
review and real isolated fixture acceptance. Respect native Pulse file
mutation and undo contracts; no universal undo, automatic snapshot, background
write, force push or arbitrary CLI by default.

**Exit:** per-operation risk/consent and capability tests, concurrent change,
cancellation, recovery, repository integrity and actual installed acceptance.
Leave any unapproved operation disabled and record it explicitly rather than
making the whole provider appear writable.

## P5 — Other independent extensions

| ID | First deliverable | Explicit exclusions |
| --- | --- | --- |
| strangelion.convert | PNG/JPEG batch conversion to new files via staging | No in-place replacement |
| strangelion.inspect | Read-only PE metadata and signature inspection | No execution or malware verdict |
| strangelion.data | SQLite schema and bounded NPY/NPZ metadata | No arbitrary SQL writes |
| strangelion.devkit | Project detection and toolchain inventory | No automatic install or build scripts |
| strangelion.compare | Recursive read-only content comparison | No sync/deletion until safety review |
| strangelion.companion | Existing independent desktop pet manager; maintain C/D stage | No broad rewrite or generic Agent; complete actual measurements |
| strangelion.forge (conditional) | Reusable templates, constrained recipes, validation and maintenance | No generic coding Agent; separate MCP/panel only with demonstrated value |

- [ ] Deferred RT2+ design gate: allow separately installed Pulse Extras add-ons to reuse a single versioned runtime binary and same-host runtime instance, only after host dependency/lifecycle support and mixed-addon acceptance are proven. Keep the current bundled source-sharing model until then. See [shared binary dependency plan](shared-runtime.md#deferred-shared-binary-dependency-multi-add-on-coexistence).

RT2: all new products reuse the shared runtime contract; extend it only for proven needs, track bundled runtime revisions and rebuild/test/release affected consumers after fixes. Test independent instances and mixed-version coexistence. Recheck upstream source, roadmap, SDK and registry for overlap before implementing each extension. Pulse already has basic Git and SVN status, native lock detection, common previews and archive integration. Coordinate 3D/OCR/remote features with upstream.

Current priority is P2A → P2B → P3A → P3B for VCS. Companion is maintenance/acceptance only unless a user reports a defect or explicitly requests expansion. After the VCS read-only product stages, choose the next independent product (Convert, Inspect, Compare, Data, DevKit) according to demand and verified upstream overlap. Each needs its own complete first-use stage (UI, processing, persistence where needed, errors, tests, packaging/acceptance), not a collection of empty modules. See [product scope](product-scope.md). Do not block usable products on a speculative platform.

Release follows milestone R and [release.md](release.md). Keep secrets out of Git/CI logs. Project license is AGPL-3.0-only, preserving prior Apache-2.0 grants and upstream/third-party obligations. Zig-first remains unchanged; review source delivery and registry acceptance before distributing.

## C — Companion maintenance (previous feasibility stages)

C0/C1 delivered the standalone/runtime and OpenPets-compatible manager,
native settings/library/market/running views, import/download and resource
management; an unsigned 1.0.0 preview is published. The user reports basic
import/download working after ordinary local packaging/install. Preserve
those working paths, avoid broad rewrites while VCS is the active priority.

### Companion stage D — packaging and real-host acceptance (planned)

- D0/D1: official package composition and preview release implemented; exact
  isolated package lifecycle/upgrade/rollback still needs recorded evidence.
- D2/D3/D4: complete the existing [canonical acceptance register](companion-manager.md#d2-real-host-functional-acceptance-matrix)
  when actual host access is available: image rendering/fallback, concurrent
  market, 100 visible pets and separately high-count actual managed instances,
  soak/leak/CPU/memory/handles, crash/recovery and cleanup. User-reported
  basic import/download is not proof of every case.
- D5: verified formal candidate and separately authorized stable/signing/
  registry decision. No speculative shared-binary runtime in this stage.

If requested later, C3 is a complete usability update (thumbnail/list detail,
running manager, pagination/search and interaction polish), not repeated
partial visual redesigns. Preserve established import/download format and
compatibility and verify the full workflow before a new preview.

## F — Forge authoring tooling (conditional, after real components/package foundations)

- [ ] F0: reusable author templates and shared components from real products, constrained declarative recipes where supported, deterministic SDK/package validation and migration. Reuse official author tools and existing Pi/DSH/Codex transports; no duplicated general Agent infrastructure.
- [ ] Benchmark representative tasks against direct Agent authoring: time, tokens, correctness, repair cycles and maintenance. If no material advantage, keep tooling in DevKit/shared scripts.
- [ ] F1: only if justified, thin standalone Zig author CLI/MCP and bounded Agent integration with explicit authorization and OS-level isolation for generated native code.
- [ ] F2: optional visual editor/native panel, shareable recipes and compatible preview if verified and demanded.
- [ ] F3: discuss typed AI tool registration and permissions with upstream; direct native assistant integration remains unsupported by the pinned public SDK.

See [Forge design](forge-architecture.md). Do not block VCS or other independent packages on Forge, and do not create placeholder projects. A single natural-language request is a development task, not permission for unreviewed native execution or release.

## Delivery and reporting

Follow the stage execution contract above and [AGENTS.md](../AGENTS.md).
Use one final stage report with: stage ID and deliverables; source SHA and
exact test commands/results/CI scope; artifact hashes and actual host evidence
where available; resource measurements and limitations; remaining blockers
with the smallest user action; next stage only after exit-gate review.
Do not manufacture measurements, repeat completed work, call a docs-only gate
code validation, or change release tags in an ordinary stage. Historical
development milestones and failed experiments remain in Git history and
[testing.md](testing.md); current state belongs in this roadmap and the
feature-specific acceptance register.
