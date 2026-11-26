import struct
import unittest
from pathlib import Path
from unittest.mock import patch

from vcs_approval import build_input, check_status, path_bytes


class ApprovalTests(unittest.TestCase):
    def test_requires_absolute_path(self):
        with self.assertRaises(ValueError):
            path_bytes(Path("relative"))

    def test_inventory_must_contain_exact_executable(self):
        with patch("vcs_approval.inventory", return_value=[]):
            with self.assertRaises(ValueError):
                build_input(Path("git.exe"), Path("repo"), Path("neutral"), Path("install"))

    def test_input_binds_inventory(self):
        root = Path.cwd()
        exe = root / "git.exe"
        digest = bytes(range(32))
        with patch("vcs_approval.inventory", return_value=[(exe, digest)]):
            payload, entries = build_input(exe, root / "repo", root / "neutral", root)
        self.assertTrue(payload.startswith(b"PVCSIN01"))
        self.assertTrue(payload.endswith(digest))
        self.assertEqual(entries, [(exe, digest)])
        self.assertIn(struct.pack("<H", 1) + path_bytes(exe), payload)

    def test_errors_are_not_success(self):
        check_status("test", 0)
        with self.assertRaises(RuntimeError):
            check_status("test", 8)
