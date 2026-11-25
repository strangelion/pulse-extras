# Companion real-host test runbook

Status: D pending, no current real-host acceptance. The
[canonical acceptance register](companion-manager.md#d2-real-host-functional-acceptance-matrix)
and [Stage D plan](companion-manager.md#stage-d-official-testformal-packaging-and-real-host-acceptance)
own the status. Earlier smoke experiments are preserved in
[Git history](https://github.com/strangelion/pulse-extras/blob/78a33f1a54cabb6e880687023692a07aba44163c/docs/companion-host-smoke.md); older read-only statements are historical.

## 1. Prepare isolated Windows environment

Use a disposable VM or dedicated Windows test user with no production
Companion inventory/dumps. A fresh Pulse --store and --profile do not
isolate native LocalAppData. Do not run writable cases in the regular
account. Record exact clean source SHA, pinned Zig, actual host/SDK and
backend. First require current full code CI, not a docs-only gate.

The existing official author-tool path supports package-only preparation:

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

For the current combined build/launch flow, choose a different fresh
output and append `--launch`; this builds a new artifact, records it,
installs/enables the development ID with explicit native consent and runs
an isolated profile. Do not confuse it with reuse of the package-only
artifact. Exact-artifact verified reuse remains a D1 implementation task.
Use the verified tested archive SHA in every acceptance record. Official
tools and actual matching host are required; no invented package format.

## 2. Execute D cases

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

## 3. Evidence and recovery

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
