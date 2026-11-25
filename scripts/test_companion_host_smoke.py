"""Portable tests for optional standalone helper build evidence."""
import hashlib
from pathlib import Path
import os
import tempfile
import unittest

from companion_host_smoke import HELPER_NAME, helper_evidence


class HelperEvidenceTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.build = Path(temp.name) / "helper-build"
        self.exe = self.build / "bin" / HELPER_NAME
        self.exe.parent.mkdir(parents=True)

    def test_fixed_location_and_digest(self):
        self.exe.write_bytes(b"synthetic helper")
        record = helper_evidence(self.build, "wic")
        self.assertEqual(record["path"], "helper-build/bin/" + HELPER_NAME)
        self.assertEqual(record["sha256"], hashlib.sha256(b"synthetic helper").hexdigest())
        self.assertEqual(record["bytes"], len(b"synthetic helper"))
        self.assertFalse(record["runtime_approved"])
        self.assertEqual(helper_evidence(self.build, "libwebp")["backend"], "libwebp")

    def test_missing_empty_or_duplicate(self):
        with self.assertRaises(RuntimeError):
            helper_evidence(self.build, "wic")
        self.exe.touch()
        with self.assertRaises(RuntimeError):
            helper_evidence(self.build, "wic")
        self.exe.write_bytes(b"fixture")
        (self.build / HELPER_NAME).write_bytes(b"duplicate")
        with self.assertRaises(RuntimeError):
            helper_evidence(self.build, "wic")

    def test_hardlink_rejected(self):
        self.exe.write_bytes(b"fixture")
        alias = self.build / "alias"
        try:
            os.link(self.exe, alias)
        except OSError as exc:
            self.skipTest(str(exc))
        with self.assertRaises(RuntimeError):
            helper_evidence(self.build, "wic")

    def test_unknown_backend(self):
        with self.assertRaises(ValueError):
            helper_evidence(self.build, "unexpected")


if __name__ == "__main__":
    unittest.main()
