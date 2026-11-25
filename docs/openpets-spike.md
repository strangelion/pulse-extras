# OpenPets interoperability spike / 兼容性实验

Experimental branch only. No shipping extension or network access is added.
Baseline [OpenPets 2f02bb0](https://github.com/OpenPetsHQ/openpets/tree/2f02bb04d872dec6923a47572343305235c63482), MIT. Reference contract, no copied upstream implementation:
[client protocol](https://github.com/OpenPetsHQ/openpets/blob/2f02bb04d872dec6923a47572343305235c63482/packages/client/src/protocol.ts),
[server handler](https://github.com/OpenPetsHQ/openpets/blob/2f02bb04d872dec6923a47572343305235c63482/apps/desktop/src/local-ipc-request-handler.ts),
[IPC docs](https://github.com/OpenPetsHQ/openpets/blob/2f02bb04d872dec6923a47572343305235c63482/docs/ipc.md).

Observed: v1 JSON-line protocol; Windows named pipe, Unix socket, optional TCP.
Max message 16 KiB; discovery includes endpoint, protocol, token, PID/platform.
The app generates base64url token; hello/status and leased pet.react use the
result envelopes exercised in the tests. Lease TTL is 15s, not a permanent claim.
No generic command execution is needed.

## Experiment

shared/companion/openpets_protocol.zig implements a bounded pure wire codec
for hello/status/leased react only. No transport, filesystem access, IPC endpoint
ownership, lease acquisition or live OpenPets calls. Strict ASCII atom subset,
request-ID and response shape checks, no arbitrary speech, media, install or
remote transport. Tests use synthetic fixtures matching the pinned handler;
they do not establish interoperability with a running server. Error details are
not propagated or logged. No new dependencies/submodules.

Run `zig test shared/companion/openpets_protocol.zig` or the existing full
`zig build test --summary all`. The module is included in the test source list,
not compiled into a shipping DLL. Zig 0.17.1 and live OpenPets are unavailable in
the authoring environment; GitHub CI is required before merge. No test result is
claimed here.

## Next gate

After codec checks pass, verify against a real approved Windows OpenPets
instance. Add safe discovery validation (trusted owner/ACL, reparse defense,
bounded reads, never log token), local named-pipe transport only with
finite connection/read/write/cancel deadlines and owned handles, test with
an isolated mock named pipe, then actual hello/status. Only then implement
explicit lease acquire/heartbeat/release and leased reactions with user approval;
no automatic default-pet override or LAN/remote mode. Use shared runtime once
its lifecycle is validated; do not run blocking work on Pulse UI thread.
Consider compatibility of data-only pet packages (bounded parsing/decoding,
asset licensing) separately. Native rendering needs actual host SDK verification.
Do not port Electron/JS plugins, general Agent systems or claim full compatibility.
An optional backend is preferable to an OpenPets clone; a separate native
backend is justified only by measured usability and resource gains.

## Native rendering: resource-first, cross-platform core

OpenPets at the pinned revision uses Electron BrowserWindow and CSS sprite
animation (pet-window.ts, pet-window-render.ts); it is not a native C++ pet
renderer. Use its documented asset/animation contract, not Chromium. The
Pulse native UI capability must be verified independently. Do not assume
the host exposes arbitrary GPU surfaces, transparent overlay windows or a
shared Direct2D device.

The preferred first independent Windows prototype is a small premultiplied
BGRA surface and Win32 layered window (UpdateLayeredWindow), or a supported
host surface if the SDK provides one. Benchmark CPU blitting against a
Direct2D/DirectComposition backend for the same sprites; choose the simplest
backend that meets measured budgets. UpdateLayeredWindow updates the whole
window, so keep its dimensions near the pet rather than the desktop.
Do not create a separate graphics device for every pet. A standalone
companion must be optional, with owned lifecycle and no forced background
startup; it must not depend on Pulse private window/device internals.

Keep sprite layout/animation timing, state/event mapping, asset parsing and
resource limits in portable Zig. Separate OS windowing, image decoding and
presentation behind a narrow interface once actual consumers need it.
SDL3 SDL_Renderer is a candidate for a portable standalone backend; it can
select supported native render drivers (including D3D11, Metal or Vulkan
depending on platform/build). Its transparent window flag requires correct
premultiplied alpha. Test transparency, click-through/hit testing, no focus
stealing, placement, DPI, monitor changes, sleep and Wayland restrictions on
each platform; portability of a graphics API does not prove window behavior.
Do not mandate Vulkan, SDL, a game engine, WebView2 or Electron for the initial
Windows prototype. Raw Vulkan requires device/queue/swapchain, synchronization,
memory and device-loss management; only introduce it if actual requirements
and measured comparison justify it. macOS support through Metal or other
verified backend is separate; the Pulse native extension itself is Windows
only. No new dependency or rendering source is added by this experiment.

### Memory and scheduling constraints

Pinned OpenPets sprite-layout.ts defines 192x208 cells, 8 columns, 9 rows
(v1) or 11 rows (v2). A full uncompressed 32-bit atlas costs 11,501,568 or
14,057,472 bytes (about 10.97 or 13.41 MiB), before decoder temporaries,
GPU copies, driver overhead and presentation buffers. One cell costs
159,744 bytes. A compressed WebP file size is not its decoded memory size.
Validate supported exact dimensions, format, decoded byte arithmetic,
input size and asset count before full decoding. Decode via an audited
existing image decoder supporting WebP; check OS codec availability and
fallback, never assume WIC always has WebP support. Use bounded decoding
workers for untrusted assets; no arbitrary scripts or SVG execution.
Keep one active atlas or a measured bounded set of frame/row textures;
avoid retaining duplicate CPU and GPU copies unless a recovery/CPU path
requires it. Reuse buffers, do not allocate/decode/upload on every frame.
Release old assets after their consumers finish, limit prefetch, disable
wardrobe/extra effects initially. Do not allocate full-monitor surfaces.
Account for native decoder/driver/child memory beyond allocator tracking.

Event-driven update, schedule next actual animation frame from monotonic
time, no busy polling or permanent 60 FPS loop. Use the authored animation
durations, skip obsolete frames after sleep or stalls; only repaint when
frame/geometry/state changes. Pause hidden/minimized/suspended sprites and
release evictable resources on idle/close; no input or render timer while
completely inactive. No model calls for idle behavior. Bound IPC buffers,
use a single in-flight request per session and coalesce redundant state
events. Use shared runtime when its teardown is proven.

Compare release builds on the same machine, same sprite, dimensions and
states, with idle/animating/hidden/skin-change/exit scenarios. Record
incremental Private Bytes, committed bytes, working set, GPU dedicated/shared
memory, decoder peak, CPU, timer wakeups, frame latency, handles and threads.
Compare native with the full OpenPets process tree (not a single renderer).
Aim for low steady state and resource return after close; do not assert a
10-30 MB process cap or zero GPU use until measured. Preserve real lifecycle
and device recovery tests. Keep rendering evaluation independent of IPC
codec CI; do not claim that this wire experiment is a renderer.

References: [SDL3 window transparency](https://wiki.libsdl.org/SDL3/SDL_CreateWindow),
[SDL renderer drivers](https://wiki.libsdl.org/SDL3/SDL_HINT_RENDER_DRIVER),
[SDL GPU drivers](https://wiki.libsdl.org/SDL3/SDL_CreateGPUDevice),
[Win32 layered windows](https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features),
[UpdateLayeredWindow](https://learn.microsoft.com/en-us/windows/win32/api/winuser/nf-winuser-updatelayeredwindow),
[pinned sprite layout](https://github.com/OpenPetsHQ/openpets/blob/2f02bb04d872dec6923a47572343305235c63482/packages/pet-format/src/sprite-layout.ts).

## CI correction

Run 45444213171 failed in zig fmt on both runners at the legacy array repetition
expression in the oversized-frame test (line 195). Replace that expression with
a fixed buffer initialized by @memset. No claim of compilation or test success
until the follow-up run finishes.

## Windows pipe primitive (experimental)

The pure Zig probe and discovery/framing tests passed Windows and Linux CI
in run [45527745615](https://github.com/strangelion/pulse-extras/actions/runs/45527745615).
The separate C Win32 primitive in shared/companion/openpets_pipe_win32.{h,c}
now implements local byte-mode overlapped named-pipe read/write, finite
deadline waits, event cancellation with completion draining, server-PID
matching on the opened pipe, and idempotent handle close. The caller must
supply a separately authenticated, live process handle and retain it during
open. PID matching is not a substitute for trusted executable and owner
verification. The primitive fails fast on missing/busy endpoints; no retry,
token, discovery, process launch or host integration is added. All calls
belong on a worker. Kernel cancellation completion can delay the drain;
do not advertise a strict deadline for all synchronous OS calls or the drain.

A Windows CI test compiles the primitive with Zig's C compiler and exercises
an isolated kernel named pipe with synthetic data, timeout, cancellation,
subsequent I/O, EOF and repeated close. It is not a running OpenPets test.
This experiment is not linked into the shipping DLL. The remaining gate
is secure opened-handle discovery/ACL and independently authenticated
process identity, then a Zig adapter and real approved hello/status.

## Windows discovery and candidate process trust primitives

The pipe primitive passed run [45528576360](https://github.com/strangelion/pulse-extras/actions/runs/45528576360).
The separate openpets_trust_win32 C primitive accepts a caller-approved,
pinned directory handle on a fixed local drive. It opens only ipc.json
relative to that handle (NtCreateFile, no concatenated path fallback),
opens reparse objects without following them, and rejects reparse attributes,
multiple hard links, empty/oversized data and unexpected ACLs. File sharing
denies concurrent write/delete; both directory and file must be owned by the
current user and have a non-null DACL with only effective ordinary allow ACEs
for that user, SYSTEM or Administrators. Other ACE forms fail closed (ordinary
deny ACEs are allowed). This intentionally may reject real installations.
All reads are bounded, unsuccessful reads clear the destination; synchronous
metadata/file operations still belong on a worker and are not hard-cancellable.

The candidate process function takes an independently approved executable path,
checks the live process's token user, session and reported image path, and returns
an owned handle for subsequent named-pipe server PID comparison. It is not a
signature/hash check of the mapped executable and does not protect against
malicious same-user code, administrators, or preexisting privileged handles.
Do not derive the approved path or directory from the discovery JSON.
Directory bootstrap (including safe ancestor traversal and user approval) and
the Zig-to-C adapter remain separate gates. No automatic discovery or shipping
extension is enabled by these primitives.

Windows CI exercises a private temporary directory, real kernel ACL checks,
hard links, exact-size/oversized/missing files, cancellation and process
identity/path mismatch. Reparse-point rejection is implemented but its
privilege-dependent fixture and live OpenPets compatibility remain unverified.

API references: [NtCreateFile](https://learn.microsoft.com/windows/win32/api/winternl/nf-winternl-ntcreatefile),
[GetSecurityInfo](https://learn.microsoft.com/en-us/windows/win32/api/aclapi/nf-aclapi-getsecurityinfo).

## Explicit directory bootstrap and Zig/Win32 bridge

openpets_windows.zig implements ProbeTransport using the existing Win32
primitives and a small C ABI bridge. The caller supplies independently
approved UTF-16 directory and image paths, a reusable workspace, a fresh
request ID and optional borrowed cancellation event. No implicit APPDATA,
environment override, process launch or network fallback. The directory
bootstrap accepts a bounded absolute fixed-drive DOS path, walks each
component via handle-relative opens without following reparse objects, rejects
dot/trailing-space/alternate-stream components and checks the final private
ACL. Earlier ancestor handles are released after each child is opened; this
pins the final object but does not claim immutable ancestry or executable
signature verification. Same-user code remains outside this trust model.
Only hello/status are enabled, with no lease or pet changes.

The Windows CI command links Zig, C bridge and native primitives into an
isolated test binary. A private temporary discovery file and real local
named pipe exercise the actual hello exchange, cancellation, invalid directory
and rejected image path. It is a synthetic fixture, not actual OpenPets or
Pulse host integration. The new CI result must be checked before expanding
the API. The production DLLs remain unchanged.

## Explicit lease codec and lifecycle experiment

openpets_lease.zig implements only the pinned acquire, heartbeat and release
wire shapes, including the upstream success results that do not have an
inner ok field. Acquire requires an explicit pet ID, positive client PID
and caller-supplied stable per-session nonce (the eventual integration must
generate it with a secure random source). The bounded decoded lease ID is
owned; arbitrary peer error text does not escape. An acquired lease may
drive reactions only if the server confirms an active explicit target
matching the requested pet and PID, without fallback. A fallback or late
result is retained solely for release.

The pure Session policy schedules heartbeat at 5s and uses a conservative
10s local monotonic validity window (upstream TTL 15s), both anchored to
request start, not the peer's wall-clock expiresAt. Reactions are suspended
when renewal is due or in flight; unknown leases clear local ownership,
ambiguous failures can be invalidated to release-only, and no reacquire is
automatic. Callers must serialize requests, correlate responses, use fresh
request IDs and discard stale results. A release response of false means
the lease was already absent; ambiguous release retains release-only state
and the remote TTL is the ultimate cleanup.

This module is pure and included in host regression tests; the live
Windows bridge remains read-only. Before enabling lease writes, verify the
actual approved OpenPets hello/status, bind the lifecycle to a stable
authenticated server instance (including restart handling), integrate
cancellation/shutdown, and require explicit user consent. No default-pet
mutation or automatic lease acquisition is enabled.

## Bounded companion behavior scheduler

The lease codec passed after the test-fixture naming correction in
[45530953947](https://github.com/strangelion/pulse-extras/actions/runs/45530953947).
behavior.zig is a pure, single-worker policy with 32 fixed task slots,
no dynamic allocation, no threads and no I/O. Producers supply non-reused
task IDs, begin/update/finish events and a common monotonic timestamp;
long-running tasks must be refreshed within 60s. Unknown updates cannot
revive tasks, capacity errors never evict existing work and stale clock
samples are rejected. Priorities are testing, running, editing, working,
thinking, waiting; a failure overrides activity for 1.8s, whereas success
only displays when no tasks remain. Cancellation does not celebrate.

One pending delivery ticket, 250ms minimum send spacing and identical-state
coalescing bound emission. A shown=false acknowledgment does not trigger
automatic retries; failed delivery disables output until availability is
explicitly restored. Disconnect/reset discards terminal reactions and stale
delivery tickets without reusing ticket numbers. nextWake reports the next
useful deadline instead of requiring fixed-rate polling. Offline events can
update current tasks but cannot replay completed animations on reconnect.

The defaults are experimental tuning choices, not measured performance.
The authenticated lease owner must supply availability, serialize writes,
recheck authorization and report completion. This pure scheduler does not
enable live writes, start a timer or integrate with Pulse host events yet.
Host CI includes six behavior regression tests.

## Classic atlas and animation core

The first native renderer asset subset is deliberately classic static WebP:
V1 1536x1872 (9 rows) and V2 1536x2288 (11 rows), 192x208 cells,
8 columns. pet_assets.zig validates the approved folder ID, canonical
spritesheet.webp path, required metadata fields and explicit version.
Unsupported metadata extensions, SVG, Motion packages and noncanonical
paths fail closed. Metadata is bounded to 128 KiB and must be parsed with
a bounded scratch allocator. Compressed WebP input is limited to 16 MiB.
RIFF and VP8/VP8L header preflight validates the declared image dimensions,
chunk bounds and static subset; animation, unrelated chunks and trailing
data are rejected. This is NOT a compressed image decoder or proof that
image data is safe. Before rendering, a separately vetted decoder must
decode into a bounded allocation and return exact tightly packed RGBA8
dimensions and stride. One decoded V1 atlas is 11,501,568 bytes, V2 is
14,057,472 bytes; renderer/cache allocations are additional.

animation.zig uses the pinned classic state rows, durations and reaction
mapping; integer-only sampling skips missed frames without catch-up loops.
Finite waving/jumping/failed animations fall back to idle, repeated state
selection does not restart playback unless explicitly requested, and
hidden windows have no frame wakeups. Reduced motion uses V2's neutral
pose or V1's first idle frame. These are local timeline primitives, not
an implemented Windows renderer. No image decoder, asset downloads,
archive extraction, SVG rasterizer, Motion clips, wardrobe, gaze or host
integration is enabled. Tests use synthetic headers rather than real art.

## Desktop placement and native layered surface

The native companion is intended to be a separate transparent desktop
window, not a child of the Pulse main window. Prefer a separate lightweight
helper process for fault isolation; Pulse owns opt-in settings, activity
events, backend selection and lifetime. Minimize should not hide it by
default; full Pulse exit should stop the helper by default. An in-app
preview is optional and not the primary surface. External OpenPets IPC and
the native desktop backend must be mutually exclusive as display backends.
No helper executable, launch mechanism or host settings are enabled yet.

pet_surface_win32.{h,c} implements a worker-independent, dedicated UI-thread
Win32 window primitive using WS_EX_LAYERED, WS_EX_TOOLWINDOW and
WS_EX_NOACTIVATE. The caller selects optional topmost and click-through,
position and whole-window opacity. It reuses one top-down 192x208 32-bit DIB
(159,744 bytes of pixels), converts only the selected decoded RGBA8 atlas
cell to premultiplied BGRA8, and presents it with UpdateLayeredWindow.
No full-atlas copy per frame, timer, polling, global hook, GPU dependency
or extra image library. The initially hidden surface must be successfully
primed before showing. Close is owner-thread-only and idempotent.
The owner must run a dedicated message loop, use animation deadlines,
and avoid rendering when hidden. Scaling, DPI/work-area policy, dragging,
actual WebP decode/cache, Zig binding and helper lifecycle remain pending.

CI compiles the C primitive and checks synthetic pixel conversion, bounds,
alpha, hidden window presentation, styles, wrong-thread rejection and
repeated cleanup on Windows. This is a hidden kernel/GDI surface test,
not an interactive desktop or resource benchmark. No production DLL is
changed; the sample pixels are not distributable pet artwork.

## Standalone native desktop demo

Build on Windows from repository root with the pinned Zig:

```powershell
zig build-exe shared/companion/pet_demo.zig shared/companion/pet_demo_win32.c shared/companion/pet_decode_win32.c shared/companion/pet_surface_win32.c shared/companion/pet_config_win32.c -target x86_64-windows-gnu -O ReleaseSafe -lc -luser32 -lgdi32 -lshell32 -lole32 -lwindowscodecs -luuid -ladvapi32 '-femit-bin=pulse-pet-demo.exe'
.\pulse-pet-demo.exe
.\pulse-pet-demo.exe --reduced-motion
.\pulse-pet-demo.exe --webp-v2 C:\path\to\spritesheet.webp
```

The default demo generates original geometric placeholder pixels, shows
a nonactivating independent window near the primary work area's bottom
right and uses the Zig timeline. Left click waves; right click exits.
Reduced motion waits for messages without frame timers. The message loop
waits until the next frame or input and redraws only on cell changes;
missed frames are skipped. The hidden --smoke mode explicitly exercises
multiple frames and exits after 500ms (plus OS call/scheduling latency).
CI builds the executable and runs that hidden synthetic smoke test.

An optional explicit V1/V2 WebP path is read once (16 MiB compressed cap,
fixed local drive and final reparse rejection), validated by the Zig
preflight, then decoded using installed Windows Imaging Component
codecs. One frame, exact dimensions, tight RGBA8 output and a fixed
allocation are required. COM objects and compressed bytes are freed before
the render loop. No automatic codec installation, internet download or
asset search. This is not a sandboxed decoder; WIC internal memory and
execution time are outside the pixel-budget guarantee. Actual WebP support
depends on the installed Windows codec and is not exercised by synthetic
CI; a missing or incompatible codec fails instead of silently falling back.
No pet.json file loading, signed asset trust, DPI scaling, dragging,
multimonitor persistence, Pulse supervision or release packaging yet.
This executable remains a standalone experiment, not a default startup
item or production DLL.

## Desktop movement and bounded scaling

Run 45534257173 failed before compilation with PowerShell passing a separate
".exe" parameter to Zig. Quote the entire -femit-bin argument in CI and the
documented PowerShell build command. The previous layered surface regression
passed in run 45533855889; the standalone build still needs confirmation.

The demo now supports left-button drag with a 4px threshold, capture loss
handling, click-to-wave and right-click exit. Position-only layered-window
updates avoid re-converting pixels during a drag. The monitor nearest the
cursor is used during dragging, and the nearest monitor to the window center
on display/work-area/DPI change. Clamp to rcWork, including negative screen
coordinates and small work areas. The process requests per-monitor V2 DPI
awareness, with system awareness fallback. This is explicit physical-pixel
scaling, not automatic DPI-dependent sizing.

Use --scale 50..200 (default 100) and --topmost to choose initial size and
z-order. Nearest-neighbor sampling converts only the chosen cell into a
single bounded DIB (maximum 384x416, 638,976 bytes). The atlas is unchanged.
No resampling allocation or bitmap growth per frame. CI exercises scaled
pixel conversion, position-only updates, clamp bounds and two hidden smoke
sizes. Real drag/capture behavior, display topology changes, DPI transitions
and actual visual quality still need interactive testing. No disk/registry
position persistence, automatic DPI-dependent size or Pulse supervision yet.

## Opt-in persistence and inherited shutdown signal

Use --remember to load and save the demo's settings under
HKCU\Software\PulseExtras\CompanionDemo, SettingsV1. A single 24-byte
versioned REG_BINARY record contains x/y, scale, topmost, reduced motion
and position validity. No image paths, credentials or arbitrary strings.
CLI --scale, --topmost/--no-topmost and --reduced-motion/--motion override
saved values; --reset-position --remember ignores the old location.
The nearest available monitor work area constrains restored positions.
A missing key is only created on a clean visible exit. Invalid or unknown
records are not overwritten; save failures are reported without modifying
other settings. No writes in smoke mode, no periodic writes, no registry
flush or promise of crash-durable last position. Concurrent demo instances
are not synchronized (last valid save wins); a future supervisor must
enforce one child. The load/check/write sequence is not a CAS against
concurrent registry edits.

For a trusted future launcher, --stop-handle DECIMAL accepts a valid
inheritable wait handle already present in the child, intended only for a
manual-reset event or a parent process handle with SYNCHRONIZE access.
Do not expose raw handle arguments to untrusted callers. The launch
side must explicitly allowlist inherited handles and retain its own
reference. The child waits in MsgWaitForMultipleObjectsEx alongside input
and frame deadlines; a signal stops it without polling and releases all
resources. A signaled handle at startup exits before window creation.
There is no PID lookup, termination of another process, automatic launch
or parent-crash supervision yet. A process handle can provide parent-exit
notification; the actual Pulse launcher must still implement ownership
and job-based cleanup. This is cooperative shutdown, not a hard deadline
for synchronous image decode or OS calls.

CI tests the configuration record in an isolated volatile registry key
and the pre-signaled inherited-event startup path with a Windows Python
launcher. Interactive restore, live stop during rendering and crash
behavior remain to be verified.

## Main synchronization and dependency recovery

Merge main at 2759b5141690d406518f4853c9e6371c4c75c7ec, preserving its
shared runtime, process containment, VCS and phase-diagnostic CI changes.
Retain all companion sources and regression checks. No experimental
companion is enabled in production extensions. Run 45535341677 passed
the full Windows matrix including the demo/config/stop tests, but Ubuntu
failed before Zig tests when the pinned JJ release download returned
HTTP 503. The downloader now retries transient transport errors at most
three total attempts (2s and 4s backoff), deletes partial archives and
retains the pinned checksum and version checks. Permanent HTTP errors
and checksum mismatches fail closed. Offline Python regression tests
cover retry, exhaustion, permanent failure and partial-file cleanup.
The merged runtime and companion combination still requires CI verification.
