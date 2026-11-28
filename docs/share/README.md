# Pulse Share — development plan

Current status: the consolidated connection candidate at e0f8eca integrates
native dynamic pairing, pinned CPace helper, explicit routed connections and
hybrid TLS key exchange. Its CI and real two-device/host acceptance are still
required. See the [authoritative remaining roadmap](roadmap.md) for the three
remaining delivery stages and agreed requirements. No release registration
or stable release until acceptance passes.

The older P0–P5 descriptions and commands below preserve implementation
history. They are not separate remaining delivery stages. Where historical
status or CLI instructions conflict with the current candidate, the
consolidated connection section, pairing contract and latest acceptance
runbook take precedence. Use only a matching current CI artifact.

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

## Historical implementation milestones (P0–P5)

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

The explicit target builds `pulse-share-desktop.exe` and `pulse_share.dll`.
Run the desktop executable from its bundle, or choose **Pulse Share / 文件共享**
in Pulse to open the same window with the current supported selection. The
adapter starts the exact bundled desktop image and passes the selection via a
private pipe. Without matching helper digests, the window opens with network
actions disabled. The default repository build does not install this bundle.

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

## Desktop workflow

- **发送** accepts files and folders by picker, drag and drop, or Pulse
  selection. Review the endpoint and choose a saved peer before starting.
  **接收** offers single-file receipt, optional single-file discovery, and a
  separate folder/multiple-file receiver. Starting a managed receive creates
  the default private spool if missing. A custom path must already be private
  or be initialized explicitly. The task strip exposes the listening
  address, progress and approval actions whenever they are relevant. Use
  **复制接收地址** to share the endpoint.
- **设备** lists local addresses and shows a count and selectable addresses
  after discovery. Use the interface on the same LAN as the other device.
  A single usable interface or a uniquely preferred gateway interface is
  selected automatically when no address was saved. **更改本机网络** lets
  you choose another interface. The nearby pairing and receiving lists are
  separate. Selecting an address only fills a field. Pairing suggests an
  editable device name, with support for Chinese and other UTF-8 names.
  The centered pairing window shows the live address and connection code.
  **复制地址和连接码** copies a single line the other device can fill using
  **粘贴配对信息**. The code also works in the masked input. Compare the displayed fingerprints and
  approve the pairing on both devices. For an existing private overlay, open
  **已组网？手动配对**. Enter the local overlay IP and peer label. On the code
  host, specify the expected incoming source IP and optional port. On the
  other device, enter the host's announced numeric address and port, then the
  code. Transfer routing settings do not determine these pairing inputs.
- **设置** defaults to the Windows Downloads folder and private identity/spool
  folders under LocalAppData PulseShare. Open **更改存储位置和端口** to edit them.
  **初始化本机** prepares both private directories and the device identity in
  one operation. It refuses an existing ordinary directory or unreadable
  identity, and a successful repeated run preserves the existing identity.
  The first
  desktop launch from Pulse can read older Pulse defaults. The app saves its
  current defaults under the Windows user's LocalAppData PulseShare directory,
  so an isolated Pulse store alone does not isolate desktop preferences.
  Use a dedicated Windows user or VM for installed acceptance. A standalone
  launch with `--session-only` skips disk preference reads and writes.
- **更多发送方式** and **更多接收方式** expose the clipboard and directory
  operations from the appropriate page. Switches show off, waiting for
  approval, running and stopping. Use the same switch to stop an active
  clipboard sync or read-only directory service. Starting these services
  requires explicit action and the existing approval prompts. File receipt
  requires confirmation. The outgoing queue is on **发送**.
- **高级** holds protocol options, manual fingerprint management and recovery.
  **记录** lists recent outcomes and a diagnostic summary in the current
  window. **导出诊断…** saves a UTF-8 text report of recognized error classes,
  timestamps and outcomes. The report uses fixed messages and excludes raw
  worker output, paths, endpoint values, fingerprints, codes and clipboard data.

One task runs at a time in each window. Windows-owned controls stay on the
UI thread; the worker publishes a bounded snapshot. A window close cancels
and drains the current job. Pulse deactivation cancels an in-flight launch;
a desktop window already started can be used or closed independently.
The worker launches only the verified, bundled helper set, with a private
Job Object and inherited cancellation event and pipes. Forced interruption
during commit can leave uncertain file state. Inspect recovery before retrying.

`python tests/share/test_desktop_win32.py` uses a private Windows desktop,
a digest-bound scripted worker, and a session-only app profile. It checks
handoff, discovery, prompt/terminal transitions, and closing an active task.
Physical network and installed Pulse acceptance are separate.

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

## Isolated acceptance package

Download the matching `share-acceptance-inputs` artifact from the Windows
regression, or build the four helpers with the pinned toolchains. With the
matching revision and Zig installed, stage a private candidate:

    python scripts/stage_share_test.py --pulse <Pulse.exe> --tool <official-pulse_ext.py> --binaries <helper-directory> --out .local/share-stage-1

Staging binds the four helpers to a fresh desktop executable, binds the
desktop executable to the Pulse adapter, and uses the official package
verification path. The package is unsigned. See [the acceptance runbook](acceptance.md)
and [the two-device checklist](physical-acceptance.md).

Windows path admission checks each existing directory component for reparse
attributes, normalizes ordinary DOS aliases, verifies unchanged directory
identity and fixed local volume, then checks the exact protected DACL. The
2026-11-27 CI failure at `TestPrivateDirectoryExclusive` was a path-string
comparison rejection, not a TLS or DPAPI failure. Short-name normalization
is not proof of a reparse point. Tests cover ordinary paths and, where the
OS permits, 8.3 aliases and directory symlinks. Saved-peer loopback now also
uses inherited managed cancellation events and protected stores/spool in both
child processes, without claiming actual Pulse host acceptance.

## P2 native usability revision

The development UI uses host tabs, grouped controls, independent field labels,
placeholders, byte progress, state-bound actions, and a separate host settings
page for default local bind address, identity directory, destination, spool and
port. Settings use the owner-scoped versioned resources API with explicit save;
no private key, peer pin or permission is stored in preferences. Edits in the
main panel survive reopening during the same plugin session. Apply saved defaults
explicitly. Local interface inventory is an explicit local-only operation; no
network probing. The receive-and-advertise button is a separate opt-in action.
Coalesced host dispatch wakes refresh task progress while the worker is active;
manual Refresh remains required if dispatch is unavailable or a terminal wake
precedes host task completion. No independent timer/thread is introduced.
The UI uses Chinese in this candidate. The fourth tab shows bounded session-only
transfer results; the last local-interface/discovery/peer/recovery inventory is
retained independently. Separate explicit actions create identity/spool directories.
Persistent history, localization, and selectable structured peer rows remain future work. Actual host rendering and settings lifecycle must be
retested on Pulse 1.0.62. The published manifest schema does not support catalog
metadata; local packages remain unsigned unless explicitly signed later.

This revision does not change the authenticated transport, private directory
admission or no-overwrite commit policy. The settings permission is limited to
package-owned preferences; users must explicitly re-accept it in the isolated
updated package. Do not add unsupported manifest metadata or claim that an
unsigned local package is a verified publisher release.

### Selectable device queries and native folder picker

The device page keeps separate bounded choices for local interfaces and saved
peers; the transfer page offers discovered numeric endpoints. Each list starts
with an explicit empty selection. The user must select and apply a value; no
connection or trust is granted by a discovery response. Changing the local
bind or identity directory invalidates the corresponding old query selection.
Successful pairing changes invalidate the saved-peer list until refreshed.
Use the native folder picker on supported hosts to select a receive directory
or suggest two separate private directories beneath an existing local parent.
The latter only fills fields; creation remains explicitly requested, and
existing directories are not modified. Manual entry remains available.

The main configuration tab also submits its reviewed defaults using the same
versioned preference write operation. Save admission is not completion: the
embedded settings page reports the host's actual confirmation or conflict.
A failed inventory query clears that category of choices, and manual refresh
can retry a failed model update. The picker API is optional and does not
replace the original explicit path validation. Session-only history remains.

Dynamic short-code pairing: see [pairing implementation contract](pairing.md).
The local pair-window policy and tests are present, but the network adapter
and UI are not enabled; existing fingerprint enrollment remains in use.

An isolated CPace authentication candidate is under shared/share/pake and
shared/share/lan/internal/pairauth, with separate TLS loopback CI. It is not
included in the normal acceptance package or available for device enrollment.

## Scoped CI

Share-only feature-branch pushes now select `share`: Windows/Linux Zig
`test-share`, native local/worker tests, the locked CPace helper, one Go
regression pass (including live CPace when built), digest-bound Share DLL,
and Windows LAN integration and acceptance artifact. Shared native primitive
checks and small common validation remain. Unrelated VCS tooling, production
extension builds, Companion ZIP and separate IPC/desktop jobs are omitted.
Share changes mixed with shared/unknown paths, CI or build changes, main
pushes involving Share, PR merge candidates involving Share, and manual runs
retain full regression. The regression gate requires the selected job results;
no failing test is converted into an optional success. The initial CI change
itself necessarily runs full regression. No performance savings are claimed
until a later Share-only push has measured timings.

## Consolidated connection candidate

Dynamic pairing is now wired to the standalone Windows window and
managed LAN worker. A fourth pinned sibling, `pulse-share-pake.exe`, is
required for dynamic pairing; its locked dependency notices accompany the
Windows artifact and staged package. No code is persisted or sent through
ordinary task progress: only private pipe records and the inline pairing controls
carry the short code. The old manual fingerprint enrollment remains.
Explicit routed send/receive requires saved certificate pins and an exact
numeric TCP source for receiving. Private overlay pairing is opt-in and
uses the same source restriction; public short-code pairing is disallowed.
LAN discovery remains local and opt-in, with separate untrusted endpoint
lists for pairing and file reception. Manual endpoint entry remains available. No DNS, relay,
router mapping, firewall change, system mount or background server is added.
All Share TLS connections require X25519MLKEM768; the certificate and CPace
identity mechanisms are still classical, so do not call the whole system
post-quantum authenticated. Go 1.25+ is required; CI stays pinned to 1.27.4.
Legacy saved defaults migrate from v1 to v2, with optional endpoint/source
suggestions, not automatic authorization. Pulse 1.0.62 selection handoff,
secret non-retention and two-PC overlay/proxy use still require acceptance.

The [remaining roadmap](roadmap.md) is the source of truth for new work, including
clipboard content/files, Tray Shelf integration, unified integrity checks and a
shared adaptive 32-channel ceiling. These are planned, not implemented by this
documentation revision.

### Explicit QUIC single-file transport candidate

Use matching helper artifacts, including pulse-share-go-notices.txt. The
existing send/receive CLI accepts --quic; both endpoints must select it.
Use numeric IP and UDP port, not TCP discovery. Existing --routed and
--allowed-source rules apply to the UDP source in this mode. The old TCP
mode is unchanged and no automatic fallback is performed. The same native
no-overwrite supervisor and explicit receive approval apply. Batch lanes,
resume in the installed native UI, and physical acceptance remain pending.

Build preparation: with pinned Go 1.27.4, use go mod download and go mod verify
with the public checksum database, then set GOPROXY=off and GOFLAGS=-mod=readonly
for test/build. The go.mod/go.sum are locked to the resolved probe graph;
CI must reject changes during preparation. Do not use go get -u or go mod tidy
in the build. This supersedes the historical standard-library-only note.


### Batch transfer and manual content sessions

On both endpoints choose --batch with a saved peer, and optionally --quic.
Sender uses --source or --sources (Windows paths separated by |, quoted as one
argument); receiver uses the existing destination/private spool/native helper
arguments. --channels 0 is adaptive up to 32; 1..32 is a fixed ceiling, bounded
by both peers. --resume explicitly selects a local incomplete direct-child
stage under the private spool. Re-send exactly the original content and approve
again; published or uncertain stages cannot be replayed. Batch discovery is
not enabled. A managed transfer owner rejects another managed transfer for the
same Windows user; developer CLI is for trusted local testing only.

Sender --clipboard text/image/files reads the chosen Windows format only after
an explicit action; receiver --accept-clipboard --delivery folder/clipboard
and optional --clipboard-type text/image/files restricts the type.
Default is folder, no clipboard receive or automatic sync. Only uncompressed
bounded CF_DIB images are supported. Clipboard files are copied, not moved.
A busy/changed destination clipboard is rejected. Direct Tray Shelf write is
not available; use Pulse's manual clipboard import if supported by the host.

For a one-session read-only directory offer use sender --share-root --source
<directory>; receiver --browse with optional --browse-offset (20-entry pages),
or --remote-path <exact manifest path> (or . for whole root) to download after
approval. No remote writes, arbitrary roots or unattended directory access.
Normal receive can explicitly approve an upload to a locally selected folder.


### Persistent outbox and opt-in services

The native panel adds a persistent outgoing batch queue. Jobs live under the
private identity directory in outbox.v1 and bind the original manifest, local
identity, saved peer, numeric endpoint and transport. Up to 128 records;
listing is paged in groups of 20. Use a blank job ID to run pending jobs in
order, or specify one ID. The receiving peer must still explicitly approve
ordinary file transfer. A failed connection before sending remains pending;
a started job without a successful receipt is uncertain and is never replayed
automatically. Inspect the destination before explicitly discarding it.
Prune only completed or discarded job records. This is an outgoing serial
queue, not an unattended receive inbox; no automatic startup.

Clipboard sync is a one-way active session, initiated and approved by both
saved peers. Select text or image; no initial clipboard snapshot is sent,
only new changes. File references are excluded from automatic synchronization.
Contents remain in memory, and receiving stops if clipboard replacement
would overwrite a newer local edit. Cancel or exit Pulse to stop. No
automatic restart, two-way echo, or persistent payload history.

A read-only directory service uses one explicitly selected root, one saved
peer and a fixed numeric port. The client connects with the matching batch
transport and uses the existing list/subtree controls. After a session ends,
the server reopens its listener for the next session until cancelled; at
most one authenticated session at once. Revalidate root identity and trust
before each session and transfer. No unattended writes or arbitrary paths.
The service and clipboard sync occupy the managed transfer owner while active.
The QUIC batch ALPN is now version 4; update both peers.

### Reserved Tray Shelf SDK integration

The unavailable shelf adapter deliberately returns ErrShelfUnavailable.
Do not infer support from filesystem staging or scan Pulse private state.
Required SDK: immutable snapshot/enumeration with revision and validity,
approved insertion of verified local files with ownership/lifetime semantics,
completion/error notifications, cancellation and release rules, and capability
version negotiation. Text/image require explicit conversion to ordinary files
if the host supports it. Keep UI disabled until a documented adapter is
available; manual clipboard import remains a fallback.


### Final-stage acceptance

See [automated acceptance](acceptance.md) and
[consolidated Windows host acceptance](physical-acceptance.md).
The dedicated network workflow produces real isolated transport evidence,
not a host package or a certification of every overlay. Heavy tests run
on dedicated harness changes and can be dispatched for a release candidate.
Use the same revision's ordinary Windows CI artifact for the physical package.
The fixture script is non-destructive and does not access a real clipboard.


### Action-built acceptance package

Reuse the existing **Extension test package** workflow
(upstream-candidate.yml), select main and enter
share=0.1.0-rc.1. Its upstream-candidate-packages artifact contains
the official verified, unsigned Share package, manifest, release evidence
and SHA256SUMS. The version is a candidate label, not a published release.
No signing secrets or local compilers are required. Install only into a
test profile with explicit native consent. The public SDK and installer
remain pinned to Pulse 1.0.60; separately record actual host 1.0.62
compatibility. Do not enable the development and formal packages together.

The existing Extension release workflow supports the share product after
merge to main. Share builds the desktop program, all four hash-bound helpers and both notices
only when selected. Existing signing/publication/stable acceptance gates
remain unchanged. No additional packaging workflow is introduced.

The workflow filename remains upstream-candidate.yml for existing links and SDK automation.
For a manually requested test package, run_regression defaults to false (package-only).
Enable it when a full regression is required. SDK update dispatches explicitly enable
full regression, and SDK pull requests always run full regression. A failed requested
regression blocks packaging. All packages still undergo official format verification
and digest checks; skipping regression is not proof of passing regression.
The existing upstream-candidate-packages artifact name is retained for compatibility.
