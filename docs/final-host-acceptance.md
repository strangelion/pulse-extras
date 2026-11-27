# Final consolidated installed acceptance / 最终集中实机验收

Owner decision 2026-11-26: proceed with development after code/CI gates;
do not request separate local installation for each small milestone. This
register is the entry point for the final installed round; the detailed
feature runbooks remain authoritative. No row is HOST PASS without exact
artifact and observed result.

## Before testing

- Build final affected versions with pinned Zig and SDK; run full regression
  on exact code SHA. Generate and verify official packages. Record SHA-256,
  manifest, host build, SDK/API evidence, Windows build and hardware.
- Use isolated profile/store. Never disable security software, modify the
  daily profile, or reuse test data across incompatible versions without
  backup. Do not publish or sign stable without separate permission.
- Record PASS/FAIL/NOT RUN/UNSUPPORTED by case, including reproducible steps
  and redacted evidence. Owner-accepted implementation is not a measured pass.

## Combined matrix

| Group | Required cases | Current status |
| --- | --- | --- |
| VCS P2A | All onboarding, settings, Git/JJ/SVN, denial/cancellation, native menu/locale/DPI | Code CI pass 4d53927; HOST DEFERRED |
| VCS P2B | Saved projects migration, search/favorites/relink, routing, provider switching, durable grants and individual/all revoke, stale cache, restart and concurrent instances | 147449b full code CI passed; DEV COMPLETE / HOST DEFERRED |
| VCS P3A/P3B | File/history/diff and forge/client integrations; verify offline unsupported cases and local consent scope | P3A full CI pass 378e540 / 45929366805; DEV COMPLETE / HOST DEFERRED. P3B candidate pending exact CI and live external handoff/HTTP acceptance |
| Companion ordinary functionality | Import/download, library, market, runtime, profiles, menu, recovery and lifecycle | Owner-accepted development complete; final host smoke deferred |
| Companion performance | Controlled actual Pulse-managed visible/hidden count ramp 1→1024, stop at safe measured ceiling; CPU/GPU/VRAM/private bytes/working set/handles/frame p50/p95/p99 and startup/stop latency | OPEN |
| Companion long-running | 30 min / 2 h / extended soak; repeated create/stop, asset switching, import/download, hide/show and unload; baseline/peak/steady/post-cleanup memory and handle deltas | OPEN |
| Companion images | Verify 1.0.61 public/local SDK exact layout, supported image type, loading, thumbnails/fallback, DPI, memory and rejection | DEFERRED SDK review |
| Both packages | Install/enable/disable/restart, upgrade/rollback/uninstall, coexistence, cancel/close/exit; no orphan tasks/processes or private data corruption | HOST DEFERRED |

Do not force 1024 real pets when CPU, GPU, memory, handles, responsiveness or
cleanup thresholds fail. Record last safe count and failure reason instead of
fabricating a pass. See [Companion matrix](companion-manager.md#d2-real-host-functional-acceptance-matrix),
[VCS matrix](vcs-acceptance-runbook.md#stage-specific-installed-acceptance-register-mandatory-current-status)
and [release](release.md).

P3B bb362dd / 45930749443 failed VCS settings compilation on both OSes;
Companion desktop lane was blocked by the same production build error.
Consolidated compile repair, local summary dashboard and Windows ABI fixture
require exact full CI. Live client/HTTP and installed UI: NOT RUN.
