import json
from pathlib import Path
import tempfile
import unittest

import package_common as common


class PackageCommonTests(unittest.TestCase):
    def test_copy_is_exclusive_and_digest_bound(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            source, target = root / "source.dll", root / "copy.dll"
            source.write_bytes(b"fixture")
            digest = common.sha256(source)
            self.assertEqual(common.copy_checked(source, target, digest)["sha256"], digest)
            with self.assertRaises(FileExistsError):
                common.copy_checked(source, target, digest)
            with self.assertRaises(RuntimeError):
                common.copy_checked(source, root / "bad.dll", "0" * 64)
            self.assertEqual(target.read_bytes(), b"fixture")

    def test_reject_alias_names_and_limits(self):
        for name in ("../evil", "CON.txt", "x:y", "a..b", "x.", "x/y"):
            with self.assertRaises(ValueError):
                common.member_name(name)
        with tempfile.TemporaryDirectory() as tmp:
            source = Path(tmp) / "large"
            source.write_bytes(b"1234")
            with self.assertRaises(RuntimeError):
                common.sha256(source, 3)

    def test_manifest_binding_and_evidence(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            dll = root / "entry.dll"
            dll.write_bytes(b"entry")
            entry = {"path": dll.name, "sha256": common.sha256(dll)}
            manifest = root / "manifest.json"
            manifest.write_text(json.dumps({"id": "strangelion.fixture", "native": {
                "library": dll.name, "sha256": entry["sha256"], "files": []}}), encoding="utf-8")
            common.verify_manifest_bindings(manifest, "strangelion.fixture", entry, [])
            dll.write_bytes(b"changed")
            with self.assertRaises(RuntimeError):
                common.verify_manifest_bindings(manifest, "strangelion.fixture", entry, [])
            report = root / "evidence.json"
            common.write_evidence(report, {"real_host_accepted": False})
            self.assertFalse(common.read_evidence(report)["real_host_accepted"])
            with self.assertRaises(FileExistsError):
                common.write_evidence(report, {})

    def test_official_action_rejects_install(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "log"
            with self.assertRaises(ValueError):
                common.official_step(Path("pulse"), Path("tool"), ["install"], log)
            self.assertFalse(log.exists())


if __name__ == "__main__":
    unittest.main()
