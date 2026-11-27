# Pulse Share — remaining development roadmap

Status recorded after connection candidate `e0f8eca` (2026-11-28).
This is the authoritative remaining plan. Preserve the existing P0–P5 history
in README.md; do not turn each bullet below into a separate delivery stage.
Prefer one coherent commit per stage, with separate corrective commits only
when CI, SDK contracts or real-host acceptance require them. All items marked
planned must be implemented or explicitly deferred with a documented reason.

## 1. Connection and device management

Candidate code has been submitted; CI and actual Pulse host/two-computer
acceptance are not yet established for this revision.

- Native Zig UI, device inventory, explicit discovery and address selection.
- Eight-digit dynamic code, 60-second rotation, 180-second window, at most
  five attempts, CPace confirmation bound to TLS and both certificate
  identities; explicit bilateral consent, exclusive peer record creation,
  manual full-fingerprint fallback and revocation.
- Private code display/input, no codes in logs, argv, history or settings;
  pinned and bounded helper processes and locked dependencies with notices.
- LAN IPv4/IPv6, explicit numeric routed endpoints for Tailscale, ZeroTier,
  WireGuard, TCP passthrough (FRP/Nginx stream) and manual router port
  forwarding. Require a saved peer pin and explicit expected incoming TCP
  source for routed transfer. Dynamic pairing remains limited to admitted
  private/overlay addresses; public enrollment uses independently verified
  fingerprints. No automatic port mapping or firewall modifications.
- TLS 1.3 with X25519MLKEM768; verify negotiated group. ECDSA and CPace remain
  classical authentication; do not claim a fully post-quantum system.
- Existing shared CI: verify prior regressions, actual host dialogs, secrets
  not retained in ordinary state, cancellation, peer stores and real overlay
  or TCP passthrough before calling this stage accepted.

## 2. Complete file and content sharing (planned)

All sources feed the same authorized content/transfer service. Do not create
separate network protocols or bypass the integrity and resource admission
policy for clipboard, shelf or remote browsing.

### Unified sources and clipboard

- Ordinary selected files and folders, clipboard content, clipboard files
  and folders, Pulse Tray Shelf entries when the host exposes a supported
  snapshot interface, and authorized remote directory entries.
- Native Windows clipboard integration: Unicode plain text, lossless image
  data, and ordinary file paths (CF_HDROP). Text/image payloads use bounded
  typed byte records and the same authenticated transport and content digest
  checks; clipboard files/folders use the regular file manifest and queue.
- Explicit send and explicit receive-to-clipboard action by default. Optional
  per-trusted-device automatic clipboard synchronization is disabled by
  default and must be separately opt-in, with separate content type permissions,
  pause/disable, bounded payloads, deduplication and loop suppression. Do not
  silently overwrite a newer local clipboard value; do not persist clipboard
  content in history, logs, preferences or diagnostic dumps. Never automatically
  open received links, execute content or interpret clipboard data as commands.
- Snapshot only after an explicit action (or separately granted automatic
  sync). Copy borrowed data before returning; validate Unicode, type, size,
  image dimensions and decoding budget. Handle unavailable/busy clipboard
  without blocking the host UI. Never clear, move or delete originals based on
  CFSTR_PREFERREDDROPEFFECT or a remote receipt: treat cut as copy for Share.
- Virtual shell items without regular filesystem paths (archives, Outlook,
  phone items, delayed rendering) are not ordinary CF_HDROP files. Report
  unsupported items; materialization requires an explicit safe host-supported
  operation, bounded local storage and normal validation. No silent omission.

### Pulse Tray Shelf versus staging API

- User-visible Tray Shelf is the requested sharing source. At the inspected
  upstream SDK revision b32436831a066e18448b2810bef4bf989024fc68, there is
  no documented native snapshot/list API for the user's shelf. Do not scan
  private host state, memory, config or temp directory internals as a workaround.
- Request a supported read-only shelf snapshot with ordinary selected entries,
  revision/identity, paths or expiring handles, type and stale-item status;
  copy borrowed data and revalidate on use. A missing interface must disable
  the shelf entry with an explanation, without blocking other sources.
- `pulse.staging` V1 is a different API: create a host-owned same-volume
  private staging directory, commit via normal native confirmation, get
  status, cancel and release. Evaluate it as an optional receive publication
  backend only if equivalent integrity, no-overwrite and lifecycle guarantees
  are retained. Finish/join all writers before commit/release, do not treat
  acceptance as completion and track terminal outcomes. Do not assume it
  adds an item to the visible Tray Shelf.
- SDK sources: [staging.h](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/sdk/native/include/pulse/staging.h),
  [context.h](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/sdk/native/include/pulse/context.h),
  [clipboard.h](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/src/ops/clipboard.h),
  [Tray Shelf renderer](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/src/ui/ui_tray_shelf.cpp).

### Transfer, integrity and recovery

- Bounded multi-file/folder manifests with canonical relative names, sizes,
  content hashes, file identities, entry/byte limits, collision and path
  validation. Reject traversal, unsupported reparse entries and ambiguous
  Windows aliases. Preserve empty files and directories. Never trust a
  remote absolute pathname.
- SHA-256 per block and whole file, independent receiver verification before
  publication, exact length and offset checks, authenticated manifest
  binding, source identity and change detection. Existing native P1
  no-overwrite and independent verification remain required (or an equivalent
  reviewed replacement); no clipboard/shelf bypass. TLS provides channel
  integrity but does not replace end-to-end file verification.
- Resume only verified blocks matched to the same manifest, peer identity,
  source version and locally owned transaction. Persist bounded restart
  journal/bitmap, retransmit missing or corrupt blocks, recheck entire digest
  before commit. An uncertain commit needs reconciliation, not blind retry
  or deletion. Cancellation is not rollback.
- Persistent bounded queue and per-file receipts, progress, pause/cancel,
  restart recovery, retry budgets, history metadata and retention. Do not
  retain file contents, clipboard secrets or unbounded path logs. Distinguish
  local commit, peer acknowledgement and uncertain outcomes.

### Adaptive parallel transfer: global ceiling 32

- Configurable concurrency 1–32 with automatic mode as recommended default.
  This is a hard global active data-channel budget per device across all
  simultaneous incoming/outgoing transfers and sources, not 32 per file,
  per task or per peer. Coordinate scheduler, buffer and socket limits across
  all workers/processes; negotiated peer limit may be lower.
- Use bounded Go goroutine workers, not 32 fixed OS threads or 32 helper
  processes. Parallel files and large-file range/block transfer may share
  the same budget. Authenticate every data channel and bind it to the same
  approved peer, transaction, manifest and assigned block/range. No unpaired
  data-channel endpoint; reject duplicate, invalid and stale assignments.
- Keep verification block size independent from streaming I/O buffers.
  The existing 256 KiB streaming buffer is a starting point; choose larger
  logical blocks based on measurements. A fixed 32 x 8 MiB double-buffer
  approach would consume 512 MiB per endpoint before runtime overhead and
  is not acceptable under the current job budget. Use pooled bounded
  buffers/backpressure, bounded disk queues and explicit per-device memory,
  socket, file-handle, process and disk quota budgets. No unbounded preloading.
- Start conservatively, adjust by throughput, latency/retry rate, storage
  pressure, CPU/memory and peer capacity. Prefer low concurrency for HDDs
  and small files. More channels must be justified by real measurements;
  fall back to one on unsupported peers or resource pressure, without
  relaxing authentication or integrity. Do not claim 32x throughput.
- Validate at 1/2/4/8/16/32 channels, including mixed concurrent jobs,
  cancellation/drain, corrupt block retry, interruption/resume, memory
  ceilings, disk-full and no-overwrite behavior. Measure aggregate speed,
  CPU, peak/idle memory, handles, socket counts, disk I/O and repeated-run
  resource retention. Include HDD/SSD, Wi-Fi/LAN and overlay/proxy scenarios
  where actual equipment is available; report untested combinations.

### Remote directories and UI

- Opt-in per-peer grants for explicitly selected directory roots, default
  read-only, explicit upload authorization, quotas, revoke, paginated
  browsing and safe relative path resolution. No arbitrary remote paths,
  automatic drive exposure or executable launch.
- Native Pulse UI with source selection, device choice, clipboard controls,
  transfer queue/history, adaptive concurrency settings and observable
  partial/failed outcomes. Keep existing settings migration; no WebView.
- No OS-level mounting, virtual disk/VFS driver, SMB/WebDAV server, self-built
  VPN/relay/NAT traversal server, UPnP or automatic router mapping. Reuse
  external networking tools; keep directory access inside Pulse Share.

### Future independent clients and local self-hosted Web access

Architectural constraint for stage 2; independent desktop and Web clients
are follow-up options, not extra mandatory delivery stages.

- Extract reusable Share Core from Pulse-specific UI and process supervision.
  Keep Pulse SDK, Tray Shelf and OS clipboard/filesystem adapters outside
  the portable core. Use versioned bounded client interfaces and a single
  authoritative owner of device identities, grants, queues, transactions,
  resource budgets and the global 32-data-channel ceiling. Multiple frontends
  must not independently mutate the same store or start competing engines.
  Preserve current supervised plugin shutdown until a separately owned
  service lifecycle and authenticated local IPC are implemented and accepted.
- A future standalone native desktop client need not install Pulse or embed
  a browser. A future Web frontend is a locally hosted, optional service
  serving bundled static assets and a separate versioned HTTP(S) API. The
  browser must not directly speak the existing custom TLS/TCP wire protocol.
  Browser capabilities and permissions are distinct from native peer identity.
- No required cloud account, hosted Web service, external CDN, public relay,
  proprietary tunnel, telemetry, or internet dependency for local use.
  Users independently choose whether and how to reach their local service:
  LAN, private overlay, existing reverse proxy/tunnel, or manual router
  mapping. Do not provision, discover or modify those services or routes.
  No automatic external listener, firewall changes or UPnP.
- Web service is disabled by default; explicit start/stop, concrete loopback
  bind by default, operator-selected non-loopback binding only by explicit
  opt-in. Remote access is not implicitly trusted because it traverses a VPN,
  proxy or local address. Require HTTPS for non-loopback browser access,
  with operator-managed certificates or a deliberately configured trusted
  TLS-terminating proxy over a protected backend link. Reject insecure
  remote mode; local HTTP, if supported, is restricted to loopback with
  authenticated sessions. Do not claim end-to-end TLS through a terminating
  proxy; TCP passthrough and HTTPS termination are different deployments.
- Use separately designed browser enrollment/session authentication and
  authorization, short-lived revocable credentials, secure cookie/session
  policy, CSRF and Origin/Host validation (including DNS rebinding defenses),
  explicit allowed origins, no wildcard CORS, no trust from forwarded headers
  except explicitly configured trusted proxies. Never expose pairing secrets
  or session tokens in URLs, logs or history. Limit authentication attempts,
  sessions, request sizes, concurrency, timeouts, and disk quotas.
- Per-browser/session grants are least privilege; browsing is read-only by
  default and uploads require explicit authorization. Every request is
  authorized against a granted root or approved transaction, not a caller's
  arbitrary local path. Reuse manifests, SHA-256 block/whole-file checks,
  no-overwrite publication, cancellation, recovery and global resource
  scheduling. For browser uploads the authenticated session binds a manifest
  and content digest; do not imply that browsers have native TLS pin/PAKE
  capabilities or that a user-supplied hash alone authenticates a file.
  Browser download verification must be documented according to its actual
  capabilities. Do not expose native clipboard, shelf, device private keys,
  arbitrary filesystem access or command execution as a generic Web API.
- Local owner can see listener status/bind, authorized sessions, grants and
  active transfers, revoke access, stop accepting requests, cancel/drain
  tasks and shut down the Web service independently. Distinguish disabling
  new requests from cancelling active transfers and already committed files.
  No automatic execution, clipboard sync or file overwrite on Web access.
- Future acceptance must cover unauthorized requests, invalid Origin/Host,
  untrusted proxy headers, expired/revoked sessions, interrupted uploads,
  corruption, quotas, parallel clients, listener shutdown and no service
  listening by default. External connectivity is the user's responsibility;
  document supported configurations and limitations, not universal reachability.
  The current release does not contain a Web server or standalone desktop app.


## 3. Acceptance and release (planned)

- Physical two-PC tests on the supported Pulse host, local and routed
  transport, first pairing, revocation, clipboard and shelf (if the supported
  API is available), transfer integrity, grants and recovery.
- Stress/throughput and resource measurements, audit dependencies and
  identity/permission boundaries, fix host lifecycle and crash/cleanup
  defects, finish UI/localization and user/developer documentation.
- Pin reproducible artifacts and notices, verify all bundled members, use
  signed preview and existing release gates, promote the exact accepted
  candidate. No release secret in branch CI. No unsupported features
  advertised as implemented.

## CI and delivery rules

Reuse the existing Share-only scope for ordinary feature-branch changes;
keep relevant Zig/Go/Rust/native integration, new content/queue tests and
resource stress regression. Do not repeatedly run unrelated Companion/VCS
integration. Shared SDK/build/workflow changes, Share merge candidates,
main Share pushes and manual full checks retain full regression. A green CI
does not prove actual host, two-machine, security or performance acceptance.
Record PASS / FAIL / NOT RUN in [acceptance.md](acceptance.md).
