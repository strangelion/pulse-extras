# Pulse Share — development plan

Status: P1 local worker implementation; compilation and real Windows integration
are CI gates, not yet claimed passed. This branch does not provide network file
sharing. Do not publish or add a release.toml until transport, pairing and
host acceptance gates pass.

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
- P1 (implemented, awaiting CI and host acceptance): worker executable,
  supervised single-process job, inherited handle-only local IPC, owner-only
  same-directory staging, independent hash verification, no-overwrite commit
  and cleanup after worker failure. Explicit developer harness only; UI never
  starts a worker yet. No named endpoints or production signing keys.
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

## P1 local worker contract

    zig build share-local -Doptimize=ReleaseSafe

Explicit Windows x64 GNU target, produces pulse-share-worker.exe and
pulse-share-local.exe under zig-out/bin. The native developer harness owns the
file handles and creates a single-use process with a 64 MiB job commitment
limit and kill-on-close. The worker has no network listener or filename
request, receives exactly five explicitly inherited handles (read-only source,
stage read/write, request read, reply write, cancellation event) and one
fixed-size request. Handle inheritance is a local capability boundary for
this single-use process, not a sandbox against same-user or elevated code.
The digest-pinned absolute worker image stays open through launch. The parent
opens the worker suspended, assigns the job before resume, waits off the
Pulse UI thread and drains before reporting success. The worker uses the
Zig Receive state machine after each successful staged write; only the
parent publishes. Child output is a bounded fixed-size status/byte receipt.

Local use, only with explicitly chosen files and a disposable target:

    $worker = (Resolve-Path zig-out/bin/pulse-share-worker.exe).Path
    $digest = (Get-FileHash $worker -Algorithm SHA256).Hash.ToLowerInvariant()
    & ./zig-out/bin/pulse-share-local.exe --confirm-local-copy $worker $digest (Resolve-Path ./sample.bin).Path (Resolve-Path ./test-destination).Path received.bin

The target directory must already exist, be a local fixed drive, and use
canonical DOS paths. The parent opens a regular single-link source without
write/delete sharing, rejects unsupported entries and reparse points, hashes
the source, creates a unique same-directory owner-only staging file with
CREATE_NEW and sends the already-open file handles. Worker writes at most
256 KiB per chunk and verifies final size/hash. Parent independently hashes
the stage, rechecks directory and file path identities, and performs a
no-overwrite handle rename. A committed file keeps its owner-only ACL.
The parent never deletes the source or uses a peer-supplied absolute path.
No alternate data streams are copied; this is a normal data-file copy only.
Path/handle checks do not defend against a malicious same-user process or
hostile ancestor mutations. The user must choose a trusted local directory.
No UNC, removable media, automatic directory traversal or overwrites.

Ctrl+C requests cooperative cancellation between chunks, then the parent
drains the child job after a bounded grace period. The five-minute child
wait is a provisional local-harness deadline; disk I/O and parent pre/post
hashing are not globally deadline-bounded. Cancellation before commit
prevents publication; once the rename succeeds it is not rolled back.
Failures clean up the parent-owned staging handle; cleanup failures are
reported without deleting by pathname. A hard parent/power failure may
leave a unique .pulse-share-*.part file. Do not auto-delete by glob; persistent
ownership receipts and restart recovery are a later gate, before enabling UI
transfers. There is no promise of power-fail durability.

CI: full regression builds the DLL and local worker on Linux and Windows.
The local worker build and Windows integration run immediately after formatting,
before unrelated VCS dependency provisioning; failures still fail the full gate.
The harness emits bounded, fixed phase/result diagnostics on failure (no file
contents or peer data). Windows invokes real parent/child integration for multi-chunk Unicode files,
empty files, existing target, bad worker digest, worker exit, false success
with wrong bytes (including an existing destination), invalid names and
hard-linked source. The false-success fixture is built only for tests; the
parent's independent SHA-256 must reject its receipt. Manual cancellation,
deliberate disk-full and
real-host lifecycle tests remain outstanding. P2 must connect the DLL through
a reviewed lifecycle/IPC controller and complete actual two-PC acceptance;
no network functionality or production packaging is enabled here.
