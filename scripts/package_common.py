"""Shared package staging primitives; official Pulse tool remains authoritative.

Caller owns a fresh private staging directory and independently trusts the
host, author tool, manifest template and source outputs. No install, launch,
signature, publication or automatic discovery. Not a race-free path sandbox.
"""
from __future__ import annotations

import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess
import sys

FILE_MAX = 64 * 1024 * 1024
ARCHIVE_MAX = 256 * 1024 * 1024 + 256 * 1024
EVIDENCE_MAX = 64 * 1024


def regular_file(path: Path, limit: int):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or getattr(info, "st_file_attributes", 0) & 0x400
            or not 0 < info.st_size <= limit):
        raise RuntimeError("invalid bounded regular file: " + path.name)
    return info


def require_digest(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise RuntimeError("expected lowercase SHA-256")
    return value


def sha256(path: Path, limit: int = ARCHIVE_MAX) -> str:
    before = regular_file(path, limit)
    digest = hashlib.sha256()
    total = 0
    with path.open("rb") as stream:
        while chunk := stream.read(64 * 1024):
            total += len(chunk)
            if total > limit:
                raise RuntimeError("file exceeds limit")
            digest.update(chunk)
    after = regular_file(path, limit)
    if total != before.st_size or _identity(before) != _identity(after):
        raise RuntimeError("file changed during hashing")
    return digest.hexdigest()


def _identity(info):
    return info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns


def member_name(name: str) -> str:
    if (not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", name)
            or name.endswith(".") or ".." in name
            or name.split(".")[0].upper() in {
                "CON", "PRN", "AUX", "NUL",
                *(f"COM{i}" for i in range(1, 10)),
                *(f"LPT{i}" for i in range(1, 10)),
            }):
        raise ValueError("invalid flat package member")
    return name


def copy_checked(source: Path, destination: Path, expected: str,
                 limit: int = FILE_MAX) -> dict:
    member_name(destination.name)
    expected = require_digest(expected)
    before = regular_file(source, limit)
    total = 0
    digest = hashlib.sha256()
    with source.open("rb") as src, destination.open("xb") as dst:
        while chunk := src.read(64 * 1024):
            total += len(chunk)
            if total > limit:
                raise RuntimeError("copy exceeds limit")
            digest.update(chunk)
            dst.write(chunk)
    after = regular_file(source, limit)
    if (total != before.st_size or _identity(before) != _identity(after)
            or digest.hexdigest() != expected or sha256(destination, limit) != expected):
        raise RuntimeError("copy or source digest mismatch")
    return {"path": destination.name, "sha256": expected}


def read_evidence(path: Path) -> dict:
    regular_file(path, EVIDENCE_MAX)
    with path.open("rb") as stream:
        data = stream.read(EVIDENCE_MAX + 1)
    if len(data) > EVIDENCE_MAX:
        raise RuntimeError("evidence exceeds limit")
    result = json.loads(data)
    if not isinstance(result, dict):
        raise RuntimeError("invalid evidence object")
    return result


def write_evidence(path: Path, evidence: dict) -> None:
    data = (json.dumps(evidence, indent=2, ensure_ascii=True) + "\n").encode("utf-8")
    if len(data) > EVIDENCE_MAX:
        raise RuntimeError("evidence exceeds limit")
    with path.open("xb") as stream:
        stream.write(data)


def verify_manifest_bindings(manifest: Path, extension_id: str,
                             library: dict, members: list[dict]) -> None:
    document = read_evidence(manifest)
    native = document.get("native", {})
    if (document.get("id") != extension_id or native.get("library") != library["path"]
            or native.get("sha256") != library["sha256"]
            or native.get("files", []) != members):
        raise RuntimeError("manifest does not bind staged members")
    for item in [library, *members]:
        if sha256(manifest.parent / member_name(item["path"]), FILE_MAX) != require_digest(item["sha256"]):
            raise RuntimeError("staged member digest mismatch")


def official_step(pulse: Path, tool: Path, args: list[str], log: Path,
                  timeout: int = 90) -> None:
    # Explicit trusted author tool; no shell. Logs remain in the private
    # staging directory, not captured in memory. Disk use is not hard capped
    # for this trusted developer-only tool; never use for untrusted children.
    if not args or args[0] not in {"native-manifest", "pack", "verify"}:
        raise ValueError("unsupported official staging action")
    if not 0 < timeout <= 300:
        raise ValueError("invalid timeout")
    with log.open("xb") as stream:
        subprocess.run([sys.executable, str(tool), "--pulse", str(pulse), "--json", *args],
                       stdout=stream, stderr=subprocess.STDOUT, timeout=timeout, check=True)


def stage(pulse: Path, tool: Path, template: Path, out: Path, extension_id: str,
          library: Path, members: list[tuple[Path, str]]) -> dict:
    """Fresh isolated staging; caller chooses trusted paths and fixed member names."""
    if len(members) > 63:
        raise ValueError("too many package members")
    # Do not resolve source leaf symlinks before validation.
    names = [member_name(library.name), *(member_name(name) for _, name in members)]
    if len(set(name.lower() for name in names)) != len(names) or any(
            name.lower() in {"manifest.json", "package.json", "build-evidence.json",
                             "native-manifest.log", "pack.log", "verify.log", "candidate.pulse-ext"}
            for name in names):
        raise ValueError("duplicate or reserved package name")
    total = sum(regular_file(path, FILE_MAX).st_size for path in [library, *(p for p, _ in members)])
    if total > 256 * 1024 * 1024:
        raise RuntimeError("package payload exceeds limit")
    host_sha, tool_sha = sha256(pulse), sha256(tool)
    template_sha = sha256(template, EVIDENCE_MAX)
    out.mkdir(parents=True, exist_ok=False)
    entry = copy_checked(library, out / library.name, sha256(library, FILE_MAX))
    files = [copy_checked(path, out / name, sha256(path, FILE_MAX)) for path, name in members]
    manifest, package = out / "manifest.json", out / "candidate.pulse-ext"
    args = ["native-manifest", str(template), "--library", str(out / library.name), "--output", str(manifest)]
    for item in files:
        args.extend(["--file", str(out / item["path"])])
    official_step(pulse, tool, args, out / "native-manifest.log")
    verify_manifest_bindings(manifest, extension_id, entry, files)
    manifest_sha = sha256(manifest, EVIDENCE_MAX)
    official_step(pulse, tool, ["pack", str(manifest), "--output", str(package)], out / "pack.log")
    package_sha = sha256(package)
    official_step(pulse, tool, ["verify", str(package)], out / "verify.log")
    verify_manifest_bindings(manifest, extension_id, entry, files)
    if (sha256(package) != package_sha or sha256(manifest, EVIDENCE_MAX) != manifest_sha
            or sha256(pulse) != host_sha or sha256(tool) != tool_sha
            or sha256(template, EVIDENCE_MAX) != template_sha):
        raise RuntimeError("staging inputs or outputs changed")
    evidence = {"schema_version": 1, "extension_id": extension_id, "verified": True,
                "real_host_accepted": False, "package_sha256": package_sha,
                "manifest_sha256": manifest_sha, "host_sha256": host_sha,
                "author_sha256": tool_sha, "template_sha256": template_sha,
                "library": entry, "members": files}
    write_evidence(out / "build-evidence.json", evidence)
    return evidence
