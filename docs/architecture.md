# Architecture / 架构

Zig-first, fixed stable toolchain, Windows x64 MSVC ABI. No Cargo or C++ build pipeline in the active project. The official SDK exposes a C ABI but documents C++ authoring; Zig package and real host acceptance require evidence. Never link private Pulse internals.

## Boundaries

- shared/pulse/abi.zig: minimal extern structs and C function pointers checked against the pinned upstream C header. Extend only after reviewing public headers. Adopt generated translate-c bindings where they reduce drift; this initial probe is deliberately small and manually mirrored.
- extensions/abi-probe: no-op DLL with two required exports, allocation and lifecycle checks. No file, network or UI operations.
- Future shared runtime: safe host wrappers, explicit allocators, bounded IPC, process execution, diagnostics and file plans. Implement when a real extension needs them.
- Future independent extensions: VCS, Convert, Inspect, Data, DevKit, Compare. Heavy parsing, external commands and untrusted input should use isolated workers where practical.

## Safety

Use explicit allocation ownership, bounded resources, clear error unions and cleanup. Never free host-owned memory, retain borrowed callback data, or cross ABI with unwinding. Zig safety checks can still terminate a process; they are not a sandbox or a substitute for worker isolation. Use ReleaseSafe for production DLLs unless evidence supports another mode. No unbounded I/O on UI threads. Respect the owner thread and drain callbacks/workers before unload. Never execute inspected binaries or interpolate shell commands. Do not upload user data or change files during passive browsing. Generated user files must use supported Pulse confirmation/staging; unsupported mutations remain disabled pending design review.

## Regression gates

1. Pin toolchain and SDK revision; run format checks, unit tests and Windows DLL builds.
2. Check C and Zig sizes, alignment, offsets, exports and calling convention. Test actual DLL loading through a C harness.
3. Test allocation failure, cancellation, stale callbacks, unload and malformed inputs when relevant; use std.testing.allocator in owned logic.
4. Validate real Pulse install, enable, restart, upgrade and rollback in isolated profiles. A C harness is not real host acceptance.
5. Track cold/warm build time, cache and output size, runtime memory and UI responsiveness. Establish baselines before setting thresholds; no claims without measurements.

Use no private signing keys in Git or logs. Independent packages under strangelion.*; preserve Apache-2.0, audit third-party licenses, sign official manifest bytes, publish releases and submit catalog metadata to the upstream registry.
