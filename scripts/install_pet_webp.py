"""Stage and verify the pinned optional decoder; builds never download."""
import argparse
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import urllib.request

VERSION = "1.6.0"
NAME = "libwebp-" + VERSION
URL = "https://storage.googleapis.com/downloads.webmproject.org/releases/webp/" + NAME + ".tar.gz"
SHA256 = "e4ab7009bf0629fd11982d4c2aa83964cf244cffba7347ecd39019a9e38c4564"
SIZE = 4296070
MAX_UNPACKED = 64 * 1024 * 1024
ROOT = Path(__file__).resolve().parents[1] / ".local" / "deps"


def read_archive(path):
    if path.is_symlink() or not path.is_file() or path.stat().st_size != SIZE:
        raise RuntimeError("Missing or invalid pinned archive: " + str(path))
    data = path.read_bytes()
    if len(data) != SIZE or hashlib.sha256(data).hexdigest() != SHA256:
        raise RuntimeError("libwebp archive size or SHA-256 mismatch: " + str(path))
    return data


def unpack(data, parent):
    with tarfile.open(fileobj=io.BytesIO(data), mode="r:gz") as archive:
        members = archive.getmembers()
        if len(members) > 4096 or sum(m.size for m in members) > MAX_UNPACKED:
            raise RuntimeError("Unpacked dependency exceeds bounds")
        for member in members:
            path = Path(member.name)
            if (not path.parts or path.parts[0] != NAME or path.is_absolute()
                    or ".." in path.parts or not (member.isfile() or member.isdir())):
                raise RuntimeError("Unexpected archive entry")
        archive.extractall(parent, members=members, filter="data")
    staged = parent / NAME
    for required in ("COPYING", "PATENTS", "src/webp/decode.h", "src/dec/alpha_dec.c"):
        if not (staged / required).is_file():
            raise RuntimeError("Incomplete upstream archive")
    return staged


def snapshot(root):
    if root.is_symlink() or not root.is_dir():
        raise RuntimeError("Invalid dependency directory: " + str(root))
    entries = {}
    total = 0
    pending = [root]
    while pending:
        for path in pending.pop().iterdir():
            if len(entries) >= 4096 or path.is_symlink() or (
                    hasattr(path, "is_junction") and path.is_junction()):
                raise RuntimeError("Unexpected dependency entry: " + str(path))
            key = path.relative_to(root).as_posix()
            if path.is_dir():
                entries[key] = None
                pending.append(path)
            elif path.is_file():
                size = path.stat().st_size
                total += size
                if total > MAX_UNPACKED:
                    raise RuntimeError("Staged dependency exceeds bounds")
                with path.open("rb") as stream:
                    entries[key] = (size, hashlib.file_digest(stream, "sha256").hexdigest())
            else:
                raise RuntimeError("Unexpected dependency entry: " + str(path))
    return entries


def prepare(root, check=False):
    cached = root / (NAME + ".tar.gz")
    dest = root / NAME
    if not check:
        root.mkdir(parents=True, exist_ok=True)
    if not cached.exists() and not check:
        with urllib.request.urlopen(URL, timeout=60) as response:
            data = response.read(SIZE + 1)
        if len(data) != SIZE or hashlib.sha256(data).hexdigest() != SHA256:
            raise RuntimeError("libwebp archive size or SHA-256 mismatch")
        with tempfile.TemporaryDirectory(prefix="webp-download-", dir=root) as temp:
            archive = Path(temp) / cached.name
            archive.write_bytes(data)
            # Only verified bytes are published. Concurrent downloads of the
            # same pinned archive are equivalent.
            archive.replace(cached)
    data = read_archive(cached)
    if check and not dest.is_dir():
        raise RuntimeError("Pinned source directory missing: " + str(dest))
    with tempfile.TemporaryDirectory(prefix="webp-verify-", dir=root) as temp:
        staged = unpack(data, Path(temp))
        if dest.exists() or dest.is_symlink():
            if snapshot(dest) != snapshot(staged):
                raise RuntimeError("Staged source differs from pinned archive: " + str(dest)
                                   + "; move the directory aside and rerun the installer")
        elif check:
            raise RuntimeError("Pinned source directory missing: " + str(dest))
        else:
            # Same-volume rename; no partial directory is published.
            staged.rename(dest)
    print("Verified and staged", NAME)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true", help="Verify local cache only; never download")
    args = parser.parse_args()
    try:
        prepare(ROOT, check=args.check)
    except (OSError, ValueError, RuntimeError, tarfile.TarError) as exc:
        parser.exit(1, f"libwebp: {exc}\nRun python scripts/install_pet_webp.py to prepare the dependency.\n")


if __name__ == "__main__":
    main()
