"""Stage the exact upstream source for the opt-in pet decoder build."""
import hashlib
import io
from pathlib import Path
import shutil
import tarfile
import tempfile
import urllib.request

VERSION = "1.6.0"
NAME = "libwebp-" + VERSION
URL = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/" + NAME + ".tar.gz"
SHA256 = "e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
SIZE = 4296070
MAX_UNPACKED = 64 * 1024 * 1024


def main():
    root = Path(__file__).resolve().parents[1] / "zig-out" / "deps"
    root.mkdir(parents=True, exist_ok=True)
    dest = root / NAME
    if dest.exists():
        raise RuntimeError("Remove the existing staged dependency before re-verifying it")
    with urllib.request.urlopen(URL, timeout=60) as response:
        data = response.read(SIZE + 1)
    if len(data) != SIZE or hashlib.sha256(data).hexdigest() != SHA256:
        raise RuntimeError("libwebp archive size or SHA-256 mismatch")
    with tempfile.TemporaryDirectory(prefix="webp-", dir=root) as temp:
        with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
            members = archive.getmembers()
            if len(members) > 4096 or sum(m.size for m in members) > MAX_UNPACKED:
                raise RuntimeError("Unpacked dependency exceeds bounds")
            for member in members:
                path = Path(member.name)
                if (not path.parts or path.parts[0] != NAME or path.is_absolute()
                        or ".." in path.parts or not (member.isfile() or member.isdir())):
                    raise RuntimeError("Unexpected archive entry")
            archive.extractall(temp, members=members, filter="data")
        staged = Path(temp) / NAME
        for required in ("COPYING", "PATENTS", "src/webp/decode.h"):
            if not (staged / required).is_file():
                raise RuntimeError("Incomplete upstream archive")
        shutil.move(str(staged), str(dest))
    print("Verified and staged", NAME)


if __name__ == "__main__":
    main()
