# Companion real-host test runbook

Status: D pending, no current real-host acceptance. The
[canonical acceptance register](companion-manager.md#d2-real-host-functional-acceptance-matrix)
and [Stage D plan](companion-manager.md#stage-d-official-testformal-packaging-and-real-host-acceptance)
own the status. Earlier smoke experiments are preserved in
[Git history](https://github.com/strangelion/pulse-extras/blob/78a33f1a54cabb6e880687023692a07aba44163c/docs/companion-host-smoke.md); older read-only statements are historical.

## 1. Obtain the test package

The existing Zig regression workflow accepts the manual input
companion_test_package=true. After the full required gate passes, the
Windows package job fetches the exact official v1.0.60 installer pinned
by size and SHA-256, checks out matching author tools at b324368, uses
the upstream /PULSETEST mode without optional startup/services, and
runs the existing package-only script with pinned static libwebp.
An explicit [test-package] commit marker on the experimental branch
also requests this job for full-scope changes. Ordinary pushes/PRs do
not package. On success download companion-dev-test-<source SHA> from
the Actions run's Artifacts (14 days): companion-dev.pulse-ext,
build-evidence.json and the official verification log. No release/tag
or signing. Do not install an artifact from a failed/incomplete run.

Check the exact downloaded archive SHA-256 against the Actions summary
and evidence. The package was verified against official Pulse 1.0.60,
not every host version. For another host version, use its matching
official author tool to verify the same archive before an explicitly
consented isolated install; record both host identities. The script's
strict --reuse-from mode requires the original matching host/catalog/
author-tool identity, so for another host use the official commands
below rather than weakening that evidence check.

## 2. Prepare isolated Windows environment

Use a disposable VM or dedicated Windows test user with no production
Companion inventory/dumps. A fresh Pulse --store and --profile do not
isolate native LocalAppData. Do not run writable cases in the regular
account. Record exact clean source SHA, pinned Zig, actual host/SDK and
backend. First require current full code CI, not a docs-only gate.

### Restricted-token, sandboxed and image-trust sessions

Two different environments produce the same stage failure. Both are
environment conditions, not product defects, and both must be confirmed
before treating a `PackageStagePendingCreateFailed` as a bug.

- **Path-filtered sandbox** (agent session, job object, container): writes
  outside the workspace are denied, so the Companion private root and the
  `pet-<id>.pending` staging directory under `%LocalAppData%` cannot be
  created. The workspace probe succeeds, the AppData probe fails.
- **Image-trust restriction** (some security suites, enterprise policies):
  the denial follows the process image, not the path. A locally built,
  unsigned helper is refused in every `%LocalAppData%` directory, including
  one just created by PowerShell with an inherited ACL, while the same
  helper writes the workspace normally; PowerShell and `cmd.exe` create
  files there without error. A probe that compares a PowerShell-created
  directory with a product-created one separates this case from an ACL
  defect: identical `Win32 5` in both means the policy is image-based.

Observed signature in both cases: `pending directory creation failed
(Win32 5)`. Since the diagnostics patch the host reports
`PackageStageAccessDenied` and the library status line asks the user to
allow the helper in the security software. Real-host acceptance requires a
normal user session on a machine whose policy allows the shipped,
signed helper, a dedicated Windows test user, or a VM.

If the artifact is available, local recompilation is unnecessary. In
the dedicated Windows test account/VM, with the matching official
author tool and actual host, use these example commands after checking
the package hash (replace paths and use a fresh store/profile):

```powershell
$pkg = "C:\Test\companion-dev.pulse-ext"
$pulse = "C:\Path\To\pulse.exe"
$author = "C:\Path\To\PulseSdk\tools\extensions\pulse_ext.py"
$store = "C:\Test\companion-store-01"
$profile = "C:\Test\companion-profile-01"
Get-FileHash -Algorithm SHA256 $pkg
python $author --pulse $pulse --json verify $pkg
# Continue only if hash and official verify succeed; native consent is explicit.
python $author --pulse $pulse --json install $pkg --store $store --allow-native
python $author --pulse $pulse --json enable strangelion.companion-dev --store $store --allow-native
python $author --pulse $pulse --json run --store $store --profile $profile
```

Alternatively, the existing official author-tool path supports local package-only preparation:

```powershell
python scripts/companion_host_smoke.py --pulse "C:\Path\To\pulse.exe" --sdk-root "C:\Path\To\PulseSdk" --out ".local\companion-d-test-01" --prepare-helper wic --bundle-runtime
```

For static WebP, run `python scripts/install_pet_webp.py` then choose
`--prepare-helper libwebp`. Match the intended formal backend; fresh output
directory required. The script builds ReleaseSafe, hashes runtime/helper
before entry build, stages declared members, invokes official manifest,
pack and verify, writes build-evidence.json and companion-dev.pulse-ext.
It does not install/sign/publish by default. Inspect package/manifest/member
hashes and source provenance before explicitly authorizing native execution.

## Reuse the exact test package

Copy the recorded package SHA-256 from the package-only build's
build-evidence.json or console output. In the same dedicated test
environment, with the same trusted host and official author tool:

```powershell
python scripts/companion_host_smoke.py --pulse "C:\Path\To\pulse.exe" --sdk-root "C:\Path\To\PulseSdk" --reuse-from ".local\companion-d-test-01" --expected-sha256 "<64 lowercase hex from evidence>" --out ".local\companion-d-run-01" --launch --confirm-isolated-user
```

The placeholder must be replaced with the actual digest. Reuse requires
versioned clean bundled-build evidence, copies the fixed archive into
a new directory without replacement, checks its exact digest, invokes
official verify, and checks manifest/member identity before official
install/enable/run. It never recompiles or trusts file paths from evidence.
The host, catalog and author-tool hashes must match the build's evidence.
A separate fresh run can reuse the same artifact. The acknowledgement
flag is not proof of OS isolation; use a dedicated test user/VM.
No production signing or publication. Omit --launch and the confirmation
for re-verification only. Combined build/launch remains possible with
both flags but produces a new artifact. Use the actual tested SHA in
every acceptance record. D1 has not yet been executed with a real host.

## 3. Execute D cases

Use the manager's D2/D3 matrices. Start with a single built-in pet, then
permitted test assets, small mixed sessions and only then bounded stress.

| Case | Expected observation |
| --- | --- |
| Install/enable/open | Correct dev ID, settings entry and four sections; missing/unapproved runtime rejected. |
| Native UI | Light/dark, narrow/scroll, high DPI, keyboard navigation, popup and menu cancellation. |
| Library | Verified import, duplicate/cancel, profiles, search, quarantine/restore and explicit cleanup only of owned test assets. |
| Market | User-triggered search/filter/detail and parallel queue; cancel/failure/offline; no install without consent. |
| IMAGE diagnostic | Four colored squares (blue/green, purple/orange) render; acceptance without pixels is NOT a pass. Reject/blank fallback restores text; browser handoff only on explicit click. |
| Runtime | First-frame ACK, batched plan and cancellation, targeted/all stop, actual hide/show; compare manual overrides with minimize/restore. |
| Host/system | Multi-window/tray, Pulse-owned login activation, menu themes/DPI. No private Fluent API. |
| Persistence/lifecycle | Save and reload; switch pages, disable while task pending, re-enable, stop when hidden/menu open, host exit; no stale callbacks/jobs. |
| Diagnostics | Numeric report, opt-in history, controlled synthetic fixture crash capture and rotation; no production fault injection or sharing raw dumps. |
| Upgrade/rollback/uninstall | Two development revisions with official consent; preserved data, proper deactivation and no orphan processes. |

On actual Windows, run independent visible and actual Pulse-managed
high-count tests separately. Record first-frame/shutdown latency,
frame-time percentiles, CPU, memory, handles, threads/GDI/USER objects,
disk usage, leak trends; separate host/renderer/watcher measurements.
Follow safe escalation and stop conditions from D3; do not force 100 if
the system rejects admission. See [performance](performance.md) for the
historical hidden baseline. Keep heavy soak and visual checks off
routine CI.

## 4. Evidence and recovery

Record one result per case (PASS / FAIL / NOT RUN / UNSUPPORTED),
expected vs observed, exact source/manifest/package hashes, Pulse/Windows
version, SDK, decoder, hardware, logs and screenshots as needed.
Use a fresh output for each new build, preserve failed evidence, review
redacted logs only; raw memory dumps/private paths/tokens remain local.
Check no production directories were modified and owned children drained
before deleting only explicitly approved disposable test data.

Rebuild and rerun affected cases after fixes; current full regression must
pass before the formal candidate is generated. The official author tool
verifying a package or returning a PID is not real-host acceptance.
Formal signing/release follows [release.md](release.md), separately
authorized. Do not add new test-only runtime UI or package modes merely
to pass manual acceptance.

### Activation failure triage

An enabled package in the palette is not a loaded/active DLL. Before a
fresh isolated run set ABI_PROBE_LOG to a new absolute log file in the
local acceptance directory. Click Open; inspect companion-entry,
companion-settings-create, companion-settings-query-model,
companion-commands-subscribed and companion-activate. If activation fails,
the error name and raw stage status identify the rejected SDK operation.
The GUI process stdout file may be empty; failed activation normally calls
deactivate/destroy and unloads the module. Rebuild a new verified test
package after a code fix, retain the previous revision and do not reuse
its old hash as the fixed package. Actual UI acceptance is still required.

Market default browse: enter Market with no running desktop-pet session;
expect a single automatic read-only curated directory load, then results
without typing a query. Re-enter after switching pages: no redundant
automatic request. Search/filter/clear, offline cache and cancel are
separate cases; verify failure does not automatically retry or download an
asset. Record cache/network/parse stage, shard count and final outcome.

For market reentry and the Preparing caption use a fresh absolute
ABI_PROBE_LOG before launch. Capture companion-runtime-phase / ready,
companion-task-report-id / percent / status, companion-navigation,
companion-market-enter-task, market stage/shards and update-failed.
Status 0 means the report was accepted; UINT32_MAX percent means
indeterminate. Compare actual task status with the host popup caption.
Do not cancel a running session merely to dismiss its popup.

Persistent session popup: launch the runtime from Running. The finite
runtime-check task may appear briefly; starting/adding/stopping desktop
pets must not create a Pulse progress popup. Read readiness in the Running
page, stop one/all, restart, and disable/exit the host while pets run.
The extension-owned worker must be joined before deactivate returns;
confirm no child processes remain and no late callbacks run. Collect
companion-runtime-worker-start/end and phase/ready/terminal logs rather
than session task-step logs (finite market tasks still report steps).
