"""Classify a complete push/PR tree diff; unknown changes require full CI."""
from __future__ import annotations

import json
import os
from pathlib import Path
import re
import subprocess


def is_doc(path: str) -> bool:
    return path == "README.md" or (path.startswith("docs/") and path.endswith(".md"))


def classify(paths: list[str]) -> str:
    # An empty/unavailable diff must not silently skip required checks.
    if not paths:
        return "full"
    if all(is_doc(path) for path in paths):
        return "docs"
    if all(is_doc(path) or (path.startswith("shared/vcs/") and path.endswith(".zig"))
           for path in paths):
        return "vcs"
    if all(is_doc(path) or path.startswith(("shared/companion/", "tests/companion/")) or
           path == "shared/companion_host.zig" for path in paths):
        return "companion"
    return "full"


def event_base(event_name: str, ref: str, event: dict) -> str | None:
    if event_name == "push" and ref.startswith("refs/heads/"):
        if event.get("forced") or event.get("created") or event.get("deleted"):
            return None
        sha = event.get("before")
    elif event_name == "pull_request":
        sha = event.get("pull_request", {}).get("base", {}).get("sha")
    else:
        return None
    if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{40}", sha) or sha == "0" * 40:
        return None
    return sha


def determine_scope() -> tuple[str, str]:
    try:
        event = json.loads(Path(os.environ["GITHUB_EVENT_PATH"]).read_text(encoding="utf-8"))
        base = event_base(os.environ["GITHUB_EVENT_NAME"], os.environ["GITHUB_REF"], event)
        if base is None:
            return "full", "manual, tag, new/rewritten branch or unknown event"
        # PR checkout is the tested merge commit; compare it to the PR base.
        # --no-renames includes both old and new paths, and -z preserves names.
        result = subprocess.run(
            ["git", "diff", "--name-only", "--no-renames", "-z", base, "HEAD", "--"],
            check=True, capture_output=True, timeout=30,
        )
        paths = [p.decode("utf-8") for p in result.stdout.split(b"\0") if p]
        return classify(paths), f"{len(paths)} changed path(s)"
    except (OSError, ValueError, KeyError, AttributeError, TypeError, subprocess.SubprocessError) as exc:
        return "full", f"diff unavailable ({type(exc).__name__})"


def main() -> None:
    scope, reason = determine_scope()
    print(f"CI scope: {scope}; {reason}", flush=True)
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as out:
        out.write(f"level={scope}\n")
    summary = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary:
        with open(summary, "a", encoding="utf-8") as out:
            out.write(f"## CI scope: {scope}\n\n{reason}.\n")
            if scope == "docs":
                out.write("Documentation-only change; no Zig build, ABI or VCS integration tests run.\n")
            elif scope == "vcs":
                out.write("VCS regression and DLL builds; companion and SDK checks omitted.\n")
            elif scope == "companion":
                out.write("Companion unit/native regression; unrelated VCS, production DLL and SDK checks omitted.\n")
            else:
                out.write("Full regression, SDK regeneration and Windows C ABI loader.\n")


if __name__ == "__main__":
    main()
