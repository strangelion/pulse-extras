"""Install a pinned, hash-verified official Zig archive on GitHub Actions.

Only the original archive is cached, never a previously extracted executable.
The expected sizes and SHA-256 hashes come from Zig's official release index.
"""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import time

ROOT = Path(__file__).resolve().parents[1]


def archive_valid(path: Path, size: int, sha256: str) -> bool:
    if not path.is_file() or path.stat().st_size != size:
        return False
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest() == sha256


def timed(label: str, fn):
    start = time.monotonic()
    try:
        return fn()
    finally:
        print(f"{label}: {time.monotonic() - start:.2f}s", flush=True)


def install():
    version = (ROOT / ".zig-version").read_text(encoding="utf-8").strip()
    lock = json.loads((ROOT / "scripts/zig-downloads.json").read_text(encoding="utf-8"))
    if lock["version"] != version:
        raise SystemExit("Zig version and download lock disagree; update both from the official release index")
    if platform.machine().lower() not in {"amd64", "x86_64"}:
        raise SystemExit(f"Unsupported CI architecture: {platform.machine()}")
    os_name = platform.system()
    release = lock["platforms"][os_name]
    name = release["name"]
    suffix = ".zip" if os_name == "Windows" else ".tar.xz"
    expected_name = f"zig-x86_64-{os_name.lower()}-{version}{suffix}"
    if name != expected_name:
        raise SystemExit("Unexpected locked archive filename")
    size, digest = release["size"], release["sha256"]
    runner_temp = Path(os.environ["RUNNER_TEMP"])
    cache_dir = runner_temp / "pulse-zig-archives"
    cache_dir.mkdir(parents=True, exist_ok=True)
    archive = cache_dir / name

    if timed("Cached archive verification", lambda: archive_valid(archive, size, digest)):
        print(f"Verified Zig archive cache HIT: {name}", flush=True)
    else:
        print(f"Zig archive cache MISS: {name}", flush=True)
        archive.unlink(missing_ok=True)
        partial = cache_dir / (name + ".partial")
        partial.unlink(missing_ok=True)
        url = f"https://ziglang.org/download/{version}/{name}"
        try:
            # curl has a wall-clock deadline, unlike a socket-read timeout.
            timed("Download from official Zig origin", lambda: subprocess.run(
                ["curl", "--fail", "--location", "--silent", "--show-error",
                 "--connect-timeout", "30", "--max-time", "1200",
                 "--retry", "1", "--retry-max-time", "1200",
                 "--output", str(partial), url],
                check=True, timeout=1260,
            ))
            if not timed("Downloaded archive verification", lambda: archive_valid(partial, size, digest)):
                raise SystemExit("Downloaded Zig archive failed pinned size/SHA-256 validation")
            partial.replace(archive)
        finally:
            partial.unlink(missing_ok=True)

    base = Path(tempfile.mkdtemp(prefix=f"zig-{version}-", dir=runner_temp))
    timed("Extract verified Zig archive", lambda: shutil.unpack_archive(str(archive), str(base)))
    exe = base / name.removesuffix(suffix) / ("zig.exe" if os_name == "Windows" else "zig")
    if not exe.is_file():
        raise SystemExit(f"Compiler missing at expected path: {exe}")
    actual = timed("Verify compiler version", lambda: subprocess.check_output(
        [str(exe), "version"], text=True, timeout=30
    )).strip()
    if actual != version:
        raise SystemExit(f"Expected Zig {version}, got {actual}")
    print(f"Verified Zig {actual}: {exe}", flush=True)
    with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as out:
        out.write(str(exe.parent) + "\n")


if __name__ == "__main__":
    install()
