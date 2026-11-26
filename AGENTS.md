# Repository Agent Instructions

## Before changing code

- Read `README.md`, `docs/architecture.md`, and `docs/testing.md`.
- Read `docs/roadmap.md` and the feature document for the selected stage.
  For VCS, read `docs/vcs-architecture.md` and `docs/vcs-acceptance-runbook.md`;
  for Companion, start with `docs/companion-manager.md` and `docs/shared-runtime.md`.
- Follow `docs/local-reference.md` for local SDK materials.

## Stage-based delivery (mandatory)

- A request to continue means finish the earliest incomplete in-scope development
  stage defined in the roadmap, not just its first task. Check its full deliverable,
  exclusions, exit gate and existing evidence before touching code. The owner
  explicitly defers actual installed-host tests to one final acceptance round;
  green required code CI permits advancing, but never implies HOST PASS.
- Implement the complete usable vertical slice across UI, data/storage,
  provider/runtime, failure handling, tests and docs. Batch related fixes,
  review them together, run local format/build/targeted tests before pushing
  when available, then run the required regression on the final combined SHA.
  Multiple coherent commits or a stage branch are encouraged; do not make
  repetitive tiny partial changes followed by separate full CI runs.
- Do not stop after one small subtask if other mandatory work can proceed
  safely. Do not ask for routine approvals between subtasks or add placeholder
  UI/providers. Preserve working behavior and avoid broad unnecessary rewrites.
- If a toolchain/SDK/host/account/safety blocker prevents finishing, implement
  other independent stage requirements, state exact blockers and tests NOT RUN,
  and provide one consolidated acceptance request. Never mark a partial stage
  COMPLETE, use a docs-only green check as code evidence, or claim an ancestor's
  CI as proof of the final source.
- Current priority: VCS P2B → P3A → P3B. P2A code regression passed at 4d53927;
  final host acceptance is deferred. Companion ordinary feature development is
  owner-accepted complete; only 1024-instance measured capacity, long-run leak
  evidence and SDK 1.0.61 image-related review remain specific open work. Bundle
  install/lifecycle verification into final acceptance. Do not change working
  Companion code during unrelated VCS stages.
- Keep the roadmap current at stage boundaries, update the relevant acceptance
  matrix and capability claims, and report the whole stage outcome once.
  No publication or credential use without explicit authorization; writes
  and destructive/remote operations retain their separate gates. Stage
  completion does not require removing security constraints.

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
