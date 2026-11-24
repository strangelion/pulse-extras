# Product scope, reuse and delivery / 产品取舍、复用与快速交付

Status: planning and initial overlap review; not a claim of implemented products,
verified dependency integration or measured market demand. Baseline Pulse public
revision [b324368](https://github.com/jimmgreen/pulse/tree/b32436831a066e18448b2810bef4bf989024fc68).
Before implementing a product, inspect the actual installed host's capabilities,
public SDK, current upstream source/issues and extension registry. The installed
1.0.61 host differs from the published SDK; see host-compatibility.md.

## 1. Do not duplicate Pulse

Pulse already provides directory/workspace layouts, filename/pinyin/content search,
quick preview of common formats, photo wall, tags/aliases/smart views/rules,
batch renaming and AI naming, staged file operations, confirmation/undo, duplicate
detection, folder sizes, metadata directory comparison, text diff, Git status and
pull/push, SVN indicators, archive integration, settings and AI/MCP. Refer to the
[pinned README](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/README.md)
and [SDK](https://github.com/jimmgreen/pulse/tree/b32436831a066e18448b2810bef4bf989024fc68/sdk/native).
Do not duplicate them just to increase package count. Native capabilities are not
automatically available to third-party plugins: if an integration API is missing,
degrade, request upstream support, or drop the feature.

| Product | Smallest useful deliverable | Exclude/defer |
| --- | --- | --- |
| Shared Runtime + VCS | Actual read-only multi-VCS panel, JJ/SVN semantics, history/diff/refs as validated | Duplicate Git badges/pull/push, full Git client before real panel |
| Release | Official pack/verify/sign pipeline with per-extension release selection | Premature production workflow or empty packages |
| Convert | PNG/JPEG batch output via Windows WIC or audited existing engine; preview plan and staging | Reimplement codecs, generic file organizer, overwrite originals |
| Companion (candidate) | Existing pet/event integration or small host-supported character prototype | Full desktop pet platform, generic AI chat, forced always-on animation |
| Inspect | Read-only PE architecture/import/metadata/signature inspection | Execute inspected programs, malware verdicts, common preview duplication |
| Compare | Recursive content verification, snapshot/report | Native one-level metadata compare/text diff, sync/delete by default |
| Data | Bounded SQLite schema/rows, NPY/NPZ metadata as needed | Duplicate CSV/XLSX/JSON/XML/Jupyter preview, arbitrary SQL writes |
| DevKit | Focused project/toolchain inventory and verified environment checks | Full IDE, terminal, general Agent/MCP manager, automatic build/install |
| Forge | Shared authoring templates/components, constrained recipes, validation/maintenance | Generic coding Agent or AI chat, model management, autonomous unreviewed DLL generation |

Prioritize one end-to-end scenario per product and deliver it before expanding
coverage. P1.5/RT0 and P2/RT1 remain first; Release follows actual VCS acceptance.
Convert is the next practical general-user package; Companion is a small feasibility
experiment, not a commitment to a new game engine. Inspect, Compare, Data and DevKit
are demand-driven thereafter. Forge grows out of real components, not speculative
platform abstractions.

## 2. Reference projects and demand evidence

The following are research leads, not selected or audited dependencies. Confirm
current repository, exact revision, license, assets, platform, dependency closure,
maintenance and integration before using any code.

| Area | Reference | What to learn/reuse first |
| --- | --- | --- |
| VCS | [lazygit](https://github.com/jesseduffield/lazygit), [jjui](https://github.com/idursun/jjui) | Status/history layout and CLI semantics; prefer actual Git/JJ/SVN CLIs |
| Convert | [FileConverter](https://github.com/Tichau/FileConverter), [libvips](https://github.com/libvips/libvips), [FFmpeg](https://ffmpeg.org/), Windows WIC | Presets/format mapping, existing codecs/engines; first measure system WIC |
| Inspect | [LIEF](https://github.com/lief-project/LIEF), Windows PE/WinVerifyTrust APIs | Audited parsing or native APIs; no execution of binaries |
| Compare | [WinMerge](https://github.com/WinMerge/winmerge) | Recursive comparison UX and test cases, not copying GPLv2-only code |
| Data | [SQLite](https://github.com/sqlite/sqlite) | Existing read-only engine; bounded scientific metadata parsers |
| Agent | [Pi packages](https://pi.dev/packages), [DSH plugins](https://dshai.org/plugins) | Existing Agent transports/events, MCP adapters, context and workflow capabilities |
| Forge | [Pulse native author MCP](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/tools/extensions/native_author_mcp.py) | Official discovery, package validation, isolated author workflow; supplement Zig |
| Companion | [OpenPets](https://github.com/OpenPetsHQ/openpets), [Clawd on Desk](https://github.com/quanxiuzhifu/clawd-on-desk), [Comi](https://github.com/IvenKooLab/desktop-pet) | Pet formats, animation/event/permission models, existing Agent bridges |

Video/search leads for product discovery: Bilibili and YouTube terms such as
“File Converter 右键批量转换”, “WinMerge 文件夹对比”, “文件管理器 自动整理”,
“DSH 桌宠”, “Codex 桌宠”, “AgentPet”, “desktop companion coding agent”,
“file manager plugin” and “custom file manager panel”. Example leads from prior
research: [File Converter video](https://www.bilibili.com/video/BV13H4weDEp7/),
[WinMerge Excel comparison](https://www.bilibili.com/video/BV1Uu4y1G7MY/),
[AgentPet](https://www.youtube.com/watch?v=de6GcwCpq2g).
Recheck availability and relevance before treating these as evidence. Do not
infer popularity from one video, downloads or stars; no view/comment/user-count
statistics or market validation are claimed here. Observe repeated real tasks,
requests/comments and adoption friction. Compare an actual prototype against
existing tools before deciding to invest.

## 3. Reuse and repository dependencies

Prefer, in order: existing public Pulse capability; OS API; installed mature CLI
or documented IPC/MCP; pinned compatible library; narrowly scoped original code.
Reference designs and fixtures without wholesale source copying. Do not embed
another general coding Agent, Node runtime, browser engine, Electron or game
engine as a mandatory Pulse DLL dependency just to provide a small feature.

Git submodules are commit references (gitlinks), not filesystem symlinks or a
license exception. For source dependencies that genuinely must be built:
use a public upstream URL and exact tested commit under a dedicated third_party/
path, with .gitmodules and a dependency record. Keep upstream history and
license/notice intact. Prefer a reviewed fork only when an actual patch is
needed; submit fixes upstream where practical. Do not point builds at moving
main/master, run automatic submodule updates, or checkout a large dependency
tree for docs-only CI. Optional research clones may live outside the repo or
in the ignored local work directory; never depend on a machine-specific symlink.

Example (illustrative, not a command to run for every reference):
```sh
git submodule add <audited-upstream-url> third_party/<name>
git -C third_party/<name> checkout --detach <verified-commit>
git add .gitmodules third_party/<name>
```
For existing CLI/system tools, discover trusted executable path and supported
version, use structured argv and bounded I/O; no bundling unless explicitly
needed and licensed. For binary dependencies pin origin/version/platform/size/
hash (and signature where available). Fetch only dependencies for selected
product targets; do not alter the working SDK pin or Zig cache mechanism.
If a submodule is required, explicit opt-in checkout for its consumer's build
and test; account for nested dependencies. Do not put private access tokens in
URLs or caches. Record dependency license/SPDX, copyright, exact revision,
source/binary provenance, build options, modifications, notices, corresponding
source requirements, security review and which packages consume it. Update
pins through reviewed changes and full affected-consumer tests, not on every run.

No new submodules are selected by this plan. Add the first real dependency only
when a working product needs it and a minimal integration proves its value.
Reference-only repos are not build dependencies, and no candidate is deemed
license-compatible merely because it is listed above.

## 4. License and distribution policy

Pulse Extras project-level license going forward: AGPL-3.0-only (GNU Affero
General Public License v3). The prior Apache-2.0 text is retained in
LICENSES/Apache-2.0.txt; prior grants are not revoked. Preserve existing copyright,
license and notice obligations, especially for upstream-derived SDK material.
Apply the AGPL to original project work to the extent the maintainers hold the
necessary rights; audit contributor/third-party provenance and obtain any required
permissions before release. Do not relicense a dependency, upstream SDK or
asset solely by changing the root LICENSE.

AGPLv3 and GPLv3 section 13 permit combining covered works under their specified
conditions; it does not convert every GPL dependency into AGPL. Apache-2.0 material
can be used in the compatible direction under GNU v3 terms with required notices.
GPL-2.0-only cannot generally be incorporated into an AGPLv3 combined work without
a compatible exception or permission; GPL-2.0-or-later needs version selection
and review. LGPL, MIT, BSD, MPL, FFmpeg build options, fonts, codecs and assets
require exact-revision/actual distribution review. CLI/IPC/submodule boundaries
alone do not determine whether a combined work exists.

Reference: [AGPLv3](https://www.gnu.org/licenses/agpl-3.0.html),
[GNU compatibility guidance](https://www.gnu.org/licenses/license-compatibility.en.html),
[Git submodules](https://git-scm.com/book/en/v2/Git-Tools-Submodules).
The Apache-licensed Pulse host remains separately maintained. Whether the native
in-process SDK/plugin relationship and registry distribution are acceptable with
AGPL must be confirmed with upstream and, if needed, qualified license review;
do not claim the host has become AGPL or that dynamic loading guarantees separation.

Before distributing binaries, make the complete corresponding source for that
release available under applicable terms, including required build scripts,
dependency sources/pins and notices, and meet AGPL section 13 when applicable
to modified network-interactive programs (including evaluating Forge MCP/service
deployment). Do not assume a private GitHub repository link fulfills recipients'
source-access rights. Do not make the repo public automatically; resolve an
accessible compliant source delivery method before public release. See release.md.

## 5. Companion feasibility (candidate, no implementation)

Goal: a lightweight, optional file-manager companion, not another full desktop
pet simulator. Do not assume most users want pets. Test demand and actual SDK
support first. C0: verify the host's supported native panel/canvas rendering,
context/task events and resource limits; verify an existing external pet's
documented event bridge and asset contract where possible. Prefer an opt-in
connector or small prototype over a new renderer. If no safe host-visible
rendering path exists, use an optional separately approved companion process
or stop; no hooks, private window hacks or assumed global host events.
C1: display one legally licensed local sprite/animation set, idle/active/success/
failure states from actual authorized events, scale, move within supported UI,
hide/pause, offline skin import and safe uninstallation. Map only events available
to the plugin or explicitly shared by other tools through documented interfaces.
No fake task states or automatic permission grants. Cross-plugin event integration
must use an explicit verified boundary, not shared raw memory.
C2: evaluate measured idle CPU, memory, power, asset load, frame time, DPI, theme,
multi-monitor as relevant, disabled/unload cleanup, privacy and user feedback
against existing companions. Stop at connector-only if no differentiation.
Defer feeding/room decoration, complex game economy, custom renderer, AI chat,
voice, memory and arbitrary behavior scripts until real demand. No paid model
call for idle animation, forced sign-in, punitive absence mechanics, keylogging,
unnecessary session/file contents, or always-on high-frequency polling.
Assets need separate licenses; no commercial character packs by default.
Use Shared Runtime for ownership, cancellation and budgets; suspend invisible
animation and load assets on demand. Import data-only bounded validated formats;
no arbitrary code from a pet pack. Forge may later produce compatible validated
recipes, but neither product depends on the other.

## 6. Faster development with less token and CI waste

At task start read roadmap, relevant module contract, current implementation and
actual failing tests; search upstream only for the specific missing API/behavior.
Do not reload the whole repository or reread all documents on each edit. Use
targeted symbol search, exact source spans, cached verified reference revisions
and concise implementation/decision summaries. Keep docs as durable source of
truth; update only affected sections. Do not create AGENTS.md.

A product spike should answer a small set of go/no-go questions: what existing
feature overlaps, which verified API or external engine supplies the missing
capability, license/size/runtime costs, smallest actual host acceptance and
what is not supported. Compare two concrete approaches and select the simpler.
Reuse tested build/test/packaging scripts and Shared Runtime. Avoid repeated
model generation for deterministic transformations, template filling, parsing,
hashing, test setup, dependency installation, ABI/manifest validation or UI
configuration. Use bounded retries with actual compiler diagnostics; no broad
rewrite or repeated blind pushes. Prefer short targeted local tests during
development; full/reduced CI follows testing.md. Never weaken safety/functional
gates just to save time. Cache trusted verified tools; no unnecessary CI
fetches, paid model calls, reference repos or stress runs. Manual depth tests
and exact-source release validation remain required where applicable.

For Forge explicitly compare representative tasks against direct use of Pi/Codex/
DSH: time to usable verified package, model input/output tokens where observable,
number of build/repair iterations, correctness and maintenance/upgrade cost.
Use deterministic test fixtures and the same SDK/requirements; record unknown
metrics instead of fabricating them. If templates/recipes/maintenance offer no
material advantage, keep author tools as DevKit/shared scripts instead of
shipping Forge as a separate product.
