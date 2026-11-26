"""Windows-only: validate the isolated collector against a synthetic sibling."""
from pathlib import Path
import struct
import subprocess
import sys
import tempfile


def run(collector, path, *args):
    return subprocess.run(
        [str(collector), str(path), *args], timeout=45, check=False
    ).returncode


def main():
    collector = Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as tmp:
        root = Path(tmp)
        normal = root / "normal.dmp"
        assert run(collector, normal, "--smoke") == 0
        assert not normal.exists()
        capped = root / "capped.dmp"
        assert run(collector, capped, "--limit-mib", "1") == 2
        assert not capped.exists()
        output = root / "crash.dmp"
        assert run(collector, output) == 10
        assert 8 * 1024 * 1024 <= output.stat().st_size <= 256 * 1024 * 1024
        with output.open("rb") as dump:
            signature, _, count, directory, _, _, flags = struct.unpack(
                "<IIIIIIQ", dump.read(32)
            )
            assert signature == 0x504D444D
            assert flags & 2  # MiniDumpWithFullMemory
            assert 0 < count < 1024
            dump.seek(directory)
            streams = {}
            for _ in range(count):
                kind, size, offset = struct.unpack("<III", dump.read(12))
                streams[kind] = (size, offset)
            assert 9 in streams  # Memory64ListStream
            assert 6 in streams  # ExceptionStream
            dump.seek(streams[6][1] + 8)
            assert struct.unpack("<I", dump.read(4))[0] == 0xE0420001
        sentinel = root / "existing.dmp"
        sentinel.write_bytes(b"do not overwrite")
        assert run(collector, sentinel) == 2
        assert sentinel.read_bytes() == b"do not overwrite"


if __name__ == "__main__":
    main()
