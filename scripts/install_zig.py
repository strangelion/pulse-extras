"""Install the pinned official Zig distribution in a GitHub Actions runner."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import subprocess
import tempfile
import time
from urllib.request import urlopen
from urllib.parse import urlsplit

version = (Path(__file__).resolve().parents[1] / ".zig-version").read_text().strip()
os_name = {"Windows": "windows", "Linux": "linux"}[platform.system()]
base = Path(tempfile.mkdtemp(prefix=f"zig-{version}-", dir=os.environ["RUNNER_TEMP"]))

def retry(label, operation):
    for attempt in range(1, 4):
        try:
            return operation()
        except (OSError, ValueError, RuntimeError) as exc:
            print(f"{label}: attempt {attempt}/3 failed: {exc}", flush=True)
            if attempt == 3:
                raise
            time.sleep(2 ** attempt)

def read_index():
    with urlopen("https://ziglang.org/download/index.json", timeout=30) as response:
        return json.load(response)

release = retry("Fetch release index", read_index)[version][f"x86_64-{os_name}"]
url = release["tarball"]
parsed = urlsplit(url)
if parsed.scheme != "https" or parsed.hostname != "ziglang.org":
    raise SystemExit("Unexpected Zig download origin")
name = Path(parsed.path).name
suffix = ".zip" if os_name == "windows" else ".tar.xz"
if not name.endswith(suffix):
    raise SystemExit(f"Unexpected archive format: {name}")
archive_root = name.removesuffix(suffix)
with tempfile.TemporaryDirectory() as tmp:
    archive = Path(tmp) / name
    def download():
        with urlopen(url, timeout=120) as response, archive.open("wb") as out:
            shutil.copyfileobj(response, out)
        if archive.stat().st_size != int(release["size"]):
            raise RuntimeError("Zig archive size mismatch")
        with archive.open("rb") as stream:
            actual = hashlib.file_digest(stream, "sha256").hexdigest()
        if actual != release["shasum"]:
            raise RuntimeError("Zig archive checksum mismatch")
    retry("Download and verify Zig", download)
    shutil.unpack_archive(str(archive), str(base))
exe = base / archive_root / ("zig.exe" if os_name == "windows" else "zig")
if not exe.is_file():
    raise SystemExit(f"Compiler missing at expected path: {exe}; archive roots: {list(base.iterdir())}")
actual_version = subprocess.check_output([str(exe), "version"], text=True, timeout=30).strip()
if actual_version != version:
    raise SystemExit(f"Expected Zig {version}, got {actual_version}")
print(f"Verified Zig {actual_version}: {exe}", flush=True)
with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as out:
    out.write(str(exe.parent) + "\n")
