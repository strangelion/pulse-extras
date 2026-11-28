#!/usr/bin/env python3
"""Tests for release packaging declarations; the official tool is not run."""
from __future__ import annotations

import contextlib
import hashlib
import io
import json
import tempfile
import unittest
from pathlib import Path

import package_release


class VersionTests(unittest.TestCase):
    def test_accepts_semver(self):
        for value in ("0.1.0", "1.2.3", "10.20.30", "0.1.0-rc.1",
                      "1.0.0+build.5", "2.0.0-beta+exp.sha.5114f85"):
            with self.subTest(value=value):
                self.assertEqual(package_release.parse_version(value), value)

    def test_rejects_invalid(self):
        for value in ("v0.1.0", "1.2", "01.2.3", "1.2.3.4", " 1.2.3",
                      "1.2.3\n", "", "1.2.x", "1.2.3-", "1.2.3+"):
            with self.subTest(value=value), self.assertRaises(ValueError):
                package_release.parse_version(value)


class DeclarationTests(unittest.TestCase):
    def test_unknown_extension(self):
        with self.assertRaises(ValueError):
            package_release.plan("nope", Path("."))

    def test_missing_artifacts_names_build_step(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError) as raised:
            package_release.plan("companion", Path(tmp))
        self.assertIn("pulse_companion.dll", str(raised.exception))
        self.assertIn("zig build", str(raised.exception))

    def test_plan_binds_declared_flat_names(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            for name in ("pulse_companion_runtime.dll", "pulse-pet-demo.exe"):
                (root / name).write_bytes(b"x")
            digests = [hashlib.sha256((root / name).read_bytes()).hexdigest()
                       for name in ("pulse_companion_runtime.dll", "pulse-pet-demo.exe")]
            (root / "pulse_companion.dll").write_bytes("--".join(digests).encode())
            plan = package_release.plan("companion", root)
        self.assertEqual(plan["id"], "strangelion.companion")
        self.assertEqual(plan["library"].name, "pulse_companion.dll")
        self.assertEqual([name for _, name in plan["members"]],
                         ["pulse_companion_runtime.dll", "pulse-pet-demo.exe"])
        self.assertTrue(plan["template"].is_file())

    def test_unbound_companion_library_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp, self.assertRaises(ValueError) as raised:
            root = Path(tmp)
            for name in ("pulse_companion.dll", "pulse_companion_runtime.dll",
                         "pulse-pet-demo.exe"):
                (root / name).write_bytes(b"x")
            package_release.plan("companion", root)
        self.assertIn("was not built against", str(raised.exception))
        self.assertIn("-Dcompanion-runtime-sha256=", str(raised.exception))

    def test_share_exact_members_and_digest_chain(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            from release_registry import SHARE_HELPERS, SHARE_MEMBERS
            digests = []
            for key in SHARE_HELPERS:
                path = root / f"pulse-share-{key}.exe"
                path.write_bytes(key.encode("ascii"))
                digests.append(hashlib.sha256(path.read_bytes()).hexdigest())
            desktop = root / "pulse-share-desktop.exe"
            # Non-UTF-8 bytes model a binary, not a dependency notice.
            desktop.write_bytes(b"\xff\x00" + "--".join(digests).encode("ascii"))
            library = root / "pulse_share.dll"

            def bind_desktop():
                library.write_bytes(hashlib.sha256(desktop.read_bytes()).hexdigest().encode("ascii"))

            bind_desktop()
            original_dll = library.read_bytes()
            original_desktop = desktop.read_bytes()
            for name in SHARE_MEMBERS:
                if name.endswith("-notices.txt"):
                    (root / name).write_text("fixture notice", encoding="utf-8")
            plan = package_release.plan("share", root)
            self.assertEqual(plan["id"], "strangelion.share")
            self.assertEqual([name for _, name in plan["members"]], list(SHARE_MEMBERS))
            for key in SHARE_HELPERS:
                with self.subTest(helper=key):
                    path = root / f"pulse-share-{key}.exe"
                    original = path.read_bytes()
                    path.write_bytes(b"changed")
                    with self.assertRaisesRegex(ValueError, f"-Dshare-{key}-sha256"):
                        package_release.plan("share", root)
                    path.write_bytes(original)

                    # Even a correctly bound desktop must pin every helper.
                    desktop.write_bytes(original_desktop.replace(digests[SHARE_HELPERS.index(key)].encode("ascii"), b"x" * 64))
                    bind_desktop()
                    with self.assertRaisesRegex(ValueError, f"-Dshare-{key}-sha256"):
                        package_release.plan("share", root)
                    desktop.write_bytes(original_desktop)
                    library.write_bytes(original_dll)

            desktop.write_bytes(original_desktop + b"changed")
            with self.assertRaisesRegex(ValueError, "pulse-share-desktop.exe"):
                package_release.plan("share", root)
            desktop.write_bytes(original_desktop)
            # Old DLL-only helper binding cannot substitute for the new chain.
            library.write_bytes("--".join(digests).encode("ascii"))
            with self.assertRaisesRegex(ValueError, "pulse-share-desktop.exe"):
                package_release.plan("share", root)
            library.write_bytes(original_dll)
            for name in SHARE_MEMBERS:
                with self.subTest(missing=name):
                    path = root / name
                    original = path.read_bytes()
                    path.unlink()
                    with self.assertRaisesRegex(ValueError, "missing build output"):
                        package_release.plan("share", root)
                    path.write_bytes(original)
            for name in SHARE_MEMBERS:
                if name.endswith("-notices.txt"):
                    path = root / name
                    path.write_text("  ", encoding="utf-8")
                    with self.assertRaisesRegex(ValueError, "empty Share dependency notices"):
                        package_release.plan("share", root)
                    path.write_text("fixture notice", encoding="utf-8")
            package_release.plan("share", root)

    def test_vcs_has_no_extra_members(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pulse_vcs_panel.dll").write_bytes(b"x")
            plan = package_release.plan("vcs", root)
        self.assertEqual(plan["members"], [])
        self.assertEqual(plan["template"].name, "manifest.release.json")

    def test_asset_name(self):
        self.assertEqual(package_release.asset_name("strangelion.vcs", "0.1.0"),
                         "strangelion.vcs-0.1.0.pulse-ext")

    def test_release_manifests_are_templates_without_native(self):
        for extension in ("companion", "vcs", "share"):
            with self.subTest(extension=extension):
                product = package_release.PRODUCTS[extension]
                document = json.loads(
                    (package_release.ROOT / product["template"]).read_text(encoding="utf-8"))
                self.assertEqual(document["apiVersion"], 1)
                self.assertEqual(document["id"], product["id"])
                self.assertNotIn("native", document)


class DryRunTests(unittest.TestCase):
    def test_dry_run_prints_plan_and_writes_nothing(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "pulse_vcs_panel.dll").write_bytes(b"x")
            out = root / "out"
            stream = io.StringIO()
            with contextlib.redirect_stdout(stream):
                code = package_release.main([
                    "--extension", "vcs", "--version", "0.1.0",
                    "--pulse", str(root / "pulse.exe"),
                    "--sdk-root", str(root / "sdk"),
                    "--artifacts", str(root), "--out", str(out), "--dry-run"])
            self.assertFalse(out.exists())
        self.assertEqual(code, 0)
        report = json.loads(stream.getvalue())
        self.assertTrue(report["dry_run"])
        self.assertEqual(report["asset"], "strangelion.vcs-0.1.0.pulse-ext")
        self.assertEqual(report["members"], [])

    def test_dry_run_rejects_bad_version(self):
        with tempfile.TemporaryDirectory() as tmp, \
                contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            code = package_release.main([
                "--extension", "vcs", "--version", "v1.0.0",
                "--pulse", str(Path(tmp) / "pulse.exe"),
                "--sdk-root", str(Path(tmp) / "sdk"),
                "--artifacts", tmp, "--out", str(Path(tmp) / "out"), "--dry-run"])
        self.assertEqual(code, 1)


if __name__ == "__main__":
    unittest.main()
