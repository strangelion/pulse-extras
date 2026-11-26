#!/usr/bin/env python3
"""Package a Pulse extension release candidate with the pinned official tool.

Explicit local or manual-release workflow invocation: the official author tool remains
authoritative for manifest generation, archive layout and verification.
This script declares each product's package contents, binds every input by
digest, renames the verified archive to its release asset name and writes
evidence. It performs no signing, publication, registry or host install, and
ordinary regression CI never runs it (see docs/release.md).
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from pathlib import Path

import package_common

ROOT = Path(__file__).resolve().parents[1]

# Declared release composition. Sources are the fixed install paths produced
# by the build commands below; no globbing and no implicit extras.
PRODUCTS = {
    "companion": {
        "id": "strangelion.companion",
        "template": "extensions/companion/manifest.release.json",
        "library": "pulse_companion.dll",
        "members": ("pulse_companion_runtime.dll", "pulse-pet-demo.exe"),
        "build": (
            "zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe",
            "zig build companion-runtime-bridge -Doptimize=ReleaseSafe",
            "zig build pet-demo -Doptimize=ReleaseSafe",
        ),
    },
    "vcs": {
        "id": "strangelion.vcs",
        "template": "extensions/vcs-panel/manifest.release.json",
        "library": "pulse_vcs_panel.dll",
        "members": (),
        "build": ("zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe",),
    },
}

_VERSION = re.compile(
    r"(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)\.(?:0|[1-9]\d*)"
    r"(?:-(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*)"
    r"(?:\.(?:0|[1-9]\d*|\d*[A-Za-z-][0-9A-Za-z-]*))*)?"
    r"(?:\+[0-9A-Za-z-]+(?:\.[0-9A-Za-z-]+)*)?"
)


def parse_version(text: str) -> str:
    """Accept a strict SemVer 2.0.0 string; no prefix, padding or whitespace."""
    if not isinstance(text, str) or not _VERSION.fullmatch(text):
        raise ValueError("invalid SemVer version: " + repr(text))
    return text


def asset_name(extension_id: str, version: str) -> str:
    return f"{extension_id}-{parse_version(version)}.pulse-ext"


def plan(extension: str, artifacts: Path):
    """Resolve declared inputs under one artifact directory, failing early."""
    product = PRODUCTS.get(extension)
    if product is None:
        raise ValueError("unknown extension: " + extension)
    template = ROOT / product["template"]
    if not template.is_file():
        raise ValueError("missing manifest template: " + str(template))
    library = artifacts / product["library"]
    members = [(artifacts / name, name) for name in product["members"]]
    missing = [str(path) for path in (library, *(item[0] for item in members)) if not path.is_file()]
    if missing:
        raise ValueError(
            "missing build output(s): " + ", ".join(missing)
            + "; build with: " + "; ".join(product["build"]))
    for member, _ in members:
        digest = hashlib.sha256(member.read_bytes()).hexdigest()
        if digest.encode("ascii") not in library.read_bytes():
            option = ("-Dcompanion-helper-sha256=" if member.suffix == ".exe"
                      else "-Dcompanion-runtime-sha256=")
            raise ValueError(
                f"{library.name} was not built against {member.name} "
                f"(sha256 {digest}); rebuild with {option}{digest} "
                "and the other digest option as scripts/companion_host_smoke.py does")
    return {
        "id": product["id"],
        "versioned_id": product["id"],
        "template": template,
        "library": library,
        "members": members,
    }


def git(*args: str) -> str:
    result = subprocess.run(["git", *args], cwd=ROOT, check=True, capture_output=True,
                            text=True, encoding="utf-8", timeout=60)
    return result.stdout.strip()


def package(args) -> Path:
    version = parse_version(args.version)
    inputs = plan(args.extension, args.artifacts.resolve())
    pulse = args.pulse.resolve(strict=True)
    tool = (args.sdk_root.resolve() / "tools" / "extensions" / "pulse_ext.py").resolve(strict=True)
    out = args.out.resolve()
    if out.exists():
        raise ValueError("output directory already exists: " + str(out))
    if git("status", "--porcelain", "--untracked-files=normal"):
        raise ValueError("release packaging requires a clean source tree")
    revision = git("rev-parse", "HEAD")
    zig_version = (ROOT / ".zig-version").read_text(encoding="utf-8").strip()
    evidence = package_common.stage(
        pulse, tool, inputs["template"], out / "stage", inputs["id"],
        inputs["library"], inputs["members"])
    asset = asset_name(inputs["id"], version)
    archive = out / asset
    (out / "stage" / "candidate.pulse-ext").rename(archive)
    if package_common.sha256(archive) != evidence["package_sha256"]:
        raise RuntimeError("renamed archive digest changed")
    release = {
        "schema_version": 1,
        "extension_id": inputs["id"],
        "version": version,
        "asset": asset,
        "asset_sha256": evidence["package_sha256"],
        "manifest_sha256": evidence["manifest_sha256"],
        "source_revision": revision,
        "source_dirty": False,
        "zig_version": zig_version,
        "sdk_pin_sha256": package_common.sha256(ROOT / "sdk" / "upstream.toml",
                                                package_common.EVIDENCE_MAX),
        "host_sha256": evidence["host_sha256"],
        "author_sha256": evidence["author_sha256"],
        "template_sha256": evidence["template_sha256"],
        "library": evidence["library"],
        "members": evidence["members"],
        "official_verified": evidence["verified"],
        "signed": False,
        "published": False,
        "real_host_accepted": False,
    }
    package_common.write_evidence(out / "release-evidence.json", release)
    (out / "SHA256SUMS.txt").write_text(
        f"{evidence['package_sha256']}  {asset}\n"
        f"{evidence['manifest_sha256']}  stage/manifest.json\n",
        encoding="utf-8")
    return archive


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--extension", required=True, choices=sorted(PRODUCTS))
    parser.add_argument("--version", required=True, help="release SemVer, e.g. 0.1.0")
    parser.add_argument("--pulse", required=True, type=Path, help="trusted Pulse host executable")
    parser.add_argument("--sdk-root", required=True, type=Path,
                        help="SDK root containing tools/extensions/pulse_ext.py")
    parser.add_argument("--artifacts", type=Path, default=ROOT / "zig-out" / "bin",
                        help="directory holding the freshly built binaries")
    parser.add_argument("--out", required=True, type=Path,
                        help="fresh output directory; never overwritten")
    parser.add_argument("--dry-run", action="store_true",
                        help="validate declarations and print the plan without packaging")
    args = parser.parse_args(argv)
    try:
        if args.dry_run:
            version = parse_version(args.version)
            inputs = plan(args.extension, args.artifacts.resolve())
            print(json.dumps({
                "extension_id": inputs["id"],
                "version": version,
                "asset": asset_name(inputs["id"], version),
                "template": str(inputs["template"]),
                "library": str(inputs["library"]),
                "members": [name for _, name in inputs["members"]],
                "out": str(args.out),
                "dry_run": True,
            }, indent=2))
            return 0
        print(package(args))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"Release packaging failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
