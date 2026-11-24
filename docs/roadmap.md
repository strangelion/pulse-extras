# Roadmap / 开发路线

## P0 — Zig compatibility (blocking)

- [x] Confirm CI format, native tests and x64 DLL builds.
- [x] Confirm C loader tests using the exact pinned upstream header.
- [x] Verify official package tooling and isolated real Pulse host load, activate,
      deactivate and unload (2026-11-24, Pulse 1.0.61; see `docs/host-compatibility.md`).
- [ ] Confirm Zig-built packages are accepted by the registry maintainer.
- [x] Establish public SDK binding generation/checking and safe commands wrappers
      (`scripts/generate_bindings.py`, `shared/pulse/{abi,host,commands,ui_model,ui_mount}.zig`).
- [ ] Measure build time, cache size and runtime memory baselines.

## P1 — Independent extensions

- [x] Build the minimal `strangelion.hello-panel` extension: command registration,
      `pulse.ui.model` panel and `pulse.ui.mount` workspace placement, verified end
      to end on the real host (2026-11-24, see `docs/host-compatibility.md`).
- [x] Add a `pulse.context` directory/selection panel and verify secondary-sidebar
      placement (`HELLO_PANEL_PLACEMENT=sidebar`, 2026-11-24).
- [ ] Verify light theme, non-100% DPI and panel resize behaviour.

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
