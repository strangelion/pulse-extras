# Pulse Extras

Independent modular native extensions for [Pulse File Manager](https://github.com/jimmgreen/pulse).

面向 Pulse 文件管理器的独立社区增强包集合，以 Zig 为主要语言，优先考虑轻量构建、C ABI 兼容、回归测试与宿主安全。

## Status

Experimental bootstrap. The ABI probe is a no-op DLL, not a production extension. Real Pulse installation, packaging and registry acceptance are not yet verified.

| Extension | Scope | Status |
| --- | --- | --- |
| VCS | Git / Jujutsu advanced management | Planned |
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

The DLL is installed under zig-out/. CI also checks the pinned upstream C header and exercises the Windows DLL through a C loader harness. Python 3 is used only by CI and SDK verification tools.

- [Architecture](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
- [SDK pin](sdk/upstream.toml)
- [CI](https://github.com/strangelion/pulse-extras/actions)
- [Official extension registry](https://github.com/jimmgreen/pulse-extensions)

Independent community project, not affiliated with the official Pulse project. Apache-2.0.
