# Companion isolated real-host smoke test

**Current safety gate:** see [Stage D](companion-manager.md#stage-d-official-testformal-packaging-and-real-host-acceptance). The following sections preserve historical smoke scenarios; their older read-only/feature-status statements are not a current acceptance report. The bundled development package now has writable paths. A fresh host store/profile does not isolate native LocalAppData roots. Use a dedicated disposable Windows test user/VM without production Companion data before any writable test or bundled launch. No production publication or signing is implied.

Status: experimental read-only library and host settings acceptance. This is
not a production package or a test of actual desktop-pet launch, import, or
editing. The native preference transaction passed its separate Windows test,
but the MSVC DLL does not yet link that writer.

## Prepare and launch on Windows

Use the repository's pinned Zig and the SDK author tool matching the actual
Pulse host. From the repository root, substitute actual absolute paths:

```powershell
python scripts/companion_host_smoke.py --pulse "C:\Path\To\pulse.exe" --sdk-root "C:\Path\To\PulseSdk" --out ".local\companion-smoke-01" --launch
```

For package-only preparation omit --launch. Each run requires a new output
directory; do not reuse an existing store/profile. The script captures the
actual host SDK, builds MSVC ReleaseSafe, generates a fresh manifest with the
official author tool, packs and verifies, then (only with explicit --launch)
installs/enables the unsigned development package in a fresh isolated store
and launches an isolated host profile. No GitHub release, signature, registry
submission, or production extension-store change. Review the native source
and binary provenance before choosing --launch.

The library reader still resolves the real Windows known-folder path,
%LOCALAPPDATA%\PulseExtras-Companion, independently of the host's isolated
test profile. This version only reads it. Do not create, delete, or edit
inventory files for the smoke test. A missing inventory is a valid outcome.
Only the extension's own download preference is persisted by the host.

## Manual acceptance

1. Open the extension entry Pulse Companion (Development), then the
   enhanced-package settings page. Check title and navigation.
2. Switch all four sections; library, running, market and global should
   remain responsive. Running and market must explicitly say unavailable,
   not invent counts. Check narrow window, light/dark themes and high DPI.
3. In library wait for automatic read and result collection; use search/refresh to retry. The manual check is fallback only. Missing
   inventory should show the missing message and zero rows; existing records
   should show their real IDs, not verified-artwork claims. Try a nonmatching
   query, favorites and pagination if the existing inventory permits.
4. In global settings wait for the asynchronous read. Increase or decrease
   concurrency by one, confirm the saved value only after the reply, and
   press reload. Verify the same value on reactivation in the same store;
   this setting does not change a live download scheduler yet.
5. Start a library read, switch away and disable the development extension
   while it is pending. Reenable/open it. No freeze, crash, or stale callback
   should occur. Exit the isolated host fully via its normal exit command.
6. Record host version, exact source revision, results (pass/fail/not
   applicable) and screenshots. Review the new directory's
   companion-lifecycle.log for entry, activate, worker start/end, terminal,
   deactivate, destroy, or explicit failure diagnostics. The script only
   records build evidence and never marks real host acceptance true.

Report a failed command with its numbered log and a UI failure with the
screenshot and lifecycle log. Do not send private inventory contents or
unrelated host profile files. No need to manually test 100 pets in this
read-only phase; the existing desktop stress harness remains separate.

## Optional standalone helper build evidence

Add `--prepare-helper wic` or `--prepare-helper libwebp` to the smoke
command to build a separate Windows GNU ReleaseSafe helper under the fresh
acceptance directory, at `helper-build/bin/pulse-pet-demo.exe`. For libwebp,
prepare the pinned cache first with `python scripts/install_pet_webp.py`.
The default read-only DLL build and package are unchanged. Evidence records
the relative fixed path, size, SHA-256, target and decoder choice, with
`runtime_approved: false`. Reject unexpected locations, aliases, hardlinks,
empty/oversize files and detectable changes during hashing. This is build
provenance, not a secure runtime pin or proof of installation ACLs. The
helper is neither added to the package nor launched, even with --launch;
that flag still launches only the isolated read-only host. Packaging support,
independent approval and a worker-owned native launch bridge remain required.

## Multi-file development package

The pinned Pulse SDK native-package contract supports repeated
`native-manifest --file` options for flat private DLLs and resources. Use
`--prepare-helper wic --bundle-runtime` (or libwebp after cache preparation)
to build the MSVC entry DLL, GNU Runtime DLL and GNU Helper EXE separately,
then stage the latter two next to the entry DLL. The libwebp variant also
includes its COPYING and PATENTS notices. No existing file is replaced.
Each additional member is capped at the official 64 MiB package-file limit;
the official author tool additionally verifies architecture, manifest and
archive limits. Verify the generated manifest binds the exact staged member
hashes, then run official pack and verify before optional isolated install.
Build evidence records the member list and archive SHA-256. The default
single-DLL smoke and standalone helper-only behavior remain available.
The package installation now has a supported distribution path, but the
entry DLL does not yet activate the Runtime Owner or spawn pets. The new
option does not claim production signing, live host acceptance or permission
to launch anything outside the explicitly isolated development host.

## First actual host runtime validation

For bundled packages, build the native runtime first, then pass its exact
SHA-256 to the MSVC entry DLL as a build option. The package manifest also
binds that same digest. No environment-provided executable approval or UI
path is used. Enter Running in the real host: a serialized host task resolves
the actual entry DLL location, validates the pinned companion runtime, opens
an empty group, and closes it again before returning. Existing task/timer
collection publishes explicit status; single-DLL packages report unavailable.
No persistent worker or child is launched yet. This tests the installed
package path and ABI in the host, without risking live children on unload.
The caller still relies on Pulse's verified immutable package installation;
independent ACL policy and actual real-host acceptance remain to verify.

## Preview 3 native image renderer acceptance (market)

Use a fresh isolated store/profile, never the normal Pulse installation's
extension store. Build and stage the runtime bundle using the existing
smoke command with --prepare-helper wic --bundle-runtime --launch (or the
pinned libwebp variant). Record the exact host executable version/digest,
SDK contract identity and package source SHA. Verify Zig 0.17.1 formatting
and required CI separately.

In the real settings page, open Market without searching. Click
"SDK 图片测试（不联网）". The expected image is a 24x24 PNG of four
colored squares (blue/green on top, purple/orange below) displayed using
contain with minimum height 64. Record whether the model is accepted AND
whether the image actually renders. If the host rejects the node, the
text-only model should return with the disabled diagnostic button; if
the host accepts but renders blank, record unsupported data URI rather
than success. Click close-test, navigate away/back and repeat. Test
disable/reenable and normal host exit. Confirm no unexpected network
requests, persistent preview files, stale image or crash. Record
screenshots plus companion-lifecycle.log (including update/fallback
failure if present). Older pinned-host rejection is an expected
compatibility outcome, not proof that the current host renders.

This fixture is deliberately generated locally and never uses market
artwork. After verifying supported source syntax, test actual selected
thumbnail only with a bounded transfer and isolated decode/re-encode
implementation. Do not classify live previews, cache or license
provenance as accepted based solely on this fixture. No real-host
result is recorded until someone runs the isolated test.

## Market image fallback and default browser acceptance

Use the existing bundled isolated-host workflow. On the market page:
1. Verify the text URL and browser button before performing any search.
2. Enable the offline SDK image diagnostic; if rejected, the text layout
   and browser button must remain usable, with no browser opening on its own.
3. Explicitly press "浏览器查看图库". Confirm the default browser opens
   https://openpets.dev/gallery, not a ZIP download, install protocol,
   search-engine page or local file. No pet should be installed.
4. Verify selection, filters and queued packages are unchanged after
   returning to Pulse. The browser action should be refused while another
   market/library task owns the host task slot.
5. On a separate test profile with no browser association or a restricted
   shell, confirm a visible failure and the manual URL. Do not change the
   user's actual default browser. Switch pages or deactivate during the
   task and verify safe worker collection. Browser remains open if launched.
6. Record host version, exact source revision and whether Windows accepted
   the browser handoff separately from whether the gallery actually loaded.
   This is a manual real-host check, not an automated CI result.

If the diagnostic is accepted but blank, click "图片不可见？本次回退文字显示".
Verify the node disappears, the diagnostic cannot be submitted again during
that activation, and no browser opens unless the gallery action is clicked.
When a task is pending without an automatic timer, use "手动检查任务状态"
on Market; it must collect the same owned task rather than spawn a duplicate.

## Stage C isolated-host acceptance

Use a fresh isolated bundled runtime store and profile. Keep automatic
startup off initially. Save 0:2:500:2000:10000;builtin:3:0, execute the
plan, verify first-frame acknowledgements and the inter-batch delay.
Cancel remaining launches before the last batch; existing children
remain alive. Use a missing managed ID to verify fail-closed admission.
Enable automatic only in the isolated profile, deactivate/reactivate,
and check one plan per activation, with no restart after a child exits.
Set an instance ID and hide/show it, then hide/show all ready children.
Verify actual windows and copied acknowledgement labels, lower hidden
CPU, and safe stop while hidden. Test configured grace/deadline and
confirm no unrelated process is terminated. Export a diagnostic and
verify numeric-only contents, no private paths or tokens, and no overwrite.
Repeat with missing dispatcher, constrained resources and while
deactivating. Record exact host version, source revision, logs and
screenshots; never count the ABI fixture as real desktop acceptance.

Verify the new policy editor: toggle auto-start, edit the four numeric
fields and two nonadjacent plan rows, save, reload and confirm canonical
values. Verify invalid intervals, duplicate IDs, a semicolon in one row,
and resource-limit violation cannot save. An older host without set_states
must retain the compatible text field. Change download concurrency while
editing the policy and verify it does not replace the unsaved draft.
For the pet right-click menu verify checked toggles, radio sizes/outfits
and grouped separators, then exercise keyboard dismissal, high contrast,
light/dark Windows settings, multiple monitor DPI and stop while open.
The native menu's actual appearance is not evidence of Pulse theme parity.

For the default-off minimize option, use an isolated host; ensure all
actual main windows are minimized, verify hide acknowledgements, restore
one main window, and verify only policy-hidden pets show. A manually hidden
pet must stay hidden; manually showing a pet while minimized overrides the
policy until the next restore/minimize cycle. Test multiple windows,
tray-only, disabled flag, unknown main-window class, and stopping while
hidden. Window observation is a pinned-source compatibility fallback, not
a guaranteed host SDK interface. Confirm Pulse's own login startup plus the
saved plugin activation plan separately; the plugin never writes OS startup
entries.

Enable retained diagnostic history explicitly on the isolated profile.
After a normal isolated session drain, export diagnostics and verify
history_write_status and retained_sessions. After 17 small fixture
sessions confirm only 16 records; aged rows disappear on the next append.
Test malformed and pending records in a fixture-only private root, with
no destructive recovery or user export cleanup. Full memory dumps and
visual Fluent theme parity remain unverified/unimplemented.
