# Architecture / 架构

## Language decision

Rust-first: Cargo workspace, stable Rust, Windows MSVC target. The public Pulse boundary is C ABI; C++20 is the official convenience layer, not a Rust compatibility guarantee. The official documentation describes C++ authoring, so direct Rust loading and registry acceptance require validation. Do not link private Pulse libraries. If Rust DLL acceptance fails, use a minimal official C++ adapter with a Rust worker. Go is optional for independent service executables; do not embed the Go runtime into the unloadable host DLL without separate validation.

## Boundaries

- `crates/pulse-abi`: minimal raw ABI declarations; grow only against pinned public headers. Later generate/check bindings with a C layout probe. No safe wrapper may expose borrowed host memory beyond its callback.
- `extensions/abi-probe`: no-op load/activate/deactivate/destroy experiment; no production package.
- Future shared crates: safe host adapter, cancellation and bounded IPC, process execution, diagnostics and filesystem plans. Create these only when a real extension needs them.
- Future feature crates: independent VCS, Convert, Inspect, Data, DevKit and Compare.
- Complex parsing, external commands and heavy I/O should run out of process where practical. DLLs retain host-side UI and lifecycle ownership.

## Safety and regression

Host callbacks use the documented owning thread and borrowed data lifetime. No Rust panic, C++ exception or allocator ownership crosses the ABI. Keep unsafe blocks localized and reviewed; future callbacks that can panic must contain unwind and convert it to a status. A caught panic does not protect against UB, abort, access violation or OOM. Stop workers and drain callbacks before unload; never block the UI on unbounded I/O.

Use bounded input/output, memory, timeout and concurrency; cancellation is cooperative, not rollback. Treat files and subprocess output as untrusted. Never execute inspected binaries. Use typed argument arrays, not shell interpolation. Do not auto-download tools, upload user data, or write repository contents during passive browsing. For generated files use Pulse confirmation/staging where supported; operations outside that contract must remain disabled until an approved design exists. No secrets or signing private keys in the repository or logs.

## Regression gates

1. Format, Clippy and unit tests on every change.
2. Compare C and Rust sizes, alignment, offsets, calling convention and exported names on x64 MSVC; check each SDK revision.
3. Test missing interfaces, old preview, invalid lengths, cancellation, stale events, unload and repeated activation.
4. Test actual packaging, install, enable, restart, upgrade and rollback using isolated Windows profiles; inspect host logs and UI.
5. No compatibility or release claim until the relevant gate has evidence. The initial probe tests Rust-side behavior only.

## Distribution

Independent extension IDs under `strangelion.*`, with individually built/signed packages. Preserve Apache-2.0 for this repository, audit upstream SDK and dependency licensing separately. Pin upstream commit and Cargo.lock; only update through tested changes. Use the official registry for registration after real artifacts and publisher signatures exist.
