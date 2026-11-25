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
3. In library click read, then check result after task completion. Missing
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
