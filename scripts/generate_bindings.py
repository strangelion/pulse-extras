"""Generate the Zig bindings for the pinned Pulse native SDK headers.

The bindings are produced with `zig translate-c` from an umbrella header that
includes every published `pulse/*.h` file, so the whole ABI lands in one Zig
module and there are no duplicated (conflicting) struct definitions.

Usage::

    python scripts/generate_bindings.py            # write shared/pulse/raw/pulse_all.zig
    python scripts/generate_bindings.py --check    # fail when the file is stale

The include directory defaults to `.sdk-cache/include` (what CI populates with
`scripts/fetch_sdk.py`) and falls back to `.local/sdk/sdk/native/include`.
"""

from __future__ import annotations

import argparse
import difflib
import hashlib
import pathlib
import re
import shutil
import subprocess
import sys
import tempfile

sys.path.insert(0, str(pathlib.Path(__file__).resolve().parent))
from sdk_headers import HEADERS  # noqa: E402  (script-local helper, not a package)
import upstream_pin as pin_config  # noqa: E402

ROOT = pathlib.Path(__file__).resolve().parent.parent
DEFAULT_OUTPUT = ROOT / "shared/pulse/raw/pulse_all.zig"


def resolve_include(explicit: pathlib.Path | None) -> pathlib.Path:
    candidates = [explicit] if explicit else [
        ROOT / ".sdk-cache/include",
        ROOT / ".local/sdk/sdk/native/include",
    ]
    for candidate in candidates:
        if candidate and (candidate / "pulse" / "abi.h").is_file():
            return candidate.resolve()
    raise SystemExit("no SDK headers found; run scripts/fetch_sdk.py or pass --include")


def upstream_pin() -> dict:
    path = ROOT / "sdk/upstream.toml"
    return pin_config.load(path)


def verify_headers(include: pathlib.Path, pin: dict) -> None:
    """Verify every pinned header digest before generating bindings."""
    digests = pin.get("headers", {})
    for name in HEADERS:
        header = include / "pulse" / f"{name}.h"
        if not header.is_file():
            raise SystemExit(f"missing SDK header {header}; run scripts/fetch_sdk.py")
        expected = digests.get(name)
        if not expected:
            raise SystemExit(f"missing pinned digest for {header}")
        actual = hashlib.sha256(header.read_bytes()).hexdigest()
        if actual != expected:
            raise SystemExit(
                f"{header} sha256 mismatch: {actual} != {expected} (pinned in sdk/upstream.toml)"
            )
    verify_abi_header(include, pin)


def verify_abi_header(include: pathlib.Path, pin: dict) -> None:
    header = include / "pulse" / "abi.h"
    blob = subprocess.run(
        ["git", "hash-object", str(header)], capture_output=True, text=True, check=False
    )
    if blob.returncode != 0:
        raise SystemExit(f"git hash-object failed for {header}: {blob.stderr.strip()}")
    expected = pin.get("abi_header_blob")
    if expected and blob.stdout.strip() != expected:
        raise SystemExit(
            f"abi.h blob mismatch: {blob.stdout.strip()} != {expected} (pinned in sdk/upstream.toml)"
        )


def normalize_source_locations(text: str) -> str:
    """Normalize only standalone translate-c source-location comments.

    Preserve declarations, diagnostics, line/column numbers and all other
    text. SDK and compiler header paths vary between installations.
    """
    pattern = re.compile(r"(?m)^(?P<indent>[ \t]*)// (?P<path>[^\r\n]+):(?P<line>[0-9]+):(?P<column>[0-9]+)$")

    def replace(match: re.Match[str]) -> str:
        path = match["path"].replace("\\", "/")
        if not (path.startswith("/") or re.match(r"^[A-Za-z]:/", path)):
            return match[0]
        # Only known headers in the pinned SDK or compiler stdint header.
        for name in HEADERS:
            if path.endswith(f"/pulse/{name}.h"):
                path = f"pulse/{name}.h"
                break
        else:
            if path.endswith("/lib/include/stdint.h"):
                path = "zig/lib/include/stdint.h"
            else:
                return match[0]
        return f'{match["indent"]}// {path}:{match["line"]}:{match["column"]}'

    return pattern.sub(replace, text)


def build_bindings(zig: str, include: pathlib.Path) -> str:
    with tempfile.TemporaryDirectory(prefix="pulse-bindings-") as directory:
        umbrella = pathlib.Path(directory) / "pulse_all.h"
        umbrella.write_text(
            "\n".join(f'#include "pulse/{name}.h"' for name in HEADERS) + "\n", encoding="utf-8"
        )
        result = subprocess.run(
            [zig, "translate-c", "-target", "x86_64-windows-msvc", "-I", str(include), str(umbrella)],
            capture_output=True,
            text=True,
            check=False,
            env={**__import__("os").environ, "ZIG_GLOBAL_CACHE_DIR": str(ROOT / ".local/zig-global-cache")},
        )
        if result.returncode != 0:
            raise SystemExit(f"zig translate-c failed:\n{result.stderr}")
        if result.stderr.strip():
            print(result.stderr.strip(), file=sys.stderr)
        return result.stdout


def banner(include: pathlib.Path, pin: dict) -> str:
    lines = [
        "//! Generated by scripts/generate_bindings.py - do not edit by hand.",
        "//! Regenerate with: python scripts/generate_bindings.py",
        "//!",
        f"//! SDK revision: {pin.get('revision', 'unknown')}",
        f"//! Pulse source: {pin.get('pulse_source_version', 'unknown')}",
        f"//! SDK preview:  {pin.get('sdk_preview', 'unknown')}",
        "//!",
        "//! Header digests (sha256):",
    ]
    for name in HEADERS:
        digest = hashlib.sha256((include / "pulse" / f"{name}.h").read_bytes()).hexdigest()
        lines.append(f"//!   pulse/{name}.h {digest}")
    return "\n".join(lines) + "\n"


def formatted(zig: str, text: str) -> str:
    """Run `zig fmt` over the bindings so the committed file passes --check."""
    with tempfile.TemporaryDirectory() as work:
        path = pathlib.Path(work) / "pulse_all.zig"
        path.write_text(text, encoding="utf-8", newline="\n")
        subprocess.run([zig, "fmt", str(path)], check=True, capture_output=True, text=True)
        return path.read_text(encoding="utf-8")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--zig", default=shutil.which("zig") or "zig")
    parser.add_argument("--include", type=pathlib.Path, default=None)
    parser.add_argument("--out", type=pathlib.Path, default=DEFAULT_OUTPUT)
    parser.add_argument("--check", action="store_true", help="verify the committed file is current")
    args = parser.parse_args()

    include = resolve_include(args.include)
    pin = upstream_pin()
    verify_headers(include, pin)
    content = formatted(args.zig, banner(include, pin) + normalize_source_locations(build_bindings(args.zig, include)))
    output = args.out if args.out.is_absolute() else ROOT / args.out

    if args.check:
        if not output.is_file():
            print(f"missing {output}", file=sys.stderr)
            return 1
        committed = output.read_text(encoding="utf-8")
        if committed != content:
            print(f"{output} is stale; run python scripts/generate_bindings.py", file=sys.stderr)
            diff = list(difflib.unified_diff(
                committed.splitlines(), content.splitlines(),
                fromfile="committed", tofile="regenerated", lineterm="",
            ))
            for line in diff[:200]:
                print(line, file=sys.stderr)
            if len(diff) > 200:
                print(f"... {len(diff) - 200} additional diff lines", file=sys.stderr)
            return 1
        print(f"{output} is up to date")
        return 0

    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(content, encoding="utf-8", newline="\n")
    print(f"wrote {output} ({len(content)} bytes, {content.count(chr(10))} lines)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
