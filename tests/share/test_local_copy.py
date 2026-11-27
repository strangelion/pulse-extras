"""Isolated Windows integration; invokes native parent/child, no Pulse or network."""
from pathlib import Path
import hashlib
import os
import subprocess
import sys
import tempfile
import unittest

if len(sys.argv) != 5:
    raise SystemExit("usage: test_local_copy.py supervisor.exe worker.exe failing-worker.exe corrupt-worker.exe")
SUPERVISOR, WORKER, FAILING, CORRUPT = (Path(p).resolve(strict=True) for p in sys.argv[1:])
sys.argv[1:] = []


def sha(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


@unittest.skipUnless(sys.platform == "win32", "Windows native integration")
class LocalCopy(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="pulse-share-test-")
        self.addCleanup(self.temp.cleanup)
        # Resolve actual long-name DOS path before native strict identity checks.
        self.root = Path(self.temp.name).resolve(strict=True)
        self.destination = self.root / "destination"
        self.destination.mkdir()
        self.source = self.root / "source 文件.bin"

    def invoke(self, name="received 文件.bin", worker=WORKER, digest=None, expected=0):
        before = self.source.read_bytes()
        result = subprocess.run(
            [str(SUPERVISOR), "--confirm-local-copy", str(worker), digest or sha(worker),
             str(self.source), str(self.destination), name],
            capture_output=True, text=True, timeout=30, check=False,
        )
        self.assertEqual(result.returncode, expected, (result.stdout, result.stderr))
        self.assertIn("PULSE_SHARE_LOCAL_V1 " + str(expected), result.stdout)
        self.assertEqual(self.source.read_bytes(), before)
        self.assertFalse(list(self.destination.glob(".pulse-share-*.part")),
                         "supervisor left a staging file")

    def test_large_unicode_file(self):
        self.source.write_bytes(bytes(range(256)) * 4097)
        self.invoke()
        target = self.destination / "received 文件.bin"
        self.assertEqual(sha(target), sha(self.source))

    def test_empty_file(self):
        self.source.touch()
        self.invoke("empty.bin")
        self.assertEqual((self.destination / "empty.bin").stat().st_size, 0)

    def test_no_overwrite(self):
        self.source.write_bytes(b"new data")
        target = self.destination / "existing.bin"
        target.write_bytes(b"original data")
        self.invoke("existing.bin", expected=5)
        self.assertEqual(target.read_bytes(), b"original data")

    def test_worker_digest_mismatch(self):
        self.source.write_bytes(b"test")
        self.invoke(digest="0" * 64, expected=4)
        self.assertFalse(list(self.destination.iterdir()))

    def test_unexpected_worker_exit(self):
        self.source.write_bytes(b"test")
        # Worker may exit before the request write or before the response.
        before = self.source.read_bytes()
        result = subprocess.run(
            [str(SUPERVISOR), "--confirm-local-copy", str(FAILING), sha(FAILING),
             str(self.source), str(self.destination), "failed.bin"],
            capture_output=True, text=True, timeout=30, check=False,
        )
        self.assertIn(result.returncode, (1, 2), (result.stdout, result.stderr))
        self.assertEqual(self.source.read_bytes(), before)
        self.assertFalse(list(self.destination.iterdir()))

    def test_false_success_cannot_publish_corrupt_bytes(self):
        self.source.write_bytes(b"nonzero content")
        self.invoke(worker=CORRUPT, expected=4)
        self.assertFalse(list(self.destination.iterdir()))

    def test_false_success_cannot_replace_existing_file(self):
        self.source.write_bytes(b"nonzero content")
        target = self.destination / "existing.bin"
        target.write_bytes(b"original")
        self.invoke("existing.bin", worker=CORRUPT, expected=4)
        self.assertEqual(target.read_bytes(), b"original")

    def test_invalid_destination_names(self):
        self.source.write_bytes(b"test")
        for name in ("..", "..\\escape.bin", "CON.txt", "foo:stream", "a. ", "NUL"):
            with self.subTest(name=name):
                self.invoke(name, expected=5)
        self.assertFalse(list(self.destination.iterdir()))
        self.assertFalse((self.root / "escape.bin").exists())

    def test_hardlinked_source_rejected(self):
        self.source.write_bytes(b"original")
        alias = self.root / "alias.bin"
        os.link(self.source, alias)
        self.invoke(expected=5)
        self.assertEqual(alias.read_bytes(), b"original")
        self.assertFalse(list(self.destination.iterdir()))


if __name__ == "__main__":
    unittest.main(verbosity=2)
