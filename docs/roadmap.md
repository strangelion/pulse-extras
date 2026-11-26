# Roadmap / 开发路线

## Baseline (2026-11-24)

The last full verified CI baseline is [c330c24 / run 45421511648](https://github.com/strangelion/pulse-extras/actions/runs/45421511648): Ubuntu 83/83 tests, Windows 81 passed and 2 SVN integrations skipped, 6/6 Windows DLL build steps on both runners, pinned SDK regeneration, and 16 C ABI loader lifecycle cycles. Both Zig archive caches hit. These are historical results, not a claim that later commits or real VCS host integration have passed.

Current merged Runtime baseline: [2759b51 / run 45514152046](https://github.com/strangelion/pulse-extras/actions/runs/45514152046), Windows 131/133 and Ubuntu 129/133 (platform-only skips), isolated Windows Job Object tests, both ReleaseSafe builds and Regression gate passed. Main CI 45515451399 was still running at review. This is a library baseline, not a VCS panel release.

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

- [x] Provider contract, capability/risk models, bounded identity types, marker detection and CLI discovery.
- [x] Bounded snapshot cache and generation counter primitives.
- [x] Git, JJ and SVN read-only status summaries; Git and JJ real temporary repositories on both CI OSes, SVN actual local working copy on Ubuntu.
- [x] Git rename-source parsing regression, same-root Git/JJ candidate detection, JJ operation-log invariance test.
- [ ] History, file-level diff, complete repository identity and provider-specific field availability.
- [ ] Windows SVN integration (currently skipped explicitly).

## P1.5 — Required hardening before background panel integration

- [ ] Implement RT0 of the [Shared Runtime contract](shared-runtime.md): explicit scoped ownership, standard allocator budgets, resource cleanup, cancellation, bounded queue and process-tree teardown. Remove unsafe DLL-local process-lifetime assumptions from the existing runner; prove workers/callbacks drained before unload. Test OOM/partial init, repeated lifecycle, infinite output, cancellation and timeout. Never terminate unrelated processes. Reuse source modules across independent DLL instances, not a central GC/service.
- [ ] RT0 candidate: caller-owned I/O, finite deadlines, bounded output reservations, earlier VCS buffer release and owner-thread cache publication. Confirm full CI and actual owner lifecycle. Next candidate adds bounded requested-byte allocator, stop admission/drain checks and deterministic OOM/resize/remap/timeout/repeated-run tests. Single owned std.Io future candidate adds bounded argument/environment copies, cancellation/join and independent-owner checks. Verify format, compilation, async cancellation, environment cleanup and repeated execution before merging. Process-tree containment, provider-wide async scheduling, trusted environment policy and actual unload remain open.
- [ ] Resolve trusted absolute executable paths and supported CLI versions; constrain environment/config/interactive prompts. Verify passive commands' actual side effects instead of trusting names.
- [ ] Cache key must include provider, repository and workspace. Enforce generation checks on submission, document thread/ownership rules, prevent stale results and dangling borrowed pointers.
- [ ] Separate true zero/empty from unknown/not queried/unsupported/stale/partial/error. Resolve actual worktrees/shared metadata rather than assuming markers prove colocation.
- [ ] Pin JJ multi-query snapshots to one operation when supported; distinguish recorded snapshot from disk changes. Test Git optional-lock/config effects. Use bounded safe SVN XML parsing and distinct SVN semantics, including attributes, tree conflicts and mixed revisions.
- [ ] Add deterministic tests with each fix; use current SDK contracts and installed Zig stdlib. Do not delay actual feature delivery with unused wrappers or empty providers.

## P2 — First real VCS extension

- [ ] Create independent `extensions/vcs`, ID `strangelion.vcs`; keep ABI Probe and Hello Panel independent.
- [ ] RT1: consume applicable shared runtime primitives in the actual VCS panel; establish measured resource budgets, owned allocation/handle baselines and multi-cycle teardown evidence. Do not postpone VCS for a speculative generic framework.
- [ ] Provide current-directory repository/CLI detection, multi-provider/workspace selector, native status panel, conflict counts, data age, manual refresh, cancellation and useful errors.
- [ ] Use public Pulse context, tasks/dispatch and native UI APIs as required. All potentially blocking work off UI thread; cancel/discard obsolete requests, stop when panel closes, safely drain before deactivation/unload.
- [ ] Support English/Chinese, light/dark, DPI and resize; no private host API, duplicate native Git badges or background writes.
- [ ] Produce an isolated-installable `strangelion.vcs-0.1.0.pulse-ext` candidate. Verify on real Pulse: non-repo, Git/JJ/colocated/SVN, missing CLI, rapid navigation, large repo, close/reopen, disable during query, exit, upgrade/rollback. Record screenshots/logs, build hash, process and memory evidence. Mark unrun cases NOT VERIFIED.

## R — Shared packaging and release (after first P2 acceptance)

- [ ] After the first real VCS package passes isolated host acceptance, implement reusable official package/verify helpers and per-extension version descriptors.
- [ ] Add one manually dispatched Release workflow with single/selected/all eligible extensions, dry-run by default, then protected draft/publish modes. Full CI and relevant host evidence must match the released source/artifact. Keep each extension independently versioned.
- [ ] Validate signing with test keys, protected production key handling, collision/partial failure recovery and official registry metadata. Confirm registry acceptance; no automatic official catalog publication.

See [release design](release.md). This is a separate milestone after P2, not blocked by completion of all VCS backends or write operations. No production publication before the relevant gates pass.

## P3 — Read-only advanced functions

- [ ] Changed-file list, paged history, bounded file/revision diff and revision content.
- [ ] Git refs/tags/worktrees; JJ change/bookmark/workspace/operation log; SVN revision/attributes.
- [ ] Mercurial, then Perforce once the panel and first three providers pass acceptance. Server fixtures are not real server acceptance.
- [ ] Plastic, Sapling, Fossil and other VCS only as justified. Do not advertise unimplemented capabilities.

## P4 — Write operations (disabled until reviewed)

Implement one operation at a time with risk classification, explicit plan/confirmation, revalidation, advisory shared-store locking, external-change detection, bounded execution, cancellation and partial-failure recovery. Do not promise universal undo. No destructive or remote operations by default. Follow official Pulse file-mutation rules and verify actual integration before exposing writes.

## P5 — Other independent extensions

| ID | First deliverable | Explicit exclusions |
| --- | --- | --- |
| strangelion.convert | PNG/JPEG batch conversion to new files via staging | No in-place replacement |
| strangelion.inspect | Read-only PE metadata and signature inspection | No execution or malware verdict |
| strangelion.data | SQLite schema and bounded NPY/NPZ metadata | No arbitrary SQL writes |
| strangelion.devkit | Project detection and toolchain inventory | No automatic install or build scripts |
| strangelion.compare | Recursive read-only content comparison | No sync/deletion until safety review |
| strangelion.companion (candidate) | Existing pet/event bridge or small supported native character prototype | No full pet simulator or generic Agent; validate demand and SDK first |
| strangelion.forge (conditional) | Reusable templates, constrained recipes, validation and maintenance | No generic coding Agent; separate MCP/panel only with demonstrated value |

- [ ] Deferred RT2+ design gate: allow separately installed Pulse Extras add-ons to reuse a single versioned runtime binary and same-host runtime instance, only after host dependency/lifecycle support and mixed-addon acceptance are proven. Keep the current bundled source-sharing model until then. See [shared binary dependency plan](shared-runtime.md#deferred-shared-binary-dependency-multi-add-on-coexistence).

RT2: all new products reuse the shared runtime contract; extend it only for proven needs, track bundled runtime revisions and rebuild/test/release affected consumers after fixes. Test independent instances and mixed-version coexistence. Recheck upstream source, roadmap, SDK and registry for overlap before implementing each extension. Pulse already has basic Git and SVN status, native lock detection, common previews and archive integration. Coordinate 3D/OCR/remote features with upstream.

After P2/R, prioritize Convert, a small Companion feasibility experiment, then Inspect, Compare, Data and focused DevKit according to demonstrated demand; VCS advanced functions continue as needed. See [product scope](product-scope.md) for overlap exclusions, research references, dependency policy and low-token delivery. Do not block usable features on a complete platform.

Release follows milestone R and [release.md](release.md). Keep secrets out of Git/CI logs. Project license is AGPL-3.0-only, preserving prior Apache-2.0 grants and upstream/third-party obligations. Zig-first remains unchanged; review source delivery and registry acceptance before distributing.

## C — Companion feasibility (candidate)

- [ ] C0: compare OpenPets/other bridges and installed SDK; validate event/rendering support and minimal resource cost. Stop if redundant or unsupported.
- [ ] C1: optional connector or small character prototype with data-only skins, actual authorized task states, visibility/pause and bounded assets.
- [ ] C2: actual user/host acceptance and resource measurements before considering independent renderer or richer offline interaction. See [product scope](product-scope.md#5-companion-feasibility-candidate-no-implementation).

### Companion stage D — packaging and real-host acceptance (planned)

- [ ] D0–D1: official native v2 test package with existing development ID, verified exact artifact, isolated Windows test account/VM and host store/profile; green full code CI first. Exact-artifact reuse and evidence checks passed automatic regression at 6d63439; explicit official test-package job added to the existing CI, first artifact and actual installation remain to verify.
- [ ] D2–D4: use the [canonical D acceptance register](companion-manager.md#d2-real-host-functional-acceptance-matrix): 100 independent visible pets, separately high-count actual Pulse-managed instances, long soak/leak checks, crash/recovery, live market, image fallback and install/update/uninstall. Escalate safely; repair and repeat affected tests with exact-artifact evidence.
- [ ] D5: independently verified formal candidate, official manifest and signing/release eligibility; separate publication approval. No shared-binary runtime implementation in this stage.

See [Companion stage D](companion-manager.md#stage-d-official-testformal-packaging-and-real-host-acceptance). No claim of actual installed acceptance or publication.

## F — Forge authoring tooling (conditional, after real components/package foundations)

- [ ] F0: reusable author templates and shared components from real products, constrained declarative recipes where supported, deterministic SDK/package validation and migration. Reuse official author tools and existing Pi/DSH/Codex transports; no duplicated general Agent infrastructure.
- [ ] Benchmark representative tasks against direct Agent authoring: time, tokens, correctness, repair cycles and maintenance. If no material advantage, keep tooling in DevKit/shared scripts.
- [ ] F1: only if justified, thin standalone Zig author CLI/MCP and bounded Agent integration with explicit authorization and OS-level isolation for generated native code.
- [ ] F2: optional visual editor/native panel, shareable recipes and compatible preview if verified and demanded.
- [ ] F3: discuss typed AI tool registration and permissions with upstream; direct native assistant integration remains unsupported by the pinned public SDK.

See [Forge design](forge-architecture.md). Do not block VCS or other independent packages on Forge, and do not create placeholder projects. A single natural-language request is a development task, not permission for unreviewed native execution or release.

## Delivery and reporting

Synchronize remote main without overwriting local work. Read existing docs and code before changes. Commit logically related fixes after local tests; add CI coverage with new features. Report exact commands, results, CI scope, actual host evidence, resource measurements, remaining gaps and next work. See [testing.md](testing.md) for the reduced/full CI policy. Do not create AGENTS.md or duplicate design documents.

RT0 follow-up candidate: retain only actual completed output bytes, expose safe owner-thread diagnostics, validate explicit local paths/environment and maximum deadlines. CI verification and trusted resolver adoption precede VCS panel integration. Do not add a global service or claim descendant ownership before an actual tested process-tree backend exists.

RT0 latest-only task candidate provides one running future plus one replaceable queued request and a real VCS Session consumer. Full CI and existing Git/JJ/SVN fixture checks precede merge. Host-specific acceptance may be scheduled later, but process-tree implementation, trusted resolution, UI completion delivery and host lifecycle checks remain recorded gates; no shipping VCS DLL yet.

RT0 non-host candidate implements Windows job-backed Runner opt-in, approved path/digest and narrow env admission, group budgets, FIFO, typed event ring, owned temporary file store. Validate full CI and follow up on failures; actual host and measured multi-plugin acceptance deferred. Persistent crash recovery/rotation, race-free trusted installation verification and product-level policy integration remain explicit follow-up, not claimed complete.

Deferred real-host checks are enumerated in [shared-runtime-host-acceptance.md](shared-runtime-host-acceptance.md); retain NOT VERIFIED until actual evidence. A merge of the library foundation does not certify production VCS panel distribution.

VCS panel milestone: host-independent coordinator and bounded native SDK model are implemented as a candidate; no new DLL/package or automatic execution. Full CI precedes host wiring; UI delivery must respect official dispatch and teardown contract. Actual approved tool/repository policy, JJ/SVN identity and history remain open.
