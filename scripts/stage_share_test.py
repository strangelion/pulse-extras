"""Build a digest-bound Share DLL and stage a private acceptance package.

Requires matching, locally trusted helper binaries and the pinned Zig and
official Pulse author tools. No install, launch, signing or publication.
The output directory must not already exist.
"""
from __future__ import annotations

import argparse
import json
from pathlib import Path
import subprocess
import sys
import tempfile

import package_common as pkg

ROOT = Path(__file__).resolve().parents[1]
EXTENSION_ID = "strangelion.share-dev"
HELPERS = ("lan", "local", "worker")


def prepare(pulse: Path, tool: Path, binaries: Path, out: Path) -> dict:
    if out.exists():
        raise ValueError("Output directory already exists")
    if not out.parent.is_dir():
        raise ValueError("Create the trusted output parent directory first")
    # Use a private fresh workspace and build against exact copied inputs.
    # No arbitrary binary lookup, inherited PATH is only used for pinned Zig.
    with tempfile.TemporaryDirectory(prefix="share-build-", dir=out.parent) as temp:
        work = Path(temp).resolve()
        members = []
        flags = []
        for key in HELPERS:
            name = f"pulse-share-{key}.exe"
            source = binaries / name
            expected = pkg.sha256(source, pkg.FILE_MAX)
            copied = work / name
            pkg.copy_checked(source, copied, expected)
            members.append((copied, name))
            flags.append(f"-Dshare-{key}-sha256={expected}")
        version = (ROOT / ".zig-version").read_text(encoding="utf-8").strip()
        actual = subprocess.check_output(["zig", "version"], text=True, timeout=30).strip()
        if actual != version:
            raise ValueError(f"Expected pinned Zig {version}, got {actual}")
        prefix = work / "build"
        subprocess.run(
            ["zig", "build", "share-dev", "-Dtarget=x86_64-windows-msvc",
             "-Doptimize=ReleaseSafe", "--prefix", str(prefix), *flags],
            cwd=ROOT, check=True, timeout=300,
        )
        library = prefix / "bin" / "pulse_share.dll"
        # Keep the exact helper bindings consistent after compilation.
        for (path, _), flag in zip(members, flags, strict=True):
            if pkg.sha256(path, pkg.FILE_MAX) != flag.split("=", 1)[1]:
                raise RuntimeError("Helper changed during DLL compilation")
        return pkg.stage(pulse, tool, ROOT / "extensions/share/manifest.dev.json",
                         out, EXTENSION_ID, library, members)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("pulse", "tool", "binaries", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        evidence = prepare(args.pulse.absolute(), args.tool.absolute(),
                           args.binaries.absolute(), args.out.absolute())
        print(json.dumps(evidence, indent=2))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"Share staging failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
