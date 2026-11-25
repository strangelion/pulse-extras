"""Explicitly fetch pinned optional test artwork, not an installer."""
import argparse
import json
import hashlib
import os
from pathlib import Path
import tempfile
from urllib.request import urlopen

SOURCE = "https://raw.githubusercontent.com/Moemark/codex-pet-juhuali/73d50ad6ab61a95d92660b868529ebece9a84a4b/spritesheet.webp"
SHA256 = "7f21d59534ca4500b6fa64361c5518a6533dcdfffebc79aac05dcbd77d75d847"
SIZE = 2218452
ROOT = Path(__file__).resolve().parents[1]
DEST = ROOT / "zig-out" / "test-assets" / "juhuali" / "spritesheet.webp"


def verify(data: bytes) -> None:
    if len(data) != SIZE or hashlib.sha256(data).hexdigest() != SHA256:
        raise ValueError("Juhuali test atlas size or SHA-256 mismatch")


def fetch() -> None:
    if DEST.exists():
        verify(DEST.read_bytes() if DEST.stat().st_size == SIZE else b"")
        print(f"Verified existing test asset: {DEST}")
        return
    with urlopen(SOURCE, timeout=60) as response:
        data = response.read(SIZE + 1)
    verify(data)
    DEST.parent.mkdir(parents=True, exist_ok=True)
    # Create a new file only; do not replace an existing user file.
    fd, name = tempfile.mkstemp(prefix="juhuali-", suffix=".tmp", dir=DEST.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        # Hard-link publication is atomic and refuses to overwrite.
        os.link(name, DEST)
    finally:
        Path(name).unlink(missing_ok=True)
    print(f"Verified MIT test asset: {DEST}")
    print("Attribution: tests/companion/assets/juhuali/README.md")



# Git tree entries are pinned by object ID and size, not by a freshly
# downloaded checksum. The existing Juhuali SHA-256 check is unchanged.
HOODIE_REVISION = "2f02bb04d872dec6923a47572343305235c63482"
HOODIE_BASE = f"https://raw.githubusercontent.com/OpenPetsHQ/openpets/{HOODIE_REVISION}/"
HOODIE_ASSETS = (
    ("spritesheet.webp", "default-pet-spritesheet.webp", 2241132, "e7fb02e3199026d7a31c4b22c7fcc89c10521cfc"),
    ("outfits/pajamas.webp", "default-pet-outfits/pajamas.webp", 2737792, "242d1b157661f3020470e9ef26cfbc03324c2e57"),
    ("outfits/weekend.webp", "default-pet-outfits/weekend.webp", 2235944, "574af7279e32e9fccbd627263732192516e0c297"),
    ("outfits/halloween.webp", "default-pet-outfits/halloween.webp", 2478086, "e3459336e4da27ed505564ea831a759b4653e1c5"),
    ("outfits/holidays.webp", "default-pet-outfits/holidays.webp", 2506164, "7f588ee48d03d99e16ddc1e56c55a4e0bc47c7e9"),
    ("outfits/summer.webp", "default-pet-outfits/summer.webp", 2512456, "38d894c3eac92ac85388b86eb3c9555fd87a905c"),
)
HOODIE_LICENSE = (1065, "950628f106d38c8d11057cbb0e6a4fa26d891f2e")
HOODIE_METADATA = ROOT / "tests" / "companion" / "assets" / "hoodie-cat" / "pet.json"


def git_blob_id(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode("ascii") + data).hexdigest()


def verify_blob(data: bytes, size: int, expected: str) -> None:
    if len(data) != size or git_blob_id(data) != expected:
        raise ValueError("Pinned Hoodie Cat asset size or Git blob ID mismatch")


def publish_new(dest: Path, data: bytes) -> None:
    dest.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix="hoodie-cat-", suffix=".tmp", dir=dest.parent)
    try:
        with os.fdopen(fd, "wb") as out:
            out.write(data)
        os.link(name, dest)
    finally:
        Path(name).unlink(missing_ok=True)


def exact_file(dest: Path, data: bytes) -> None:
    if dest.exists():
        if dest.stat().st_size != len(data) or dest.read_bytes() != data:
            raise ValueError(f"Existing test file differs; not overwriting: {dest}")
        return
    publish_new(dest, data)


def fetch_blob(source: str, dest: Path, size: int, expected: str) -> None:
    if dest.exists():
        verify_blob(dest.read_bytes() if dest.stat().st_size == size else b"", size, expected)
        return
    with urlopen(source, timeout=60) as response:
        data = response.read(size + 1)
    verify_blob(data, size, expected)
    publish_new(dest, data)


def fetch_hoodie_cat() -> None:
    root = ROOT / "zig-out" / "test-assets"
    dest = root / "hoodie-cat"
    # Keep attribution adjacent, not inside the admitted pet asset package.
    fetch_blob(HOODIE_BASE + "LICENSE", root / "hoodie-cat.LICENSE", *HOODIE_LICENSE)
    for local, upstream, size, expected in HOODIE_ASSETS:
        fetch_blob(HOODIE_BASE + "apps/desktop/assets/" + upstream,
                   dest / local, size, expected)
    # Publish metadata only after every declared atlas has been verified.
    # Normalize CRLF on Windows so identical checkouts generate exact bytes.
    metadata = HOODIE_METADATA.read_text(encoding="utf-8")
    json.loads(metadata)
    exact_file(dest / "pet.json", metadata.encode("utf-8"))
    print(f"Verified Hoodie Cat wardrobe test package: {dest}")
    print(f"MIT license: {root / 'hoodie-cat.LICENSE'}")
    print(f'Run: zig-out\\bin\\pulse-pet-demo.exe --package "{dest}" hoodie-cat')


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pet", choices=("juhuali", "hoodie-cat"), default="juhuali")
    args = parser.parse_args()
    if args.pet == "hoodie-cat":
        fetch_hoodie_cat()
    else:
        fetch()


if __name__ == "__main__":
    main()
