"""Stage an isolated VCS acceptance package using the pinned official tool.

No native code execution, installation, enabling, signing or publication.
Require explicit paths; use a fresh output directory and never overwrite.
"""
from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

ROOT = Path(__file__).resolve().parents[1]


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def stage(pulse: Path, tool: Path, library: Path, out: Path) -> Path:
    pulse, tool, library, out = (p.resolve() for p in (pulse, tool, library, out))
    for path in (pulse, tool, library):
        if not path.is_file():
            raise ValueError(f"Missing input: {path}")
    if library.name != "pulse_vcs_panel.dll":
        raise ValueError("Expected pulse_vcs_panel.dll")
    out.mkdir(parents=True, exist_ok=False)
    copy = out / library.name
    shutil.copyfile(library, copy)
    if digest(copy) != digest(library):
        raise ValueError("Library changed during staging")
    template = ROOT / "extensions/vcs-panel/manifest.test.json"
    manifest = out / "manifest.json"
    package = out / "strangelion.vcs-test.pulse-ext"
    commands = [
        ["native-manifest", str(template), "--library", str(copy), "--output", str(manifest)],
        ["pack", str(manifest), "--output", str(package)],
        ["verify", str(package)],
    ]
    reports = []
    for args in commands:
        result = subprocess.run(
            [sys.executable, str(tool), "--pulse", str(pulse), "--json", *args],
            capture_output=True, text=True, encoding="utf-8", errors="replace", timeout=90,
        )
        reports.append({"command": args[0], "exit": result.returncode,
                        "stdout": result.stdout[:65536], "stderr": result.stderr[:65536]})
        (out / "stage-report.json").write_text(json.dumps({"verified": False, "steps": reports}, indent=2), encoding="utf-8")
        if result.returncode:
            raise RuntimeError(f"{args[0]} failed; see stage-report.json")
    if not package.is_file() or not manifest.is_file():
        raise RuntimeError("Official tool did not produce the expected outputs")
    (out / "stage-report.json").write_text(json.dumps({
        "verified": True, "scope": "official package verification only; real-host acceptance NOT VERIFIED",
        "pulse_sha256": digest(pulse), "tool_sha256": digest(tool), "library_sha256": digest(copy),
        "manifest_sha256": digest(manifest), "package_sha256": digest(package), "steps": reports,
    }, indent=2), encoding="utf-8")
    return package


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("pulse", "tool", "library", "out"):
        parser.add_argument("--" + name, type=Path, required=True)
    args = parser.parse_args()
    try:
        print(stage(args.pulse, args.tool, args.library, args.out))
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"Staging failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
