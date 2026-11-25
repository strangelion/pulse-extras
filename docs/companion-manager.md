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

## Real package fingerprint and managed launch verification

The package validator now hashes its already-read, pinned, validated bytes
on demand, using the same canonical SHA-256 algorithm as the inventory.
--fingerprint-package DIR ID emits a single machine-readable digest after
successful metadata/inventory/header validation; no full image decode is
claimed. --expected-sha256 checks the digest before renderer startup.
Group.startManaged requires a stored digest and passes it via typed native
launch; mismatch exits without readiness. Legacy explicit package launch
remains available for experimental tests. No extra image buffer or reread
for hashing, bounded file descriptors on stack. The digest covers runtime
package files, not arbitrary root extras. Test uses independent Python
hashlib framing, successful expected digest and modified metadata rejection.
No import copy/transaction, root ACL provisioning or legacy migration UI yet.
Latest Windows regression and mixed preflight pending.

## Exclusive staged package copy

The approved helper now accepts --fingerprint-package SOURCE ID
--expected-sha256 DIGEST --stage-root PRIVATE_ROOT ID_HEX. It verifies the
source digest, keeps metadata and declared assets pinned, copies only those
files through a 16 KiB buffer to an exclusive pet-<id>.pending directory,
flushes each file, releases source pins, opens the copy with the normal
validator and verifies the digest again. Only then close copy handles and
rename to pet-<id> without replacement. Source files are never written.
A failed or interrupted copy may retain a pending directory; no recursive
blind deletion or overwrite. Root ACL approval remains required. Header
validation is not a full image decode. The catalog transaction must reserve
and persist the high-water mark before invoking this helper, validate its
exit/output, then publish/save the inventory; not wired in this commit.
Windows package smoke now exercises real staging, byte equality and
existing target rejection. Previous SHA inventory regression passed; new
native staging tests and prior fingerprint integration await CI.

## Import transaction coordinator

The worker coordinator probes a validated source digest, returns existing
ID on a duplicate before any writes, reserves/persists the high-water
mark, invokes the staged-copy helper, then publishes and persists the
inventory. The Windows store adapter binds this to actual inventory writes;
the typed helper uses the approved Runner with Windows job policy, explicit
environment, bounded output and timeout, checks exact machine output and
clean exit. Any ambiguous reservation-save, staging or commit error latches
a recovery fault and ID; partial imports remain invisible in memory and
no retry occurs without recovery. If the final write succeeded but reported
an error, disk reload is required to resolve ambiguity. No automatic orphan
adoption/deletion or root initialization. Native store test uses fake stage;
actual staging is tested separately. End-to-end real-helper transaction and
UI remain pending. Fixed independent Python SHA reference: use actual NUL
rather than four literal escape characters. Both Windows regressions
45575428171 and 45576460968 stopped at this assertion before staging test.
Both mixed preflights and Linux regressions passed. Latest CI pending.

## Independent dual digests

Use SHA-256 + SHA-512 independently over each validated file, then the
same canonical framing with algorithm-specific domain separators. PCI3
stores 32+64 bytes; SHA-256 remains compatible with old primary values.
A matching primary with a different secondary is a distinct asset, not
a duplicate; matching pairs deduplicate. PCI1/PCI2 lack the second digest
and are not silently trusted for managed launch or matching-primary
imports. Explicit migration/revalidation UI remains pending. V2 helper
protocol uses 64 hex + colon + 128 hex; legacy V1 diagnostics still work.
Both fingerprints are verified on staged copy and managed launch. No MD5
and no claim of collision impossibility; byte-for-byte duplicate comparison
is not implemented. Added injected primary collision and independent Python
SHA-512 reference tests. Inventory bound increases to 131072 native bytes
(512 records); no extra image allocation, both hash the same input bytes.
Latest CI pending.

## Public OpenPets market (V3)

Protocol boundary pet_market.zig follows https://docs.openpets.dev/catalog/
and OpenPetsHQ/openpets packages/pet-format/src/catalog-validation.ts.
V3 index and paged entries parsed with bounded response size and caller-owned
scratch budget. URLs restricted to official HTTPS catalog, preview and pet
ZIP origins/paths; no arbitrary URLs or plugin archives. V1/V2 metadata,
category, curated flags, base and optional full package URLs are retained.
SVG and entries declaring a minimum upstream version are conservatively
non-installable until explicit capability mapping. No remote download or
networking yet: require TLS, no redirects, size/time quotas, lazy caching,
validated ZIP extraction, origin/attribution metadata and the existing
SHA-256/SHA-512 import transaction before exposing install. Never assume
all public pets are freely redistributable; show source and license where
provided, do not bundle third-party art. Search-index protocol, live fixture
verification, UI and network transport remain pending. No plugins or private
Teams/Studio accounts in scope. Portable tests cover URL and page validation.

## Windows import regression triage

Runs 45575428171 and 45576460968 failed the Python SHA-256 reference
assertion (fixed in 4302d68). Runs 45577858134 and 45578997179 progressed
to stage-publish but failed MoveFileExW. All four Ubuntu jobs succeeded;
the Windows codec probe alone did not exercise staged import. The target
parent previously used the same read-only sharing as immutable package
files. Allow write sharing on that parent only, still disallow delete
sharing and retain normalized-path checks. Keep same-volume non-replacing
MoveFileExW with write-through; add exact Win32 failure code to logs.
This is a targeted sharing hypothesis, not a confirmed root cause until
Windows CI passes. Existing source handles keep read-only sharing. Add
real package smoke to automatic runtime preflight before sampling, and
check an occupied pending directory's sentinel is preserved. No tests
skipped and no heavy benchmark added. Latest regression awaits CI.

## Confirmed green and real import integration

Commit e3e02eb passed full Windows and Ubuntu regression (45580004636)
and the updated lightweight Windows import/codec preflight (45580004653).
No checks weakened. Add an explicit Windows test-companion-import build
step, invoked after the normal standalone build in CI, using an original
fully encoded fixture and the actual approved executable/Runner, native
store, coordinator and dual digest. Verify import, persisted ID and digest,
reloaded duplicate, actual final/source fingerprint, preference save/reload
and runner drain. Isolated test cleanup is limited to known filenames.
New integration is not yet verified by CI. The real Pulse page, recovery
and online market transport are still separate pending work.

## Classic ZIP admission plan

Upstream path contract checked in OpenPetsHQ/openpets packages/pet-format/src/node/paths.ts
and node/archive.ts. pet_zip.zig reads pinned archive ranges (not the
whole archive) and produces a bounded normalized extraction plan, accepting
flat or one safe wrapper directory, stored/deflate ZIP32 and data descriptors.
Limits: 320 MiB archive/aggregate output, 290 files + 3 directory entries,
128 KiB metadata, 16 MiB WebP, 2 MiB activity strip and 16 MiB aggregate
activities. Strict initial policy rejects archive/entry comments, ZIP64,
unknown extra fields, encrypted or special entries, traversal, reserved DOS
names, mixed layout, duplicates, hidden/overlapping local ranges and
local/central disagreement. Does NOT decompress, verify CRC of payloads,
create files or import ZIPs yet. The next extractor must use this plan,
actual output bounds and CRC; keep archive pinned. Portable file-backed
and malformed metadata tests added. Real upstream ZIP fixture verification
still pending. Previous af52c35 actual helper/durable import CI step passed
Windows; remaining checks in progress at time of this change.

## Bounded ZIP payload extraction

pet_zip.zig now exposes extractFile for an already approved private scratch
root and pinned archive file. Reinspect archive before exclusive creation of
unpacked; extract only normalized admitted paths, using a positional range
reader per entry and Zig standard raw Deflate with a fixed history window.
Stored and deflated payloads are streamed through 16 KiB chunks; exact
uncompressed length, CRC32 and compressed-range exhaustion are required.
No extra output byte is written, even if size metadata is false. Empty
compressed directory records are validated too. Existing staging is never
reused, and failed staging remains unpublished for explicit cleanup. No
recursive deletion, no user source mutation, no full archive allocation.
This is a low-level staging API: caller must provide private ACL/root,
archive pin, worker lifecycle and subsequent validated import; no live
market download, crash recovery or full end-to-end ZIP import yet.
Added real file-backed extraction and raw Deflate/CRC/size/suffix tests.
Previous af52c35 full regression and stress passed; 419a106 Ubuntu passed
and Windows still running when this change started. Latest CI pending.

## CI lane split and pinned ZIP API repair

3906930 passed formatting but failed compiling pet_zip.zig on both platforms:
Io.Dir.makeDir is not available in pinned Zig 0.17.1. Use createDir with
.default_dir; exclusive creation remains mandatory. No toolchain change.
CI regression now runs general Windows/Linux checks and a separate Windows
companion matrix (ipc and desktop) in parallel, preserving every existing
native test and the SDK/DLL build checks. The desktop lane builds its own
helper rather than trusting an artifact from another lane. Fast standalone
ZIP regression precedes the broader unit suite. Existing Regression gate
requires both general and native matrix results on companion/full changes;
docs and VCS retain explicit skip semantics. Classify the catalog store
and real import integration adapters as companion paths. Workflow edits
trigger full CI; automatic codec preflight and manual heavy benchmarks
remain separate. Actual latency and the repaired ZIP tests await CI.

## Performance evidence

See [performance.md](performance.md) for verified full 100-process synthetic
and mixed profiles, exact raw units, historical CI sources, resource budget
semantics and remaining host capacity/soak tests. Keep measurements scoped
to their commit and workload; neither 1024 backend slots nor the signed
configuration range is a measured live-process capacity.

## Bounded market transfer backend

The previous full regression 45584837927 passed on all parallel lanes.
Add a worker-owned WinHTTP HTTPS GET adapter for the official V3 index,
page/search JSON, raster previews and pet ZIPs. Default certificate checks,
fixed origins/paths, no redirects/cookies/automatic authentication, no HTTP
content compression, status 200, bounded response headers/body, exact
Content-Length when present, and 16 KiB chunks into the existing exclusive
temporary store. Use OS automatic proxy policy. Resolve/connect/send/receive
timeouts and a cooperative 120-second deadline checked between synchronous
calls; not a hard deadline or immediate in-flight cancellation. Record OS
network error code, do not log URLs containing credentials (not accepted).
A sealed store file is borrowed for positional reads; the owner must outlive
readers. Failed writes poison the entry; failure removes owned temporary
files or reports cleanup failure. Pool admission is serialized and reserves
worst-case request bytes: 4 ZIP and 4 preview workers by default (1..8
configurable each), one catalog request, shared 2 GiB disk reservation budget.
Release only after worker join and cleanup; extraction needs its own disk
reservation. No actual thread scheduler, bandwidth limiter, cache, retries,
range requests, production ACL initialization or download-to-import UI yet.
Tests exercise fake streaming body, cleanup, cancellation, quota, stale
leases and native URL parity/pre-cancel without internet. Windows integration
build links real WinHTTP; actual external TLS/download validation is pending.
New code awaits CI; do not claim live market works yet.

## Parallel market download workers

Use a stable-address dispatcher owner with up to 17 slots (8 ZIP, 8 raster,
1 catalog), shared Group running quota and existing per-kind Pool leases.
Each request copies its URL, runs via std.Io.concurrent and owns its own
transport, atomic progress/cancel flags and temporary Store. Monotonic
lease IDs name exclusive files in the approved scratch root; no worker
shares a mutable Store. Backpressure returns to the caller instead of
launching unbounded jobs or running inline. Join returns the real result;
release is separate and requires all file readers to have stopped. Stop
rejects new tasks, cancels active ones, joins every future and attempts
cleanup. Retain leases on cleanup failure; distinguish native transport
cleanup failure from recoverable file cleanup. The WinHTTP specialization
is available as Downloads. Tests use real concurrent futures and isolated
files with fake network bodies; no live external transfer or throughput
claim. This is a bounded active-task dispatcher, not yet a persistent FIFO
queue, bandwidth limiter or user-facing task manager. The external UI must
never block on join/shutdown. Production root approval and end-to-end market
installation remain pending. Prior Ubuntu regression passed and prior
Windows native adapter/codec preflight passed; latest Windows CI was still
running when work started. New code awaits pinned formatting and CI.

## Owned archive-to-inventory integration

The previous WinHTTP regression 45587907507 passed. Add a tracked ZIP Stage
that records only files/directories exclusively created by this operation,
including partially written files. Cleanup removes only recorded files and
empty owned directories, retains failed ownership for retry, and refuses
an existing unpacked subtree. Add a serialized Windows Install adapter
for a sealed download result and approved scratch directory/path. It
reserves worst-case 640 MiB for unpacked data and a second package copy
until cleanup, separate from archive/download reservation; persistent
asset disk quota is not implemented. The caller must provide the same
budget and matching private scratch handle/path for cleanup. Test with a
real Python-generated Deflate ZIP from the existing WebP fixture, actual
concurrent download dispatcher using controlled fixture bytes, actual ZIP
extraction, approved helper, persisted dual digest, reloaded inventory and
duplicate detection. No external network is required. Add unknown-file
cleanup and preexisting-directory tests. Live HTTPS end-to-end and UI,
production root ACL provisioning, crash recovery and persistent asset
quota remain pending. New code awaits CI.

## V3 lightweight search

Implement search index/page validation from OpenPets catalog-validation.ts
and catalog-v3.ts. Require matching root revision/total, bounded page sizes,
exact final page length, safe distinct URLs and valid detail-page references.
Search one page at a time with a caller-bounded allocator; Scan owns only
seen IDs and at most 128 copied result rows per requested window. Reject
cross-page duplicates and incomplete scans before publishing results.
Default curated filter (original or featured), optional category/version,
original/featured and ASCII-insensitive multi-term search with exact UTF-8
matching for non-ASCII text. Explicit ID lookup includes non-curated assets.
Re-resolve selected hit against its detail page; no download URL comes
from a search row. Full Unicode folding, persisted cache, live network
or UI wiring not yet implemented. Callers must retain the same validated
root/index for all page fetches and discard provisional rows on failure.
Tests exercise cross-page selection, duplicate IDs and revision mismatch.
Previous full parallel-download regression and lightweight stress passed;
archive-install regression still in progress. New search code awaits CI.

## Persistent bounded market JSON cache

Reuse the Windows private-root atomic record store for a separate disposable
cache namespace. Reserve root slot 0 plus 31 direct-mapped revision/URL
slots and a single exclusive pending file. Each record is capped at 4 MiB
JSON + 2164 bytes envelope (worst case 33 records including pending,
about 132.07 MiB, excluding filesystem overhead). Collisions evict a cache
slot, never return another key's bytes. Record exact generation, URL,
UTC fetch timestamp and SHA-256 of header/key/body. Cache payload is
revalidated through the same typed market parsers on read and write.
Root freshness 15 minutes, versioned page freshness 24 hours; explicit
offline stale read up to seven days, no future timestamps. Unknown or
corrupt records report errors rather than successful cache hits. A stale
pending file blocks writes pending explicit recovery; do not delete unknown
files. No arbitrary filename, recursive scan, archive or thumbnail cache.
Fixed-slot collisions can cause misses; this is not a complete offline
catalog guarantee. The approved cache root and UTC clock are provided by
the caller, actual request/cache orchestration and UI are still pending.
Add portable codec and Windows durable reload/expiry tests. Prior archive
installation full regression and stress passed; search regression general
checks passed and desktop integration was still running. New CI pending.

## Worker-facing market service

Connect typed requests to the persistent cache, bounded concurrent download
owner, search scan and selected-package admission. Fresh cache first;
explicit offline-only mode never contacts the network, and optional stale
fallback is restricted to NetworkFailed. Do not hide corruption, protocol,
cancel, admission or cleanup errors. Cache payloads are read into a
caller-budgeted bounded buffer; release the download lease before cache
publication. The root and search result carry a revision/freshness token;
rehydrate the selected ID on its detail page and reject stale/offline
install selection. Package admission returns a task ID for the existing
join and Install adapter; it does not auto-publish. Test uses actual
Windows cache, concurrent task lifecycle and synthetic V3 responses,
including cache-only root read, network failure fallback and package
admission. The caller must serialize the service and retain the same root
for search results; it must not block a UI callback on this service. No
live HTTPS, UI, persistent queue, or in-flight whole-search cancellation
claim yet. Cache reads may fail visibly on a corrupt record or pending
write; recovery remains explicit. New code awaits Windows integration CI.

## Native Companion settings contribution (experimental)

Build a distinct pulse_companion.dll using the pinned Preview 3 SDK. On
activation create a dedicated pulse.settings.pages page, query its scoped
pulse.ui.model, subscribe only to declared navigation/settings commands,
and remove the page on deactivate. If the settings interface is absent,
use an ordinary workspace panel. Never mount a settings page outside the
settings surface. Four native sections: library, running instances, market,
and global preferences. Navigation updates the real tree; disconnected
backend operations are explicitly unavailable, not fake empty lists.
Global download concurrency preference (1..8, default 4) is read/written
with pulse.resources settings_get/settings_set and optimistic versioning.
Only confirmed replies change the saved display; a failed/conflicting
write requires refresh. At most one pending request; cancel on teardown.
Preference is persisted, but does not yet control a live download owner.
No network, helper launch, user directory access or resident worker in
this first DLL. Unit tests cover tree and setting validation; native host
acceptance, package manifest, production root approval and runtime hookup
remain open. The DLL is experimental, not release eligible. No real-host
performance claims. Previous cache regression passed; service regression
was still running when this change started.

## Companion actual DLL ABI acceptance fixture

Add a full-CI Windows loader for the built pulse_companion DLL using the
pinned C headers. Eight load/unload cycles exercise both dedicated settings
and workspace fallback plus partial subscription failure (16 full lifecycle
scenarios and 8 partial activations). Validate scoped page IDs, tree shape,
callback registration, deferred settings replies, versioned writes, conflict
recovery, wrong-operation reply rejection, cancel on stop and a retryable
page-removal error. Ignore settings commands outside the global section;
show default-vs-saved status accurately; never apply an unconfirmed setting.
This is an independent simulated host, not a real Pulse renderer or install
acceptance. No new runtime or OS permissions. CI pending for this change.

## Read-only native library connection

Use the pinned pulse.tasks interface for explicit background inventory reads.
The Windows known-folder API resolves LocalAppData, then only the fixed
PulseExtras-Companion/inventory.pci path. This experimental reader never
creates or writes a root, accepts no UI-supplied path, requires normal
fixed-drive directories/files and rejects aliases, reparse points and
hardlinked inventory files. Decode PCI using the existing strict codec;
show stable local IDs, source IDs and presence of both digest records (not
proof of file validity). Display 16 rows per page; click to read, then
check the task result; no automatic refresh yet. Read-only root discovery
is not ACL approval for writes/launch. No thumbnail, metadata name, tags,
import/delete/launch or production root initialization in this change.
Host task owns execution; publish only after terminal/release and acquire
of the worker result. Cancellation is cooperative and host drains its
workers before destroy. CI native import fixture now reads actual persisted
inventory through the reader. Existing DLL ABI fixture updated for new
navigation commands. Previous actual DLL ABI regression passed; new CI pending.

### MSVC cross-build correction

The initial library reader passed explicit shell32/ole32 link dependencies
through the shared Modules import table, breaking all three Windows MSVC
DLL cross-builds on Ubuntu (run 45596177364). Remove those explicit link
requirements from the shared module and integration root. Resolve the two
known-folder APIs only through LoadLibraryExW with SYSTEM32 search policy
on the background worker; release both module references after freeing the
known-folder string, and surface missing symbols or cleanup failure. The
standalone GNU companion's existing system-library dependencies stay intact.
No changes to CI scope, tests, root discovery policy or file write access.

## Native read-only preference filtering

Read per-asset PCT1 records only by stable inventory ID from the same
pinned root, with the same exact size/type/path/link checks and identity
validation in the existing codec. Missing record means default preferences;
corruption fails the scan visibly. Match all terms against source ID and
all tags (ASCII case-insensitive, non-ASCII exact), optional favorites-only.
Read at most 512 preferences on the host worker, cooperatively check cancel
between files. Retain compact result rows (first tag preview and total tag
count, not full preference records), 16 rows per page. Native search state
is copied before starting; explicit read/poll remains. No preference writes
or artwork metadata/thumbnail claim; root ACL initialization still pending.
Tests cover real persisted preferences, second-tag matching, favorite and
no-match filtering, and actual System32 known-folder resolution. New CI
pending. This is read-only, not permission to manage existing user files.

## Private native root admission (Windows)

Add a separate native lease for the future serialized writer. Given the
already approved canonical LocalAppData parent (fixture parent in CI),
create only PulseExtras-Companion using an explicit protected DACL with
one inheritable full-access ACE for the process user and that user as
owner. Reopen and independently verify fixed-drive canonical path, no
reparse point, exact owner and protected ACL. Never rewrite a preexisting
ACL. Hold parent/root without delete sharing and hold a zero-byte,
single-link, non-reparse owner.lock with exclusive sharing for the entire
writer lifetime. Existing unsafe lock or root refuses admission, without
truncation or recursive removal. This serializes cooperating processes;
it does not protect against the same user/admin or hostile ancestors.
The root lease is not yet connected to the host DLL: no production root
created by UI, and caller approval of the parent remains required.
Add native desktop CI test of creation, second-owner rejection, close and
reopen, and preservation of unrelated content in an incompatible existing
root. No production write permissions or release readiness claimed.

## Private-owner preference transactions

Connect the native root lease to a serialized Zig preference writer and
existing durable PCI/PCT store. Re-read inventory identity and preferences
under the held lease before every edit. Compare a content revision token
(presence bit plus SHA-256 of canonical PCT1 bytes); reject stale selection
or version mismatch rather than overwrite. Support explicit favorite value,
add/remove tag and idempotent no-op. Never publish a successful new state
until atomic store write returns success. On write failure fault the owner;
close/reopen and reload before further edits. A content token is not a
monotonic revision and cannot detect ABA. The owner is not yet connected
to the production DLL; approved parent provisioning and a compatible MSVC
backend remain open. Test on a fresh private child with actual ACL lease,
second-owner rejection, stale edit, Unicode tag, reload, and no-op.
No automatic cleanup of user content. New integration CI pending.

## First isolated real-host smoke package

Add a development-only manifest and Windows preparation script that invokes
matching official SDK tooling, captures the host contract and source/binary
hashes, builds the existing MSVC DLL and verifies a local package. Explicit
--launch installs and enables only in a fresh isolated store/profile.
Opt-in lifecycle logs contain fixed event names and terminal status, not
inventory contents. See [manual acceptance](companion-host-smoke.md).
The read-only library still reads the real LocalAppData known-folder path;
the script never seeds, deletes or modifies that inventory. User testing
is now appropriate for rendering/settings/tasks, not process launch or
preference editing. MSVC writer integration remains unresolved; no release
eligibility or real-host result is claimed.

## Real-host feedback: automatic library loading and text refresh

The first user smoke test confirmed native embedded settings rendering.
Market navigation changed its body but retained the previous section title;
manual read/poll was an experimental limitation. Start one bounded read
on activation (and on entering an unloaded library), collect automatically
via the published UI dispatcher and a Windows threadpool timer at 100 ms.
The timer only posts coalesced UI callbacks; task APIs remain UI-thread-only.
Stop/drain the timer and cancel its queued token on terminal collection or
stop, with manual poll fallback if unavailable. No idle timer. Changed text
uses content-derived node identity so a retained text control is recreated;
interactive input/navigation identities remain stable. Search/refresh is
explicit, not a scan on each keystroke. Tests add actual DLL timer/dispatch
collection without touching user data, and changed label IDs. Real host
retest required; no new filesystem writes or process launches.

## Compact native library layout and shared edit token

After the first real-host screenshot, group search/refresh and favorites
in a horizontal toolbar with visible caption and input placeholder. Hide
manual poll except when automatic polling is unavailable; show separate
empty-library/no-match messages and hide pagination for 16 or fewer rows.
Group download preference controls horizontally as well. Use the same
canonical PCT1 content token in read-only result rows and the owner writer
so future edit commands can carry the selected snapshot instead of silently
re-reading a new version for overwrite. Integration test compares the actual
persisted reader token against the writer's shared codec. No new writes or
ACL changes in the DLL. Real-host layout retest and MSVC write integration
remain pending; new CI not yet verified.

## Bounded worker pumping and shutdown admission

The existing native group adapter now provides a round-robin worker tick,
scanning at most 32 physical manager slots per call. It emits copied outcomes
per instance (confirmed exit code or explicit error); empty slots cannot
shift later rows past the cursor. No new timer, thread or allocation is added.
Shutdown closes new launch admission immediately, uses cooperative stop by
default and permits explicit force escalation of owned jobs only. No child
reservation is released on a stop request; confirmed reap remains mandatory.
The caller must keep pumping until remaining reaches zero and report errors;
zero outcomes from a tick do not imply shutdown is complete. The existing
Windows real-child regression exercises polling, launch rejection during
drain, confirmed exit and reopen. This is a worker integration seam, not yet
wired to the MSVC settings DLL, and does not establish real Pulse shutdown
acceptance. The approved executable/root provisioning and unload callback
contract remain prerequisites.

## Pinned helper executable verification

The Zig group now passes its independently approved SHA-256 to the native
supervisor. Hash the already opened, write/delete-sharing-denied image
handle using System32 BCrypt before CreateProcessW, and hold the handle
through creation. A mismatch fails before creating a job or child; the
logical reservation is reclaimed on zero native ID. The existing real-child
adapter regression checks the wrong digest and subsequent successful starts.
Legacy native fixture APIs and singleton remain unchanged. This narrows the
pathname check/use gap, not a guarantee against hostile ancestors, same-user
or admin mutation, or unsafe DLL search paths. Independently approved root
ACLs, packaging, and host worker integration are still required. No new
static link dependency on BCrypt; Windows regression must verify the code.

## Versioned GNU/MSVC runtime bridge

An explicit companion-runtime-bridge build produces a GNU Windows DLL with
one versioned C query export. The caller supplies the table size and storage;
unknown versions and mismatched sizes fail. The Zig group uses the same
manager and admission budget through either its directly linked supervisor
or a copied validated function table. No heap ownership crosses the compiler
boundary. Module lifetime must cover all groups and worker calls. Windows CI
builds an MSVC Zig executable to load the freshly built fixture bridge, reject
unsupported ABI versions, sizes and missing callbacks, and open/drain/close
and reopen the group. This is cross-ABI acceptance, not a production module
loader or real child launch via the host. Production packaging, an independently
approved module/installation root, worker ownership and settings integration
are still required. The default DLL install is unchanged.

## Pinned runtime module owner

The worker-side Runtime Owner accepts an independently approved canonical
installation directory and SHA-256, uses only the fixed bridge DLL name,
and rejects remote drives, reparse/alias paths, hardlinks and oversized
images. It pins the root and read-only image, checks SHA-256 before loading,
restricts dependent DLL search to System32 and rejects preloaded same-name
modules. After validating the versioned table, it opens the existing Group.
Close refuses a nonempty group and releases the module before file/root
handles; cleanup errors retain handles for retry. This is not an ACL approval
authority or protection from malicious same-process code. Caller must keep the
owner at a stable address, serialize calls, and provision a trusted root.
The MSVC fixture now supplies the built bridge digest independently through
CI, checks wrong-digest refusal and successful open/drain/close/reopen. It
never launches real pets. The host DLL still does not create a runtime owner;
production package installation and worker hookup remain pending.

## First live built-in session

A bundled dev package embeds both runtime and helper digests. The Running
page enables an explicit built-in start only after a successful runtime
check. A single host-owned task serializes start, first-frame readiness,
100 ms sampling, and exit. Cancellation stops admission, requests cooperative
exit, escalates after two seconds and waits up to five seconds; emergency job
close is reported as unconfirmed shutdown, never normal successful reap.
The private bridge ABI is now v2 (adds terminal abandon); rebuild both DLLs.
This pilot deliberately limits the session to one built-in pet and reuses
the existing single task slot: library refresh is unavailable during the
session. No managed asset launch or general multi-instance UI yet. Runtime
and helper remain bound to the actual installed package location and embedded
digests. Host task cancellation and final destroy retain the existing SDK
lifetime contract. Real Pulse launch/stop and cleanup need acceptance.

## Bundled live host ABI regression

The Windows desktop lane builds a second MSVC entry DLL with the actual
runtime/helper SHA-256 options, stages the verified binaries beside it and
loads it via the pinned public C ABI fixture. The fixture runs runtime and
session callbacks on a real worker thread and collects UI status through
host dispatch. It checks explicit start, first frame, cooperative stop,
restart, cancellation on deactivate and task completion before destroy.
The ordinary unbundled ABI scenarios remain unchanged. This is a simulated
host using actual DLLs and a real Helper process, not real Pulse UI or
installation acceptance. The new lane must pass before expanding launches.

## Independent runtime and library task slots

The settings attachment now retains separate IDs, completion atomics and
error/result storage for runtime and library operations. A single coalesced
UI dispatcher timer polls both and disarms only after both slots clear.
Navigation or library refresh does not cancel or replace the live runtime
worker; close requests cancellation for both before removing the page.
The bundled ABI fixture additionally switches to the library while a real
built-in helper is running, collects a simulated canceled library read
without touching real user files, then returns to Running and stops the
same session. This is still one live pet per attachment; managed asset
start and multi-instance command admission are not implemented here.

## Bounded multi-instance built-in session

The existing host runtime worker now opens a pilot group of eight instances
with an aggregate 1 GiB committed-memory admission budget (128 MiB reserved
per child, not an allocation or measured working set). Additional built-in
launches use a single atomic pending request, accepted only when all existing
instances are ready and below the pilot limit. The worker rechecks native
admission, keeps existing pets on rolled-back launch refusal, and aggregates
owned/ready counts and sampled memory from the existing manager. A retained
ambiguous launch or supervision failure drains the session. Stop All cancels
the single host task and drains all owned jobs. Pending requests are cleared
on terminal shutdown, not automatically retried. No additional host worker
per pet. Native stable IDs are retained in Group; per-instance UI and managed
asset selection are not connected yet. The bundled fixture now starts a
second real pet in the same task, checks two ready instances, switches to the
library, and stops the entire group. Pilot limit is not the final configured
limit; 100-pet host testing remains separate.

## Per-instance snapshots and targeted stop

The runtime worker publishes bounded copies of the current instance rows
via a nonblocking atomic lock; UI retains its prior copy when publication
is busy. Rows show stable instance ID, state, PID, measured CPU core percent,
working set, private bytes and handle count; absent samples are not zero.
A fixed text input and command accept an explicit instance ID (not a row
index/PID). At most one targeted stop is pending/in progress; the worker
revalidates the ID, cooperatively stops that instance, escalates after two
seconds and requires confirmed reap. A five-second failure drains the group
with explicit diagnostics. Stop All remains available. The bundled fixture
now starts two actual helpers, stops ID 1, verifies ID 2 remains, then stops
all. The pilot limit stays eight. This does not yet authorize managed asset
starts or make the limit configurable.

## Managed asset launch from the library

The library accepts a selected numeric asset ID only if the displayed row
has both fingerprints. The runtime worker independently resolves LocalAppData,
acquires the existing protected private-root ACL/owner lease via a separate
versioned bridge export, rereads inventory.pci and resolves the deterministic
pet directory. The child verifies the exact SHA-256/SHA-512 pair before
readiness; display data is not launch approval. The lease stays owned until
Group shutdown. Existing incompatible ACLs fail closed; no ACL repair or
arbitrary UI path is accepted. Built-in pets use a reserved max-u64 model ID,
separate from managed IDs. A single pending start carries the selected ID.
The UI switches to Running for results. This is not a sandbox against
same-user programs. Managed launch is implemented but full isolated-host
fixture and actual imported asset acceptance are still required.

## Managed launch error handling correction

Allow built-in additions to an already-running verified managed session
without requiring a second runtime-check task. Report bounded rejection
categories in Running instead of just a counter; a native cleanup failure
still drains the group. A nonzero child exit with confirmed reap does not
stop unrelated healthy instances; a failing last child retains the terminal
error. Native supervision failures and unconfirmed stops remain fail-closed.

## Runtime error-path drain and lease ABI regression

All session-loop exits, including unexpected native API errors, now enter the
same bounded cooperative/forced drain before attempting owner close. An
unconfirmed exit still returns a failure; emergency abandonment is not
normal capacity reclamation. The MSVC bridge probe now opens, closes and
reopens a private-root lease through the GNU DLL, using a unique CI-only
parent and cleaning the isolated fixture afterwards. This does not access
actual LocalAppData or prove managed asset launch end to end.

## Managed bridge end-to-end fixture

The Windows bridge probe now performs a second run in its unique isolated
private-root fixture. An independent Python generator writes PCI3 inventory
and SHA-256/SHA-512 package fingerprints for synthetic V1 and V2 (wardrobe)
assets and a deliberately wrong third fingerprint. MSVC opens the verified
GNU runtime, acquires the private lease, rereads the index, rejects an unknown
ID, launches both valid packages using the actual helper and requires both
first-frame acknowledgments with matching asset IDs. The mismatched third
asset must exit nonzero without readiness; the two valid siblings remain
owned. All children drain before lease/module release. This covers the
managed worker/native path but not real Pulse settings UI or actual user
inventory; the generated fixtures remain offline and CI-only.
