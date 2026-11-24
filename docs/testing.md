# CI and local testing

The full Zig regression workflow runs on Windows and Linux. It checks formatting, Python 3.12 script syntax, Zig unit tests, native provider integration tests, Windows x64 DLL builds, and (on Windows) pinned SDK binding regeneration and C ABI loader tests. Reduced scopes are defined below.

| Coverage | Windows | Linux |
| --- | --- | --- |
| SDK wrappers and ABI tests | Required | Required |
| Git temporary repository | Required | Required |
| Jujutsu 0.46.0 temporary repository and operation-log invariance | Required | Required |
| SVN local repository and working-copy status | Optional if installed locally | Required |
| Windows DLL build | Required | Required |
| C loader + binding regeneration | Required | Not run |
| Actual Pulse UI/host acceptance | Manual isolated host | Not run |

CI installs the pinned JJ binary from its official release and checks the recorded SHA-256. Linux CI installs Subversion through the runner's package manager and creates a local repository using svnadmin. The build script snapshots PATH and PULSE_REQUIRE_* flags from the build environment into a generated test-options module using Zig 0.17's supported build graph environment map. Test code does not fabricate platform-specific std.process.Environ blocks. The flags prevent absent tools from silently skipping required integrations. The SVN fixture path is passed through the same generated options module. Local runs may skip unavailable optional CLI tests; skipped tests are not integration evidence.

No remote VCS server, credentials or real user repositories are required. Host UI, packaging, cancellation/worker teardown, multi-provider cache correctness and performance tests still need dedicated coverage as the relevant features are implemented. A green workflow does not prove those untested properties.

## Zig installation cache

The workflow restores the original Zig archive with actions/cache v5. The locked sizes and SHA-256 digests in scripts/zig-downloads.json come from the official release index. Every restored archive is checked again before extraction and the extracted compiler version is verified. On a cache miss the archive is downloaded from the official origin, checked, extracted and saved immediately, before compilation or VCS integration tests. The cache key changes with the pinned release metadata, OS or architecture. Pull requests restore but do not save this cache. The installer reports cache hits/misses and download, verification, extraction and version-check timings separately. A corrupted cached archive is re-downloaded; if an immutable cache entry remains corrupted, delete that entry in GitHub Actions cache management. No extracted toolchain, user data, test fixture or release package is cached. Community mirrors and compiler caches are deliberately not enabled yet; mirror adoption requires official signature verification and compiler-cache adoption requires measurements.

## Reproducible SDK bindings

The generator normalizes standalone translate-c source-location comments for known SDK headers and the compiler's stdint.h. Absolute installation paths are not part of the ABI. All declarations, diagnostic expressions, header hashes, and source line/column numbers remain subject to exact comparison. A failed check prints a bounded unified diff to identify any remaining differences without weakening the gate.

## Change-aware CI

The same workflow is triggered on every push, pull request and manual dispatch. A small Ubuntu scope job classifies all changed paths; the final Regression gate reports success only when the required jobs succeed (or the code jobs are intentionally skipped for docs). No path-filtered workflow is left pending.

| Scope | Changes | Required checks |
| --- | --- | --- |
| docs | Only README.md and Markdown under docs/ | Classifier tests and scope/gate only; no Zig install or functional tests |
| vcs | Only Zig source under shared/vcs/ plus allowed Markdown | Both OSes: Python checks, Zig format, all unit/real-repository integration tests and ReleaseSafe DLL build; no Windows SDK regeneration or C loader |
| full | Everything else, mixed/unknown changes, tags, new/rewritten branches, unavailable/empty diff, manual dispatch | All existing checks including SDK regeneration and Windows C loader |

Push scope uses the entire before-to-after diff, not just the last commit. PR scope compares the checked-out merge tree against its base SHA. Renames are considered as old and new paths; unavailable diffs default to full. The classifier is tested in scripts/test_ci_scope.py. Workflow, build.zig, toolchain/SDK locks, SDK wrappers, process runner, extensions, scripts and test changes always require full CI. A new build dependency on documentation requires revisiting the allowlist.

A docs-only green gate validates scope only, not earlier commits or code. Reduced VCS checks do not prove the omitted ABI tests. Run the workflow manually (full) before release, after a series of reduced runs, or when a prior code check failed. There is no scheduled cache keepalive or extra periodic workflow. If configuring branch protection, use the stable **Regression gate** check after its first run; do not require an intentionally omitted individual step. Existing protection settings are not changed by this workflow.

Last historical full baseline: [run 45421511648](https://github.com/strangelion/pulse-extras/actions/runs/45421511648), c330c24. Ubuntu 83/83; Windows 81/83 with two optional SVN integrations skipped; both DLL builds, binding check and 16 C loader cycles passed. Host-specific tests remain manual. The cache-hit installation phase was about 5–7 seconds excluding cache restore, versus 380–599 seconds cold. Do not add large compiler caches without measurements.

## Shared runtime regression policy (planned)

See [Shared Runtime](shared-runtime.md) for the ownership, resource limits, cancellation, unload and acceptance contract. Changes under shared/runtime, shared/memory and shared/process are FULL scope by the existing conservative classifier. As real primitives/consumers are implemented, require deterministic leak/ownership, allocation failure, budget arithmetic, timeout/cancel/process-tree cleanup, stale result and repeated lifecycle tests on both OSes. C loader and real host evidence must cover runtime consumers, including multiple plugins and mixed runtime revisions. Keep long soak, stress, fuzz, large workloads, OS containment and live host measurements manual/opt-in; never skip required correctness regressions to reduce CI time. Measure live tracked bytes, peak/reserved bytes, Private Bytes/commit/working set, handles/threads, children and idle CPU; document baseline/plateau and untracked third-party allocations. No claims from a docs-only check.

## Planned release and authoring validation

Ordinary docs/VCS/full scopes remain unchanged. The future [release workflow](release.md) must require full regression on the exact release SHA, selected package tests, hash-bound actual host evidence and protected signing; it must not accept a reduced/docs green gate as full evidence. Dry runs use no production secrets or release writes. [Forge](forge-architecture.md) tests use deterministic fixtures and isolated workers; paid/live model calls and contained real-host preview are opt-in acceptance, not routine CI. A separate profile and C ABI loader do not constitute OS isolation. These are planned gates, not implemented workflow stages.

## Dependency and reuse gates

New submodules/dependency pins, license changes and build integration are FULL scope under the existing conservative classifier. Fetch only audited dependencies needed by selected builds; reference-only repositories and docs checks must not acquire them. Use real engine/CLI/IPC tests and fixture-based authoring, pet event and recipe tests before advertising support. Keep resource/host/containment and benchmark acceptance separate from lightweight routine CI. Release source and exact dependency/license review follow [product scope](product-scope.md) and [release](release.md).

RT0 candidate adds deterministic output-budget overflow/rollback/drain tests, serialized provider/workspace cache key and stale-generation checks, strict known CLI version prefixes, UTF-8 text validation, and VCS intermediate output lifetime changes. Full CI is required. No Windows real-host cancellation or unload evidence yet.

RT0 allocator/stop candidate: ordinary Windows/Linux tests cover reserve/alloc failure rollback, resize/remap, zero-byte/alignment-sized allocation, independent owners, admission rejection, refusal to stop with live outcomes, real finite single-child timeout and repeated cleanup. Verify all tests against pinned Zig; tests use finite child fixtures, not an unbounded stress workload. Deeper cancellation/descendant, concurrency and mixed-plugin real-host acceptance remain required. Record tracked live bytes/reservations, not an inferred Private Bytes or working-set limit.
