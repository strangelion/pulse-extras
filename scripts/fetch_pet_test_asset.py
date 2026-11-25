"""Explicitly fetch the MIT-licensed Juhuali V2 test atlas, not an installer."""
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


if __name__ == "__main__":
    fetch()
