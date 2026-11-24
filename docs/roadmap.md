# Roadmap / 开发路线

## P0 — Rust compatibility (blocking)

- [ ] Verify Rust exports and the pinned public C ABI against C header layout on Windows x64.
- [ ] Build ABI probe DLL and validate with official package tools.
- [ ] Install and load in an isolated real Pulse host; test lifecycle and restart.
- [ ] Confirm Rust-built packages are acceptable to the official registry maintainer.
- [ ] Add a safe commands/context adapter with mock tests and host acceptance.
- [ ] Decide direct Rust DLL vs minimal C++ bridge based on evidence.

## P1 — Independent extensions

| ID | First deliverable | Explicit exclusions |
| --- | --- | --- |
| strangelion.vcs | Read-only Git/JJ repo summary, history and JJ operation log | No duplicate host Git badges; no automatic snapshots or writes |
| strangelion.convert | PNG/JPEG batch conversion to new files via staging | No in-place replacement or media encoder assumptions |
| strangelion.inspect | Read-only PE metadata and signature inspection | No execution or malware verdict |
| strangelion.data | SQLite schema and bounded NPY/NPZ metadata preview | No arbitrary SQL writes |
| strangelion.devkit | Project detection and toolchain inventory | No automatic install or build scripts |
| strangelion.compare | Recursive read-only content comparison and reports | No sync/deletion until safety review |

The current upstream Pulse source already implements Git status/pull/push, SVN status, native file-lock detection, text comparison, common preview formats and 7-Zip integration. The official registry lists archive and desktop enhancements. Recheck source, issues, SDK and registry before starting each module.

## P2 — Release

Introduce capability checks, bounded worker processes and fixture-based regression tests with each real feature. Release only after host acceptance and review of filesystem writes, dependencies, licenses, signing and distribution. Sign manifests with private keys kept outside Git. Submit registration metadata to a fork of jimmgreen/pulse-extensions, not extension source code.

## Evidence

The SDK pin and manually transcribed ABI bootstrap are initial inputs, not verified host results. Record CI runs, test logs and acceptance evidence as work progresses.
