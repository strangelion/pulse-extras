# Roadmap / 开发路线

## P0 — Zig compatibility (blocking)

- [ ] Confirm CI format, native tests and x64 DLL builds.
- [ ] Confirm C loader tests using the exact pinned upstream header.
- [ ] Verify official package tooling and isolated real Pulse host load/unload.
- [ ] Confirm Zig-built packages are accepted by the registry maintainer.
- [ ] Establish public SDK binding generation/checking and safe commands/context wrappers.
- [ ] Measure build time, cache size and runtime memory baselines.

## P1 — Independent extensions

| ID | First deliverable | Explicit exclusions |
| --- | --- | --- |
| strangelion.vcs | Read-only Git/JJ summary, history and JJ operation log | No duplicate host Git badges or automatic snapshots/writes |
| strangelion.convert | PNG/JPEG batch conversion to new files via staging | No in-place replacement |
| strangelion.inspect | Read-only PE metadata and signature inspection | No execution or malware verdict |
| strangelion.data | SQLite schema and bounded NPY/NPZ metadata | No arbitrary SQL writes |
| strangelion.devkit | Project detection and toolchain inventory | No automatic install or build scripts |
| strangelion.compare | Recursive read-only content comparison | No sync/deletion until safety review |

Recheck upstream source, roadmap, SDK and registry for overlap before implementation. Pulse already has Git status/pull/push, SVN status, native lock detection, common previews and archive integration.

## P2 — Release

Add fixture-based regressions, bounded workers as needed, actual host acceptance, license and security review, signing and registry submission. No production release before relevant gates pass.
