# CI and local testing

The full Zig regression workflow runs on Windows and Linux. It checks formatting, Python 3.12 script syntax, Zig unit tests, native provider integration tests, Windows x64 DLL builds, and (on Windows) pinned SDK binding regeneration and C ABI loader tests. Reduced scopes are defined below.

| Coverage | Windows | Linux |
| --- | --- | --- |
| SDK wrappers and ABI tests | Required | Required |
| Git temporary repository | Required | Required |
| Jujutsu 0.46.0 temporary repository and operation-log invariance | Required | Required |
| SVN local repository and working-copy status | Required in VCS/full CI | Required |
| Mercurial 7.2.4 real ordinary repository, history/diff and native approved fixture | Required in VCS/full CI | Required in VCS/full CI |
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
| companion | Only classified companion source/test paths and allowed Markdown | Windows/Linux companion regression, Windows native IPC and desktop lanes, fast ZIP test; no unrelated VCS or SDK/DLL checks |
| companion-host | Exact allowlisted Companion extension, runtime/store adapters, probe or C loader, optionally with companion paths and allowed Markdown | All companion checks, production DLL builds on both OSes, pinned headers and unbundled Companion C ABI on Windows; no Git/JJ/SVN integration or SDK binding regeneration |
| full | Everything else, mixed/unknown changes, tags, new/rewritten branches, unavailable/empty diff, manual dispatch | All existing checks including SDK regeneration and Windows C loader |

Push scope uses the entire before-to-after diff, not just the last commit. PR scope compares the checked-out merge tree against its base SHA. Renames are considered as old and new paths; unavailable diffs default to full. The classifier is tested in scripts/test_ci_scope.py. Workflow, build.zig, toolchain/SDK locks, SDK wrappers, process runner, other extensions, scripts and unclassified test changes always require full CI. The companion-host allowlist is exact, not a wildcard over extensions or shared adapters. Git still checks out the repository in every scope, but JJ installation, VCS tool checks and SVN fixture preparation run only for vcs/full. Manual dispatch remains full. A new build dependency on documentation requires revisiting the allowlist.

A docs-only green gate validates scope only, not earlier commits or code. Reduced VCS checks do not prove the omitted ABI tests. Run the workflow manually (full) before release, after a series of reduced runs, or when a prior code check failed. There is no scheduled cache keepalive or extra periodic workflow. If configuring branch protection, use the stable **Regression gate** check after its first run; do not require an intentionally omitted individual step. Existing protection settings are not changed by this workflow.

Last historical full baseline: [run 45421511648](https://github.com/strangelion/pulse-extras/actions/runs/45421511648), c330c24. Ubuntu 83/83; Windows 81/83 with two optional SVN integrations skipped; both DLL builds, binding check and 16 C loader cycles passed. Host-specific tests remain manual. The cache-hit installation phase was about 5–7 seconds excluding cache restore, versus 380–599 seconds cold. Do not add large compiler caches without measurements.

## Shared runtime regression policy (planned)

See [Shared Runtime](shared-runtime.md) for the ownership, resource limits, cancellation, unload and acceptance contract. Changes under shared/runtime, shared/memory and shared/process are FULL scope by the existing conservative classifier. As real primitives/consumers are implemented, require deterministic leak/ownership, allocation failure, budget arithmetic, timeout/cancel/process-tree cleanup, stale result and repeated lifecycle tests on both OSes. C loader and real host evidence must cover runtime consumers, including multiple plugins and mixed runtime revisions. Keep long soak, stress, fuzz, large workloads, OS containment and live host measurements manual/opt-in; never skip required correctness regressions to reduce CI time. Measure live tracked bytes, peak/reserved bytes, Private Bytes/commit/working set, handles/threads, children and idle CPU; document baseline/plateau and untracked third-party allocations. No claims from a docs-only check.

## Planned release and authoring validation

Ordinary docs/VCS/full scopes remain unchanged. The future [release workflow](release.md) must require full regression on the exact release SHA, selected package tests, hash-bound actual host evidence and protected signing; it must not accept a reduced/docs green gate as full evidence. Dry runs use no production secrets or release writes. [Forge](forge-architecture.md) tests use deterministic fixtures and isolated workers; paid/live model calls and contained real-host preview are opt-in acceptance, not routine CI. A separate profile and C ABI loader do not constitute OS isolation. These are planned gates, not implemented workflow stages.

## Dependency and reuse gates

New submodules/dependency pins, license changes and build integration are FULL scope under the existing conservative classifier. Fetch only audited dependencies needed by selected builds; reference-only repositories and docs checks must not acquire them. Use real engine/CLI/IPC tests and fixture-based authoring, pet event and recipe tests before advertising support. Keep resource/host/containment and benchmark acceptance separate from lightweight routine CI. Release source and exact dependency/license review follow [product scope](product-scope.md) and [release](release.md).

Historical RT0 test additions, Windows timeout investigation and detailed
checkpoint logs are retained in the [pre-consolidation testing document](https://github.com/strangelion/pulse-extras/blob/78a33f1a54cabb6e880687023692a07aba44163c/docs/testing.md).
Current requirements are the ownership, timeout, quota, leak and lifecycle
gates above; keep the isolated Windows Job diagnostics and mandatory
aggregate test deadlines. Formatting failure prints the exact patch in
the disposable checkout; never mutates the repository.

## Parallel native lanes and performance evidence

The Windows native IPC and desktop jobs run in parallel with Windows/Linux
general checks; the stable Regression gate requires every applicable lane.
The desktop lane owns both standalone and managed crash tests, supervisor,
private-root/catalog, bundled C ABI, actual import and static WebP
allocator/mixed two-child/package-admission checks. Reuse its existing
WebP helper build, supervisor executable and fixture directory; do not
launch an additional workflow for the same push. The mixed codec probe
retains diagnostics on failure. The fast ZIP regression precedes the broad
suite. No failure is converted to a skip.

Only two workflows are needed now: Zig regression (automatic scoped
correctness, manual full) and Companion stress benchmark (manual independent
hidden, synthetic or mixed static WebP, 1–100 processes, 5–180 seconds).
Do not add hosted-visible, WIC-only or separate release workflows merely
for D; local harness options remain available for diagnosis. Actual
visible, host-managed, soak, network and package acceptance belong to
[Stage D](companion-manager.md#stage-d-official-testformal-packaging-and-real-host-acceptance).
See [performance.md](performance.md) for historical evidence. A docs-only
green check does not prove an earlier code change passed.

### Test artifact on request

Latest-only slot/session candidate: two slot and three session unit tests plus real Git/JJ/SVN existing repository fixtures through Session. Check bounded coalescing across 1,000 submissions, stale generation and failed refresh, cancellation preserving the newer queued request, stop and drain. No separate workflow. Full CI is required; actual Pulse lifecycle, multi-plugin host acceptance and process resource plateau tests remain deferred with status NOT VERIFIED, not counted as passed.

RT0 non-host candidate tests: Windows job ABI/layout, suspended child capture and descendant timeout, Runner opt-in tree and approved environment checks; aggregate allocation and queue caps; FIFO order/backpressure and cancellation; grouped latest-only/VCS admission; redacted ring eviction and exclusive temp-file cleanup preserving pre-existing files. Full Windows/Ubuntu CI required; Windows-only tests skip on Linux. Native host tests remain explicitly deferred. Do not treat compile-only or mock tests as verified runtime behavior.

See [Shared Runtime host acceptance](shared-runtime-host-acceptance.md) for the deferred NOT VERIFIED matrix. The merge gate is current full CI on Windows/Ubuntu; a green ancestor is not sufficient. Added tests for owned approval, bounded diagnostic export and quota-aware session rotation. Crash-safe recovery remains a separate non-host gate; no automatic scan/delete on prefix.

Windows CI 45453154189 was canceled in the aggregate test step after ~29m40s; Ubuntu passed 129/131 (two platform skips). Isolated Windows Job Object tests now precede the full suite with test-name and phase output and a 4-minute step deadline. The full suite remains mandatory and has its own 15-minute deadline. Do not ignore a hang or skip the backend tests to merge. Phase markers are test-only.

### Shared foundation candidate checks

The existing full Windows/Linux regression includes shared SDK and runtime
modules and Python package helper tests. Windows additionally compiles/runs
the shared private-root and native-primitives fixtures and a synthetic sibling
crash collector; managed dump storage is compile-checked here and retains its
product integration test in the Companion branch. No live network, Pulse
host, user approval store or user data is used by these shared tests.
The same Regression gate remains mandatory. Do not mark product migration,
real-host resource/drain behavior, or formal release as passed on this basis.

## Stage regression and acceptance closure

For each stage in [roadmap](roadmap.md), test the complete vertical slice
rather than only the last edited helper. Run targeted local tests/format/build
before the combined push where the pinned toolchain is available. Retain
all existing scope gates; stage completion and release candidates require
full regression on the exact final code SHA. A docs-only check or green
ancestor does not satisfy it. Consolidate related CI failures and fixes;
never skip or weaken a positive provider/negative security fixture.

VCS P2A requires actual Windows Git/JJ/SVN local-session queries (ordinary
installations), settings/picker/consent/revoke/lifecycle, and exact package
host acceptance. P2B adds project record persistence/migration/version
conflict/selection and per-project trust tests. P3A adds real provider
file/history/diff and bounded malformed data fixtures; P3B adds URL/client/
optional API consent, redaction, quota and offline fixtures. The authoritative
installed matrix is [vcs-acceptance-runbook.md](vcs-acceptance-runbook.md).
If local toolchain/actual host/credential access is missing, state exact
NOT RUN/BLOCKED cases in one stage report and keep required gates intact.

## Mandatory Zig safety review

The existing Regression gate includes a dependency-free lexical safety
inventory on the Linux code-check lane (`python scripts/safety_audit.py`).
Both OS lanes run its Python regression tests. It checks handwritten Zig
under build.zig, shared, extensions and tests; generated SDK declarations
under shared/pulse/raw are covered by the existing binding checks instead.
The inventory rejects explicit @setRuntimeSafety overrides other than
literal true. No broad baseline or silent suppression is used. It reports
potentially risky constructs (optional force unwrap, pointer dereference,
C pointer types, casts, undefined, unreachable, empty error handlers,
truncation and memory copy) as REVIEW, not automatic defects. It is not an
AST, control-flow, alias, lifetime or data-race analyzer. A green scan is
not evidence that the code has no null pointers or other memory bugs.

### Local review before integration (required for handwritten native changes)

Run `python scripts/safety_audit.py --details` and review relevant findings
against the change diff, including existing callers. For every changed
risky operation record its concrete invariant, owner and failure path in
the review/PR or existing acceptance report; do not blanket-suppress findings.
An independent review pass must inspect the following, not merely rerun the
compiler:

- Null and ABI: check C/optional pointers and callbacks before dereference;
  distinguish null from INVALID_HANDLE_VALUE for the actual Win32 API.
  Check ABI size/version before tail fields, bounds and alignment before
  casts, integer conversion, pointer/length consistency and borrowed views.
  An arbitrary non-null foreign address cannot be proven readable by a
  lexical check. Never use IsBadReadPtr as a safety guarantee.
- Ownership: identify allocator, allocation/free pair, handle close owner,
  borrowed scope, stable address, partial-init unwind and error rollback.
  No cross-DLL allocator ownership without a documented ABI.
- Concurrency and unload: prove callback userdata remains live through
  cancellation/drain/release; distinguish cancellation request from join,
  test early and late callbacks, stale generations, reentrancy, repeated
  stop/destroy and unload. Do not assume an extension can veto host unload.
- Resource and errors: retain raw/native failure information and unresolved
  ownership; prove memory/handle/process/file cleanup and quota arithmetic.
  No arbitrary catch-unreachable or swallowed cleanup errors.

Add focused tests for touched boundaries: null/nonzero-length views, missing
optional tables and callbacks, malformed/short ABI data, invalid IDs/handles,
allocation failure (using the pinned std testing facilities), partial-init
failure, cancellation and release races, cleanup failure and repeated lifecycle.
Exercise the actual native C ABI and isolated host fixture where applicable.
No test that intentionally crashes or corrupts a user's real Pulse host.
The Debug test suite and ReleaseSafe DLL build remain required; the latter
alone is not a ReleaseSafe runtime test.

### Additional local analysis tools

ZLS, ZLint, Zwanzig and any optional compiler analysis must first be proven
compatible with the exact repository Zig pin. ZLS is an editor diagnostic
tool, not a lifetime verifier. Use available compatible lint/control-flow
analysis for native changes, and Clang Static Analyzer for C code. Record
version, target, invocation, findings and limitations; if unavailable or
incompatible, report BLOCKED/UNSUPPORTED, not PASS. Do not downgrade Zig
or install unreviewed binaries simply to run a tool.

Use ASan/UBSan for supported instrumented C/native fixtures, TSan for
supported concurrency fixtures, and fuzz bounded parsers/IPC/ZIP/JSON
with synthetic inputs and resource caps. Verify support against the
actual compiler and target; these are not unconditional Windows DLL flags.
Use Application Verifier (heap/handle checks) and WinDbg on an isolated
Windows test process, and real Pulse lifecycle acceptance in an isolated
profile/user where necessary. Keep crash dumps local and test instrumentation
out of shipping DLLs. Do not claim an unexecuted analysis passed.
Promote reproducible, pinned, measured checks into the existing CI only
after compatibility and false-positive review; do not bypass existing gates.
### VCS hardening candidate checks

Post-merge candidate adds a Windows Runner cancellation/reuse test, per-field VCS count availability, strict Git distance and JJ revision parsing, explicit JJ commit diff selection, bounded SVN local-status XML structural validation, and Hello Panel mock model callback/rollback tests. New changes require CI; these are not native host acceptance or complete XML validation. Current approved-path policy and persistent recovery remain separate gates.

Candidate tests: relative/traversal PATH rejection, approval refusing compatibility and unsupported tools, malformed identity output, real linked Git worktree. No new dependency/workflow; current CI required. Host integration remains deferred.

CLI/worktree candidate efdc821 passed full CI 45516706043. New panel tests cover superseded selection, stale failure, cancellation and stop, owned text buffers and zero/unknown distinction; real Git fixture exercises controller/model generation. All new tests pending current CI. Mock controller/model is not actual Pulse host acceptance.

Panel baseline 440a360 passed full CI 45518972152 after the clock shadowing fix. New candidate tests cover task cancellation versus terminal, retryable release failure, invalid ID/snapshot, inline dispatch and STATE, host task publication after terminal release, cancellation before work and mismatched workspace. Mock callbacks run synchronously in tests; cross-thread delivery, actual host task ordering and cancellation latency require host acceptance. No new dependencies, no private host interfaces.

Host controller/model candidate tests: three navigation requests coalesce, completed obsolete output is discarded, failed admission retries only on explicit event, failed refresh retains stale data, failed cancel/release keeps ownership, stop suppresses publication, and fixed interactive commands route through the mock task bridge. New CI required; actual host callbacks and automatic completion remain separate acceptance gates.

SDK task bridge 914d780 passed full CI 45519919502. New Binding mock tests exercise the actual SDK function pointer signatures, fixed command subscription, wrong panel ID, refresh/result update, partial registration rollback, missing callbacks and model update failure while a task is active. Tests remain pending new CI. Actual host owner scheduling, context resolution, automatic delivery and unload remain gates.

Context navigation candidate adds mailbox tests for borrowed-string lifetime, coalescing, duplicate suppression, loading/overlong/NUL rejection, stale tickets across navigation and reopen, failed unsubscribe, and invalid successful subscription ID. VCS mock host exercises public context get/subscribe/unsubscribe plus panel/task callbacks, stale resolution and render-before-pump invalidation, and retryable teardown. New CI required; no local Zig run or real-host validation recorded.

Worker resolver candidate: tests cover release failure before handoff, A/B/C navigation coalescing, denied policy, cancelled queued work, stop/drain, lexical local path gating and rejection of a policy result outside the detected candidate root. Previous final code commit b10ecd2 passed full CI 45521721561; c968aab passed documentation-only gate 45521753364. This combined code/docs revision requires new platform CI; real-host and real approval policy remain NOT VERIFIED.

The combined candidate also covers the visible discovery/cancel state and explicit refresh after permission denial, requiring a new policy decision before the next summary.

Wake candidate adds mock tests for inline-before-post-return, coalescing, queue rejection, successful zero token, failed cancellation, late delivery after stop, navigation-to-resolver-to-summary dispatch, premature worker-return delivery, and explicit owner fallback. The latest resolver revision a143792 was separately submitted; its platform CI must be checked independently. This combined revision requires its own full CI. Mock callback delivery does not certify actual host scheduling or unloading.

Ordinary Git approval tests cover grant path rejection, incomplete/changed evidence, revocation, exact command and cwd admission, unrelated navigation, worktree marker refusal and metadata matching. Fake evidence is not real approval or positive approved-tool execution. Resolver revision a143792 passed both platform jobs and regression gate in CI 45522520423. This candidate needs independent platform CI.

Additional tests cover Windows reported separator normalization (not case or other aliases) and the actual Execution gate rejecting a request before Runner spawn/accounting.

Windows evidence tests cover the restricted config grammar, composition without upgrading flags, and actual Win32 identity observation on the current local directory (Windows only). The test does not certify reparse/ACL attack fixtures or real approved Git execution. Dispatch revision f040ea1 passed full CI 45523125690. This candidate requires independent platform CI.

Additional Windows-only fixture checks actual config handle reads and changed content, distinguishes missing from existing marker, and rejects both names of a hard-linked regular file. Junction/reparse and ACL attack fixtures remain pending.

ACL candidate tests cover pure basic ACL grammar, untrusted write/delete/ownership grants, unknown ACEs, invalid SID/ACE size, explicit owner and changed permission fingerprints, plus real Windows process-token SID ownership and exact system-config isolation variable. No real DACL fixture or effective-access proof yet. Latest previous platform CI must be independently confirmed before release.

Git isolation tests cover exact environment values and rejection of arbitrary global config paths and injected config count. The real Windows DACL fixture modifies only a private test file, using native security APIs, and checks that a trusted owner/user with an Everyone read ACE passes while an added Everyone write ACE fails. The final ACL candidate 0a19791 passed full CI 45524845597 and Windows evidence ad59679 passed 45524373830. This revision still requires its own platform CI and real Git isolation launch evidence.

Runner admission regression additionally verifies mandatory isolation controls and reset on executable reconfiguration without spawning a child. The temporary DACL fixture restores the restrictive ACL on failure as well as on success.

Positive approved Git integration candidate: the CI-provided Git executable is explicitly hashed and a private ordinary repository plus separate empty-config neutral directory are created. The test exercises the actual Policy resolver, version, identity, status, Runner and Windows Job Object where applicable; altered global config, changed verifier evidence and revocation must reject further commands. It deliberately uses an explicit fixture verifier, NOT production installation/ACL certification. Windows native dependency-handle digest test covers content change and total-byte quota; manifest tests cover root and executable matching. Prior isolation candidate 0c924ee passed full CI 45526013867. New revision needs independent CI.

Native lifecycle candidate regression checks locked Binding selection/command denial, navigation, failed close retention and retry, invalid/missing host interface and repeat failed activation. The independent Windows C loader also loads pulse_vcs_panel.dll for 16 missing-interface rejection cycles. It does not exercise the actual Pulse host. Prior real Git fixture revision fc3c8a8 passed full CI 45527308082. Candidate requires its own CI.

C ABI locked candidate test now runs 16 full successful model/context attachment cycles against a public-header mock, including partial activation rollback, repeated activation, forbidden commands, navigation, check repaint, close refusal/retry, user-close and host-first interface invalidation before deactivate/destroy. The mock checks no tasks were created/queried/cancelled/released and all panels/callbacks are gone. This is actual DLL execution but not the installed Pulse host. Prior native candidate platform jobs passed; verify this revision independently.

New regressions cover failed ordinary cancel with pending wake, documented host-final retirement without SDK release calls, unpublished summary discard, permanent stop and two-step grant review drift/incomplete evidence. Prior native candidate 682eaca passed full CI 45528486318; lifecycle C-loader revision 1e23264 passed Ubuntu and Windows was still running at review time. This revision requires its own CI; real-host execution intentionally deferred.

Regression candidate includes versioned review encoding/decoding and staging tool failure paths. Native reviewed session integrates explicit provisioning, revocation and Runner drain. The default test build uses the locked source; positive product source/host lifecycle remain to be validated. See docs/vcs-acceptance-runbook.md.

New tests cover strict stored-record parsing, restricted Git index/name rejection and approval CLI payload/error handling. Default DLL source now uses the actual Windows manager, while Zig unit tests of the entry explicitly import the locked source. The C loader assumes a clean candidate slot on its disposable CI Windows user. The positive real-host and protected storage acceptance matrix is deferred. No real registry grant is written by unit tests.

Additional tests exercise ancestor-only create rights, target write rejection, inherit-only versus inherited ACEs, and DPAPI round-trip/tamper refusal without modifying the registry. The package remains an isolated acceptance candidate.
**No packaging in CI.** Neither workflow produces or uploads a package. Release
candidates are packaged locally with the pinned official author tool through
scripts/package_release.py (native-manifest, pack, verify, evidence) as described
in [release](release.md#packaging-local-official-tool). CI only builds and tests;
a green run is not package, signature or real-host evidence.

P2A follow-up: Windows VCS/full lanes provision pinned SlikSVN 1.14.5 and
require the real local working-copy fixture, in addition to Git/JJ. The
vendor archive is verified using the independently recorded digest in
scripts/ci_vcs.py; administrative extraction is confined to ephemeral CI.
Native settings fixtures exercise optimistic version conflicts, exact path
precedence, stale picker completion, draft preservation and render failure.
Installed Pulse acceptance is still separate. No production SDK or CLI is
bundled by this fixture.

Windows SVN provisioning correction: run 45848217684 failed before the tests
because the vendor download returned HTTP 403. The versioned Chocolatey
package contains the vendor ZIP; extract that exact member, verify the
published inner SHA-256 (corrected transcription), and execute only the
verified vendor MSI's administrative extraction. Never run the community
install script. The new mandatory Windows lane remains unverified until
its actual result; Ubuntu and Companion lanes passed the earlier run.

Four-provider baseline full CI passed 6f29edf / 45935843006. Hg Windows
CI uses a private adjacent Python runtime and mandatory isolated preflight;
native approved version/status test remains mandatory. Consolidated
candidate extends approved Windows fixture coverage to actual local history/
content/diff and preserves the negative admission/config/path checks.
No tests have been removed or converted to optional. Exact candidate CI
and installed Pulse acceptance are separate gates.

## Native fixed-stack inventory

The existing Windows lanes run `python scripts/stack_audit.py zig-out/bin --output zig-out/stack-audit.json --baseline scripts/stack-baseline.json` on the already built ReleaseSafe images; the bundled Companion lane also inventories its actual DLL/helper directory. JSON reports are retained even if a later check fails. No separate workflow or rebuild is needed. The tool rejects malformed supported PE metadata and fixed frames above 128 KiB at exported entry points. Internal frames above 16 KiB are reviewed; above 64 KiB are highlighted. A reviewed baseline can record the descending list of all fixed frames above 128 KiB per image; the gate then rejects added/worsened ranked frames. The first measured baseline is recorded from run 46141666396 (d69eb98) for unchanged native images in the normal and bundled profiles. Companion DLL baseline is recorded separately from the subsequent green run 46142783886 (ceacae8) for both normal and bundled profiles, before the stack reduction changes. This inventory includes existing large frames, not a certification that those functions are safe; resolve their RVA to symbols and assess reachability before remediation. Image-level rank is not function identity; inspect the RVA/export and source when reviewing changes. Go LAN and Rust CPace helpers are explicitly out of this native Zig/C inventory. Dynamic frames, functions without unwind entries, nested calls and worker-specific stack reservation are not measured by this tool. The VCS and Companion C fixtures exercise their existing lifecycle scenarios on 512 KiB owner threads without repeating the tests. A green inventory is not proof that all callbacks or actual Pulse host paths fit.

The first stack inventory found repeated large fixed frames across several images (roughly 512 KiB and 464 KiB). Similar sizes alone do not establish their source or execution path. Preserve the low-stack tests and prioritize symbolized host-callback call chains before moving unrelated worker buffers. The measured baseline prevents ranked regressions; it does not authorize historical frames on the host stack.

### Stack reduction and symbol diagnostics

The owner scratch and live-prefix changes retain the existing tests for stale
VCS results, failed release, cache revocation, Companion label reorder/shrink,
large instance counts and Share desktop operations. No new build or full job is
introduced. Compare measured frames against the existing baseline; do not raise
it to accommodate an implementation regression. The native audit enriches RVA
records using the runner's local llvm-symbolizer with matching image debug
information (PDB/DWARF). It reports symbolizer availability and unresolved frames
explicitly; these never waive the unwind gate. Reports use the exact compiled
image and record its SHA-256 rather than using a rebuilt approximation. A resolved symbol is not proof of
reachability from a host callback. No debug server or download is configured.
