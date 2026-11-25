"""Portable tests for optional standalone helper build evidence."""
import hashlib
import json
from pathlib import Path
import os
import tempfile
import unittest

from companion_host_smoke import (HELPER_NAME, RUNTIME_NAME, binary_evidence, helper_evidence,
                                  stage_package_file, verify_manifest_files)


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


class BundleTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.build = self.root / "runtime-build"
        self.source = self.build / "bin" / RUNTIME_NAME
        self.source.parent.mkdir(parents=True)
        self.source.write_bytes(b"runtime fixture")
        self.package = self.root / "package"
        self.package.mkdir()

    def test_manifest_binding_and_exclusive_copy(self):
        record = binary_evidence(self.build, RUNTIME_NAME)
        member = stage_package_file(self.source, self.package, RUNTIME_NAME, record["sha256"])
        self.assertEqual(member, {"path": RUNTIME_NAME, "sha256": record["sha256"]})
        manifest = self.package / "manifest.json"
        manifest.write_text(json.dumps({"native": {"files": [member]}}), encoding="utf-8")
        verify_manifest_files(manifest, [member])
        with self.assertRaises(FileExistsError):
            stage_package_file(self.source, self.package, RUNTIME_NAME, record["sha256"])
        (self.package / RUNTIME_NAME).write_bytes(b"tampered")
        with self.assertRaises(RuntimeError):
            verify_manifest_files(manifest, [member])

    def test_wrong_digest_or_missing_declaration(self):
        with self.assertRaises(RuntimeError):
            stage_package_file(self.source, self.package, RUNTIME_NAME, "0" * 64)
        manifest = self.package / "manifest.json"
        manifest.write_text(json.dumps({"native": {}}), encoding="utf-8")
        with self.assertRaises(RuntimeError):
            verify_manifest_files(manifest, [{"path": RUNTIME_NAME, "sha256": "0" * 64}])

    def test_unapproved_filename(self):
        with self.assertRaises(ValueError):
            stage_package_file(self.source, self.package, "../unexpected", "0" * 64)


if __name__ == "__main__":
    unittest.main()
