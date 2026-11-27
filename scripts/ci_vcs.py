"""Provision pinned JJ binaries and a local SVN fixture on hosted CI runners."""
import argparse
import hashlib
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import sysconfig
import tempfile
import time
from http.client import IncompleteRead
from urllib.error import HTTPError, URLError
from urllib.request import urlopen
from zipfile import ZipFile

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


# Apache lists SlikSVN as a Windows distribution. Official archive and
# independently recorded SHA-256:
# https://community.chocolatey.org/packages/sliksvn/1.14.5 (VERIFICATION.txt)
SVN_VERSION = "1.14.5"
SVN_ARCHIVE_SHA256 = "77d4fe02999dda3bdc3a20e86243ae6ede99aaf072b4c12b0cdedb54d88e954a"


def extract_named_zip_member(source: Path, member: str, target: Path) -> None:
    """Only extract the exact bounded member; never run NuGet package scripts."""
    with ZipFile(source) as z:
        matches = [item for item in z.infolist() if item.filename == member]
        if len(matches) != 1 or matches[0].is_dir() or not 0 < matches[0].file_size <= 128 * 1024 * 1024:
            raise SystemExit("Unexpected SVN archive member")
        with z.open(matches[0]) as src, target.open("xb") as out:
            shutil.copyfileobj(src, out)


def download_svn_archive(root: Path, name: str) -> Path:
    archive = root / f"{name}.zip"
    # The vendor rejected the hosted runner with HTTP 403. Chocolatey's
    # versioned package embeds the original vendor ZIP, whose independently
    # documented SHA-256 is checked before any extraction or execution.
    package = root / f"sliksvn.{SVN_VERSION}.nupkg"
    download_archive(f"https://community.chocolatey.org/api/v2/package/sliksvn/{SVN_VERSION}", package)
    extract_named_zip_member(package, f"tools/{name}.zip", archive)
    with archive.open("rb") as stream:
        if hashlib.file_digest(stream, "sha256").hexdigest() != SVN_ARCHIVE_SHA256:
            raise SystemExit("SVN archive checksum mismatch")
    return archive


def valid_svn_version(output: str) -> bool:
    # The pinned vendor binaries report a distribution suffix on Windows.
    return output.strip() in (SVN_VERSION, f"{SVN_VERSION}-SlikSvn")


def install_windows_svn():
    if platform.system() != "Windows":
        raise SystemExit("Windows SVN provisioning must run on Windows")
    root = Path(tempfile.mkdtemp(prefix="pulse-svn-tools-", dir=os.environ["RUNNER_TEMP"]))
    name = f"Slik-Subversion-{SVN_VERSION}-x64"
    archive = download_svn_archive(root, name)
    msi = root / f"{name}.msi"
    extract_named_zip_member(archive, msi.name, msi)
    target = root / "installed"
    # Administrative extraction only into the ephemeral runner's private
    # directory. No PATH or registry mutation by a third-party package script.
    msiexec = Path(os.environ["SystemRoot"]) / "System32" / "msiexec.exe"
    result = subprocess.run([str(msiexec), "/a", str(msi), "/qn", "/norestart",
                             f"TARGETDIR={target}", "/l*v", str(root / "msi.log")],
                            timeout=120, check=False)
    if result.returncode not in (0, 3010):
        raise SystemExit(f"SVN administrative extraction failed: {result.returncode}")
    candidates = [p for p in target.rglob("svn.exe") if (p.parent / "svnadmin.exe").is_file()]
    if len(candidates) != 1:
        raise SystemExit("Expected exactly one SVN client/admin pair")
    binary = candidates[0]
    for name in ("svn.exe", "svnadmin.exe"):
        version = subprocess.check_output([str(binary.parent / name), "--version", "--quiet"],
                                          text=True, timeout=30).strip()
        if not valid_svn_version(version):
            raise SystemExit(f"Unexpected {name} version: {version!r}")
    print(f"Verified pinned SVN archive and both {SVN_VERSION} tools", flush=True)
    with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as out:
        out.write(str(binary.parent) + "\n")


def svn_fixture():
    root = Path(tempfile.mkdtemp(prefix="pulse-svn-", dir=os.environ["RUNNER_TEMP"]))
    repo, wc = root / "repository", root / "working-copy"
    subprocess.run(["svnadmin", "create", str(repo)], check=True, timeout=30)
    subprocess.run(["svn", "checkout", "--non-interactive", repo.as_uri(), str(wc)], check=True, timeout=30)
    # Preserve the LF bytes that the native SVN content test expects.
    (wc / "tracked.txt").write_bytes(b"original\n")
    subprocess.run(["svn", "add", "tracked.txt"], cwd=wc, check=True, timeout=30)
    subprocess.run(["svn", "commit", "--non-interactive", "-m", "fixture"], cwd=wc, check=True, timeout=30)
    (wc / "tracked.txt").write_bytes(b"changed\n")
    (wc / "untracked.txt").write_bytes(b"new\n")
    with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as out:
        out.write(f"PULSE_TEST_SVN_WC={wc}\nPULSE_REQUIRE_SVN=1\n")


def prepare_windows_hg():
    """Use upstream exewrapper.c's private hg-python layout, not ambient PATH.

    The pinned wheel is installed by the workflow with the hosted CPython.
    Its hg.exe and neighboring hg script are copied unchanged. Only this
    ephemeral CI installation is assembled; the plugin never copies DLLs.
    https://sources.debian.org/src/mercurial/7.2.4-2/mercurial/exewrapper.c/
    """
    scripts = Path(sysconfig.get_path("scripts"))
    exe, script = scripts / "hg.exe", scripts / "hg"
    if not exe.is_file() or not script.is_file():
        raise RuntimeError("Expected pinned wheel hg.exe and adjacent hg script")
    source = Path(sys.base_prefix)
    dll = source / f"python{sys.version_info.major}{sys.version_info.minor}.dll"
    if not dll.is_file() or not (source / "Lib" / "encodings").is_dir():
        raise RuntimeError("Hosted CPython runtime incomplete")
    install = Path(tempfile.mkdtemp(prefix="pulse-hg-tools-", dir=os.environ["RUNNER_TEMP"]))
    private = install / "hg-python"
    private.mkdir()
    shutil.copy2(exe, install / "hg.exe")
    shutil.copy2(script, install / "hg")
    # Copy standard library and native runtime, never the runner's global
    # site-packages. Py_SetPythonHome points to this exact private directory.
    shutil.copytree(source / "Lib", private / "Lib",
                    ignore=shutil.ignore_patterns("site-packages", "__pycache__"))
    if (source / "DLLs").is_dir():
        shutil.copytree(source / "DLLs", private / "DLLs")
    for library in source.glob("*.dll"):
        if library.is_file():
            shutil.copy2(library, private / library.name)
    if (source / "python.exe").is_file():
        shutil.copy2(source / "python.exe", private / "python.exe")
    if not (private / dll.name).is_file():
        raise RuntimeError("Private Python DLL was not copied")
    # Install the same pinned package into the isolated runtime, not a
    # mutable user-site directory. Never execute arbitrary repo scripts.
    subprocess.run([sys.executable, "-m", "pip", "install",
                    "--disable-pip-version-check", "--only-binary=:all:",
                    "--target", str(private / "Lib" / "site-packages"),
                    "mercurial==7.2.4"], check=True, timeout=180)
    with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as out:
        out.write(str(install) + "\n")
    return str(install / "hg.exe")


def hg_fixture():
    root = Path(tempfile.mkdtemp(prefix="pulse-hg-", dir=os.environ["RUNNER_TEMP"]))
    exe = prepare_windows_hg() if platform.system() == "Windows" else shutil.which("hg")
    if not exe:
        raise RuntimeError("Mercurial executable missing")
    env = dict(os.environ, HGPLAIN="1", HGRCPATH="", HGRCSKIPREPO="1", HGENCODING="UTF-8", PYTHONNOUSERSITE="1")
    def hg(*args):
        subprocess.run([exe, *args], cwd=root, env=env, check=True, timeout=30)
    hg("init")
    (root / "tracked.txt").write_bytes(b"original\n")
    hg("add", "tracked.txt")
    hg("commit", "-u", "Pulse Fixture", "-m", "initial")
    hg("bookmark", "fixture")
    hg("copy", "tracked.txt", "copy.txt")
    (root / "tracked.txt").write_bytes(b"changed\n")
    (root / "untracked.txt").write_bytes(b"new\n")
    # A failing hook must never run in the controlled read session.
    (root / ".hg" / "hgrc").write_text("[hooks]\npre-status = exit 73\n", encoding="utf-8")
    if platform.system() == "Windows":
        # Same explicit environment and neutral cwd as LocalSession, but
        # without the Zig job wrapper. Diagnose launcher vs containment.
        system = os.environ["SystemRoot"]
        minimal = {
            "SystemRoot": system, "WINDIR": system, "LANG": "C",
            "LC_ALL": "C", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_TERMINAL_PROMPT": "0", "GIT_OPTIONAL_LOCKS": "0",
            "GIT_NO_LAZY_FETCH": "1", "HGPLAIN": "1",
            "HGRCPATH": "", "HGRCSKIPREPO": "1",
            "HGENCODING": "UTF-8", "PYTHONNOUSERSITE": "1",
        }
        preflight_ok = True
        for label, args in (
            ("version", ["--version"]),
            ("root", ["--cwd", str(root), "--repository", str(root), "--noninteractive", "--config", "ui.paginate=never", "root"]),
            ("status", ["--cwd", str(root), "--repository", str(root), "--noninteractive", "--config", "ui.paginate=never", "status", "--modified", "--added", "--removed", "--deleted", "--unknown", "--ignored", "--copies", "--print0"]),
        ):
            try:
                result = subprocess.run([exe, *args], cwd=system, env=minimal,
                                        stdin=subprocess.DEVNULL, capture_output=True,
                                        timeout=10, check=False)
                print(f"Hg minimal-environment {label}: exit={result.returncode}, "
                      f"stdout_bytes={len(result.stdout)}, stderr_bytes={len(result.stderr)}")
                if result.returncode:
                    preflight_ok = False
                    # Only a generated CI fixture and pinned installation;
                    # never log production repository CLI output.
                    print(repr(result.stderr[:1024]))
            except (OSError, subprocess.TimeoutExpired) as exc:
                preflight_ok = False
                print(f"Hg minimal-environment {label}: {type(exc).__name__}")
        if not preflight_ok:
            raise RuntimeError("Private Hg installation failed minimal-environment preflight")
        # This preflight does not replace the mandatory approved Runner test.
    with open(os.environ["GITHUB_ENV"], "a", encoding="utf-8") as out:
        out.write(f"PULSE_TEST_HG_WC={root}\nPULSE_REQUIRE_HG=1\nHGPLAIN=1\nHGRCPATH=\nHGRCSKIPREPO=1\nHGENCODING=UTF-8\nPYTHONNOUSERSITE=1\n")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["jj", "svn-windows", "svn-fixture", "hg-fixture"])
    args = parser.parse_args()
    if args.action == "jj":
        install_jj()
    elif args.action == "svn-windows":
        install_windows_svn()
    elif args.action == "hg-fixture":
        hg_fixture()
    else:
        svn_fixture()
