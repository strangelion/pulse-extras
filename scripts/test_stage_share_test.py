"""Test digest-bound developer staging with fake local inputs; no host execution."""
import tempfile
from pathlib import Path
import unittest
from unittest.mock import patch

import stage_share_test as stage
import package_common as pkg


class ShareStage(unittest.TestCase):
    def test_binds_exact_helpers_and_stages_once(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            binaries = root / "bin"
            binaries.mkdir()
            for key in stage.HELPERS:
                (binaries / f"pulse-share-{key}.exe").write_bytes(key.encode())
            (binaries / stage.NOTICE).write_text("fixture notices", encoding="utf-8")
            (binaries / stage.GO_NOTICE).write_text("fixture Go notices", encoding="utf-8")
            out = root / "out"
            version = (stage.ROOT / ".zig-version").read_text(encoding="utf-8").strip()

            def fake_build(args, **kwargs):
                self.assertEqual(args[:3], ["zig", "build", "share-dev"])
                for key in stage.HELPERS:
                    expected = pkg.sha256(binaries / f"pulse-share-{key}.exe")
                    self.assertIn(f"-Dshare-{key}-sha256={expected}", args)
                prefix = Path(args[args.index("--prefix") + 1])
                (prefix / "bin").mkdir(parents=True)
                (prefix / "bin" / "pulse_share.dll").write_bytes(b"fixture")

            def fake_stage(pulse, tool, template, output, extension, library, members):
                self.assertEqual(output, out)
                self.assertEqual(extension, "strangelion.share-dev")
                self.assertEqual(library.read_bytes(), b"fixture")
                self.assertEqual(len(members), len(stage.HELPERS) + 2)
                for (path, name), key in zip(members[:-2], stage.HELPERS, strict=True):
                    self.assertEqual(path.read_bytes(), key.encode())
                    self.assertEqual(name, f"pulse-share-{key}.exe")
                self.assertEqual(members[-2][1], stage.NOTICE)
                self.assertEqual(members[-2][0].read_text(encoding="utf-8"), "fixture notices")
                self.assertEqual(members[-1][1], stage.GO_NOTICE)
                self.assertEqual(members[-1][0].read_text(encoding="utf-8"), "fixture Go notices")
                return {"real_host_accepted": False}

            with patch.object(stage.subprocess, "check_output", return_value=version), \
                 patch.object(stage.subprocess, "run", side_effect=fake_build), \
                 patch.object(stage.pkg, "stage", side_effect=fake_stage) as pack:
                self.assertFalse(stage.prepare(root / "Pulse.exe", root / "tool.py",
                                               binaries, out)["real_host_accepted"])
                pack.assert_called_once()
            self.assertEqual(sorted(x.name for x in root.iterdir()), ["bin"])

    def test_existing_output_refused(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with self.assertRaises(ValueError):
                stage.prepare(root / "Pulse.exe", root / "tool.py", root, root)

    def test_missing_helper_does_not_build(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            with patch.object(stage.subprocess, "run") as build:
                with self.assertRaises(OSError):
                    stage.prepare(root / "Pulse.exe", root / "tool.py", root, root / "out")
                build.assert_not_called()


if __name__ == "__main__":
    unittest.main()
