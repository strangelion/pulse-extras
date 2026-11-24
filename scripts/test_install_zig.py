"""Offline regression tests for the Zig archive integrity gate."""
import hashlib
from pathlib import Path
import tempfile
import unittest

from install_zig import archive_valid


class ArchiveTests(unittest.TestCase):
    def test_cache_validation(self):
        with tempfile.TemporaryDirectory() as root:
            path = Path(root) / "archive"
            expected = b"verified archive bytes"
            digest = hashlib.sha256(expected).hexdigest()
            self.assertFalse(archive_valid(path, len(expected), digest))
            path.write_bytes(expected)
            self.assertTrue(archive_valid(path, len(expected), digest))
            self.assertFalse(archive_valid(path, len(expected) + 1, digest))
            path.write_bytes(b"x" * len(expected))
            self.assertFalse(archive_valid(path, len(expected), digest))


if __name__ == "__main__":
    unittest.main()
