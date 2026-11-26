# Pulse Extras

Independent modular native extensions for [Pulse File Manager](https://github.com/jimmgreen/pulse).

面向 Pulse 文件管理器的独立社区增强包集合，以 Zig 为主要语言，优先考虑轻量构建、C ABI 兼容、回归测试与宿主安全。

## Status

Unsigned previews of [Companion 1.0.0](https://github.com/strangelion/pulse-extras/releases/tag/companion/v1.0.0)
and [VCS 1.0.0](https://github.com/strangelion/pulse-extras/releases/tag/vcs/v1.0.0)
are available. The current main includes newer VCS candidates that are not in
those packages. Neither stable signing nor official registry acceptance is
claimed. The ABI Probe and Hello Panel have separate recorded real-host
evidence; see [host compatibility](docs/host-compatibility.md).
Current stage order, actual blockers and exit criteria are in the
[roadmap](docs/roadmap.md); see [VCS installed acceptance](docs/vcs-acceptance-runbook.md).

| Extension | Scope | Status |
| --- | --- | --- |
| Hello Panel | Command + `pulse.context` panel, workspace and sidebar placement | Verified on Pulse 1.0.61 (2026-11-24) |
| VCS | Multi-VCS manager: Git / Jujutsu / Subversion first | 1.0.0 unsigned preview; newer native tool setup, session trust and initial project/forge bookmarks are source candidates; daily-use acceptance pending ([architecture](docs/vcs-architecture.md), [roadmap](docs/roadmap.md)) |
| Convert | File conversion | Planned |
| Inspect | Binary and package inspection | Planned |
| Data | Database and scientific data preview | Planned |
| DevKit | Project and toolchain management | Planned |
| Compare | Recursive directory comparison | Planned |
| Companion | Optional lightweight desktop pets / OpenPets compatibility | 1.0.0 unsigned preview; basic import/download reported working after local packaged install; full host lifecycle, stress and resource acceptance pending ([manager](docs/companion-manager.md), [measurements](docs/performance.md)) |
| Forge | Reusable authoring components, bounded recipes and maintenance tooling | Design only; external Agents first, independent product conditional ([design](docs/forge-architecture.md)) |

## Build and test

Install [Zig 0.17.1](https://ziglang.org/download/). The initial probe has no external Zig package dependencies.

```powershell
zig version
zig fmt --check build.zig shared extensions
zig build test --summary all
zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe --summary all
```

The DLLs are installed under zig-out/. Full CI also checks the pinned upstream headers,
regenerates bindings with `zig translate-c` (`python scripts/generate_bindings.py --check`),
and exercises the Windows DLL through a C loader harness. Documentation-only changes
use a lightweight scope check; isolated VCS code changes run both-platform regression
and DLL builds. Isolated companion changes run companion tests and native Windows lanes;
allowlisted Companion host changes also retain production DLL builds and Windows
Companion C ABI tests without installing JJ or preparing SVN fixtures. Manual regression runs
and mixed/shared changes run full CI. The separate stress workflow is
manual independent-hidden only; visible/actual Pulse-managed testing
and release gates are tracked in [Companion D](docs/companion-manager.md#d2-real-host-functional-acceptance-matrix).
See [testing](docs/testing.md).
Python 3 is used only by CI and SDK verification tools.

- [Architecture](docs/architecture.md)
- [Product scope, reuse and dependency policy](docs/product-scope.md)
- [Shared Runtime: memory, lifecycle and resource safety](docs/shared-runtime.md)
- [Testing and CI coverage](docs/testing.md)
- [Extension capabilities and measured performance](docs/performance.md)
- [VCS architecture and capability matrix](docs/vcs-architecture.md)
- [Roadmap](docs/roadmap.md)
- [Forge authoring architecture](docs/forge-architecture.md)
- [Unified extension release design](docs/release.md)
- [SDK pin](sdk/upstream.toml)
- [Local SDK reference layout](docs/local-reference.md)
- [CI](https://github.com/strangelion/pulse-extras/actions)
- [Official extension registry](https://github.com/jimmgreen/pulse-extensions)

Independent community project, not affiliated with the official Pulse project.
Project license: [AGPL-3.0-only](LICENSE). Existing upstream/third-party notices and prior Apache-2.0 grants are preserved; see [license and dependency policy](docs/product-scope.md#4-license-and-distribution-policy).
