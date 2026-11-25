"""Portable tests for optional standalone helper build evidence."""
import hashlib
import json
from pathlib import Path
import os
import tempfile
import unittest
import zipfile

from companion_host_smoke import (HELPER_NAME, RUNTIME_NAME, binary_evidence, helper_evidence,
                                  stage_package_file, verify_manifest_files, copy_archive,
                                  validate_evidence, verify_archive_bindings, sha256,
                                  PACKAGE, PACKAGE_NAME, ENTRY_NAME, EVIDENCE_VERSION)


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


class ExactPackageTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory()
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.package = self.root / PACKAGE_NAME
        self.members = [{"path": RUNTIME_NAME, "sha256": "1" * 64},
                        {"path": HELPER_NAME, "sha256": "2" * 64}]
        self.manifest = {"id": PACKAGE, "native": {"library": ENTRY_NAME,
                         "sha256": "3" * 64, "files": self.members}}
        self.evidence = {
            "schema_version": EVIDENCE_VERSION, "package": PACKAGE,
            "source_revision": "a" * 40, "source_dirty": False,
            "real_host_accepted": False, "bundled_runtime": True,
            "zig_version": "test-version", "sdk_pin_sha256": "4" * 64,
            "host_sha256": "5" * 64, "author_sha256": "6" * 64,
            "sdk_catalog_sha256": "7" * 64, "dll_sha256": "3" * 64,
            "runtime": {"sha256": "1" * 64},
            "helper": {"sha256": "2" * 64, "backend": "wic"},
            "package_members": self.members,
        }
        self.write_fixture()

    def write_fixture(self, extra=False):
        # Synthetic metadata fixture, not an official/native package.
        raw = json.dumps(self.manifest).encode()
        with zipfile.ZipFile(self.package, "w") as archive:
            archive.writestr("manifest.json", raw)
            archive.writestr("package.json", "{}")
            for name in (ENTRY_NAME, RUNTIME_NAME, HELPER_NAME):
                archive.writestr(name, b"fixture")
            if extra:
                archive.writestr("unlisted.txt", b"unexpected")
        self.evidence["manifest_sha256"] = hashlib.sha256(raw).hexdigest()
        self.evidence["package_sha256"] = sha256(self.package)

    def validate(self):
        validate_evidence(self.evidence, self.evidence["package_sha256"],
                          "5" * 64, "6" * 64, "7" * 64)

    def test_exact_copy_and_manifest_binding(self):
        self.validate()
        target = self.root / "copy.pulse-ext"
        copy_archive(self.package, target, self.evidence["package_sha256"])
        verify_archive_bindings(target, self.evidence)
        self.assertEqual(sha256(target), sha256(self.package))
        with self.assertRaises(FileExistsError):
            copy_archive(self.package, target, self.evidence["package_sha256"])

    def test_tamper_rejected(self):
        self.package.write_bytes(b"tampered")
        with self.assertRaises(RuntimeError):
            copy_archive(self.package, self.root / "copy.pulse-ext", self.evidence["package_sha256"])
        with self.assertRaises(RuntimeError):
            verify_archive_bindings(self.package, self.evidence)

    def test_foreign_id_or_extra_file_rejected(self):
        self.manifest["id"] = "strangelion.companion"
        self.write_fixture()
        with self.assertRaises(RuntimeError):
            verify_archive_bindings(self.package, self.evidence)
        self.manifest["id"] = PACKAGE
        self.write_fixture(extra=True)
        with self.assertRaises(RuntimeError):
            verify_archive_bindings(self.package, self.evidence)

    def test_evidence_dirty_wrong_host_or_wrong_member_rejected(self):
        for key, value in (("source_dirty", True), ("host_sha256", "0" * 64),
                           ("author_sha256", "0" * 64), ("schema_version", 1),
                           ("package_members", [{"path": "../evil.dll", "sha256": "1" * 64}])):
            with self.subTest(key=key):
                old = self.evidence[key]
                self.evidence[key] = value
                with self.assertRaises(RuntimeError):
                    self.validate()
                self.evidence[key] = old

    def test_manifest_digest_mismatch_rejected(self):
        self.evidence["manifest_sha256"] = "0" * 64
        with self.assertRaises(RuntimeError):
            verify_archive_bindings(self.package, self.evidence)


if __name__ == "__main__":
    unittest.main()
