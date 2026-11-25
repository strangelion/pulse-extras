# Repository Agent Instructions

## Before changing code

- Read `README.md`, `docs/architecture.md`, and `docs/testing.md`.
- Read the feature document for the area being changed. For Companion, start
  with `docs/companion-manager.md` and `docs/shared-runtime.md`.
- Follow `docs/local-reference.md` for local SDK materials.

## Pulse Native SDK references

- The reproducible build baseline is pinned in `sdk/upstream.toml`. Do not
  silently replace it with a locally installed host SDK.
- If `.local/reference/pulse-sdk/1.0.61-preview3-20261124/sdk/native/` exists,
  read its `AGENTS.md`, `skills/pulse-plugin-author/SKILL.md`, relevant
  headers, and `api-catalog.json` before using Preview 3 host-only interfaces.
- Treat public C headers and API metadata as the contract. Verify file hashes
  against `native-sdk-manifest.json`; do not infer ABI layouts from examples.
- Keep local SDK bundles, harness binaries, host snapshots, profiles, and
  acceptance output under ignored `.local/`. Never commit or redistribute
  the unpublished local SDK bundle.
- Keep `.sdk-cache/` as the pinned public build-header cache. Do not mix it
  with the local reference bundle or `.local/host-sdk/` snapshots.

## Native API and compatibility rules

- Negotiate interface name, version, and table size. Optional host interfaces
  must degrade gracefully when unavailable.
- For manually maintained ABI adapters, record the exact header SHA-256 and
  assert x64 structure sizes/offsets. Add an independent C ABI fixture.
- Preserve old-host behavior when introducing newer interface versions.
- Respect UI-thread affinity and borrowed callback-data lifetimes. Copy any
  path or string retained beyond a callback. Never block the Pulse UI thread.
- Use the shared process/Job Object boundary for helpers and untrusted
  parsing; do not introduce shell execution or arbitrary executable lookup.
- Distinguish C ABI fixture coverage, headless helper tests, and real-host UI
  acceptance. Do not describe one as proof of another.

## Required checks

Use the repository's pinned Zig version and the applicable CI scope. For
Companion-only changes, use `zig build test-companion --summary all` instead
of unrelated real VCS integration tests; retain the applicable native ABI and
Windows lanes. For shared changes and release candidates, run the full suite.
Always check formatting before pushing. Full baseline commands:

```powershell
zig fmt --check build.zig shared extensions
zig build test --summary all
zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe --summary all
```

For native host acceptance, use a fresh isolated extension store and profile
as documented in `docs/companion-host-smoke.md`. Never install experimental
native packages into the user's normal Pulse extension store during automated
tests. Record the exact host version, source revision, results, and evidence.
