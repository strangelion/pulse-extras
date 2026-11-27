"""Locally sign exact Pulse release manifest bytes using the pinned registry tool.

No key generation in CI, no upload, no publication and no private-key output.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import zipfile

import package_common as common
import release_workflow as release

REGISTRY_REVISION = "0a325ac77d5ecddb98a45f9062fd1b0129978dbe"
REGISTRY_URL = "https://github.com/jimmgreen/pulse-extensions"


def outside_repo(path: Path) -> Path:
    resolved = path.resolve(strict=True)
    if resolved.is_relative_to(release.ROOT.resolve()):
        raise ValueError("keep signing keys outside the pulse-extras repository")
    return resolved


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--product", required=True, choices=sorted(release.package.PRODUCTS))
    parser.add_argument("--candidate", required=True, type=Path,
                        help="original extracted dry-run per-product directory")
    parser.add_argument("--registry", required=True, type=Path)
    parser.add_argument("--private-key", required=True, type=Path)
    parser.add_argument("--public-key", required=True, type=Path)
    parser.add_argument("--publisher-name", default="Pulse Extras", help="public publisher display name")
    parser.add_argument("--out", required=True, type=Path, help="new local signature output directory")
    args = parser.parse_args()
    try:
        if sys.platform != "win32":
            raise ValueError("official CNG signing requires Windows")
        if not args.publisher_name.strip() or len(args.publisher_name) > 100:
            raise ValueError("invalid public publisher name")
        private, public = outside_repo(args.private_key), outside_repo(args.public_key)
        if private == public:
            raise ValueError("private and public key files must differ")
        common.regular_file(private, 8192)
        common.regular_file(public, 8192)
        registry = args.registry.resolve(strict=True)
        if (release.capture("git", "-C", str(registry), "rev-parse", "HEAD") != REGISTRY_REVISION
                or release.capture("git", "-C", str(registry), "status", "--porcelain", "--untracked-files=normal")):
            raise ValueError("registry tool must be a clean checkout of the reviewed revision")
        tool = registry / "tools/pulse_sign.py"
        common.regular_file(tool, common.FILE_MAX)
        directory = args.candidate.resolve(strict=True)
        evidence = common.read_evidence(directory / "release-evidence.json")
        revision = release.package.git("rev-parse", "HEAD")
        if release.package.git("status", "--porcelain", "--untracked-files=normal"):
            raise ValueError("signing requires clean source checkout of the exact candidate revision")
        item = release.plan(f"{args.product}={evidence['version']}", "dry-run")[0]
        release.verify_candidate(item, directory, revision)
        manifest = directory / "manifest.json"
        before = common.sha256(manifest, common.EVIDENCE_MAX)
        public_data = public.read_bytes()
        fingerprint = hashlib.sha256(public_data).hexdigest()
        out = args.out.resolve()
        out.mkdir(parents=True, exist_ok=False)
        signature = out / (item["asset"].removesuffix(".pulse-ext") + ".sig.json")
        # Never print or copy the private key; upstream CLI accepts its path.
        release.run(sys.executable, str(tool), "sign-manifest", str(manifest),
                    "--private-key", str(private), "--output", str(signature), cwd=registry)
        release.run(sys.executable, str(tool), "verify-manifest", str(manifest),
                    "--signature", str(signature), "--public-key", str(public), cwd=registry)
        signed = common.read_evidence(signature)
        if signed.get("publisher") != fingerprint or common.sha256(manifest, common.EVIDENCE_MAX) != before:
            raise ValueError("signature publisher or manifest identity mismatch")
        release.verify_candidate(item, directory, revision)
        common.write_evidence(out / "publisher.json", {
            "formatVersion": 1, "id": fingerprint, "name": args.publisher_name.strip(),
            "url": "https://github.com/strangelion/pulse-extras", "publicKey": public_data.hex(),
        })
        common.write_evidence(out / "signing-evidence.json", {
            "schema_version": 1, "source_revision": revision, "asset": item["asset"],
            "asset_sha256": evidence["asset_sha256"], "manifest_sha256": before,
            "signature": signature.name, "signature_sha256": common.sha256(signature),
            "signature_size": signature.stat().st_size, "publisher": fingerprint,
            "registry_tool_revision": REGISTRY_REVISION, "signature_verified": True,
            "published": False, "registry_accepted": False,
        })
        print("Signature verified; keep the original package unchanged. Public fingerprint: " + fingerprint)
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, subprocess.SubprocessError, zipfile.BadZipFile) as exc:
        print(f"Local signing failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
