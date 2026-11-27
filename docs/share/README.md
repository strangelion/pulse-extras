# Pulse Share — development plan

Status: P0 foundation only. This branch does not yet provide network file
sharing. Do not publish or add a release.toml until the actual transport,
pairing, staging and host acceptance gates pass.

## Scope and architecture

Windows x64, native Zig Pulse UI, isolated worker process for networking and
file transfer. Both computers run the same extension. Start with explicit
two-way file sending and receiving over LAN (IPv4 and IPv6). Add directory
sharing later; do not turn this into a filesystem mount until a supported SDK
contract exists. Public Pulse Preview 3 supports UNC enumeration but not
controlled UNC transfer; do not claim that fileops can transfer over UNC.

The DLL must only own UI and bounded IPC state. Worker launch/identity,
same-user authenticated IPC, process lifetime and cleanup must be reviewed
before running network code. A worker failure must not crash Pulse.
Use a reviewed TLS implementation with authenticated device identities,
explicit first-pair confirmation and revocation. Discovery is an untrusted
hint, not an authorization decision. No automatic firewall rules, public
listeners, UPnP, external relay or unrestricted drive exposure.

## Stages

- P0 (this commit): development manifest, native menu and read-only status UI;
  bounded single-file receive state, approval, ordered chunks, streaming
  SHA-256, terminal verification and commit receipt. Tests exercise the
  abstract contract only. No real files are opened or transferred.
- P1: worker executable and supervised lifetime; authenticated local IPC;
  isolated local staging, no-overwrite commit, cleanup and failure reporting.
  Build/launch test fixtures and mock host callbacks before LAN use.
- P2: TLS transport, explicit pairing, IPv4/IPv6 discovery, user-confirmed
  file offers and live two-PC acceptance. Discovery is opt-in. Keep identity
  private keys separate from release signing keys.
- P3: directory manifests, relative path validation, bounded queues, per-file
  receipt, cancellation and resume. Verify actual opened source/destination
  identities; reject reparse points and unsupported entries. Never overwrite
  silently, execute received files or accept remote arbitrary paths.
- P4: opt-in shared directory browsing, read-only by default, per-peer grants,
  quotas, revocation, optional upload with explicit confirmation.
- P5: release registration, reproducible worker digest binding, signed
  preview, real-host acceptance and stable promotion. Reuse existing release
  input and Environments. No production signing secret in branch CI.

The receive state is not a protocol or a durable transaction journal.
The worker must report chunks only after successful private staging writes,
verify final size and digest, then perform a no-overwrite filesystem commit.
Cancellation/commit must be serialized by the worker. A failed commit is a
failure, not success. Empty files are valid. The 1 TiB file and 256 KiB chunk
limits are provisional testable defaults, not performance guarantees.

## Build/test

From repository root:

    zig build test-share --summary all
    zig build share-dev -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe

The explicit dev target produces pulse_share.dll. It is not installed by
the default build and the development manifest is not a release descriptor.
Use the pinned official author tools to package it for isolated host testing.
Open "Pulse Share / 文件共享" from the command menu. The panel explicitly says
network functionality is unavailable. No sockets, discovery, file writes,
or production key are used by this stage.

Before moving to P1: confirm Windows and Linux unit regression, cross-build
the DLL, test entry/activation/open/close/disable and multiple host windows.
Real-host acceptance remains outstanding.
