# Unified extension release / 统一增强包发布设计

Status (2026-11-26): **historical unsigned preview releases; current unified signed release workflow**.
[Companion 1.0.0](https://github.com/strangelion/pulse-extras/releases/tag/companion/v1.0.0)
and [VCS 1.0.0](https://github.com/strangelion/pulse-extras/releases/tag/vcs/v1.0.0)
are independent unsigned prereleases targeting df5009c. Local packaging remains
available. Those historical releases do not imply signing, stable release, registry submission or complete actual-host acceptance. Ordinary regression CI does not package or publish.
Use the [stage roadmap](roadmap.md) and batch a complete usable update; do not
publish each tiny implementation change. User-authorized preview testing remains
possible with exact limitations; no automatic publication on stage completion.

## 1. Upstream publication contract

Official [registry contribution guide](https://github.com/jimmgreen/pulse-extensions/blob/main/CONTRIBUTING.md)
and [native package quickstart](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/docs/extensions-sdk-quickstart.md)
define the authoritative format. Recheck them at implementation/release; the reviewed public baseline is
in `sdk/upstream.toml` (initially Pulse 1.0.60 SDK Preview 3, Windows x64 MSVC ABI). Confirm Zig-built packages are acceptable
to the registry maintainer; working on a local host is not registry approval.

Publish a verified .pulse-ext and matching .sig.json to this repository's GitHub Release;
register the publisher public key/fingerprint and extension version metadata via a PR to
jimmgreen/pulse-extensions. Its maintainer verifies and signs the official catalog. Publishing
here does not automatically make the package available in the store.

## 2. Packaging (official tool)

Ordinary regression CI does not package. The separate manual preview workflow can build and package on an ephemeral Windows runner; local packaging remains supported.

Companion bundles a runtime DLL and a helper executable, so the entry DLL must
be compiled against their exact digests; otherwise the panel reports
`未打包运行时；无法启动桌宠` and start stays disabled. Build the bundled
files first, then rebuild the entry with both pins:

    zig build pet-demo -Doptimize=ReleaseSafe
    zig build companion-runtime-bridge -Doptimize=ReleaseSafe
    zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe `
        -Dcompanion-runtime-sha256=<sha256 of pulse_companion_runtime.dll> `
        -Dcompanion-helper-sha256=<sha256 of pulse-pet-demo.exe>

`build.zig` rejects any non-empty digest that is not exactly 64 hex characters,
so a CRLF-contaminated value fails at configure time instead of silently
disabling the pin. `scripts/companion_host_smoke.py` performs the same two-phase
build automatically and records binary evidence.

VCS has no bundled binaries:

    zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe

Then run the product composer (it calls the pinned official author tool, and
refuses a Companion DLL that does not embed the digests of its packaged members):

    python scripts/package_release.py --extension companion --version 0.1.0 \
        --pulse "C:\Program Files\Pulse\pulse.exe" --sdk-root .local/sdk --out dist
    python scripts/package_release.py --extension vcs --version 0.1.0 \
        --pulse "C:\Program Files\Pulse\pulse.exe" --sdk-root .local/sdk --out dist

`--dry-run` prints the plan without resolving the host or tool. Each run requires a
clean tree, records the source revision in `release-evidence.json`, and executes
native-manifest → pack → official verify → digest-bound rename. Output is
`dist/<id>-<version>.pulse-ext`, `release-evidence.json` and `SHA256SUMS.txt`.
The archive is unsigned and unpublished; evidence states `signed: false`,
`published: false` and `real_host_accepted: false`. Registry publication is the
separate manual step in section 1; real-host acceptance remains the gate in
[Companion stage D](companion-manager.md#stage-d-official-testformal-packaging-and-real-host-acceptance).

Composition is declared per product in `extensions/<name>/manifest.release.json`
(official schema, native-free) and its sibling `release.toml` (repository-only
metadata). The release registry discovers explicit descriptors, checks unique keys
and IDs, validates flat artifact names and manifest identity, and selects a
reviewed build profile. No arbitrary commands are accepted from descriptors.
For a new ordinary extension, add its Zig build target/output, formal manifest
and descriptor; no workflow or generic Python changes are needed. Example:
```toml
key = "convert"
id = "strangelion.convert"
manifest = "manifest.release.json"
library = "pulse_convert.dll"
build_profile = "native"
members = []
```
The native profile uses the existing Windows x64 MSVC Zig build; the companion
profile preserves its two digest-bound auxiliary builds. A genuinely new build
profile requires reviewed code. Test/example extensions without descriptors are
not release products. Descriptor digests are bound into release evidence.

## 3. Independent package versions

One monorepo, independent packages and SemVer. Example IDs: strangelion.vcs, strangelion.convert,
strangelion.inspect, strangelion.data, strangelion.devkit, strangelion.compare,
and conditional candidates strangelion.companion and strangelion.forge.
The ABI Probe and Hello Panel remain test/example packages and are not released as products
by default. No placeholder or incomplete extension is publishable.

The authoritative product composition is the discovered per-extension release.toml registry. Each manual preview dispatch supplies its own SemVer for each selected product. A committed release descriptor/changelog remains a future stable-channel improvement; do not duplicate version truth. The pinned official manifest schema rejects a product version field, so product SemVer belongs in release tag, asset name and evidence, not native.version (which is the ABI format version). Tag example:
`vcs/v0.1.0`; asset: `strangelion.vcs-0.1.0.pulse-ext`. Treat published versions/tags as immutable.
Shared library changes may require new versions of affected packages, never a forced version bump
for unaffected ones. Each build records its bundled [Shared Runtime](shared-runtime.md) source/API
revision and relevant hashes alongside Zig/SDK pins. Runtime is linked into independent DLLs,
not a hot-updated global component. For a runtime fix identify all affected released consumers,
rebuild/test/accept and independently release their new versions; older installed packages retain
the old implementation until updated. Verify mixed-version coexistence; no raw allocator or
mutable object sharing across DLLs. Do not create empty descriptors now.

### Local test package versus formal package

The Companion development identity (strangelion.companion-dev) uses the
same official native v2 .pulse-ext format, author tool and hash checks
as the future formal identity. See [Stage D](companion-manager.md#stage-d-official-testformal-packaging-and-real-host-acceptance).
Local test packaging reuses the existing smoke tool; it is not a GitHub
preview release or an implementation of the shared R milestone. Test
and formal packages require separated writable data, verified artifact
identity and distinct acceptance. No production key or tag for test
packages. Formal preview/stable publication channels remain separate.

## 3A. One manually dispatched workflow

Open Actions → Extension release → Run workflow on main. The unified
workflow replaces the separate stable-release workflow, without merging
the protected environments.

| Input | Meaning |
| --- | --- |
| request | Build/preview: product=SemVer pairs; stable: run=123456,host=1.0.61 |
| mode | dry-run (default), draft, publish-preview, draft-stable, publish-stable |
| acceptance_confirmed | Required only for stable; confirm exact installed candidate checks |

Examples: companion=1.1.0,vcs=1.2.0 with dry-run builds numeric stable
candidates; companion=1.1.0-rc.1,vcs=1.2.0-beta.1 with publish-preview
publishes independent prereleases. all=1.1.0 is explicit same-version
selection for dry-run. Preview drafts/publications require a SemVer prerelease
suffix; bare numeric versions are reserved for stable. Existing tags/releases
are never overwritten. Dry-run creates no tag or Release.
All selected packages go through full regression, official package verification
and protected release-signing approval. The signed sidecars are in
extension-release-signatures; exact build bytes are in
extension-release-candidates. Download both for installation testing. The
signing summary lists the candidate run ID and SHA-256 values. Preview
publication independently re-verifies the signatures, attaches publisher and
signature evidence, and publishes only after all selected drafts are checked.
Drafts stay private; publish-preview marks prerelease and never latest.
Failed batches retain existing drafts for review; no automatic deletion.
Stable promotion uses the same workflow, as detailed in section 3C.

## 3B. Public Pulse dependency updates

`sdk/upstream.toml` is the single reviewed lock for public SDK revision, ABI
and preview, header digests and the matching Windows installer filename, byte
size and SHA-256. The installer URL is derived from the official repository
and exact stable tag; the release workflow checks out the exact SDK commit
and verifies downloaded installer bytes before isolated installation.
No release uses an unreviewed "latest" binary. The separate `[host]` section
is the historical local SDK snapshot; a candidate resets `host_verified`
without changing that snapshot.

**Actions → Pulse upstream updates** runs daily (02:37 UTC) and on demand.
It ignores component-pack releases, drafts and prereleases, compares stable
versions numerically, detects in-place tag/asset changes, resolves the new
tag to its commit, and checks official installer digest metadata and SDK
header Git blobs. Changed ABI version, SDK preview, architecture, missing
installer metadata or new/missing C headers block automatic proposals:
inspect the report and adapt the wrappers/header inventory explicitly.
For supported candidates it compares C ABI prefixes and regenerates pinned
Zig bindings with the current compiler. A separate writer creates
`deps/pulse-vX.Y.Z` with only the lock and generated binding, dispatches
**Extension test package**, and opens a review PR. It never
overwrites an existing branch, merges, signs or creates releases.

Candidate compatibility runs full regression and official package verification
for every registered extension on a read-only runner. Its synthetic
`0.0.0-upstream` version is artifact-only and cannot be published by that
workflow. Inspect the run for the candidate commit before merging; the
automated dispatch is necessary because GITHUB_TOKEN-generated pushes and PRs
may not trigger normal CI. If Actions cannot create PRs, enable the repository
setting "Allow GitHub Actions to create and approve pull requests" if
appropriate, or open the already-created branch as a PR manually. Re-run
candidate compatibility on that branch if dispatch failed. The job uses
only narrowly scoped write permissions for branch/PR/dispatch, never runs
candidate code with the write token, and does not auto-approve.
Scheduled runs with no new stable release leave the lock untouched.

Before merging: review SDK/ABI diffs, ensure candidate regression and
all-package checks succeeded, and run the isolated real-host activation,
settings, multi-window and unload checks where the host contract changes.
The ABI prefix check is not a proof of behavioral compatibility. If a
candidate fails, retain the previous pin; delete/close the candidate only
after review. Re-run a candidate after manually updating bindings or adding
a new SDK header. After merge, future manually dispatched releases
automatically use the new reviewed installer and SDK without YAML changes.

Reserved future gates (not enabled or claimed): upstream Authenticode or
release-attestation verification once a trusted policy/key is agreed;
compatibility matrix across supported old/current hosts; signed registry
submission and stable-channel approval; SBOM/provenance and reproducibility
evidence; real-host GUI acceptance and rollback. Keep these separate from
unsigned preview publication. Do not add empty secrets, signing placeholders,
or auto-merge before these controls are implemented and reviewed.

### Public-host manifest compatibility

The pinned public Pulse 1.0.60 manifest parser at SDK revision
`b32436831a066e18448b2810bef4bf989024fc68` accepts only
`apiVersion`, `id`, `name`, `resources` and `native`.
The later locally captured 1.0.61 SDK supports the `activation` field;
do not include it in formal release templates until a compatible public
host and schema are reviewed and pinned. Development/test templates retain
their explicit startup activation for newer-host acceptance; they are not
the public release templates. No automatic field stripping or validation
bypass is used. Confirm actual settings-page startup behavior on the
target host before stable promotion. Release CI retains official author
tool logs and isolated installer logs as a seven-day diagnostic artifact,
including on package failure.

## 3C. GitHub stable promotion and local signing

Stable GitHub publication is independent of official registry approval; this repository requires publisher signatures for stable promotion.
Use **Extension release → dry-run** with final numeric versions (no prerelease
suffix), download the exact candidate artifact and complete the applicable
[installed acceptance matrix](final-host-acceptance.md). Record actual
Pulse version, SHA-256 for every selected .pulse-ext and reproducible acceptance
evidence. Do not promote a failed, incomplete or untested candidate.

Then dispatch **Extension release** again, with request
run=<successful dry-run ID>,host=<actual tested Pulse version>, select
draft-stable or publish-stable, and check acceptance_confirmed only after
independently comparing the downloaded .pulse-ext SHA-256 values with the run
summary and completing all applicable installed checks. The workflow derives
and checks actual package hashes rather than requiring manual re-entry.
The run reference is recorded in stable-acceptance.json; the attestation is
owner-reported, not automatically observed GUI testing. Do not include private
data in release evidence. The successful signed candidate must be from the same
current main SHA and retained artifacts; if main moves or artifacts expire,
rebuild and retest. A preview suffix cannot be promoted to a stable version.
Stable preparation downloads the exact original build and signature artifacts
from that run. The protected stable-release job verifies both again and
publishes them without rebuilding or re-signing. No production private key is
accessed during promotion. A stable draft may be published manually after
review; existing tags/releases block promotion. All versions remain non-latest.

Configure both environments before use: release-signing and stable-release,
main-only, required reviewer(s), self-review permitted for a sole maintainer
or a distinct reviewer. The environment name alone is not an approval control.
The signing environment alone contains Secret PULSE_SIGNING_PRIVATE_KEY
(Base64 CNG private blob) and Variables PULSE_SIGNING_PUBLIC_KEY (Base64 public
blob) and PULSE_PUBLISHER_FINGERPRINT (lowercase SHA-256).
The reviewed public identity and official signing tool revision are fixed in
sdk/publisher.toml. Key rotation requires a reviewed update.
All ordinary release candidates (including dry-run) now require protected
signing; candidate builds for upstream compatibility remain internal unsigned
diagnostics and do not access the production key. No private key is uploaded,
cached or passed to the publishing job. Invalid or missing signatures block
all publication. Original pre-sign build evidence remains unchanged; separate
signing evidence records the verified signature. This is publisher signing,
not official registry approval.

Owner-reported legacy local key location (2026-11-27):
`.local/PulseSigning/pulse-extras/` relative to this checkout. This is a
location note only, not a CI input, not a verified inventory, and not a
request to generate another key. The directory is ignored by Git, but ignored
files are not a security boundary and can be removed by local cleanup.
Keep an encrypted backup outside the checkout and preferably relocate the
existing key pair outside all repositories (do not regenerate it).
The optional local signing wrapper deliberately rejects in-repository key
paths, including ignored paths. Environment signing does not use this location.

For optional local signing, the actual official keygen/sign/verify CLI is
in **jimmgreen/pulse-extensions**, not the public Pulse SDK checkout.
Use the reviewed commit `0a325ac77d5ecddb98a45f9062fd1b0129978dbe`.
On Windows (PowerShell), clone outside this repository, check out the commit,
and generate a publisher key once:

```powershell
$registry = Join-Path $env:LOCALAPPDATA "PulseSigning\registry"
$keys = Join-Path $env:LOCALAPPDATA "PulseSigning\pulse-extras"
git clone https://github.com/jimmgreen/pulse-extensions.git $registry
git -C $registry checkout --detach 0a325ac77d5ecddb98a45f9062fd1b0129978dbe
python (Join-Path $registry "tools\pulse_sign.py") keygen --out-dir $keys --bits 3072
```

Keep the private blob outside all repositories, cloud sync and logs; restrict access to your account, encrypt backups and never share it. For automated signing only, place its Base64 encoding in the protected release-signing Environment Secret, never a repository variable, ordinary repository secret or artifact. Base64 is not encryption.
The public blob, fingerprint and publicKey are publishable. Do not regenerate
the key for each package/version. The same publisher can sign multiple products.
The official Windows CNG tool uses RSAFULLPRIVATEBLOB / RSAPUBLICBLOB, not PEM.
The separate Pulse signature compatibility workflow tests disposable key generation,
signing, verification and byte-tamper rejection on Windows, without uploading keys.

With the exact clean source checkout of the dry-run candidate, sign locally
using an extracted per-product directory and a new output directory:

```powershell
python scripts/sign_release.py --product companion --candidate .local/candidates/companion `
  --registry $registry --private-key (Join-Path $keys "publisher.private.blob") `
  --public-key (Join-Path $keys "publisher.public.blob") --out .local/signed-companion
```

This verifies package hashes and source identity, signs the raw manifest bytes
with the pinned official CLI, verifies against the explicitly supplied public
blob, and writes a detached .sig.json, public publisher.json (copy to publishers/<fingerprint>.json in the registry PR) and
signing-evidence.json. The original candidate is not changed. The protected stable workflow now signs and includes the matching verified signature automatically; local signing remains available for controlled manual use. This
wrapper does not create a release, change trust policies or submit registry
metadata. Never upload private blobs, and do not claim signed registry
acceptance until the official catalog PR is reviewed.

## 4. Further signed registry / production release phases

The following are additional requirements for signed registry distribution and further production hardening. Stable GitHub promotion above intentionally does not imply registry approval.

1. Plan: resolve immutable source commit, selection, descriptors, dependency impact, versions,
   tag/asset names and acceptance policy. Preflight every selected package and fail before any
   publication if the batch is invalid.
2. Validate: require full regression (not the docs/VCS reduced gate) on the exact source SHA,
   pinned SDK check, relevant tests and actual isolated Pulse acceptance evidence for the
   selected package/build. If no valid full check exists, run it. Never reuse an unrelated
   earlier green run. Reuse the tested toolchain archive cache; do not trigger repeated full CI
   for each selected package.
3. Build: trusted release source only, Windows x64 MSVC ReleaseSafe, bounded matrix concurrency.
   Build each selected target and its tests; require all selected candidates to pass.
   Record source SHA, toolchain, SDK and artifact hashes. No signing secrets or write token here.
4. Package: use official matching host/SDK author tools to generate manifest and bind the DLL
   and resource hashes, package .pulse-ext and verify. Use explicit absolute paths, isolated
   temp directories, validated manifests, no archive traversal or unlisted dependencies.
   Pin/verify any host binary or release tool fetched by CI. If the official compatible host
   cannot be provisioned securely, use a controlled manual packaging step; never fake verification.
5. Verify: validate actual PE machine/ABI/exports, package structure, version, manifest hash,
   per-file and package hashes, notices and installation compatibility. Recheck artifact identity
   across jobs. Run package lifecycle/rollback tests where applicable. Do not call arbitrary
   untrusted DLLs on a credential-bearing release runner.
6. Sign: for draft/publish only, separate protected environment/job, explicit approval and
   minimal trusted signing code. Verify candidate hashes again, sign exact raw manifest bytes,
   verify signatures using public key and official policy. Do not run generated source or
   untrusted build scripts here. Never regenerate the manifest after signing. No production
   key in Git, caches, ordinary artifacts, logs, Forge projects or pull request jobs. Prefer
   local controlled signing if secure CI key handling is not available. Use separate test keys
   for validation. Remove transient private key material; plan key rotation/revocation.
7. Publish: revalidate source SHA, asset hashes, approval and collision state. Create independent
   tags/releases per selected package; only this job gets contents:write. Upload assets to drafts,
   verify completeness, then publish as authorized. GitHub has no atomic multi-release
   transaction: prepare all first, report partial publication honestly, resume only matching
   artifacts, never overwrite immutable releases or silently delete published tags/assets.
   Serialize release runs to avoid races; retries must not duplicate releases.
8. Registry: generate candidate metadata and validate with official catalog.py including actual
   downloads and signatures. Open/update an explicit reviewable registry PR only when authorized;
   no automatic merge or official catalog signing. Draft/preview metadata must not reference
   unavailable or ineligible public assets.

Use the official commands as verified against the chosen SDK, for example:

```powershell
python tools/extensions/pulse_ext.py --pulse <trusted-pulse.exe> --json native-manifest manifest.json --library <dll> --output out/manifest.json
python tools/extensions/pulse_ext.py --pulse <trusted-pulse.exe> --json pack out/manifest.json --output out/extension.pulse-ext
python tools/extensions/pulse_ext.py --pulse <trusted-pulse.exe> --json verify out/extension.pulse-ext
python <pulse-extensions-checkout>/tools/pulse_sign.py sign-manifest out/manifest.json --private-key <protected-key> --output out/extension.sig.json
```

Paths are placeholders, not executable commands as written. The manifest/library/resources
must be laid out according to the official tool contract, outputs must not already exist,
and private key use requires the protected stage. Signed verification must use the appropriate
official signature/policy options; consult the tool version's help rather than guessing flags.

## 5. Release assets and evidence

Unsigned preview releases include the archive, raw manifest, release evidence, SHA256SUMS.txt, AGPL license and retained Apache license. The exact public source tag/commit is linked in the notes; the current composition uses the system WIC backend and no bundled libwebp or third-party pet assets. Before any composition change, review dependency notices and corresponding-source obligations. Stable/registry releases must additionally satisfy the following.

Each signed official-registry product release includes at minimum:

- strangelion.<name>-<version>.pulse-ext
- strangelion.<name>-<version>.sig.json
- SHA256SUMS.txt, AGPL-3.0-only license text and THIRD_PARTY_NOTICES.txt; preserve applicable upstream/dependency/asset licenses and notices
- Complete corresponding source access for this exact release, including necessary build scripts, dependency sources/pins and modifications as required. A private repository link alone is not sufficient for public recipients; resolve compliant access before publishing.
- Release notes with supported Pulse/SDK versions, features, limitations, known skipped
  tests, source commit and build/test/host evidence references.

Record manifest/package/signature hashes and byte sizes, minPulse, sdkPreview, resources,
localized descriptions, license, source and official GitHub release download URLs for registry
metadata. Publisher fingerprint and public key are public; private key is not. Do not fabricate
a successful signature, public download or registry acceptance. No unsigned official-store
claim. Local dry-run artifact is not a production release.

## License gate

Project license is AGPL-3.0-only going forward, preserving prior Apache-2.0 and third-party rights. Review exact dependency revisions, build options and distribution, upstream SDK/host plugin compatibility, contributor rights, assets and registry acceptance; do not infer compliance from a submodule or IPC boundary. Include source access and applicable AGPL section 13 network-interaction requirements. See [product scope / licensing](product-scope.md#4-license-and-distribution-policy). No automatic repository visibility change or production publication.

## 6. Implementation sequence and tests (R milestone)

R1/R2 packaging and unsigned preview workflow are implemented and exercised;
R0 isolated installed lifecycle and R3 signing/registry acceptance are not
complete. R4 coexistence and measured resource evidence remains open. The
following describes the remaining verification and original stage boundaries.

R0: first real VCS package built and manually verified/installed/upgraded/rolled back with
official tooling in isolated host; record artifact SHA and evidence.
R1: reusable descriptor reader, selection planner, package helper, manifest/hash verification
and CLI dry run; fixture tests for selection, collisions, malformed metadata, unsafe paths,
package tampering and missing SDK/host. No secrets.
R2: manual release workflow dry run, real package matrix and exact-SHA full CI gate; test
single/multiple/all, no eligible packages, failure/cancel, artifact mismatch and reproducibility.
R3: protected draft/publish/signing, test-key signature verification, replay/collision/partial
failure recovery, registry candidate generation and review. Confirm actual registry acceptance.
Add only real implemented stages; no placeholder workflows. No scheduled release, no automatic
AI publication, no unnecessary jobs for docs. Maintain [testing](testing.md) and
[roadmap](roadmap.md) with real evidence and actual current status.

Isolated acceptance packaging is implemented separately by scripts/stage_vcs_test.py and extensions/vcs-panel/manifest.test.json. It delegates manifest generation, pack and verify to the official pinned tool and refuses existing output directories. No release signing, registry publication or installation is performed. Production eligibility remains blocked by the acceptance runbook.


## Share packaging

The existing release registry includes Share, with the fixed four helper
executables and two Go/Rust third-party notices. Selecting share builds
the locked Go and Rust modules, verifies their dependency preparation,
then builds the DLL with all four helper SHA-256 values. The official
author tool stages/verifies the complete archive. Other selected products
do not require Share toolchains unless Share is also selected.

For unsigned branch acceptance, dispatch Extension test package
with request share=0.1.0-rc.1 (or another valid candidate SemVer).
No additional workflow, signing or publication. The regular Extension
release workflow remains main-only and stable promotion still requires
exact accepted artifact evidence.

The workflow filename remains upstream-candidate.yml for existing links and SDK automation.
For a manually requested test package, run_regression defaults to false (package-only).
Enable it when a full regression is required. SDK update dispatches explicitly enable
full regression, and SDK pull requests always run full regression. A failed requested
regression blocks packaging. All packages still undergo official format verification
and digest checks; skipping regression is not proof of passing regression.
The existing upstream-candidate-packages artifact name is retained for compatibility.
