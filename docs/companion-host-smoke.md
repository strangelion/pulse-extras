# Companion isolated real-host smoke test

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
