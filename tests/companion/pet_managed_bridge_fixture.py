"""Isolated managed-launch fixture; independent fingerprint and PCI3 writer."""
from __future__ import annotations

import hashlib
from pathlib import Path
import shutil
import struct
import subprocess
import sys

from pet_stress_fixtures import main as generate_source


def fingerprint(directory: Path) -> bytes:
    files = sorted(p for p in directory.rglob("*") if p.is_file())
    result = bytearray()
    for algorithm in ("sha256", "sha512"):
        outer = hashlib.new(algorithm)
        outer.update(f"pulse-classic-package-{algorithm}-v1".encode() + b"\0")
        outer.update(struct.pack("<Q", len(files)))
        for file in files:
            name = file.relative_to(directory).as_posix().encode("ascii")
            data = file.read_bytes()
            outer.update(struct.pack("<Q", len(name)))
            outer.update(name)
            outer.update(struct.pack("<Q", len(data)))
            outer.update(hashlib.new(algorithm, data).digest())
        result.extend(outer.digest())
    return bytes(result)


def main() -> None:
    parent = Path(sys.argv[1]).resolve(strict=True)
    helper = Path(sys.argv[2]).resolve(strict=True)
    root = parent / "PulseExtras-Companion"
    # The native lease probe creates/approves the fixed directory first.
    if not root.is_dir() or not (root / "owner.lock").is_file():
        raise ValueError("Expected an approved fixture root")
    source = parent / "source"
    sys.argv = [sys.argv[0], str(source)]
    generate_source()
    data = bytearray(b"PCI3" + struct.pack("<QI", 4, 3))
    for asset_id, name in ((1, "fixture-v1"), (2, "hoodie-cat"), (3, "fixture-v1")):
        dest = root / f"pet-{asset_id:016x}"
        shutil.copytree(source / name, dest)
        pair = fingerprint(dest)
        if asset_id != 3:
            # Distinguish header/fingerprint admission and actual full decode
            # from supervision errors. Preserve the helper's stderr in CI.
            expected = pair[:32].hex() + ":" + pair[32:].hex()
            for action in ("--check-package", "--check-package-task"):
                result = subprocess.run(
                    [str(helper), action, str(dest), name,
                     "--expected-fingerprint", expected],
                    capture_output=True, timeout=25,
                )
                if result.returncode:
                    sys.stderr.write(result.stderr.decode("utf-8", errors="replace"))
                    raise RuntimeError(
                        f"{name} {action} failed: exit {result.returncode}"
                    )
                print(f"{name}: {action} verified", flush=True)
        if asset_id == 3:
            # Valid distinct inventory fingerprint, deliberately wrong for bytes.
            pair = bytes([pair[0] ^ 1]) + pair[1:]
        source_id = name.encode("ascii")
        data.extend(struct.pack("<QB", asset_id, len(source_id)))
        data.extend(source_id + b"\x02" + pair)
    with (root / "inventory.pci").open("xb") as stream:
        stream.write(data)


if __name__ == "__main__":
    main()
