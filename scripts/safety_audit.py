"""Lightweight Zig safety review inventory, not a semantic analyzer.

Fail on explicit runtime-safety overrides other than literal true.
Everything else is a review finding, not proof of a bug or safe ownership.
No third-party dependencies; generated SDK declarations are excluded.
"""
from __future__ import annotations

import argparse
from collections import Counter
from dataclasses import dataclass
from pathlib import Path
import re
import sys


TOKEN = re.compile(
    r'(?P<comment>//[^\n]*)|(?P<multiline>\\\\[^\n]*)|'
    r'(?P<literal>@"(?:\\.|[^"\\\n])*"|"(?:\\.|[^"\\\n])*"|'
    r"'(?:\\.|[^'\\\n])*')|"
    r'(?P<space>\s+)|(?P<word>@?[A-Za-z_][A-Za-z0-9_]*)|(?P<punct>.)'
)

SINGLE = {
    "undefined": "uninitialized-value",
    "unreachable": "unreachable-path",
    "@ptrCast": "pointer-cast",
    "@alignCast": "alignment-cast",
    "@ptrFromInt": "integer-to-pointer",
    "@intFromPtr": "pointer-to-integer",
    "@truncate": "integer-truncation",
    "@memcpy": "memory-copy",
    "@memmove": "memory-copy",
}


@dataclass(frozen=True)
class Finding:
    line: int
    rule: str
    blocking: bool = False


def tokenize(source: str) -> list[tuple[str, int]]:
    tokens = []
    line = 1
    for match in TOKEN.finditer(source):
        kind = match.lastgroup
        value = match.group()
        if kind in {"literal", "multiline"}:
            tokens.append(("<literal>", line))
        elif kind not in {"space", "comment"}:
            tokens.append((value, line))
        line += value.count("\n")
    return tokens


def scan_text(source: str) -> list[Finding]:
    tokens = tokenize(source)
    values = [value for value, _ in tokens]
    findings = []
    for i, (value, line) in enumerate(tokens):
        if value == "@setRuntimeSafety":
            # Do not guess the result of arbitrary comptime expressions.
            # A deliberate exception needs a reviewed policy/code change.
            if values[i + 1:i + 4] != ["(", "true", ")"]:
                findings.append(Finding(line, "runtime-safety-override", True))
        if value in SINGLE:
            findings.append(Finding(line, SINGLE[value]))
        if values[i:i + 2] == [".", "?"]:
            findings.append(Finding(line, "optional-force-unwrap"))
        if values[i:i + 2] == [".", "*"]:
            findings.append(Finding(line, "pointer-dereference"))
        if values[i:i + 4] == ["[", "*", "c", "]"]:
            findings.append(Finding(line, "c-pointer"))
        if values[i:i + 3] == ["catch", "{", "}"]:
            findings.append(Finding(line, "empty-error-handler"))
        if values[i:i + 2] == ["catch", "unreachable"]:
            findings.append(Finding(line, "fatal-error-handler"))
    return findings


def source_paths(root: Path) -> list[Path]:
    paths = [root / "build.zig"]
    for directory in ("shared", "extensions", "tests"):
        paths.extend((root / directory).rglob("*.zig"))
    return sorted(p for p in paths
                  if not p.relative_to(root).as_posix().startswith("shared/pulse/raw/"))


def audit(root: Path, details: bool = False) -> int:
    counts = Counter()
    blocking = 0
    shown = Counter()
    paths = source_paths(root)
    for path in paths:
        if path.is_symlink() or not path.is_file():
            raise ValueError("not a regular Zig source: " + path.relative_to(root).as_posix())
        for finding in scan_text(path.read_text(encoding="utf-8")):
            counts[finding.rule] += 1
            blocking += int(finding.blocking)
            if details or finding.blocking or shown[finding.rule] < 8:
                label = "BLOCK" if finding.blocking else "REVIEW"
                print(f"{label} {path.relative_to(root).as_posix()}:{finding.line} {finding.rule}")
                shown[finding.rule] += 1
    print(f"Zig safety inventory: {len(paths)} files; {sum(counts.values())} findings; {blocking} blocking")
    for rule, count in sorted(counts.items()):
        print(f"  {rule}: {count}")
    if not details:
        print("Use --details for all review locations.")
    print("Review findings require human/agent reasoning; a clean scan is not a safety proof.")
    return int(blocking != 0)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--details", action="store_true", help="print every review location")
    args = parser.parse_args()
    try:
        return audit(Path(__file__).resolve().parents[1], args.details)
    except (OSError, ValueError) as exc:
        print(f"Safety audit could not complete: {type(exc).__name__}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
