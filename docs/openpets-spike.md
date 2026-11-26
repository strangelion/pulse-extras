# OpenPets interoperability and native companion runtime

Current technical index; the original exploratory chronology and exact
implementation checkpoints remain available in the
[immutable historical document](https://github.com/strangelion/pulse-extras/blob/78a33f1a54cabb6e880687023692a07aba44163c/docs/openpets-spike.md).
Current product scope and D acceptance are in [Companion Manager](companion-manager.md).

## OpenPets boundary

Pinned reference [OpenPets 2f02bb0](https://github.com/OpenPetsHQ/openpets/tree/2f02bb04d872dec6923a47572343305235c63482)
(MIT); [IPC](https://github.com/OpenPetsHQ/openpets/blob/2f02bb04d872dec6923a47572343305235c63482/docs/ipc.md)
and data-format contracts. The bounded codec and local named-pipe discovery,
trust and transport have synthetic regression coverage. JSON-line v1,
16 KiB cap, explicit leases; no arbitrary speech/commands, remote/LAN
transport, executable asset content or token logging. Real approved
OpenPets interoperability is not implied by mock IPC. Keep this optional
compatibility path; do not expand it into a second pet/Agent product in D.

## Native desktop runtime

Windows x64 GNU helper, layered premultiplied BGRA window, portable Zig
asset/animation/state policies, bounded WIC or pinned static libwebp decode,
no Electron/Chromium. Classic V1/V2 WebP, named activities, wardrobe
(manual/scheduled), idle gaze, reduced motion and per-instance config
have candidate native regression coverage; verify behavior on real
desktop. The shared allocator/group/latest-task handoff owns async
decode lifetime; release only after actual join. Native handles, surfaces,
menu trees and resource reservations drain before exit. No shared global
allocator, arbitrary executable, remote agent or private host renderer.
OS graphics and decoder allocations are not all represented by tracked
heap counters. See [shared runtime](shared-runtime.md).

The digest-approved supervisor now supports small managed child groups,
independent one-process Jobs and readiness/state channels. 1024 slots
are storage, not performance evidence. Per-renderer 128 MiB committed
limit and 48 MiB tracked quota are distinct. Crash opt-in is a separately
bounded watcher candidate; see manager for failure status and limits.
Independent stress children are not supervised by Pulse.

## Build and test

```powershell
zig build pet-demo -Doptimize=ReleaseSafe --summary all
python scripts/install_pet_webp.py
zig build pet-demo -Doptimize=ReleaseSafe -Dpet-libwebp=true --summary all
```

See [performance.md](performance.md) for measured independent hidden
100-process results, reproduction and visual/managed non-claims.
Automatic two-child mixed WebP preflight belongs to the required
Zig regression desktop lane; the separate Actions benchmark is manual
independent-hidden only. Visible and actual host-managed stress run on
a real desktop. WIC mixed diagnosis remains possible using the local
harness with a WIC build, not a separate automatic workflow/profile.

Optional approved test assets: `python scripts/fetch_pet_test_asset.py --pet hoodie-cat`
fetches the pinned data-only atlas/outfits and adjacent MIT notice.
See [fixture documentation](../tests/companion/assets/hoodie-cat/README.md).
Verify exact asset authorization and provenance; do not bundle real
artwork automatically. Prefer synthetic fixtures for CI.

No new renderer backend, experimental command surface or product scope
is needed to complete D. Preserve regression tests and historical
evidence; retire only verified obsolete execution paths.
