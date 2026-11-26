# Companion Manager / Pulse 桌宠管理器

**Current scope:** native Windows x64 Companion, experimental branch.
This is the current implementation/acceptance index, not a release claim.
For detailed design history, previous fixes, exact contracts and earlier
CI evidence, use the [immutable pre-consolidation document](https://github.com/strangelion/pulse-extras/blob/78a33f1a54cabb6e880687023692a07aba44163c/docs/companion-manager.md).
History remains in Git rather than repeating implementation logs here.
See [runtime and IPC](openpets-spike.md), [shared runtime](shared-runtime.md),
[host test instructions](companion-host-smoke.md), [CI](testing.md),
[performance evidence](performance.md) and [release rules](release.md).

## Current capability and boundary

| Area | Candidate implementation / remaining boundary |
| --- | --- |
| Native settings | Library, Running, Market, Global; public UI model, bounded native controls and async collection. Preview 3 IMAGE probe/fallback; actual rendering NOT VERIFIED. |
| Asset library | Classic V1/V2 data-only import, bounded validation, fingerprints, managed catalog, search/tags/favorites, profiles, quarantine/restore and explicit verified cleanup. External sources untouched; no arbitrary execution. |
| Market | Explicit official HTTPS search/filter/detail, base/full install, eight-item queue, bounded concurrency and verified staging; serialized catalog publication. Real network and cancellation/cleanup behavior need acceptance. |
| Runtime | Digest-pinned helper/runtime, independent Job Object per renderer, 1024 storage slots, configured count/commit budget, readiness ACK, bounded polling, stable session IDs, hide/show, per-instance/all stop. No arbitrary PID attach/kill or automatic restart. |
| Policy | Saved bounded startup plans, activation opt-in, host-owned login startup, minimize compatibility probe, manual visibility override, configurable batch/grace/deadline. Default off for automatic/minimize/history/dumps. |
| Diagnostics | Numeric-only export, opt-in PDH1 history, separate full-memory collector and experimental managed watcher/retention. Managed synthetic startup/capture/rotation regression passed at 6d63439; actual Pulse integration remains unverified. |
| Menu | Public Win32 radio/check semantics, mnemonic escaping and theme/DPI invalidation. Exact Pulse Fluent rendering unsupported by pinned public SDK. |
| Distribution | Existing dev manifest and official multi-file smoke packer. Test and formal acceptance pending; no formal release. |

No new speculative product features in D. Close blocking safety/correctness
defects, verify existing features, document unsupported SDK capabilities
instead of adding private hooks. The cross-add-on binary runtime remains
[deferred RT2+](shared-runtime.md#deferred-shared-binary-dependency-multi-add-on-coexistence).

## Safety and resource contracts

- UI thread publishes copied bounded model snapshots; serialized workers own
  native handles, catalog transactions and child lifecycle. No borrowed UI
  pointers across callbacks; cancel/drain before unload, retain ownership
  until confirmed exit. Unknown/failed/pending is not zero or ready.
- Pinned executable and package hashes, canonical paths, least inherited
  handles, private verified ACL/lease, isolated Job with kill-on-close and
  one process per Job. No unrelated process termination, broad inherited
  environment, arbitrary arguments or silent unmonitored fallback.
- Normal renderer: 128 MiB OS committed-memory reservation, 48 MiB tracked
  allocator quota; these are not working set or measured consumption.
  Defaults 8 instances / 1024 MiB group budget, actual limit depends on
  count, budget, 1024 storage slots and system headroom. With full dumps
  opted in, reserve 256 MiB per renderer/watcher pair, maximum four.
- Runtime policy: default `0:4:500:2000:10000`; 1–16 batch, 100–3000 ms
  interval, 0–5000 ms grace, total deadline at least grace+2000 and at most
  10000 ms; up to eight distinct asset plan entries. Optional flags:
  minimize, history, crash capture; older values remain readable.
  27 model states; native controls or legacy text fallback.
- History: 16 numeric rows / 30 days on append, corruption-checked PDH1
  (1192 bytes max). Managed dump candidate: 4 × 256 MiB completed dumps,
  one transaction slot, verified identity records and exclusive lock,
  30-day retention on capture, 30-second watchdog plus polling latency.
  Preserve ambiguous files; never delete user exports; default off.
  Full memory dumps may contain secrets and remain private. Never replace
  Pulse's own crash handler or capture host memory.
- Writable assets, cache, quarantine and history are under verified
  `%LOCALAPPDATA%\PulseExtras-Companion`; dumps under
  `%LOCALAPPDATA%\PulseExtras-Diagnostics`. Host store/profile separation
  alone does not isolate native data. Use a disposable test account/VM.
  No user-directory sweeps or destructive migration.

## C closeout — automatic regression passed

[Run 45671169009](https://github.com/strangelion/pulse-extras/actions/runs/45671169009)
on code commit 6d63439 passed all six jobs (scope, Windows/Linux checks,
Windows IPC/desktop and Regression gate). The managed watcher startup,
actual child readiness, full dump and four-slot retention tests passed,
along with standalone capture, bundled ABI, WebP and import tests.
This resolves the previously failing regression; actual Pulse UI and
real-host performance are still NOT VERIFIED. See Git history for the
canonical path and debugger suspension corrections.

## Stage D: official test/formal packaging and real-host acceptance

Status: D1 package preparation. C automatic regression passed at 6d63439;
require current full regression for every new candidate. Then prepare a
verified test package and perform actual Windows/Pulse acceptance before
a formal candidate. No production publication or shared binary work.

### D0: official package contract and two profiles

Authoritative references (recheck against the actual host/SDK at build):
[Native packages](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/docs/native-packages.md),
[SDK quickstart](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/docs/extensions-sdk-quickstart.md)
and [registry contribution guide](https://github.com/jimmgreen/pulse-extensions/blob/main/CONTRIBUTING.md).

Both profiles MUST use the official pulse_ext.py native-manifest, pack
and verify flow and native v2 .pulse-ext archive, not a custom ZIP format.
Use the pinned x64 MSVC entry ABI (PulsePluginEntryV1), GNU x64 helper
and runtime, and ReleaseSafe for representative testing. The manifest
template is restricted to official fields; no custom channel/version
fields in the closed native schema. Version/channel/source SHA live in
the release descriptor, archive name and evidence as appropriate.
The author tool generates manifest.json/package.json and binds exact
file bytes with SHA-256. Declare every private DLL, helper and notice
via repeated --file, flat ASCII filenames, no aliases or extra entries.
The pinned contract limits the manifest to 64 KiB, package metadata to
16 KiB, 64 MiB per payload file, 256 MiB total payload, 2–66 members,
and rejects ZIP64, encryption, traversal, links and duplicate names.
Recheck limits, official verify and native consent policy at packaging.
Signing covers exact manifest bytes; no regeneration after signing.

| Item | Test / local acceptance | Formal / production candidate |
| --- | --- | --- |
| Extension ID | Existing strangelion.companion-dev | Proposed strangelion.companion, validate with official tooling/registry |
| Display name | Pulse Companion (Development) | Pulse Companion |
| Build | ReleaseSafe, same feature and safety checks | ReleaseSafe; matching approved source/backend |
| Members | Entry DLL, matching runtime DLL and helper EXE, required notices | Same verified member set, no test fixture or probe logs |
| Version | Candidate/source SHA in evidence and archive filename | Independent committed SemVer, immutable published versions |
| Defaults | Auto-start/history/crash capture off, explicitly enable for tests | Same safe defaults |
| Signatures | Unsigned only with explicit isolated native consent; optional test key | Protected publisher signature, official verification and consent |
| Distribution | Local verified artifact or bounded CI artifact; no registry entry | Verified .pulse-ext + .sig.json + notices/source access per release.md |
| Installation | Dedicated test user/VM and isolated host store/profile | Normal user installation after acceptance and explicit authorization |

Do not rename a dev archive into a formal package, install one over the
other, or assume simultaneous same-process operation. The current
runtime owner/loader has process-local singleton and module-name
constraints. Use separate host processes and test accounts until
coexistence is proven. No production key, tag, registry submission,
or public release in the test path. Formal preview/stable channels
remain separate from local test identity.

### D1: reproducible test artifact and data isolation

Reuse scripts/companion_host_smoke.py, not a new packer. Build helper and
runtime first, record hashes, embed the two exact hashes into the entry
DLL, stage only fixed allowlisted files (including pinned libwebp
COPYING/PATENTS if selected), generate manifest, pack, verify, record
package and manifest/member hashes, exact source revision, toolchain,
SDK/host fingerprint and backend. Keep package-only as default, no
install/launch without explicit authorization. Preserve safety bounds.
Use clean source for acceptance; identify dirty builds as ineligible.
Do not package test fault executables, dumps, private keys, or user data.
D1 implementation candidate adds exact-artifact reuse with a required
expected SHA-256, official re-verification, manifest/entry/member evidence
binding and exclusive bounded copy. Clean build evidence records pinned Zig,
SDK pin, host/catalog and author-tool digests. Launch requires explicit
dedicated-test-user acknowledgement; this flag is not OS isolation.
Portable fixture tests passed with full regression at 6d63439. An explicit test-package request in the existing Zig regression workflow now prepares the pinned official v1.0.60 host/author tools after the full gate, runs the same script in package-only mode and uploads the verified archive and evidence. First package run remains to be verified; no host installation of Companion or real-host acceptance in CI.

IMPORTANT: isolated Pulse --store/--profile alone does NOT isolate
native data. The entry/runtime use real Windows LocalAppData
PulseExtras-Companion and the watcher uses PulseExtras-Diagnostics;
market storage is under the companion private root. First test in a
disposable Windows VM or dedicated Windows test user with no production
Companion data, plus a fresh isolated store/profile. Do not run writable
tests against ordinary existing inventory/dumps. No automatic root
deletion or migration. If same-user testing is needed later, implement
and test a distinct fixed trusted namespace throughout the entry DLL,
native bridge, helper, market/history/dump stores; no arbitrary path
from environment or UI. This isolation is not implemented by the
current dev manifest alone.

Existing package-only command, in the dedicated test environment:

~~~powershell
python scripts/companion_host_smoke.py --pulse "C:\Path\To\pulse.exe" --sdk-root "C:\Path\To\PulseSdk" --out ".local\companion-d-test-01" --prepare-helper wic --bundle-runtime
~~~

It generates companion-dev.pulse-ext and build-evidence.json. For the
pinned libwebp backend run scripts/install_pet_webp.py first and select
libwebp instead of wic; use the intended formal backend for acceptance.
For actual installation, prefer reusing the exact verified archive with
`--reuse-from`, `--expected-sha256`, a fresh `--out`,
`--launch --confirm-isolated-user`; see [runbook](companion-host-smoke.md).
Reuse requires the matching host/catalog/author-tool identity, not a
rebuild. A combined build/launch remains explicit. Successful host launch
or package verification alone does not prove acceptance.

### D2: real-host functional acceptance matrix

**Canonical D acceptance register** (statuses apply to the stated workload,
not to the latest unverified build). Update each row with source SHA,
artifact SHA where applicable, run/host evidence and date; never infer PASS
from implemented tests, a green docs gate or a historical benchmark.

| Acceptance item | Current status |
| --- | --- |
| Zig unit tests and formatting | Established; current full CI required |
| Windows native ABI tests | Established; not real Pulse acceptance |
| IPC communication regression | Established |
| 100 independent hidden processes | Historical PASS ([recorded data](performance.md#companion-paired-100-process-baseline)) |
| 100 independent visible pets | NOT VERIFIED |
| High-count instances managed by Pulse | NOT VERIFIED |
| Long-running stability and resource leaks | NOT VERIFIED |
| Crash injection and abnormal recovery | Standalone and managed synthetic fixtures passed at 6d63439; real-host abnormal recovery pending |
| Real market parallel downloads | NOT VERIFIED |
| SDK image rendering and fallback on actual host | NOT VERIFIED |
| Complete plugin install, upgrade, rollback and uninstall | NOT VERIFIED |
| Formal packaging and signing | Pending |
| Open-source licenses and asset authorization review | Pending |
| Formal Release publication | Not done; separate authorization required |

**Critical distinction:** 100 independent hidden renderer processes on
a historical hosted runner do NOT establish performance of 100 visible
pets, or of 100 instances supervised by one actual Pulse host. Independent
visible and host-managed high-count workloads are separate tests.

Record PASS/FAIL/NOT RUN/UNSUPPORTED with expected/observed behavior,
actual host and package hash, screenshots and redacted logs where useful.
Start with one built-in pet and then a small mixed asset session.

| Area | Required cases |
| --- | --- |
| Install and lifecycle | Official verify, clean install/enable, activate, settings navigation, disable/re-enable/reload, normal host exit; invalid/missing helper/runtime digest rejects startup. |
| Library | Empty test inventory, permitted synthetic/licensed assets, import/fingerprint, search, tags/favorites, profiles, cancel, duplicate, malformed asset, quarantine/restore and explicit cleanup confined to test fixtures. |
| Market | Explicit live HTTPS search/filter/detail, base/full install, queue, cancel, offline/timeout/invalid ZIP; actual image diagnostic and supported text fallback. No automatic installation. |
| Runtime | First-frame ACK, targeted stop, hide/show, manual vs policy hide, startup batches/cancel, persisted policy, actual pet windows. |
| Host/system | Minimize/restore, tray/multi-window, Pulse-owned login startup, native menu keyboard/high contrast/theme/DPI/multiple monitors. Exact Fluent remains unsupported by pinned public SDK; no private renderer. |
| Diagnostics | Numeric report without paths/tokens; opt-in history; complete dump/rotation with separately controlled synthetic fault fixtures only; disabled capture, forced stop, bounded storage and no orphan watchers. No deliberate crash injection into real Pulse/production helper. |
| Persistence | Save/reopen, exit/relaunch, disable during async work, stop when hidden/menu open, no stale callbacks, handles or jobs after confirmed unload. |
| Upgrade/rollback | Two test versions, supported official update and rollback flow with consent, verify settings/data compatibility and preserve failed evidence. |

### D3: real resource and stability measurements

Record Windows/Pulse versions, hardware, build/backend, baseline host
CPU/private bytes/working set/handles, renderer and watcher metrics
separately, visible/hidden CPU, first-frame and shutdown latency, disk
use and repeated lifecycle. Initial checks: 10 start/stop cycles, 30-minute and 2-hour visible/hidden
soak; increase normal pets from 1/2/4/8 through 16/32/64 toward 100 only
where measured headroom and responsiveness permit. Separately measure
independent visible pets and the actual Pulse-managed workload, with
frame-time p50/p95/p99 and GPU/VRAM where available. Record the last safe
count and explicit resource rejection if 100 cannot be reached; that is
not a 100-pet PASS. Crash-monitor pairs remain capped at four. Stop
escalation for sustained unresponsiveness, resource failure, leak trend
or unconfirmed cleanup. Do not launch 1024 real pets merely because
storage supports that many. Agree measured release ceilings from
evidence; do not invent universal performance thresholds.

### D4: repair and evidence

Full code CI/stress on exact candidate revision, real-host case report
tied to archive SHA, member/manifest hashes, SDK/host/toolchain,
fixture provenance and explicit gaps. After a code fix, rebuild and
reverify, rerun full CI and affected acceptance cases. Do not reuse an
earlier green run for changed code or silently treat a rebuilt archive
as the tested artifact. Keep private full memory dumps local; share
reviewed redacted evidence only. No skipped failures or deletion of
user-owned exports. Mark host acceptance NOT VERIFIED until exercised.

### D5: formal candidate, then separately authorized publication

After test acceptance, generate the formal ID manifest with official
tooling, independent version descriptor and exact file hashes. Verify
the exact formal artifact in an isolated environment, including
install/activation, update/rollback and uninstall. Recheck permissions,
source availability, notices and licenses, SDK/registry compatibility,
signature and artifact identity. Test-key signature verification precedes
protected production signing. Official registry requires verified
publisher fingerprint/public key, release asset URLs, package/signature
metadata and maintainer review; do not claim store availability from
a local install. No production signing, release tag, draft or public
publication without separate approval under release.md. Do not introduce
a parallel general release workflow before the shared R milestone.

Stage D exit: verified test artifact, green required CI, actual
functional/lifecycle acceptance, measured resource baseline, documented
nonblocking compatibility gaps, no unresolved blocking safety defects,
and separately verified formal candidate. Public publication is not
implied.

### D2 installed host activation defect

Actual Windows/Pulse acceptance: official install and native enable passed;
isolated host launched and listed the enabled package. Clicking Open logged
companion-entry, companion-activate-failed=1, companion-deactivate and
companion-destroy. The host unloaded the failed instance. Activation and
settings rendering remain FAIL until retested. Upstream pinned ui_tree.cpp
requires a nonempty accessible text label on every TextInput; initial
library search had only a placeholder, and the former fake ABI tests
explicitly expected no text. The fix routes all Companion text inputs
through one labeled constructor, checks recursive trees in Zig and C,
and logs raw settings-create/query status, subscription index on failure
and error name. This addresses a concrete upstream contract violation;
actual 1.0.61 activation still requires a successful rerun with a new package.

### D2 search field rendering follow-up

The user confirmed actual Pulse activation and displayed the initial library
page after the labeled-input fix. Search height was excessive and six
missing-glyph boxes appeared at the left. Pinned upstream
[src/ui/extension_tree_layout.cpp](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/src/ui/extension_tree_layout.cpp)
allocates surplus vertical space by child flex; the native
[control painter](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/src/ui/extension_tree_controls.cpp)
passes glyph strings to the text field as literal glyphs. Remove flex and
the unverified literal "search" glyph from all three search fields. Keep
text labels, placeholders, state keys and existing search/clear behavior.
Retest the three pages at actual host DPI/width; appearance remains
unverified after this correction. No custom renderer or new dependency.
The previous full CI (45724204710) failed compiling the added Zig label
assertion; Windows desktop and IPC passed. Correct the optional-slice
assertion, add layout checks, and force full scope on an explicit
experimental-branch test-package push so it can actually produce an artifact.

### D2 market and runtime task feedback

Real-host screenshot: single built-in child confirmed first frame, one
owned/ready, 32500 KiB working set, 16580 KiB private memory, 220 handles
(one sample, not stress acceptance). Search field now displays naturally.
Market request received 16384/62471 bytes; search completion not verified.
Market scans a validated index and all search shards sequentially. Display
validated shard count and current request separately; cap whole search at
180 seconds cooperative cancellation plus bounded blocking WinHTTP call,
retain verified cache, never publish a partial result. Distinguish request
timeout from explicit cancel and allow validated stale-cache fallback.
Report market phase and runtime starting/running/stopping via public
PulseTaskContext.report on the worker; persistent runtime task cannot be
completed until children drain. Host owns its popup; V1 has no public
programmatic dismiss/background API. User can choose Background continue;
never close arbitrary host windows or fake terminal success. Actual market
completion and new status rendering require retest.
