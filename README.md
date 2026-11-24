# Pulse Extras

Independent modular native extensions for [Pulse File Manager](https://github.com/jimmgreen/pulse).

面向 Pulse 文件管理器的独立社区增强包集合，以 Zig 为主要语言，优先考虑轻量构建、C ABI 兼容、回归测试与宿主安全。

## Status

Pre-release. The ABI probe is a test package, not a production extension, but
its full native lifecycle is now verified on a real Pulse 1.0.61 host: installed
into an isolated store with the official tools, loaded, activated, deactivated,
unloaded, and its registered command dispatched from the host UI. See
[host compatibility](docs/host-compatibility.md) for the evidence and the
explicit non-claims. Registry acceptance and shipping extensions are still open.

| Extension | Scope | Status |
| --- | --- | --- |
| Hello Panel | Command + `pulse.context` panel, workspace and sidebar placement | Verified on Pulse 1.0.61 (2026-11-24) |
| VCS | Multi-VCS manager: Git / Jujutsu / Subversion first | Planned (design in [VCS architecture](docs/vcs-architecture.md)) |
| Convert | File conversion | Planned |
| Inspect | Binary and package inspection | Planned |
| Data | Database and scientific data preview | Planned |
| DevKit | Project and toolchain management | Planned |
| Compare | Recursive directory comparison | Planned |

## Build and test

Install [Zig 0.17.1](https://ziglang.org/download/). The initial probe has no external Zig package dependencies.

```powershell
zig version
zig fmt --check build.zig shared extensions
zig build test --summary all
zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe --summary all
```

The DLL is installed under zig-out/. CI also checks the pinned upstream headers,
regenerates the bindings with `zig translate-c` (`python
scripts/generate_bindings.py --check`), and exercises the Windows DLL through a C
loader harness. Python 3 is used only by CI and SDK verification tools.

- [Architecture](docs/architecture.md)
- [VCS architecture and capability matrix](docs/vcs-architecture.md)
- [Roadmap](docs/roadmap.md)
- [SDK pin](sdk/upstream.toml)
- [CI](https://github.com/strangelion/pulse-extras/actions)
- [Official extension registry](https://github.com/jimmgreen/pulse-extensions)

Independent community project, not affiliated with the official Pulse project. Apache-2.0.
