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
A stage is **COMPLETE** only when its mandatory exit gate has passed. Owner
policy (2026-11-26): code implementation + exact-source required CI permits
advancing to the next development stage; actual installed-host cases are queued
for one final consolidated acceptance round. Label these stages DEV COMPLETE /
HOST DEFERRED, never HOST PASS or stable release. Safety regressions still block.

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

### P2A — Daily-use onboarding and reliable status (DEV COMPLETE / HOST DEFERRED)

[4d53927 / full regression 45850831284](https://github.com/strangelion/pulse-extras/actions/runs/45850831284)
passed all lanes, including Windows 686/686 tests and pinned SVN 1.14.5 actual
working-copy provisioning. Actual Pulse UI/ABI/lifecycle is deferred by owner
to the final installed acceptance round, not inferred from the C harness.

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

### P2B — Project manager and persistent trust (DEV COMPLETE / HOST DEFERRED)

4d53927 already contains V2 migrated project bookmarks, 64-record capacity,
12-row paging, name/tags/favorites/search/accepted-navigation recency, supported
folder route and in-panel session reset. This follow-up adds explicit saved
local trust and identity-bound stale snapshot reuse. [a676805 / 45856710161](https://github.com/strangelion/pulse-extras/actions/runs/45856710161) passed full regression. [a387067 / 45922243671](https://github.com/strangelion/pulse-extras/actions/runs/45922243671) passed all required lanes for selected-folder routing, project identity/cancellation and the earlier persistent trust code. [8b94fb4 / 45923906700](https://github.com/strangelion/pulse-extras/actions/runs/45923906700) passed all required lanes for saved-record inspection and recency display. [147449b / 45925323667](https://github.com/strangelion/pulse-extras/actions/runs/45925323667) passed the full code regression for project-library scope management. Owner policy permits P3A development; installed acceptance remains deferred.

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

### P3A — Complete local read-only workspace (DEV COMPLETE / HOST DEFERRED)

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

### P3B — Remote forge and external client integration (DEV COMPLETE / HOST DEFERRED, supported scope)

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

### P3C — Additional providers (Mercurial code gate passed; consolidated read-only candidate)

Mercurial full code CI passed at 6f29edf / 45935843006. The selected
read-only product scope is Git, Jujutsu, SVN and Mercurial. Defer Perforce,
Sapling, Fossil and Plastic until demonstrated demand and a supported
tool/server contract exist. Perforce needs an explicitly configured server
and client scope with credentials/TLS and an isolated server fixture; do
not reuse local marker authorization. No provider stubs or fake server
acceptance. Consolidate read-only hardening and acceptance in one candidate.

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

Current priority is the consolidated four-provider VCS read-only candidate; actual host tests are deferred. P4 native write operations remain gated by separate operation review and integrity fixtures. Companion is maintenance/acceptance only unless a user reports a defect or explicitly requests expansion. After the VCS read-only product stages, choose the next independent product (Convert, Inspect, Compare, Data, DevKit) according to demand and verified upstream overlap. Each needs its own complete first-use stage (UI, processing, persistence where needed, errors, tests, packaging/acceptance), not a collection of empty modules. See [product scope](product-scope.md). Do not block usable products on a speculative platform.

Release follows milestone R and [release.md](release.md). Keep secrets out of Git/CI logs. Project license is AGPL-3.0-only, preserving prior Apache-2.0 grants and upstream/third-party obligations. Zig-first remains unchanged; review source delivery and registry acceptance before distributing.

## C — Companion maintenance (previous feasibility stages)

C0/C1 delivered the standalone/runtime and OpenPets-compatible manager,
native settings/library/market/running views, import/download and resource
management; an unsigned 1.0.0 preview is published. The owner accepts ordinary Companion feature development as complete after
normal local packaging/install and explicitly defers the remaining actual
host checks to the final round. Preserve those working paths, avoid broad
rewrites while VCS is the active priority.

### Companion stage D — packaging and real-host acceptance (planned)

- D0/D1: official package composition and preview release implemented; exact
  isolated package lifecycle/upgrade/rollback still needs recorded evidence.
- D2: ordinary functionality marked owner-accepted DEV COMPLETE; final
  consolidated actual-host smoke/lifecycle remains HOST DEFERRED, not verified.
- D3/D4: remaining dedicated work is actual 1024-slot workload performance
  (staged toward the limit only with headroom), long-running memory/handle
  leaks and image/thumbnail behavior after reviewing the 1.0.61 SDK/host.
  No performance number or all-host pass inferred from owner acceptance.
  See [canonical acceptance register](companion-manager.md#d2-real-host-functional-acceptance-matrix).
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

### P2B project manager implementation checkpoint

Project-first native settings surface, up to 64 bounded records, V2 lazy
migration of legacy bookmarks, stable IDs across explicit relink, name/tags/
favorites, search, 12-row pages sorted favorites then recorded navigation order,
explicit add/edit/remove, browse root, and public directory-snapshot navigation
are implemented candidates. Scope is still not COMPLETE: host navigation,
physical-identity deduplication, provider/workspace cache isolation and separate
persistent multi-root grants require remaining implementation/acceptance. No
new automatic execution permission is inferred from a project record. P2A
Windows SVN provisioning and actual installed acceptance remain independent gates.

P2B follow-up: local-session reset after drain supports choosing another root
or colocated provider without closing the panel. No implicit cross-root grant;
strict persisted Git approval remains separate. The first project-library CI
failed only at formatting; its exact correction and additional stale/reparse
navigation tests are included in the follow-up candidate.

The owner-directed consolidated [final installed acceptance](final-host-acceptance.md) register covers both products. Do not request repeated local installs between development stages.

### P2B selected-folder and identity follow-up (candidate)

The single context menu now differentiates a single selected directory from
empty/file/multiple selection. It checks the fresh public selection revision,
exact directory and direct-child path before submitting public snapshot routing.
The selected folder fills the project form; saving remains explicit. A route
refusal exposes the manual-path fallback; no automatic trust is created.
New/relinked project roots require a background fixed-drive, exact-canonical,
non-reparse identity observation on Windows. Compare the observed volume and
file index against observable existing records on this explicit action only;
no startup scan. Check pending task result completes the version-checked save.
Unobservable candidate roots fail closed; unobservable existing roots cannot
be certified as duplicates and are not deleted. Editing metadata at an
unchanged missing root remains possible. This is not a race-free identity
registry, nor support for junctions or linked worktrees. Pending work blocks
conflicting owner edits and is cancelled/drained at teardown. Full source CI passed at a387067. The deterministic alias/cancellation fixture is not a real filesystem alias test. Real-host acceptance remains deferred; P2B stays active pending exact new regression and exit review.

The current-root metadata worker now inspects at most three saved approval
slots for detected provider scopes. The UI distinguishes absent, observed
but unverified, and unreadable records, and displays the stored tool path.
An unavailable original executable does not prevent explicit review and
scope revocation. Tool precedence is explicit entry, configured, saved,
then discovered; reuse still requires complete original admission checks.
No automatic execution, all-record scan, credential access, or new grant
format. Revocation without a detectable repository marker remains possible
via revoke-all; arbitrary grant enumeration is not implemented. Project
rows show the recorded accepted-navigation order (not a wall-clock time).
Exact new regression is required before declaring development complete.

### P2B project-library scope management and exit review

A selected project now exposes explicit background inspection of all three
provider scopes, independent of repository markers or directory existence.
The review shows its exact stored root and recorded tool paths. Scope revoke
requires the same selected record, root and settings version; it does not
modify the bookmark, files or unrelated provider scopes. A matching live saved
session in this instance is locally locked at admission and its cached data
removed; durable revocation is separately reported after worker completion.
No automatic grant creation or full-store enumeration. Missing/moved roots
can be handled without navigating to them; revoking all remains the fallback
for unbookmarked and unreadable scopes. The fixtures cover selection/version
changes, scope isolation and no settings mutation. Exact full CI passed at 147449b / 45925323667; installed restart, physical identity evidence and actual host routing remain in the final acceptance register. Do not start P3A on a failed
gate or claim installed acceptance. No new release.

### P3A file-status vertical slice (candidate)

Reuse the exact already-admitted status output of Git, recorded JJ and local
SVN. A compact owned 64-row/8 KiB path arena retains typed file records,
Git XY/rename source, JJ compact rename expression, SVN property/tree flags
and per-entry revision where reported. Invalid/oversized or omitted rows are
counted independently from full summary counts. No new CLI or network access.
Eight-row native pages and explicit case-sensitive retained-record search
are bound to the existing workspace generation and fresh ready view; stale
snapshots are display-only. Real CLI fixtures and malformed/overflow fixtures
cover the first slice. History, revision/file content, selected-file diff,
refs/workspaces, full provider-native detail and right-click file inspection
remain P3A requirements, not completed by this candidate. SVN server history
requires separate authorization. No SDK baseline changes or new release.

### P3A consolidated advanced workspace candidate

[5bfdaa3 / 45926890194](https://github.com/strangelion/pulse-extras/actions/runs/45926890194)
passed the file-status slice. This candidate adds the remaining advanced
local query path in the existing serialized worker and native panel: selected
file or explicitly entered literal path, full revision-ID review/selection,
file and repository history, output pagination, revision detail/content,
working/staged/revision diff as applicable, Git refs/worktrees, JJ bookmarks,
workspaces and operations, SVN local info/properties/BASE/working diff.
A single selected-file context menu copies and freshly validates the exact
selection and prefills the panel after a matching trusted workspace is ready;
the directory route is retained. No automatic authorization or file query.
Git history is anchored to a full commit ID and supports 32-entry offsets
through 4096; JJ history uses a full 128-hex operation pin shared by status
and all details, 32-entry offsets through 224, and immutable commit anchors.
The visible history rows can supply a reviewed full ID for subsequent actions.
Older saved local approvals cannot silently authorize the extended command
policy: the fingerprint is domain-separated; old same-scope records can
still be inspected/revoked and explicitly replaced.
Git suppresses external diff/textconv, refuses promisor/partial-clone
configuration, and refuses clean/process filter configuration before a
working diff. SVN uses native local targets, verifies ordinary target/parent
identity, permits only known pre-1.15 BASE/working diff (newer clients may
hydrate absent pristine content), and never admits server history or
arbitrary revision/network operations. JJ never snapshots or reconciles
divergent operations in these queries. No shell or write/network command
admission, no temporary revision files. Local trust remains not an OS
sandbox; concurrent config/filesystem changes remain outside its guarantee.

Bounded text output is 16 KiB with explicit resource, NUL/binary and encoding
failure; large histories/ref lists are bounded (Git refs maximum 128,
JJ history prefix maximum 256), not unbounded inventories. Compact JJ rename
expressions are display-only; ambiguous paths require manual literal entry.
Existing strict protected Git auditor remains summary-only, ordinary reviewed
local sessions provide the expanded workflow. Native memory Diff is not used
because the published SDK baseline lacks that contract. SVN server history
and non-pristine working copies cannot be implemented under the offline
approval gate; native installed UI, all alias/large-repo cases and full
candidate CI remain unverified. Exact required CI and exit review still
required; do not advance to P3B on a failed gate. No release or Companion
change.

Regression 59a6721 / 45928253651 failed the formatting gate on Windows and
Ubuntu before compilation. The repair aligns the exact formatter output,
fixes the duplicate Git integration-test name and Windows sentinel pointer,
allows only the exact GIT_NO_LAZY_FETCH=1 environment value, suppresses
permission-denied detail results and rejects an SVN target in a nested
checkout. Adds working diff and environment regression assertions. Exact
new full CI is mandatory; the previous failed gate is not a test pass.

P3A follow-up regression 5e70df2 / 45928869724 passed formatting and Linux
compilation, but the Linux integration gate reported 683 passed, 15 skipped,
3 failed (Git working diff guard, JJ file history, SVN working diff).
This repair isolates the compatibility fixture from ambient system/global
Git configuration, retains the deliberate local-filter denial, uses a fixed
JJ commit-ID/file-ancestry revset, and supplies a plain non-pegged SVN
working-copy diff target with empty depth (no directory recursion).
Only compatibility test builds emit bounded detail failure diagnostics;
approved host sessions do not log raw tool output. These repairs require
the exact new CI and installed acceptance remains deferred.

### P3A exit review and P3B consolidated candidate

[378e540 / 45929366805](https://github.com/strangelion/pulse-extras/actions/runs/45929366805)
passed all six required jobs (scope, both OS checks, both native Companion
lanes and Regression gate). Local-only P3A code gate is met; installed UI
and the explicitly unsupported server/history/pristine/SDK cases remain
HOST DEFERRED. No release.

P3B extends the existing project manager, rather than adding another store:
literal local Git remote discovery (six choices, 4 KiB ordinary config,
no includes or indirection), canonical chosen address with persisted
detected/manual provenance and v2 migration, fixed GitHub/GitLab/Bitbucket
browser page actions, explicit saved exact VS Code and TortoiseSVN executable
paths, a separate one-shot project/version-bound launch review and an
anonymous GitHub repository metadata snapshot. The external task slot is
serialized, retains immutable inputs through terminal release, discards
obsolete results, and never uses VCS trust or credentials. Only a chosen
canonical address persists; public API snapshots expire after five minutes
and are never reused for authorization or automatically refreshed. HTTPS
request is GET to api.github.com only, with 64 KiB body bound, timeout,
no redirects/cookies/auth or proxy auto-discovery. Rate limit/denial,
private/missing, network, invalid and oversized states stay distinct.
Client handoffs use an exact executable and fixed reviewed arguments,
not a shell, no inherited handles; applications are user-owned afterward.
VS Code CLI and TortoiseSVN automation references:
https://code.visualstudio.com/docs/configure/command-line
https://tortoisesvn.net/docs/release/TortoiseSVN_en/tsvn-automation.html
GitHub public REST: https://docs.github.com/en/rest/repos/repos#get-a-repository
WinHTTP options: https://learn.microsoft.com/en-us/windows/win32/winhttp/option-flags

No authenticated API/token storage, GitHub Desktop launcher (Windows
documented command does not establish a verified direct exe adapter),
Sourcetree/GitKraken, self-hosted forge, indirect/worktree/JJ-native remote
discovery or GitLab/Bitbucket API is claimed. Manual canonical URLs remain
available. The public API does not use the user's browser or proxy credentials;
private access remains browser-only. No credential or remote write action.
Exact P3B full CI, independent Windows HTTP/launch ABI review, live consenting
public endpoint/client tests and installed UI remain unverified. P3B remains
active until exit review; no Companion change, no SDK change or release.

P3B candidate e983c6b / 45930628317 failed the initial Linux Zig formatting
check before compilation. The combined review repair applies the formatter
correction, makes persisted remote provenance visible, disables conflicting
settings actions during integration work and adds explicit cancel with
terminal-release/stale-selection tests. No tests removed. Fresh exact CI
required; live transport and external applications remain NOT RUN.

P3B bb362dd / 45930749443 passed formatting but the Ubuntu and Windows
settings unit target failed to compile (clientPath error-union optional
payload coercion). The Companion desktop lane was blocked by the same VCS
DLL build error, not a demonstrated pet lifecycle failure. The consolidated
repair unwraps the error union before coercion, adds matching local panel
summary capture to the project dashboard (explicit, no new CLI, unknown
counts remain unknown), displays exact external command on review and adds
independent Windows-header ABI size/offset/constant assertions in CI. No
credential access or actual external launch/network test was performed.
The published GitHub Desktop CLI docs describe github PATH but do not
establish an exact direct Windows executable contract; keep manual fallback.
Authenticated API remains optional and unavailable; no account authorization
assumed. Full new code gate required, installed/live transport still deferred.

### P3B exit and P3C Mercurial candidate

[2d08926 / 45932279549](https://github.com/strangelion/pulse-extras/actions/runs/45932279549) passed all six required jobs, including Windows ABI and Companion lanes. P3B supported-scope code gate is complete; authenticated API and unverified client adapters remain intentionally unavailable, live/installed checks HOST DEFERRED.

P3C starts with one Mercurial vertical slice: non-executing ordinary .hg detection, exact configured/detected hg path, separate provider-scoped review and remembered grant/revoke, project record, native status including copy/missing/ignored/untracked and unresolved conflicts, 32-entry anchored history pages and file history, revision info/content, working/revision diff, branch/tag/bookmark inventory, existing file selection and bounded text UI. No staging, server distance, remote operations, writes or shared/subrepository support. Baseline 7.2.4, CI provisions the pinned binary wheel and local fixture on both OSes. Controlled session uses exact HGPLAIN=1, HGRCPATH empty, HGRCSKIPREPO=1, HGENCODING=UTF-8; the ordinary .hg/store layout and requirements are independently checked before every repository command. Config hooks must not execute (fixture includes a failing pre-status hook). This is not a sandbox: trusted installation and repository remain necessary; reject unknown metadata requirements, .hg/sharedpath and .hgsub/.hgsubstate. Documentation: https://www.mercurial-scm.org/help/topics/environment and https://mercurial-scm.org/help/topics/revisions . New code is a candidate; exact cross-platform CI and installed acceptance NOT RUN. Perforce and other VCS require their own complete implementation, not stubs. No Companion or SDK changes.

Mercurial candidate 7bdee3b / 45933512830 reached the build graph but failed because the added module import exceeded the old 42-entry array. Corrected to 43 entries after checking the complete import list. Exact new full CI required; no Companion functional regression is inferred from this common build failure.

Mercurial regression 235f66a / 45933783252: Ubuntu passed, Windows
compiled and passed 715/716 tests; the sole failed test was the native
approved Hg fixture, at the version probe before repository admission.
The prior logs did not distinguish launcher failure from other nonzero
exit status. Keep all mandatory checks. Add an explicit Windows
minimal-environment preflight for the generated fixture (version, root,
status) independent of the Zig job wrapper, redacted test-only native
probe status/exit/output-size diagnostics, and a ten-second Hg cold-start
version budget within the existing 15-second approved process limit.
Disable Python user-site imports via the exact PYTHONNOUSERSITE=1
environment value without admitting inherited PATH/PYTHONPATH or
credentials; the installation itself remains trusted, not sandboxed.
Mercurial 7.2.4 minimum and pinned wheel unchanged. Root cause of the
nonzero version exit is not yet established; fresh exact CI required.
Perforce work remains gated on the Mercurial regression.

Mercurial d06abe8 / 45934907652 failed: the Windows independent preflight
and contained approved version probe both exited 255, stderr 48 bytes;
preflight reported missing python312.dll. The wheel's executable loads
Python dynamically (upstream exewrapper.c), so neither a longer timeout
nor a Job Object change fixes this missing dependency. CI now assembles
its documented adjacent hg-python private runtime layout from the hosted
CPython standard library and DLLs, with the pinned Mercurial wheel in the
private site-packages, and uses the same unchanged launcher/script for
fixture construction, minimal-environment preflight and mandatory native
test. No production PATH/PYTHONPATH inheritance, registry changes, OS
sandbox downgrade, automatic user runtime installation or DLL copying.
The previous environment regression test also used nonexistent Zig
Environ.Map.remove; restore the approved value instead, then independently
reject PYTHONPATH. Both OS checks and Companion desktop were blocked by
that common test compile error. Add explicit native setup guidance for Hg
installations requiring a private runtime. New exact CI required; private
layout compatibility not yet proven. Perforce stays gated.

### Consolidated VCS read-only release candidate

6f29edf / [45935843006](https://github.com/strangelion/pulse-extras/actions/runs/45935843006)
passed all six required jobs, including Windows Hg private-runtime preflight
and approved local session, Windows/Linux and both Companion lanes. The
four-provider baseline is verified code, not installed acceptance.

Final read-only hardening: guard ordinary Git status against external
clean/process filters and partial-clone configuration and disable fsmonitor
in exact status argv (protected Git retains independent configuration audit);
reject DOS device/short-name aliases and ambiguous file paths; share path
selection policy across rendering/dispatch; prevent root SVN cat and
live file-diff directory/reparse/nested-repository targets; remove legacy
unpinned JJ admission; exercise actual approved history/content/diff in
Windows fixtures; explicitly label write restrictions and Git diff semantics.
Risk defaults require confirmation for network/local metadata writes.
Exact new full CI required. These are conservative admission checks, not
an OS sandbox or atomic defense against concurrent external changes.

P4 remains NOT IMPLEMENTED: existing read approval and read task cancellation
cannot be reused for a mutating command. Native writes require separately
bound one-shot operation plan, reviewed exact index/worktree/HEAD evidence,
shared-store lock, revalidation immediately before invocation, postcondition
verification, non-rollback cancellation reporting and isolated real tests.
No arbitrary CLI or automatic mutation. Until then reviewed external clients
are the supported handoff. Do not claim a writable product or publish.
Installed Pulse UI, HTTP/client launch, and all deferred Companion D
measurements remain one final acceptance round, not code CI evidence.
