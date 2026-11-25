# Pulse 桌宠管理器 / Companion Manager

Status: UI design and worker-side admission model only. No settings page has
been registered and the native host remains single-child. Do not present a
mockup as real host acceptance.

## SDK boundary

The pinned Pulse v1.0.60 SDK exposes pulse.settings.pages V1
([header](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/sdk/native/include/pulse/settings_pages.h)).
One settings page per package session; create copies title/tree; query obtains
page-scoped ui.model/events; remove invalidates IDs and subscriptions. All UI
calls belong to the UI thread. Query table size/version and each callback;
if unavailable, expose a normal native workspace panel command instead.
Current host 1.0.61 must be tested, not inferred from the published header.
The pinned ui.model V1 supports grids, groups, tabs, virtual lists, data tables,
buttons, switches and sliders, but no explicit image node. Use text/glyph
cards first; real preview images need an approved host drawing/resource
capability and real-host testing. No external WebView or arbitrary HTML.

## Settings > 桌宠管理

One page with three tabs, native theme and DPI:
- 素材库: bounded paginated cards (thumbnail when supported, name, author,
  license, version, compatibility, installed size, active count); import
  local OpenPets folder or verified archive, start, default settings,
  reveal source, remove. No network request or executable code from assets.
- 运行管理: task-manager table, stable instance ID, asset name, lifecycle,
  visibility (unknown unless acknowledged), PID as diagnostic only, private
  bytes, working set, sampled CPU, handles, uptime, error status. Sort by
  measured fields and retain selection by stable instance ID. Start another,
  stop, hide/show, instance settings; disable unsupported controls. No arbitrary
  PID kill. Distinguish starting/stopping from running, unknown from zero.
- 全局设置: enabled, auto-start allowlist, configured count/commit budget,
  reduced motion, visibility policy, startup batching, shutdown policy.
  Show actual consumption separately from reserved ceilings. Do not imply
  budget reserves physical RAM. Use native confirmation for destructive actions.

Default settings belong to assets; per-instance overrides belong to a
separate stable persistent profile. Ephemeral process IDs and metrics are
not persisted. Closing settings never stops pets; disabling/unloading the
package or exiting Pulse drains owned children before destroying callbacks.
No restart loops by default.

## Ownership and commands

UI thread renders copied revisioned snapshots; commands carry stable IDs,
not row indices or PIDs. Worker validates commands, owns catalog/instance
records, supervisor handles and budgets. One owner serializes transitions.
Only mark readiness when the child protocol provides positive evidence;
process creation alone is not ready. Hold budget and asset pins from
admission until confirmed no child exists. A timeout/termination request
does not release them. Reject stale commands, report errors, bound queue
and snapshot sizes. Cancel queued work and drain before plugin unload.

pet_manager.zig now provides fixed 1024-slot admission and snapshots using
the existing runtime Budget, per-instance 128 MiB conservative reservations
matching the supervisor's current OS limit, non-reused session IDs, pending
start/stop lifecycle and asset removal guards. Callers must confirmGone only
on positive evidence. No process-wide manager or new supervisor wiring yet.
No new allocation or UI code in this model. The 1024-slot hard ceiling is not a
recommended default; the configured count and total budget are explicit.
The current single-child supervisor remains unchanged. A future integration
must use owned process/job handles, retain pending-exit ownership after
abandonment, and test the aggregate limit before removing singleton admission.

## Import and removal

Stage into a private same-volume directory; validate archive paths, sizes,
file count, formats, content digest and package metadata; reject links,
reparse points and executable content. Atomically publish on success.
Never overwrite existing source or silently delete external user directories.
Removing a library item with active or pending instances must fail or
explicitly stop them and wait for confirmed exit. Distinguish unlinking an
external source from deleting an owned managed copy. Persist atomically
and recover interrupted operations without losing original assets.
Thumbnail decode must run on worker with bounded cache and byte budget;
decode only visible pages; no full atlas per card or permanent animation.

## Verification sequence

1. Unit tests for reservation, duplicate asset instances, stale IDs, late
   readiness, stop/exit ordering, missing metrics and deletion guard.
2. Native supervisor group and confirmed-exit failure injection, then actual
   multi-child launch/stop and per-child state isolation; avoid unbounded waits.
3. Catalog persistence/import/removal tests (including rollback).
4. Settings page ABI adapter and host acceptance: render/open/close, tab
   switching, command callbacks, theme/DPI, long list, uninstall/unload.
5. Resource sampling and real thumbnails; 1/10/50/100 instance tests, varied
   art, visible windows, long duration and churn; report actual versus reserved.

Latest scratch-routed run 45563839194 passed 100 mixed and 100 synthetic
children. Mixed heap peak max 15,932,243 bytes, V1 peak 13,056,823,
zero budget denials, all 100 drained. Run 45564689293 passed the native
job memory-limit regression. These are independent-process benchmarks,
not proof that the settings manager currently runs multiple pets.

## Native group checkpoint

The native supervisor now exposes an experimental worker-serialized group
API in pet_supervisor_win32.h. A process may own either the legacy singleton
or one group, not both. Up to 1024 slots; configured count and total committed
ceiling are checked before creation. Reuse the existing job creation,
private state channel, memory limits and executable pinning. The caller must
still independently verify executable digest and root ACLs. No shared
registry writes in the group until per-instance persistence exists.

Cooperative stop and force requests are nonblocking and keep ownership.
Only a signaled process handle and successful exit-code query allow reap.
An ambiguous partial-start cleanup retains job/process/stop and a nonzero
ID even on error. Close rejects nonempty groups. The native limit is a
defensive backstop; the Zig manager is not yet connected to it. IDs are
group-session scoped; UI adapters must discard stale sessions. No readiness
acknowledgment, asset-path launch, process sampling or settings page wiring
in this change. Native regression adds two simultaneous controlled fixture
children, budget denial, singleton exclusion, independent state, stop
without early release, force isolation, stale ID rejection and confirmed
reap. Local Windows execution is unavailable; CI must verify these cases.
Previous manager model Ubuntu regression passed; Windows was in progress
when checked. Prior full regression and stress runs at 17a5642 passed.

## Capacity revision: 1024

The hard ceiling is now 1024; actual admission remains bounded by configured count and commit budget. At 128 MiB per child, 1024 reservations total 128 GiB, not preallocated physical memory. Automatic stress remains 100 actual independent processes. A thousand live processes require explicit capacity preflight, bounded ramp-up/shutdown and GUI resource monitoring. Unit tests cover 1024 logical reservations, paging, stale IDs and full release; native test opens 1024 slots but launches two real fixture children under a two-child budget. Use paged copied snapshots (e.g. 32 rows), not 1024 separate control trees. Native storage should remain off small worker stacks. UI and Zig/native adapter are not wired yet. Previous run 45565745997 passed; new code awaits CI.

## Configuration range and resource warnings

The user requested signed int maximum as the configuration upper bound.
Accept 1..2147483647 in both Zig and native interfaces; do not allocate a
table of that size. Current fixed backend remains 1024 slots. Report the
configured limit, storage ceiling, committed budget, effective admission
limit and actual measurements separately. Distinct admission errors:
configured count reached, backend storage exhausted, committed quota
insufficient, system physical/commit headroom insufficient. No silent clamp
of the saved count. The native start checks GlobalMemoryStatusEx before
creation, requiring 512 MiB headroom plus the 128 MiB child ceiling in both
available physical and available commit estimates. This provisional guard
is not an OS-wide reservation and cannot prevent races with other apps.
OS errors remain distinct. Pending stop slots still count. UI should show
a clear warning and allow lower counts or stopping owned instances, not
offer an unsafe bypass. Actual dynamic storage, GUI resource guard and
UI wiring remain future work; 1024 live processes have not been tested.
The normal CI stress count remains 100. Native tests exercise INT_MAX
configuration, overrange rejection, synthetic low-memory readings and
actual budget denial; Zig tests exercise INT_MAX without oversized tables.

## Worker adapter and resource samples

companion_group.zig connects the logical manager to the native supervisor
with independently generated IDs and retained ambiguous-start ownership.
Open validates native storage size; caller owns a stable-address group.
Native creation failure without a retained ID releases the reservation;
ambiguous failure returns a live logical ID plus error for stop/reap.
Reap releases only after confirmed native exit. Native samples use owned
handles, not reopened PIDs: private bytes, working set, handle count,
diagnostic PID, cumulative CPU ticks and monotonic time. First/failed
samples have unknown CPU; subsequent same-PID monotonic samples derive
percent of one logical core (can exceed 100%). No readiness acknowledgment
yet, so creation/sample does not claim running/rendered. No asset-path
launch, settings page, resource polling timer or dynamic capacity here.
Added model CPU/binding tests, native two-process sampling assertions
and actual demo Zig group test. Windows CI remains required.

## CI cost and refresh checkpoint

Supersedes the earlier automatic dual 100-process stress trigger. Routine
manager/host/UI changes run the scope-classified regression (including
native two-child fixture and approved child adapter tests); changes to
the codec, allocator, render runtime or common build inputs automatically
run only the mixed two-child five-second decoder preflight. Full 100-child
stress is explicit workflow_dispatch, with the existing selectable profiles,
count and duration. Before release or substantive performance changes,
run synthetic-hidden and mixed-hidden manually; visible mode remains a
separate desktop validation. A skipped stress benchmark is not a pass.
The companion_group.zig path is explicitly classified as companion.
CI/classifier modifications themselves require full regression.

Group.refresh(id) is a worker-side poll primitive: check exit/reap first,
then sample; a sample racing exit retries reap, other errors propagate.
It does not equate process existence with rendered readiness. No automatic
timer, readiness channel, asset launch or real settings page in this change.

## First-frame readiness checkpoint

The private supervisor channel adds one unnamed manual-reset event, inherited
with EVENT_MODIFY_STATE only. Parent retains the wait handle. Child signals
once after successful first presentation (and visible show where applicable),
with resource tracking and cleanup. No signal on startup failure. Group polls
without blocking, marks ready only on acknowledgment, and retains stopping
state on late signals. This is not continuous visibility or render health.
Native tests check signal-only child permission, unsignaled controlled child,
and actual hidden demo acknowledgment. The Zig smoke test now sends testing
reaction required by the demo. Correct quoted PowerShell -M arguments: prior
Windows group test failed at argument parsing, not a completed runtime test.
The new two-child codec preflight run 45568884661 passed. No full benchmark
was run by that workflow. New Windows tests and ABI changes require CI.

## Catalog search and tags

pet_catalog.zig is a bounded, caller-storage-owned catalog model. Local tags,
favorite flag and search are independent of upstream package files. Search
matches all whitespace-separated terms across name, source ID and tags;
explicit tag filters support ALL/ANY, favorites and format. UTF-8 Chinese
substring matching and ASCII case-insensitive matching are supported; full
Unicode normalization/casefold, pinyin, aliases and author indexing are not
implemented. 16 tags per entry, 64 UTF-8 bytes each, 256-byte search query.
Stable asset IDs and paged matching IDs avoid UI pointers or full list
rendering. Validated metadata now retains the display name; no second JSON
parse. No persistent catalog/import/delete or actual host page yet.

Fix readiness regression from Windows run 45569661110: five tracked IPC
resources are needed (four inherited handles plus mapped state view), not
four. Adjusted the shared quota and quota boundary test, not the child
committed-memory limit. The actual demo readiness and group test still
need CI rerun. Keep heavy stress manual.

## Local preferences and automatic properties

Added bounded PCT1 versioned binary preference encode/decode for each asset,
including stable local asset ID, source ID, favorite flag and tags. Decoder
stages before replacing preferences; truncated, malformed, mismatched and
unknown-version records leave existing state unchanged. Name, source metadata
and derived properties are not overwritten by saved preferences. This is a
serialization seam, not disk persistence: atomic durable inventory writes,
private root ownership and crash recovery remain to implement. Derived
properties are activities, outfits, scheduled outfits and V2 gaze layout;
layout is a metadata capability, not a guarantee of current eye tracking.
Catalog removal checks the existing instance manager and removes only the
record after all starts/stops for the asset have been confirmed gone. No
source file deletion or ID allocator yet. Fixed the obsolete Zig array
repetition syntax from failed run 45570423680 using a typed @splat array.
New tests cover round trip, every truncation prefix, wrong ID, small output,
feature filtering and removal guards. CI remains required.

## Durable per-asset preference files

Windows adapter stores PCT1 records under an approved private local root,
using numeric stable IDs, bounded file sizes, exclusive pending files,
flush, then same-volume replacement. Prior records are validated before
replacement; invalid or unknown versions are not overwritten. A pending
file left by a crash blocks saving and is not silently deleted. This is
not a full power-loss transaction guarantee. The root ACL and serialized
ownership remain caller responsibilities. The source asset directory is
not accessed by these operations. Actual persistent inventory/ID allocation,
import and root setup/recovery are still pending. Windows CI adds an isolated
real-file round trip/replacement/corrupt-record preservation test. Prior
Ubuntu run 45570692091 passed; Windows was still running at check time.

## Selected Classic package launch

Added typed group startPackage / pet_group_start_package. The worker supplies
an approved executable, catalog local ID and source ID, and validated local
private directory (not a raw argument string). Native validates DOS path and
source ID, appends quoted package directory and restricted ID. Child accepts
managed package plus state/ready channels, rejects shared registry writes,
and reuses existing package inventory, metadata, pinned-file, decoder and
first-frame checks. Wrong package ID exits without readiness; confirmed exit
returns its reservation. The static mixed preflight adds one real supervised
package start/ready/reaction/stop test and wrong-ID rejection, without heavy
stress. Group's catalog-to-private-path resolver, import and persistent
inventory remain pending. Host-directed reaction still takes precedence over
idle custom activities. Full Windows GUI acceptance and new CI pending.
Prior regression 45570692091 passed both platforms.

## Managed inventory checkpoint

PCI1 durable inventory records stable local IDs, monotonic next ID, and
validated source IDs only. Managed directories use pet-<16 hex digits> under
the approved asset root; no arbitrary path from preferences or UI. Current
inventory capacity is 512 records (independent of active instance ceiling);
no preallocated decoded assets. Reserve and save high-water mark before
creating a directory, then validate and publish after staging; deletion
does not decrement next ID. The worker must serialize this sequence and
check active pins before removal. No directory copying or recovery of
orphaned staging files in this change. Same bounded native atomic replacement
as PCT1; corrupt inventory blocks saving. Save rejects next-ID rollback.
Group.startManaged matches catalog ID/source against inventory before deriving
the path. Actual source import and startup reconstruction still pending.
Added portable codec tests and real-file high-water mark reload test.
Previous selected-package regression 45572503915 and mixed preflight
45572503975 passed. New change awaits CI.

## SHA-256 asset fingerprints

Keep stable u64 local IDs for preferences and live instances, add full
SHA-256 content identity (32 binary bytes, 64 lowercase hex digits).
Fingerprint v1 frames sorted canonical relative paths, file lengths and
per-file SHA-256, including raw pet.json and base/variant/activity files.
Identical byte inventory gives identical fingerprint regardless of order;
metadata byte changes also change identity. Bounded streaming file helper
requires caller-pinned file handles, not a path-based security guarantee.
PCI2 preserves optional digest and rejects duplicate verified content;
PCI1 reads as unknown fingerprint, with no invented hashes. Verified import
must use publishVerified; legacy publish remains unverified. A pending
reservation is consumed once and is not resurrected after restart or delete.
No full import integration or launch-time digest verification yet; digest
alone is not publisher authentication. The native inventory size cap 65536
still accommodates 512 PCI2 records (54,288 bytes maximum).
Added canonical digest, streaming SHA vector, duplicates, migration and
reservation tests. Latest CI pending.
