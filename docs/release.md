# Unified extension release / 统一增强包发布设计

Status (2026-11-26): **manual unsigned preview workflow implemented and used**.
[Companion 1.0.0](https://github.com/strangelion/pulse-extras/releases/tag/companion/v1.0.0)
and [VCS 1.0.0](https://github.com/strangelion/pulse-extras/releases/tag/vcs/v1.0.0)
are independent unsigned prereleases targeting df5009c. Local packaging remains
available. No signing, stable release, registry submission or complete actual-host
acceptance is implied. Ordinary regression CI does not package or publish.
Use the [stage roadmap](roadmap.md) and batch a complete usable update; do not
publish each tiny implementation change. User-authorized preview testing remains
possible with exact limitations; no automatic publication on stage completion.

## 1. Upstream publication contract

Official [registry contribution guide](https://github.com/jimmgreen/pulse-extensions/blob/main/CONTRIBUTING.md)
and [native package quickstart](https://github.com/jimmgreen/pulse/blob/b32436831a066e18448b2810bef4bf989024fc68/docs/extensions-sdk-quickstart.md)
define the authoritative format. Recheck them at implementation/release; current pin is
Pulse 1.0.60 SDK Preview 3 and Windows x64 MSVC ABI. Confirm Zig-built packages are acceptable
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

Open Actions → Extension release → Run workflow on main.

| Input | Values / meaning |
| --- | --- |
| releases | Comma-separated product=SemVer pairs, e.g. companion=1.1.0,vcs=1.2.0 |
| mode | dry-run (default), draft, publish-preview |

Use `companion=1.1.0` for one product, or `companion=1.1.0,vcs=1.2.0`
for independent versions. Explicit `all=2.0.0` selects every registered product
at the same version; do not combine it with individual entries.
Each selected extension receives its own tag and Release; no global version.
SemVer build metadata is currently rejected for publication to avoid GitHub
asset-name normalization. Unknown products, duplicate keys, empty versions and
malformed requests are rejected. The preflight plan is passed to subsequent
jobs and checked against the immutable checkout and request. Existing tags or releases (including drafts visible to the
publisher) block the batch; no overwrite or automatic deletion.

The workflow requires main and a clean immutable checkout, calls the existing
full regression workflow once, then builds selected packages on Windows.
The public author checkout is pinned to the SDK revision. The official
Pulse 1.0.60 installer is pinned by exact size and SHA-256, installed using
upstream /PULSETEST on an ephemeral runner. The local 1.0.61 SDK/host is not
redistributed. Companion builds helper/runtime before embedding both hashes
in its entry DLL; this release composition uses WIC, not bundled libwebp.
The official native-manifest, pack and verify commands remain authoritative.
Build and regression jobs have read-only tokens. Only the separate publication
job receives contents:write. It revalidates artifact inventory, digests,
manifest, source and collision state before creating per-product drafts.
It compares the GitHub-returned asset digests before any explicit
publish-preview operation. A partial failure leaves existing drafts/releases
for inspection; the batch cannot be atomic. Do not delete or replace published
versions. Use a new version or manually review exact retained drafts.

Dry-run builds and verifies, retaining seven-day artifacts; no tag/release.
Draft creates private reviewable unsigned preview drafts.
Publish-preview explicitly publishes unsigned GitHub prereleases, never
marks one latest and does not claim real-host acceptance. A release exposes
native code: recipients must review its source and trust before installation.
No stable channel, signing keys or official registry submission are automated.
The stable release design below remains a separate future gate.

## 4. Future stable release phases

The following are the additional requirements for production/stable or signed registry releases, not claims made by the unsigned preview workflow.

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
python tools/pulse_sign.py sign-manifest out/manifest.json --private-key <protected-key> --output out/extension.sig.json
```

Paths are placeholders, not executable commands as written. The manifest/library/resources
must be laid out according to the official tool contract, outputs must not already exist,
and private key use requires the protected stage. Signed verification must use the appropriate
official signature/policy options; consult the tool version's help rather than guessing flags.

## 5. Release assets and evidence

Unsigned preview releases include the archive, raw manifest, release evidence, SHA256SUMS.txt, AGPL license and retained Apache license. The exact public source tag/commit is linked in the notes; the current composition uses the system WIC backend and no bundled libwebp or third-party pet assets. Before any composition change, review dependency notices and corresponding-source obligations. Stable/registry releases must additionally satisfy the following.

Each stable product release includes at minimum:

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
