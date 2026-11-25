#!/usr/bin/env python3
"""Build, verify and optionally launch a read-only Companion dev package.

Windows only. Uses the official matching SDK author tool and a new isolated
store/profile. Does not publish, sign, overwrite an existing directory, or
modify the production extension store. Native code is trusted in-process.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import stat

REPO = Path(__file__).resolve().parent.parent
PACKAGE = "strangelion.companion-dev"
HELPER_NAME = "pulse-pet-demo.exe"
HELPER_MAX_BYTES = 256 * 1024 * 1024


def sha256(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def helper_evidence(build: Path, backend: str) -> dict:
    """Record freshly built helper evidence, not execution approval."""
    if backend not in ("wic", "libwebp"):
        raise ValueError("unknown helper backend")
    expected = build / "bin" / HELPER_NAME
    matches = list(build.rglob(HELPER_NAME))
    if matches != [expected]:
        raise RuntimeError("expected exactly one helper at the fixed bin path")
    for path in (build, expected.parent, expected):
        st = path.lstat()
        if path.is_symlink() or getattr(st, "st_file_attributes", 0) & 0x400:
            raise RuntimeError("helper build path contains a reparse point")
    st = expected.lstat()
    if not stat.S_ISREG(st.st_mode) or st.st_nlink != 1 or not 0 < st.st_size <= HELPER_MAX_BYTES:
        raise RuntimeError("invalid helper file type, link count or size")
    digest = sha256(expected)
    after = expected.lstat()
    if (st.st_size, st.st_mtime_ns, st.st_ino) != (after.st_size, after.st_mtime_ns, after.st_ino):
        raise RuntimeError("helper changed during evidence collection")
    return {
        "path": expected.relative_to(build.parent).as_posix(),
        "sha256": digest,
        "bytes": st.st_size,
        "backend": backend,
        "target": "x86_64-windows-gnu",
        "runtime_approved": False,
    }


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
    parser.add_argument("--launch", action="store_true",
                        help="explicitly consent to install, enable and run this unsigned native development package in an isolated host")
    args = parser.parse_args()
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
    command(["zig", "version"], out / "02-zig-version.log")
    command(["git", "rev-parse", "HEAD"], out / "03-source-revision.log")
    command(["git", "status", "--porcelain", "--untracked-files=no"], out / "04-source-status.log")
    build = out / "build"
    command(["zig", "build", "-Dtarget=x86_64-windows-msvc", "-Doptimize=ReleaseSafe",
             "--prefix", str(build), "--summary", "all"], out / "05-build.log")
    matches = list(build.rglob("pulse_companion.dll"))
    if len(matches) != 1:
        raise RuntimeError("expected exactly one freshly built Companion DLL")
    dll = matches[0]
    manifest = dll.parent / "manifest.json"
    package = out / "companion-dev.pulse-ext"
    common = [py, str(author), "--pulse", str(pulse), "--json"]
    command(common + ["native-manifest", str(REPO / "extensions/companion/manifest.dev.json"),
                      "--library", str(dll), "--output", str(manifest)], out / "06-manifest.log")
    command(common + ["pack", str(manifest), "--output", str(package)], out / "07-pack.log")
    command(common + ["verify", str(package)], out / "08-verify.log")
    evidence = {
        "package": PACKAGE,
        "source_revision": (out / "03-source-revision.log").read_text().strip(),
        "tracked_source_dirty": bool((out / "04-source-status.log").read_text().strip()),
        "host_sha256": sha256(pulse),
        "dll_sha256": sha256(dll),
        "package_sha256": sha256(package),
        "real_host_accepted": False,
    }
    if args.prepare_helper:
        helper_build = out / "helper-build"
        helper_build.mkdir(exist_ok=False)
        helper_args = ["zig", "build", "pet-demo", "-Doptimize=ReleaseSafe",
                       "--prefix", str(helper_build), "--summary", "all"]
        if args.prepare_helper == "libwebp":
            helper_args.append("-Dpet-libwebp=true")
        command(helper_args, out / "05-helper-build.log")
        evidence["helper"] = helper_evidence(helper_build, args.prepare_helper)
    with (out / "build-evidence.json").open("x", encoding="utf-8") as stream:
        json.dump(evidence, stream, indent=2)
        stream.write("\n")
    print(f"Verified development package: {package}", flush=True)
    if args.prepare_helper:
        print("Standalone helper evidence collected; helper is not packaged, approved or launched.")
    if not args.launch:
        print("Not installed or launched. Use a fresh output with --launch for interactive acceptance.")
        return 0
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
    except (OSError, RuntimeError, subprocess.CalledProcessError) as exc:
        print(f"Companion acceptance preparation failed: {exc}", file=sys.stderr)
        raise SystemExit(1)
