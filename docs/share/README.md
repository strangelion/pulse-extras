# Pulse Share — development plan

Status: P1 local worker CI passed at 24b1ec7 (run 45995525015).
P2 is an experimental, opt-in LAN CLI with TLS 1.3, mutual ephemeral certificate
pinning, discovery and explicit receive confirmation. P2's new CI and physical
two-computer acceptance are outstanding. Pulse UI does not launch this tool.
Do not publish or add a release.toml until transport and host acceptance pass.

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
- P2 (CLI implementation, awaiting CI and physical acceptance): native Go
  executable, standard-library TLS 1.3, mutual certificate pinning with
  manual full-fingerprint comparison, explicit IPv4/IPv6 on-link bindings,
  opt-in multicast discovery, one approved file per session, SHA-256 and
  native P1 no-overwrite commit. Session private keys stay in memory and are
  entirely separate from release-signing keys. Persistent trust, Pulse UI
  lifecycle/IPC integration and physical two-PC acceptance remain open.
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
real-host lifecycle tests remain outstanding. P2's separate opt-in developer
CLI is described below. UI-driven network functionality and production
packaging remain disabled.


## P2 experimental LAN CLI

The native DLL and P1 staging remain Zig/C. For the network executable use
Go 1.27.4 (pinned CI toolchain), standard library only, CGO disabled. This
deliberately avoids implementing TLS from scratch or bundling a browser.
The Go module has no third-party dependencies. Optional DPAPI-protected persistent identity; no central service, account,
relay or automatic firewall changes.

Build from repository root with the existing pinned Zig and Go toolchains:

    zig build share-local -Doptimize=ReleaseSafe
    Push-Location shared/share/lan
    $env:GOTOOLCHAIN = 'local'
    $env:GOPROXY = 'off'
    $env:CGO_ENABLED = '0'
    go test -count=1 -timeout=90s -v ./...
    go build -trimpath -o ../../../zig-out/bin/pulse-share-lan.exe .
    Pop-Location

Both computers must be Windows x64 for the native receive commit. Choose
concrete IPs on the same subnet (RFC1918 IPv4, IPv6 ULA/link-local, or loopback
for tests); not wildcard or global public IPs. A link-local IPv6 address must
include its own local interface zone. Do not port-forward the listener.
The OS firewall may block inbound connections; do not weaken the firewall
or add broad allow rules. If multicast does not work on a multi-address
adapter or WLAN, use a numeric address. Discovery is strictly advisory.

On the receiving computer choose existing trusted private directories and
reviewed local binaries. Example (replace addresses and local paths):

    $bin = (Resolve-Path ./zig-out/bin).Path
    $sup = Join-Path $bin pulse-share-local.exe
    $worker = Join-Path $bin pulse-share-worker.exe
    $supHash = (Get-FileHash $sup -Algorithm SHA256).Hash.ToLowerInvariant()
    $workerHash = (Get-FileHash $worker -Algorithm SHA256).Hash.ToLowerInvariant()
    & "$bin/pulse-share-lan.exe" receive --bind 192.168.1.20 --port 45843 --directory C:\ShareTest\received --spool C:\ShareTest\private-spool --supervisor $sup --supervisor-sha256 $supHash --worker $worker --worker-sha256 $workerHash

Optionally append --advertise. On sender, use the actual receiver address
printed as LISTEN, or explicitly search:

    & ./zig-out/bin/pulse-share-lan.exe discover --bind 192.168.1.21
    & ./zig-out/bin/pulse-share-lan.exe send --bind 192.168.1.21 --peer 192.168.1.20:45843 --source C:\ShareTest\example.bin

Exchange the complete 64-hex FINGERPRINT displayed independently on each
computer via a trusted channel (e.g. compare screens in person). Enter the
other device's fingerprint, not your own. Do not trust fingerprints or
identities learned from a discovery announcement. Each invocation creates
a fresh in-memory ECDSA key and certificate. No trust-on-first-use, password or unauthenticated fallback; both peers must
match their explicit pin. Optional stored pairing is described below. On receiver review the escaped filename and size and enter
exactly yes to approve. Any other answer declines. Only one file is offered
per invocation. Reverse the sender/receiver roles for the other direction.

Protocol: TLS 1.3 with ALPN pulse-share/1; fixed-size bounded offer header,
UTF-8 Windows-compatible basename, length and SHA-256; explicit accept,
exact-length stream, sender-finished marker, native commit receipt. No
remote path, directory enumeration, remote command, executable launch of
received files, overwrite, or automatic reception. Sender and receiver
use at most 256 KiB explicit I/O buffer each plus standard TLS/runtime
buffers. LAN discovery advertises a fixed 8-byte magic/version/port at
most once per second on the selected interface; it carries no file or
identity data. Discovered endpoints are labelled UNVERIFIED and never
connected automatically. TCP sockets have bounded handshake/offer/transfer
deadlines; disk hashing, user prompts and Windows subprocess drain are
separate operations. A receiver is single-session, not an always-on server.

Receiver creates a unique spool directory and file under an explicitly
approved user-private parent. On Windows the parent ACL is inherited; the
Go spool does not establish or audit a separate protected ACL. Do not choose
a shared or untrusted parent. P1 performs the independent SHA-256, same-volume
owner-only staging and no-overwrite final rename. The locally approved
supervisor is hashed before invocation, but the Go CLI does not pin its image
handle through process creation. P1 independently pins its own worker.
Same-user hostile changes, malicious ancestor mutation, power failure and
forced parent termination are outside the current prototype's recovery
guarantee. Spool cleanup removes only its own known file and empty directory;
it is not a persistent recovery journal. If an acknowledgement is lost after
commit, the sender reports failure/uncertainty and must not assume rollback.

CI runs pure Go IPv4/IPv6 loopback tests for TLS, wrong peer pin, malformed
offers/discovery, user decline, digest mismatch and spool cleanup. Windows
also launches two actual CLI processes and P1 native supervisor/worker,
exercises both address families where available, verifies the destination
hash and no-overwrite behavior. Real multicast on a physical LAN, performance,
GUI integration, native process lifetime controller and two-computer testing
remain acceptance gates. Never treat a green loopback CI as LAN acceptance.


### Persistent devices (P2 opt-in)

Use a new existing absolute directory with a current-user-only ACL on each
Windows device. Never put the store in a shared directory, source repository,
cloud-synced public folder, or release signing location. The CLI does not
audit ancestor ACLs or defend against hostile same-user changes. DPAPI
encrypts/authenticates the identity blob in current-user scope. The device
certificate lasts 365 days; expired/corrupt identity fails closed, no automatic
replacement. Use a new store and pair again when replacing an identity.

    pulse-share-lan.exe identity-init --store C:\ShareTest\device
    pulse-share-lan.exe identity-show --store C:\ShareTest\device
    pulse-share-lan.exe peer-add --store C:\ShareTest\device --name laptop
    pulse-share-lan.exe peer-list --store C:\ShareTest\device
    pulse-share-lan.exe peer-revoke --store C:\ShareTest\device --name laptop

Compare the full fingerprint independently and explicitly confirm adding the
peer on both computers. No discovery response can create trust. Existing
identities and peer labels cannot be silently overwritten. Revoke requires
confirmation; then future sessions selecting that label fail. Revocation is
not retroactive to an already running transfer: stop that transfer explicitly.
For send/receive, append --store C:\ShareTest\device --paired laptop to
select the saved device. Without both flags the existing ephemeral pairing
remains available. Receiving still requires per-file confirmation. A saved
pin is not a grant to browse directories, write arbitrary paths, or receive
automatically. No private key is written as plaintext to disk.

The P1 helper now accepts a separate --confirm-verified-copy mode with the
network offer SHA-256. It checks the exact pinned source handle against that
digest before creating the final stage and keeps the source locked through
the copy. This closes the gap between network verification and native commit
without altering the original local-copy mode. Use only matching builds of
the LAN and P1 executables.

CI adds Windows DPAPI tamper/round-trip tests, peer record unit tests, original
network digest enforcement, and two saved-device transfers across fresh CLI
processes followed by revocation. Prompts time out after 90 seconds. Physical
LAN and host lifecycle acceptance remain outstanding.

## P2 native managed developer panel

The panel uses the V1 UI model `get_state` and host-owned tasks. It supports
one selected regular file, explicit local IP/peer address, existing saved peer
and store, explicit receive destination and private spool, plus discover,
send, receive, refresh and cancel. No automatic reception. The UI task reports discovery and per-file approval
through inherited pipes and includes identity creation and peer management. Closing a panel does not silently cancel its task; use the
cancel button or disable the extension. On re-open, refresh the retained task.

Build the three sibling executables first, then bind their exact SHA-256s
with `-Dshare-lan-sha256=... -Dshare-local-sha256=... -Dshare-worker-sha256=...`
when building `zig build share-dev`. Unconfigured builds remain inert.
For isolated native package testing put these three EXEs beside pulse_share.dll
and declare each as an official native resource file using the pinned author
tools. Never infer trust from PATH or a user-entered executable path.
The worker task checks all three digest-pinned regular local sibling files,
keeps their handles open through the child lifetime, launches the LAN process
suspended, assigns a private job (three process cap, 512 MiB total commit),
then resumes without a console. Only the cancellation event and local standard
input/output pipe ends are inherited.
Host cancellation signals it, allows a bounded grace period, and drains the
job. Forced termination or cancellation during P1 commit can leave a stage or
an already committed file; report uncertain, never promise rollback. Read-only recovery inspection is available; durable restart recovery,
physical two-PC and host lifecycle testing remain outstanding. This is not a production release.

### P2 managed panel follow-up

The development panel now uses bounded inherited input/output pipes rather than
a separate console. Refresh displays the current task message; approve or decline
only after reviewing the current generation of the prompt. Device identity,
peer listing/enrollment/revocation, explicit private-directory creation and
read-only recovery inspection are task commands. No silent acceptance. The
same `Store` field selects the explicit directory for private-init/recovery-list.
Full host and two-device acceptance are still required.

Byte progress is emitted at most four times per second plus start/end; the
host task reports completed/total bytes. The private-directory command creates
only a new current-user-only protected DACL directory, never modifies an
existing directory. Recovery inspection is intentionally read-only: names are
unverified hints and do not authorize deletion. Automatic restart cleanup of
P1 or network stages needs a separate durable ownership journal and remains
unimplemented. UI/host acceptance is still required.

The LAN process now sends P1 a private inherited cancellation event and allows
an eight-second graceful commit cleanup before forced termination. The outer
host job still drains the process tree; a lost receipt or forced interruption
remains an uncertain outcome. New CI tests cover exclusive private-directory
creation, non-destructive recovery inspection, progress and prompt generation.

The Windows CLI integration also starts a receive session with an inherited
cancellation event and verifies cancellation while awaiting pairing leaves
no destination or spool files. This is not an actual Pulse host UI test.

### Durable network phase records

Each accepted network receive creates a bounded `transaction.v1` record in its
unique spool directory before writing `payload.part`. Synchronized append-only
phase records distinguish `receiving`, `verified`, `committing`, and
`committed`. Read-only recovery lists the last valid phase, name, expected size
and digest; malformed or interrupted records are unknown. Ordinary exit removes
its own temporary objects. Abrupt exits may leave evidence. A committing or
committed record is not an instruction to retry: check the destination first.
Directory-entry durability on sudden power loss is not guaranteed. Recovery does
not delete or resume files automatically, and native P1 destination-side stages
still lack independent durable receipts. No ownership claim from a filename.

Managed tasks require an existing private store and spool with the protected
current-user-only ACL produced by `private-init`. Other policies are rejected
rather than modified. Use a new directory for each store and spool. CLI
sessions outside Pulse retain the documented operator-managed private-directory
prerequisite. This is not a defense against hostile same-user or administrator
changes or a race-free ancestor containment guarantee.

## Isolated P2 acceptance package

After the full branch regression succeeds, download `share-acceptance-inputs`
from the same Windows run, or build all three helpers locally with the pinned
toolchains. The artifact is not a signed release. With the matching branch
checked out and its pinned Zig installed, use the stage helper:

    python scripts/stage_share_test.py --pulse <Pulse.exe> --tool <official-pulse_ext.py> --binaries <helper-directory> --out .local/share-stage-1

It copies all three helper executables to a fresh workspace, binds their exact
SHA-256 values into a fresh DLL build, then uses the shared official staging
and archive verification path. `candidate.pulse-ext` and `build-evidence.json`
are outputs; `real_host_accepted` remains false. No install, signing or release
registration is performed. Use matching trusted helper inputs from a passed
run. The developer only chooses an existing trusted parent for the fresh output.
See [acceptance runbook](acceptance.md) for isolated profile and two-device tests.

Windows path admission checks each existing directory component for reparse
attributes, normalizes ordinary DOS aliases, verifies unchanged directory
identity and fixed local volume, then checks the exact protected DACL. The
2026-11-27 CI failure at `TestPrivateDirectoryExclusive` was a path-string
comparison rejection, not a TLS or DPAPI failure. Short-name normalization
is not proof of a reparse point. Tests cover ordinary paths and, where the
OS permits, 8.3 aliases and directory symlinks. Saved-peer loopback now also
uses inherited managed cancellation events and protected stores/spool in both
child processes, without claiming actual Pulse host acceptance.
