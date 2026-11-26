# Unified extension release / 统一增强包发布设计

Status: **design only**. No release workflow, production manifest, publisher key,
registry submission or official acceptance is implied. Implement a reusable packaging
pipeline after the first real VCS candidate passes isolated Pulse acceptance, then add
manual release automation. Preserve change-aware CI for ordinary development.

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

## 2. Independent package versions

One monorepo, independent packages and SemVer. Example IDs: strangelion.vcs, strangelion.convert,
strangelion.inspect, strangelion.data, strangelion.devkit, strangelion.compare,
and conditional candidates strangelion.companion and strangelion.forge.
The ABI Probe and Hello Panel remain test/example packages and are not released as products
by default. No placeholder or incomplete extension is publishable.

Each actual package should have an authoritative release descriptor (proposed
`extensions/<name>/extension.toml`), official manifest template, changelog, build target,
required capability/SDK/host constraints, resources, notices and acceptance evidence.
Determine the exact schema during implementation; do not duplicate version truth across files.
The descriptor records independent version, release eligibility and channel policy. Tag example:
`vcs/v0.1.0`; asset: `strangelion.vcs-0.1.0.pulse-ext`. Treat published versions/tags as immutable.
Shared library changes may require new versions of affected packages, never a forced version bump
for unaffected ones. Each build records its bundled [Shared Runtime](shared-runtime.md) source/API
revision and relevant hashes alongside Zig/SDK pins. Runtime is linked into independent DLLs,
not a hot-updated global component. For a runtime fix identify all affected released consumers,
rebuild/test/accept and independently release their new versions; older installed packages retain
the old implementation until updated. Verify mixed-version coexistence; no raw allocator or
mutable object sharing across DLLs. Do not create empty descriptors now.

## 3. One manually dispatched workflow

Proposed `.github/workflows/release.yml`, manually triggered with workflow_dispatch.
No automatic publication on a normal push, pull request or documentation update.

| Input | Values / meaning |
| --- | --- |
| scope | single, selected, all |
| extensions | one short ID or comma-separated IDs; ignored/empty for all |
| version | optional single-package override only if it matches the committed descriptor; batch uses per-package versions |
| channel | preview, stable (map to prerelease policy; do not rewrite SemVer silently) |
| mode | dry-run (default), draft, publish |

GitHub's native workflow form does not provide dynamic multi-select. Use a string for selected
IDs and validate against discovered, allowlisted package descriptors; never interpolate inputs
as shell source or filesystem paths. Choices in docs/UI are illustrative. Reject unknown IDs,
duplicates, inconsistent inputs, zero eligible packages, version/tag collisions, incompatible
dependencies and release-ineligible explicit selections. All mode selects eligible real
packages with unpublished versions; report skipped unchanged/ineligible packages and why.
No implicit release of examples or placeholders. Preview/stable eligibility must be explicit;
do not promote an unverified build to stable.

Dry run compiles/tests/packages/verifies and uploads bounded short-lived CI artifacts if needed,
without tag, signing secrets, registry changes or Release creation. Draft creates a reviewable
GitHub Release with verified signed assets and explicit draft state (not a public publication).
Publish requires approved protected release authority and complete gates. Validate effective
permissions/settings before enabling publish; if GitHub plan or environment policy cannot enforce
the required approval, keep publication manual instead of bypassing it.

## 4. Release phases

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

Each product release includes at minimum:

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

## 6. Implementation sequence and tests

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
