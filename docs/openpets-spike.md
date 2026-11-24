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
