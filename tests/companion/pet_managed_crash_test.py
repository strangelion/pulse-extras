"""Run real managed debugger fixtures in an isolated private test namespace."""
from pathlib import Path
import hashlib
import shutil
import struct
import subprocess
import sys
import tempfile


def main():
    fixture, harness = (Path(arg).resolve() for arg in sys.argv[1:])
    with tempfile.TemporaryDirectory() as tmp:
        # Windows runners can supply TEMP via an 8.3 alias (RUNNER~1).
        # The production supervisor deliberately requires the canonical
        # long path returned by GetFinalPathNameByHandleW. Resolve the
        # created fixture, rather than weakening production admission.
        root = Path(tmp).resolve(strict=True)
        child = root / "pulse-pet.exe"
        shutil.copyfile(fixture, child)
        child = child.resolve(strict=True)
        assert child.parent == root
        digest = hashlib.sha256(child.read_bytes()).hexdigest()
        store = root / "PulseExtras-Diagnostics"
        for index in range(6):
            subprocess.run([str(harness), str(child), digest], timeout=60, check=True)
            dumps = sorted(store.glob("capture-*.dmp"))
            metadata = sorted(store.glob("capture-*.pdi"))
            assert len(dumps) == len(metadata) == min(index + 1, 4)
            assert {p.stem for p in dumps} == {p.stem for p in metadata}
            for dump in dumps:
                assert 8 * 1024 * 1024 <= dump.stat().st_size <= 256 * 1024 * 1024
                with dump.open("rb") as stream:
                    signature, _, count, directory, _, _, flags = struct.unpack(
                        "<IIIIIIQ", stream.read(32)
                    )
                    assert signature == 0x504D444D and flags & 2
                    assert 0 < count < 1024
                    stream.seek(directory)
                    entries = {}
                    for _ in range(count):
                        kind, size, offset = struct.unpack("<III", stream.read(12))
                        entries[kind] = (size, offset)
                    assert 9 in entries and 6 in entries


if __name__ == "__main__":
    main()
