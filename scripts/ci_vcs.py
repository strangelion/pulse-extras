"""Provision pinned JJ binaries and a local SVN fixture on hosted CI runners."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import tempfile
import time
from http.client import IncompleteRead
from urllib.error import HTTPError, URLError
from urllib.request import urlopen

JJ_VERSION = "0.46.0"
ASSETS = {
    "Windows": (
        "x86_64-pc-windows-msvc.zip",
        "c42316b10df04611bc65029a18bcb2d92636edddb6871d511f7bb4233e999b83",
        "jj.exe",
    ),
    "Linux": (
        "x86_64-unknown-linux-musl.tar.gz",
        "fce0271158e665ceb82dc66c5eb95b1728649094e9133074f3b5baece345fc08",
        "jj",
    ),
}


def valid_jj_version(output: str) -> bool:
    # Official cli/build.rs appends one or more Git commit hashes when available.
    return re.fullmatch(rf"jj {re.escape(JJ_VERSION)}(?:-[0-9a-fA-F]{{7,64}})*", output.strip()) is not None


def download_archive(url: str, archive: Path) -> None:
    """Retry transient transport failures; never retry a failed checksum."""
    for attempt in range(1, 4):
        try:
            with urlopen(url, timeout=120) as response, archive.open("wb") as out:
                shutil.copyfileobj(response, out)
            return
        except HTTPError as exc:
            archive.unlink(missing_ok=True)
            if exc.code not in (408, 429, 500, 502, 503, 504) or attempt == 3:
                raise
            reason = f"HTTP {exc.code}"
        except (URLError, TimeoutError, ConnectionError, IncompleteRead) as exc:
            archive.unlink(missing_ok=True)
            if attempt == 3:
                raise
            reason = type(exc).__name__
        delay = 2 ** attempt
        print(f"JJ download attempt {attempt}/3 failed ({reason}); retrying in {delay}s", flush=True)
        time.sleep(delay)


def install_jj():
    suffix, expected, exe = ASSETS[platform.system()]
    name = f"jj-v{JJ_VERSION}-{suffix}"
    url = f"https://github.com/jj-vcs/jj/releases/download/v{JJ_VERSION}/{name}"
    root = Path(tempfile.mkdtemp(prefix="pulse-jj-", dir=os.environ["RUNNER_TEMP"]))
    archive = root / name
    download_archive(url, archive)
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != expected:
            raise SystemExit("JJ archive checksum mismatch")
    shutil.unpack_archive(str(archive), str(root))
    candidates = [p for p in root.rglob(exe) if p.is_file()]
    if len(candidates) != 1:
        raise SystemExit(f"Expected one JJ executable, found {candidates}")
    binary = candidates[0]
    actual = subprocess.check_output([str(binary), "--version"], text=True, timeout=30).strip()
    print(f"Verified archive SHA-256; JJ reports {actual!r}", flush=True)
    if not valid_jj_version(actual):
        raise SystemExit(f"Unexpected JJ version: {actual!r}; expected {JJ_VERSION} with optional commit hash")
    with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as out:
        out.write(str(binary.parent) + "\n")


def svn_fixture():
    root = Path(tempfile.mkdtemp(prefix="pulse-svn-", dir=os.environ["RUNNER_TEMP"]))
    repo, wc = root / "repository", root / "working-copy"
    subprocess.run(["svnadmin", "create", str(repo)], check=True, timeout=30)
    subprocess.run(["svn", "checkout", "--non-interactive", repo.as_uri(), str(wc)], check=True, timeout=30)
    (wc / "tracked.txt").write_text("original\n", encoding="utf-8")
    subprocess.run(["svn", "add", "tracked.txt"], cwd=wc, check=True, timeout=30)
    subprocess.run(["svn", "commit", "--non-interactive", "-m", "fixture"], cwd=wc, check=True, timeout=30)
    (wc / "tracked.txt").write_text("changed\n", encoding="utf-8")
    (wc / "untracked.txt").write_text("new\n", encoding="utf-8")
    with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as out:
        out.write(f"PULSE_TEST_SVN_WC={wc}\nPULSE_REQUIRE_SVN=1\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["jj", "svn-fixture"])
    args = parser.parse_args()
    if args.action == "jj":
        install_jj()
    else:
        svn_fixture()
