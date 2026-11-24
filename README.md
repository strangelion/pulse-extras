# Pulse Extras

Modular native extensions for [Pulse File Manager](https://github.com/jimmgreen/pulse).

面向 Pulse 文件管理器的独立社区增强包集合。以 Rust 为主要语言，重视内存安全、可重复构建、回归测试及宿主稳定性。

## Development status / 开发状态

Experimental bootstrap. The Rust ABI probe is not a production extension. Windows host loading, packaging, signing and UI acceptance remain unverified.

| Extension | Scope | Status |
| --- | --- | --- |
| VCS | Git / Jujutsu advanced management | Planned |
| Convert | File format conversion | Planned |
| Inspect | Binary and package inspection | Planned |
| Data | Database and scientific data preview | Planned |
| DevKit | Project and toolchain management | Planned |
| Compare | Recursive directory comparison | Planned |

## Development

Rust 1.85.1, initially targeting `x86_64-pc-windows-msvc`. No third-party Rust dependencies in the ABI probe.

```powershell
cargo test --workspace --locked
cargo fmt --all -- --check
cargo clippy --workspace --all-targets --locked -- -D warnings
cargo build -p pulse-abi-probe --release --target x86_64-pc-windows-msvc --locked
```

- [Architecture](docs/architecture.md)
- [Roadmap](docs/roadmap.md)
- [Upstream SDK pin](sdk/upstream.toml)
- [Official extension registry](https://github.com/jimmgreen/pulse-extensions)

This repository is independent of the official Pulse project. Apache-2.0; third-party dependencies retain their respective licenses.
