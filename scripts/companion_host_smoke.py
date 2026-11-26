#!/usr/bin/env python3
"""Build, verify or reuse an exact official Companion development package.

Windows only. Launch requires explicit acknowledgement of a dedicated
test user/VM as well as a fresh host store/profile. No production signing,
publication, or existing-store mutation. Native code is trusted in-process.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import stat
import zipfile

REPO = Path(__file__).resolve().parent.parent
PACKAGE = "strangelion.companion-dev"
HELPER_NAME = "pulse-pet-demo.exe"
HELPER_MAX_BYTES = 256 * 1024 * 1024
RUNTIME_NAME = "pulse_companion_runtime.dll"
PACKAGE_FILE_MAX = 64 * 1024 * 1024
ARCHIVE_MAX = 256 * 1024 * 1024 + 256 * 1024
EVIDENCE_MAX = 64 * 1024
PACKAGE_NAME = "companion-dev.pulse-ext"
ENTRY_NAME = "pulse_companion.dll"
EVIDENCE_VERSION = 2
NOTICE_NAMES = ("libwebp-COPYING.txt", "libwebp-PATENTS.txt")


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def binary_evidence(build: Path, name: str) -> dict:
    if name not in (HELPER_NAME, RUNTIME_NAME):
        raise ValueError("unknown build output")
    expected = build / "bin" / name
    matches = list(build.rglob(name))
    if matches != [expected]:
        raise RuntimeError("expected exactly one binary at the fixed bin path")
    for path in (build, expected.parent, expected):
        st = path.lstat()
        if path.is_symlink() or getattr(st, "st_file_attributes", 0) & 0x400:
            raise RuntimeError("binary build path contains a reparse point")
    st = expected.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or not 0 < st.st_size <= HELPER_MAX_BYTES:
        raise RuntimeError("invalid binary file type, link count or size")
    digest = sha256(expected)
    after = expected.lstat()
    if (st.st_size, st.st_mtime_ns, st.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
        raise RuntimeError("binary changed during evidence collection")
    return {
        "path": expected.relative_to(build.parent).as_posix(),
        "sha256": digest,
        "bytes": st.st_size,
        "target": "x86_64-windows-gnu",
        "runtime_approved": False,
    }


def helper_evidence(build: Path, backend: str) -> dict:
    """Record freshly built helper evidence, not execution approval."""
    if backend not in ("wic", "libwebp"):
        raise ValueError("unknown helper backend")
    record = binary_evidence(build, HELPER_NAME)
    record["backend"] = backend
    return record


def stage_package_file(source: Path, directory: Path, name: str, expected: str) -> dict:
    """Copy a known output without replacing anything; verify the copied bytes."""
    allowed = (HELPER_NAME, RUNTIME_NAME, "libwebp-COPYING.txt", "libwebp-PATENTS.txt")
    if name not in allowed:
        raise ValueError("unknown package member")
    info = source.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or getattr(info, "st_file_attributes", 0) & 0x400
            or not 0 < info.st_size <= PACKAGE_FILE_MAX):
        raise RuntimeError("invalid package member")
    destination = directory / name
    # Copy bounded chunks from the open source. A digest mismatch leaves the
    # fresh acceptance directory for diagnosis; nothing gets installed.
    digest = hashlib.sha256()
    total = 0
    with source.open("rb") as src, destination.open("xb") as dst:
        while chunk := src.read(64 * 1024):
            total += len(chunk)
            if total > PACKAGE_FILE_MAX:
                raise RuntimeError("package member exceeds limit")
            digest.update(chunk)
            dst.write(chunk)
    if total != info.st_size or digest.hexdigest() != expected or sha256(destination) != expected:
        raise RuntimeError("package member changed or copy digest mismatch")
    return {"path": name, "sha256": expected}


def verify_manifest_files(manifest: Path, members: list[dict]) -> None:
    native = json.loads(manifest.read_text(encoding="utf-8"))["native"]
    if native.get("files", []) != members:
        raise RuntimeError("author manifest does not bind the staged runtime members")
    for member in members:
        if sha256(manifest.parent / member["path"]) != member["sha256"]:
            raise RuntimeError("staged package member changed before packing")


def require_digest(value: object) -> str:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9a-f]{64}", value):
        raise RuntimeError("expected a lowercase SHA-256 digest")
    return value


def regular_file(path: Path, limit: int):
    info = path.lstat()
    if (not stat.S_ISREG(info.st_mode) or info.st_nlink != 1
            or getattr(info, "st_file_attributes", 0) & 0x400
            or not 0 < info.st_size <= limit):
        raise RuntimeError("invalid bounded regular file: " + path.name)
    return info


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


def copy_archive(source: Path, destination: Path, expected: str) -> None:
    """Copy the fixed archive, not paths from evidence; never overwrite."""
    expected = require_digest(expected)
    before = regular_file(source, ARCHIVE_MAX)
    total = 0
    digest = hashlib.sha256()
    with source.open("rb") as src, destination.open("xb") as dst:
        while chunk := src.read(64 * 1024):
            total += len(chunk)
            if total > ARCHIVE_MAX:
                raise RuntimeError("archive exceeds limit")
            digest.update(chunk)
            dst.write(chunk)
    after = regular_file(source, ARCHIVE_MAX)
    if (total != before.st_size or digest.hexdigest() != expected
            or (before.st_size, before.st_mtime_ns, before.st_ino)
            != (after.st_size, after.st_mtime_ns, after.st_ino)
            or sha256(destination) != expected):
        raise RuntimeError("archive changed or digest mismatch")


def validate_evidence(evidence: dict, expected: str, host_sha: str,
                      author_sha: str, catalog_sha: str) -> None:
    if (evidence.get("schema_version") != EVIDENCE_VERSION
            or evidence.get("package") != PACKAGE
            or evidence.get("bundled_runtime") is not True
            or evidence.get("source_dirty") is not False
            or evidence.get("real_host_accepted") is not False):
        raise RuntimeError("reuse requires a clean, bundled development build")
    if not re.fullmatch(r"[0-9a-f]{40}", str(evidence.get("source_revision", ""))):
        raise RuntimeError("invalid source revision")
    for key, digest in (("package_sha256", expected), ("host_sha256", host_sha),
                        ("author_sha256", author_sha), ("sdk_catalog_sha256", catalog_sha)):
        if require_digest(evidence.get(key)) != require_digest(digest):
            raise RuntimeError("evidence mismatch: " + key)
    for key in ("manifest_sha256", "dll_sha256", "sdk_pin_sha256"):
        require_digest(evidence.get(key))
    if not isinstance(evidence.get("zig_version"), str) or not evidence["zig_version"]:
        raise RuntimeError("missing Zig build version")
    helper = evidence.get("helper")
    runtime = evidence.get("runtime")
    if not isinstance(helper, dict) or not isinstance(runtime, dict):
        raise RuntimeError("missing binary evidence")
    backend = helper.get("backend")
    if backend not in ("wic", "libwebp"):
        raise RuntimeError("unknown build backend")
    members = evidence.get("package_members")
    if not isinstance(members, list):
        raise RuntimeError("missing package members")
    names = [RUNTIME_NAME, HELPER_NAME]
    if backend == "libwebp":
        names.extend(NOTICE_NAMES)
    if len(members) != len(names):
        raise RuntimeError("unexpected member count")
    for member, name in zip(members, names):
        if not isinstance(member, dict) or set(member) != {"path", "sha256"} or member["path"] != name:
            raise RuntimeError("unexpected package member")
        require_digest(member["sha256"])
    if (members[0]["sha256"] != require_digest(runtime.get("sha256"))
            or members[1]["sha256"] != require_digest(helper.get("sha256"))):
        raise RuntimeError("runtime/helper evidence does not bind package")


def verify_archive_bindings(package: Path, evidence: dict) -> None:
    """After official verify, additionally bind its exact manifest to evidence.

    This is not an alternative package verifier or a trust/signature proof.
    Only small manifest bytes are read, never extracted or executed here.
    """
    regular_file(package, ARCHIVE_MAX)
    if sha256(package) != require_digest(evidence.get("package_sha256")):
        raise RuntimeError("package digest mismatch")
    with zipfile.ZipFile(package) as archive:
        infos = archive.infolist()
        expected_names = {"manifest.json", "package.json", ENTRY_NAME}
        expected_names.update(member["path"] for member in evidence["package_members"])
        if len(infos) != len(expected_names) or {info.filename for info in infos} != expected_names:
            raise RuntimeError("unexpected official archive inventory")
        info = archive.getinfo("manifest.json")
        if not 0 < info.file_size <= EVIDENCE_MAX:
            raise RuntimeError("manifest exceeds limit")
        with archive.open(info) as stream:
            raw = stream.read(EVIDENCE_MAX + 1)
        if len(raw) != info.file_size or hashlib.sha256(raw).hexdigest() != evidence["manifest_sha256"]:
            raise RuntimeError("manifest digest mismatch")
        manifest = json.loads(raw)
        native = manifest.get("native", {})
        if (manifest.get("id") != PACKAGE or native.get("library") != ENTRY_NAME
                or native.get("sha256") != evidence["dll_sha256"]
                or native.get("files", []) != evidence["package_members"]):
            raise RuntimeError("manifest does not bind development entry/members")
    if sha256(package) != evidence["package_sha256"]:
        raise RuntimeError("package changed during evidence verification")


def write_evidence(out: Path, evidence: dict) -> None:
    with (out / "build-evidence.json").open("x", encoding="utf-8") as stream:
        json.dump(evidence, stream, indent=2)
        stream.write("\n")


def command(args: list[str], log: Path, env: dict[str, str] | None = None) -> None:
    print(f"Running {log.stem} (log: {log})", flush=True)
    with log.open("xb") as stream:
        subprocess.run(args, cwd=REPO, stdout=stream, stderr=subprocess.STDOUT,
                       env=env, check=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pulse", required=True, type=Path, help="actual Pulse host executable")
    parser.add_argument("--sdk-root", required=True, type=Path, help="SDK root containing tools/extensions/pulse_ext.py")
    parser.add_argument("--out", required=True, type=Path, help="new, empty-by-creation acceptance directory")
    parser.add_argument("--prepare-helper", choices=("wic", "libwebp"),
                        help="also build and record a standalone helper; does not package or launch it")
    parser.add_argument("--bundle-runtime", action="store_true",
                        help="include Runtime DLL and prepared helper in the verified dev package")
    parser.add_argument("--reuse-from", type=Path,
                        help="reuse a clean bundled build from a previous fresh acceptance directory")
    parser.add_argument("--expected-sha256", help="exact previously recorded archive SHA-256 for reuse")
    parser.add_argument("--launch", action="store_true",
                        help="explicitly consent to install, enable and run this unsigned native development package")
    parser.add_argument("--confirm-isolated-user", action="store_true",
                        help="acknowledge this is a dedicated Windows test user/VM without production Companion data")
    args = parser.parse_args()
    if args.bundle_runtime and not args.prepare_helper:
        parser.error("--bundle-runtime requires --prepare-helper wic or libwebp")
    if args.reuse_from and (args.prepare_helper or args.bundle_runtime or not args.expected_sha256):
        parser.error("--reuse-from requires --expected-sha256 and cannot rebuild")
    if args.expected_sha256 and not args.reuse_from:
        parser.error("--expected-sha256 requires --reuse-from")
    if args.launch and not args.confirm_isolated_user:
        parser.error("--launch requires --confirm-isolated-user; host profile alone is not OS data isolation")
    if os.name != "nt":
        parser.error("this smoke test requires Windows and an installed Pulse host")
    pulse = args.pulse.resolve(strict=True)
    author = (args.sdk_root / "tools" / "extensions" / "pulse_ext.py").resolve(strict=True)
    if not pulse.is_file() or pulse.suffix.lower() != ".exe" or not author.is_file():
        parser.error("expected a Pulse executable and the official author tool")
    out = args.out.resolve()
    # Never use a preexisting output, even an empty one.
    out.mkdir(parents=True, exist_ok=False)
    print(f"Acceptance directory: {out}", flush=True)
    env = dict(os.environ)
    env["ABI_PROBE_LOG"] = str(out / "companion-lifecycle.log")
    py = sys.executable
    command([py, str(REPO / "scripts" / "host_sdk.py"), "extract",
             "--pulse", str(pulse), "--out", str(out / "host-sdk")],
            out / "01-host-sdk.log")
    package = out / PACKAGE_NAME
    common = [py, str(author), "--pulse", str(pulse), "--json"]
    host_sha = sha256(pulse)
    author_sha = sha256(author)
    provenance = read_evidence(out / "host-sdk" / "provenance.json")
    catalog_sha = require_digest(provenance["sdk"]["catalogSha256"])
    if args.reuse_from:
        source = args.reuse_from.resolve(strict=True)
        expected = require_digest(args.expected_sha256)
        evidence = read_evidence(source / "build-evidence.json")
        validate_evidence(evidence, expected, host_sha, author_sha, catalog_sha)
        copy_archive(source / PACKAGE_NAME, package, expected)
        command(common + ["verify", str(package)], out / "08-verify.log")
        verify_archive_bindings(package, evidence)
        evidence["reused_exact_archive"] = True
        write_evidence(out, evidence)
        print(f"Verified reused development package: {package}", flush=True)
        return launch_or_finish(args, common, out, package, evidence, env)

    command(["zig", "version"], out / "02-zig-version.log")
    command(["git", "rev-parse", "HEAD"], out / "03-source-revision.log")
    command(["git", "status", "--porcelain", "--untracked-files=normal"], out / "04-source-status.log")
    zig_version = (out / "02-zig-version.log").read_text().strip()
    if zig_version != (REPO / ".zig-version").read_text().strip():
        raise RuntimeError("Zig build version does not match repository pin")
    dirty = bool((out / "04-source-status.log").read_text().strip())
    if dirty:
        raise RuntimeError("acceptance build requires clean source; use an ignored output directory")
    evidence = {
        "schema_version": EVIDENCE_VERSION,
        "package": PACKAGE,
        "source_revision": (out / "03-source-revision.log").read_text().strip(),
        "source_dirty": dirty,
        "zig_version": zig_version,
        "sdk_pin_sha256": sha256(REPO / "sdk" / "upstream.toml"),
        "host_sha256": host_sha,
        "author_sha256": author_sha,
        "sdk_catalog_sha256": catalog_sha,
        "real_host_accepted": False,
        "reused_exact_archive": False,
    }
    members = []
    runtime_build = None
    helper_build = None
    if args.prepare_helper:
        helper_build = out / "helper-build"
        helper_build.mkdir(exist_ok=False)
        helper_args = ["zig", "build", "pet-demo", "-Doptimize=ReleaseSafe",
                       "--prefix", str(helper_build), "--summary", "all"]
        if args.prepare_helper == "libwebp":
            helper_args.append("-Dpet-libwebp=true")
        command(helper_args, out / "05-helper-build.log")
        evidence["helper"] = helper_evidence(helper_build, args.prepare_helper)
        if args.bundle_runtime:
            runtime_build = out / "runtime-build"
            runtime_build.mkdir(exist_ok=False)
            command(["zig", "build", "companion-runtime-bridge", "-Doptimize=ReleaseSafe",
                     "--prefix", str(runtime_build), "--summary", "all"], out / "05-runtime-build.log")
            evidence["runtime"] = binary_evidence(runtime_build, RUNTIME_NAME)
    build = out / "build"
    build_args = ["zig", "build", "-Dtarget=x86_64-windows-msvc", "-Doptimize=ReleaseSafe",
                  "--prefix", str(build), "--summary", "all"]
    if args.bundle_runtime:
        build_args.append("-Dcompanion-runtime-sha256=" + evidence["runtime"]["sha256"])
        build_args.append("-Dcompanion-helper-sha256=" + evidence["helper"]["sha256"])
    command(build_args, out / "05-build.log")
    matches = list(build.rglob("pulse_companion.dll"))
    if len(matches) != 1:
        raise RuntimeError("expected exactly one freshly built Companion DLL")
    dll = matches[0]
    evidence["dll_sha256"] = sha256(dll)
    manifest = dll.parent / "manifest.json"
    if args.bundle_runtime:
        assert runtime_build is not None and helper_build is not None
        members.append(stage_package_file(runtime_build / "bin" / RUNTIME_NAME,
                                          dll.parent, RUNTIME_NAME, evidence["runtime"]["sha256"]))
        members.append(stage_package_file(helper_build / "bin" / HELPER_NAME,
                                          dll.parent, HELPER_NAME, evidence["helper"]["sha256"]))
        if args.prepare_helper == "libwebp":
            for notice in ("COPYING", "PATENTS"):
                source = REPO / ".local" / "deps" / "libwebp-1.6.0" / notice
                members.append(stage_package_file(source, dll.parent,
                                                  f"libwebp-{notice}.txt", sha256(source)))
    manifest_args = common + ["native-manifest", str(REPO / "extensions/companion/manifest.dev.json"),
                              "--library", str(dll), "--output", str(manifest)]
    for member in members:
        manifest_args += ["--file", str(dll.parent / member["path"])]
    command(manifest_args, out / "06-manifest.log")
    verify_manifest_files(manifest, members)
    command(common + ["pack", str(manifest), "--output", str(package)], out / "07-pack.log")
    command(common + ["verify", str(package)], out / "08-verify.log")
    evidence["package_sha256"] = sha256(package)
    evidence["manifest_sha256"] = sha256(manifest)
    evidence["bundled_runtime"] = args.bundle_runtime
    evidence["package_members"] = members
    verify_archive_bindings(package, evidence)
    write_evidence(out, evidence)
    print(f"Verified development package: {package}", flush=True)
    return launch_or_finish(args, common, out, package, evidence, env)


def launch_or_finish(args, common: list[str], out: Path, package: Path,
                     evidence: dict, env: dict[str, str]) -> int:
    print("Package SHA-256:", evidence["package_sha256"], flush=True)
    if not args.launch:
        print("Not installed or launched. Bundled builds may be reused by exact digest.")
        return 0
    # Recheck the copied/built archive just before official install. The
    # official tool also verifies its own immutable archive snapshot.
    verify_archive_bindings(package, evidence)
    if sha256(args.pulse.resolve(strict=True)) != evidence["host_sha256"]:
        raise RuntimeError("host changed before installation")
    store = out / "store"
    profile = out / "profile"
    command(common + ["install", str(package), "--store", str(store), "--allow-native"],
            out / "09-install.log")
    command(common + ["enable", PACKAGE, "--store", str(store), "--allow-native"],
            out / "10-enable.log")
    command(common + ["run", "--store", str(store), "--profile", str(profile)],
            out / "11-run.log", env)
    print((out / "11-run.log").read_text(encoding="utf-8", errors="replace"))
    print("Open Pulse Companion (Development) from the extension entry, then its settings page.")
    print("Host launch is not acceptance. See docs/companion-host-smoke.md.")
    return 0


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except (OSError, RuntimeError, ValueError, KeyError, TypeError,
            zipfile.BadZipFile, subprocess.CalledProcessError) as exc:
        print(f"Companion acceptance preparation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
