"""CI-only pinned official Zig download with archive checksum verification."""
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import tempfile
from urllib.request import urlopen

version = (Path(__file__).resolve().parents[1] / ".zig-version").read_text().strip()
os_name = {"Windows": "windows", "Linux": "linux"}[platform.system()]
with urlopen("https://ziglang.org/download/index.json", timeout=30) as response:
    release = json.load(response)[version][f"x86_64-{os_name}"]
base = Path(os.environ["RUNNER_TEMP"]) / f"zig-{version}"
base.mkdir(exist_ok=True)
url = release["tarball"]
if not url.startswith("https://ziglang.org/"):
    raise SystemExit("Unexpected Zig download origin")
with tempfile.TemporaryDirectory() as tmp:
    archive = Path(tmp) / url.rsplit("/", 1)[1]
    with urlopen(url, timeout=120) as response, archive.open("wb") as out:
        shutil.copyfileobj(response, out)
    with archive.open("rb") as stream:
        actual = hashlib.file_digest(stream, "sha256").hexdigest()
    if actual != release["shasum"]:
        raise SystemExit("Zig archive checksum mismatch")
    shutil.unpack_archive(str(archive), str(base))
exe = "zig.exe" if os_name == "windows" else "zig"
paths = list(base.rglob(exe))
if len(paths) != 1:
    raise SystemExit("Expected exactly one compiler")
with open(os.environ["GITHUB_PATH"], "a", encoding="utf-8") as out:
    out.write(str(paths[0].parent) + "\n")
