"""Manual, per-product GitHub releases. Stable promotion requires exact tested artifacts.

The build job has read-only permissions. Only the separate publish job may
write releases. The pinned public Pulse host validates package format,
not real-host lifecycle on the locally installed newer Pulse.
"""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from urllib.request import urlopen
import zipfile

import package_common as common
import package_release as package
import upstream_pin

ROOT = package.ROOT
MODES = {"dry-run", "draft", "publish-preview"}


def plan(request: str, mode: str) -> list[dict]:
    if mode not in MODES:
        raise ValueError("unknown release mode")
    if not isinstance(request, str) or not request or len(request) > 65535:
        raise ValueError("empty or oversized release request")
    versions = {}
    for pair in request.split(","):
        key, sep, version = pair.strip().partition("=")
        key, version = key.strip(), version.strip()
        if not sep or not key or not version or key in versions:
            raise ValueError("expected unique product=SemVer entries")
        if key != "all" and key not in package.PRODUCTS:
            raise ValueError("unknown release product: " + key)
        versions[key] = version
    if "all" in versions:
        if len(versions) != 1:
            raise ValueError("all cannot be combined with individual products")
        versions = dict.fromkeys(package.PRODUCTS, versions["all"])
    if not versions:
        raise ValueError("no releasable products")
    result = []
    for item, value in versions.items():
        version = package.parse_version(value)
        # Preserve immutable tag and asset names.
        if "+" in version or len(version) > 64:
            raise ValueError("release versions must omit build metadata and fit 64 characters")
        product = package.PRODUCTS[item]
        result.append({"product": item, "version": version,
                       "tag": f"{item}/v{version}",
                       "asset": package.asset_name(product["id"], version)})
    return result


def plan_json(items: list[dict]) -> str:
    return json.dumps(items, separators=(",", ":"), ensure_ascii=True)


def check_plan(items: list[dict], expected: str) -> None:
    if plan_json(items) != expected:
        raise RuntimeError("release plan differs from preflight output")


def run(*args: str, timeout: int = 600, cwd: Path = ROOT) -> None:
    subprocess.run(list(args), cwd=cwd, check=True, timeout=timeout)


def capture(*args: str) -> str:
    return subprocess.run(list(args), cwd=ROOT, check=True, timeout=120,
                          capture_output=True, text=True, encoding="utf-8").stdout.strip()


def source_revision(*, candidate: bool = False) -> str:
    ref = os.environ.get("GITHUB_REF", "")
    if not candidate and ref != "refs/heads/main":
        raise RuntimeError("release workflow must run on main")
    if candidate and not (ref.startswith("refs/heads/") or re.fullmatch(r"refs/pull/[0-9]+/merge", ref)):
        raise RuntimeError("candidate validation requires a branch or PR checkout")
    sha = os.environ["GITHUB_SHA"]
    if not re.fullmatch(r"[0-9a-f]{40}", sha) or package.git("rev-parse", "HEAD") != sha:
        raise RuntimeError("checkout differs from workflow source revision")
    if package.git("status", "--porcelain", "--untracked-files=normal"):
        raise RuntimeError("release source is not clean")
    return sha


def repository() -> str:
    repo = os.environ["GITHUB_REPOSITORY"]
    if not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repo):
        raise ValueError("invalid repository")
    return repo


def gh_pages(endpoint: str) -> list[dict]:
    pages = json.loads(capture("gh", "api", "--paginate", "--slurp", endpoint))
    return [entry for page in pages for entry in page]


def preflight(items: list[dict]) -> None:
    repo = repository()
    releases = {entry["tag_name"] for entry in gh_pages(f"repos/{repo}/releases?per_page=100")}
    tags = {entry["name"] for entry in gh_pages(f"repos/{repo}/tags?per_page=100")}
    collisions = [item["tag"] for item in items if item["tag"] in releases | tags]
    if collisions:
        raise RuntimeError("existing release or tag (never overwrite): " + ", ".join(collisions))


def install_host(work: Path, pin: dict) -> Path:
    installer = work / "PulseSetup.exe"
    expected = pin["installer"]
    total = 0
    with urlopen(upstream_pin.installer_url(pin), timeout=60) as response, installer.open("xb") as target:
        while chunk := response.read(64 * 1024):
            total += len(chunk)
            if total > expected["size"]:
                raise RuntimeError("Pulse installer exceeded pinned size")
            target.write(chunk)
    if total != expected["size"] or common.sha256(installer) != expected["sha256"]:
        raise RuntimeError("Pulse installer digest mismatch")
    destination = work / "host"
    # /PULSETEST is upstream's isolated test install. No service, startup,
    # AI or search integration; never run this against the user's machine.
    run(str(installer), "/PULSETEST", "/VERYSILENT", "/SUPPRESSMSGBOXES",
        "/NORESTART", "/TASKS=!indexservice,!globalsearch,!aiassistant,!startup,!desktopicon",
        f"/DIR={destination}", f"/LOG={work / 'setup.log'}", timeout=240)
    pulse = destination / "pulse.exe"
    common.regular_file(pulse, common.ARCHIVE_MAX)
    return pulse


def build(items: list[dict], output: Path, sdk: Path, *, candidate: bool = False) -> None:
    if sys.platform != "win32":
        raise RuntimeError("official package build requires Windows runner")
    revision = source_revision(candidate=candidate)
    pin = upstream_pin.load()
    if capture("git", "-C", str(sdk), "rev-parse", "HEAD") != pin["revision"]:
        raise RuntimeError("official author tool checkout does not match SDK pin")
    if capture("zig", "version") != (ROOT / ".zig-version").read_text().strip():
        raise RuntimeError("Zig version mismatch")
    work = ROOT / ".local" / "release-work"
    work.mkdir(parents=True, exist_ok=False)
    pulse = install_host(work, pin)
    prefix = work / "build"
    flags = ["-Doptimize=ReleaseSafe", "--prefix", str(prefix), "--summary", "all"]
    entry_flags = []
    if any(package.PRODUCTS[item["product"]]["build_profile"] == "companion" for item in items):
        run("zig", "build", "pet-demo", *flags)
        run("zig", "build", "companion-runtime-bridge", *flags)
        helper = common.sha256(prefix / "bin/pulse-pet-demo.exe", common.FILE_MAX)
        runtime = common.sha256(prefix / "bin/pulse_companion_runtime.dll", common.FILE_MAX)
        entry_flags.extend(["-Dcompanion-helper-sha256=" + helper,
                            "-Dcompanion-runtime-sha256=" + runtime])
    run("zig", "build", "-Dtarget=x86_64-windows-msvc", *flags, *entry_flags)
    output.mkdir(parents=True, exist_ok=False)
    for item in items:
        product = item["product"]
        staged = work / ("package-" + product)
        args = argparse.Namespace(extension=product, version=item["version"],
                                  pulse=pulse, sdk_root=sdk,
                                  artifacts=prefix / "bin", out=staged)
        archive = package.package(args)
        final = output / product
        final.mkdir()
        for src, name in ((archive, item["asset"]),
                          (staged / "release-evidence.json", "release-evidence.json"),
                          (staged / "stage/manifest.json", "manifest.json"),
                          (ROOT / "LICENSE", "LICENSE.txt"),
                          (ROOT / "LICENSES/Apache-2.0.txt", "Apache-2.0.txt")):
            shutil.copyfile(src, final / name)
        (final / "SHA256SUMS.txt").write_text(
            "".join(f"{common.sha256(path)}  {path.name}\n"
                    for path in sorted(final.iterdir())), encoding="ascii", newline="\n")
        verify_candidate(item, final, revision)


def verify_candidate(item: dict, directory: Path, revision: str) -> list[Path]:
    product = package.PRODUCTS[item["product"]]
    names = {item["asset"], "release-evidence.json", "manifest.json",
             "LICENSE.txt", "Apache-2.0.txt", "SHA256SUMS.txt"}
    if {path.name for path in directory.iterdir()} != names:
        raise RuntimeError("unexpected release artifact inventory")
    evidence = common.read_evidence(directory / "release-evidence.json")
    required = {"schema_version": 1, "extension_id": product["id"],
                "version": item["version"], "asset": item["asset"],
                "source_revision": revision, "source_dirty": False,
                "official_verified": True, "signed": False,
                "published": False, "real_host_accepted": False}
    if any(evidence.get(key) != value for key, value in required.items()):
        raise RuntimeError("release evidence does not match selected candidate")
    if evidence["library"]["path"] != product["library"] or [x["path"] for x in evidence["members"]] != list(product["members"]):
        raise RuntimeError("release member list differs from declaration")
    archive = directory / item["asset"]
    manifest = directory / "manifest.json"
    if common.sha256(manifest, common.EVIDENCE_MAX) != evidence["manifest_sha256"]:
        raise RuntimeError("manifest digest mismatch")
    declared = common.read_evidence(manifest)
    native = declared.get("native", {})
    if (declared.get("id") != product["id"] or native.get("library") != product["library"]
            or native.get("sha256") != evidence["library"]["sha256"]
            or native.get("files", []) != evidence["members"]):
        raise RuntimeError("manifest does not bind release members")
    common.verify_archive_bindings(archive, evidence["asset_sha256"], evidence["manifest_sha256"],
                                   evidence["library"], evidence["members"])
    # Source and license bytes are independently bound in the publish checkout.
    if (common.sha256(directory / "LICENSE.txt") != common.sha256(ROOT / "LICENSE")
            or common.sha256(directory / "Apache-2.0.txt") != common.sha256(ROOT / "LICENSES/Apache-2.0.txt")
            or evidence["sdk_pin_sha256"] != common.sha256(ROOT / "sdk/upstream.toml")
            or evidence["template_sha256"] != common.sha256(ROOT / product["template"])
            or evidence["descriptor_sha256"] != common.sha256(ROOT / product["descriptor"])
            or evidence["zig_version"] != (ROOT / ".zig-version").read_text().strip()):
        raise RuntimeError("source metadata mismatch")
    sums = "".join(f"{common.sha256(directory / name)}  {name}\n"
                   for name in sorted(names - {"SHA256SUMS.txt"}))
    if (directory / "SHA256SUMS.txt").read_text(encoding="ascii") != sums:
        raise RuntimeError("checksum file mismatch")
    return sorted(directory / name for name in names)


def publish(items: list[dict], mode: str, output: Path, *,
            stable_receipts: dict | None = None, build_run_id: str | None = None,
            signed_assets: dict | None = None) -> None:
    stable = mode in {"draft-stable", "publish-stable"}
    if mode not in {"draft", "publish-preview", "draft-stable", "publish-stable"}:
        raise ValueError("not a publication mode")
    if stable != (stable_receipts is not None) or stable != (signed_assets is not None):
        raise ValueError("stable publication requires acceptance receipts and verified signatures")
    if stable and (not build_run_id or set(stable_receipts) != {item["product"] for item in items}
                   or set(signed_assets) != set(stable_receipts)):
        raise ValueError("incomplete stable acceptance receipts")
    revision = source_revision()
    repo = repository()
    # A private source checkout is not adequate corresponding-source access.
    if json.loads(capture("gh", "api", f"repos/{repo}"))["private"]:
        raise RuntimeError("automatic release requires public corresponding source")
    if {path.name for path in output.iterdir()} != {item["product"] for item in items}:
        raise RuntimeError("artifact products differ from release selection")
    files = {item["product"]: verify_candidate(item, output / item["product"], revision)
             for item in items}
    preflight(items)
    pin = upstream_pin.load()
    if stable:
        # Do not modify the package, raw manifest, or original build evidence.
        # Add a separate owner-attestation receipt and a release checksum list.
        for item in items:
            product = item["product"]
            receipt_dir = ROOT / ".local/stable-receipts" / product
            receipt_dir.mkdir(parents=True, exist_ok=False)
            receipt = stable_receipts[product]
            evidence = common.read_evidence(output / product / "release-evidence.json")
            if (receipt.get("asset_sha256") != evidence["asset_sha256"]
                    or receipt.get("source_revision") != revision
                    or receipt.get("product") != product
                    or receipt.get("version") != item["version"]
                    or receipt.get("build_run_id") != build_run_id):
                raise RuntimeError("acceptance receipt does not bind candidate")
            common.write_evidence(receipt_dir / "stable-acceptance.json", receipt)
            assets = [path for path in files[product] if path.name != "SHA256SUMS.txt"]
            assets.append(receipt_dir / "stable-acceptance.json")
            assets.extend(signed_assets[product])
            if len({path.name for path in assets}) != len(assets):
                raise ValueError("duplicate stable asset names")
            sums = receipt_dir / "SHA256SUMS.txt"
            sums.write_text("".join(f"{common.sha256(path)}  {path.name}\n"
                                    for path in sorted(assets, key=lambda p: p.name)),
                            encoding="ascii", newline="\n")
            files[product] = assets + [sums]
    for item in items:
        tag = item["tag"]
        notes = (
            f"Unsigned preview candidate for {item['product']} {item['version']}.\n\n"
            f"Source: https://github.com/{repo}/tree/{revision}\n\n"
            f"Full regression and package build: https://github.com/{repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}\n\n"
            f"Official package-format verification used the pinned public Pulse {pin['pulse_source_version']} host. "
            "Real-host activation, coexistence and production acceptance are not certified. "
            "No official registry signature or publication. Companion uses the Windows WIC backend "
            "when selected. Release evidence describes the package before publication.\n"
        )
        if stable:
            receipt = stable_receipts[item["product"]]
            notes = (
                f"GitHub stable release: {item['product']} {item['version']} (publisher signed).\n\n"
                f"Source: https://github.com/{repo}/tree/{revision}\n\n"
                f"Exact candidate build: https://github.com/{repo}/actions/runs/{build_run_id}\n\n"
                f"Official package verification: Pulse {pin['pulse_source_version']}. "
                f"Owner-reported installed acceptance: Pulse {receipt['host_version']}; "
                "see stable-acceptance.json for scope and evidence reference. "
                "The receipt is a human attestation, not an automated GUI test. "
                "Build evidence remains the pre-acceptance snapshot. "
                "Manifest signature verified against the reviewed publisher key; see signing-evidence.json. "
                "Not submitted to or approved by the official registry.\n"
            )
        run("gh", "release", "create", tag, *(str(path) for path in files[item["product"]]),
            "--repo", repo, "--target", revision, "--draft",
            "--prerelease=false" if stable else "--prerelease", "--latest=false",
            "--title", f"{item['product']} {item['version']}" + ("" if stable else " (Preview)"), "--notes", notes)
        print("Created draft: " + tag, flush=True)
    # All drafts must have complete, digest-matching assets before any
    # publication. No deletion/overwrite on partial failure.
    releases = {entry["tag_name"]: entry for entry in gh_pages(f"repos/{repo}/releases?per_page=100")}
    for item in items:
        entry = releases[item["tag"]]
        actual = {asset["name"]: asset.get("digest") for asset in entry["assets"]}
        expected = {path.name: "sha256:" + common.sha256(path) for path in files[item["product"]]}
        if (not entry["draft"] or entry["prerelease"] != (not stable) or entry["target_commitish"] != revision
                or actual != expected):
            raise RuntimeError("draft asset/source verification failed; retain draft for review")
    if mode in {"publish-preview", "publish-stable"}:
        for item in items:
            run("gh", "release", "edit", item["tag"], "--repo", repo,
                "--draft=false", "--prerelease=false" if stable else "--prerelease", "--latest=false")
            print(("Published stable: " if stable else "Published preview: ") + item["tag"], flush=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["plan", "build", "publish", "candidate"])
    parser.add_argument("--out", type=Path, default=ROOT / ".local/release-output")
    parser.add_argument("--sdk", type=Path, default=ROOT / ".local/sdk")
    args = parser.parse_args()
    try:
        if args.action == "candidate":
            # This branch-only path never checks release tags or calls publication.
            build(plan("all=0.0.0-upstream", "dry-run"), args.out.resolve(), args.sdk.resolve(), candidate=True)
            return 0
        items = plan(os.environ["RELEASE_REQUEST"], os.environ["RELEASE_MODE"])
        source_revision()
        print(json.dumps(items, indent=2), flush=True)
        if args.action == "plan":
            preflight(items)
            if output := os.environ.get("GITHUB_OUTPUT"):
                with open(output, "a", encoding="utf-8") as stream:
                    stream.write("plan=" + plan_json(items) + "\n")
        else:
            check_plan(items, os.environ["RELEASE_PLAN"])
            if args.action == "build":
                build(items, args.out.resolve(), args.sdk.resolve())
            else:
                publish(items, os.environ["RELEASE_MODE"], args.out.resolve())
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError,
            zipfile.BadZipFile) as exc:
        print(f"Release workflow failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
