import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import subprocess

from stage_vcs_test import stage


class StageTests(unittest.TestCase):
    def test_missing_and_existing_output_are_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pulse, tool, library = (root / name for name in ("pulse.exe", "tool.py", "pulse_vcs_panel.dll"))
            with self.assertRaises(ValueError):
                stage(pulse, tool, library, root / "out")
            for path in (pulse, tool, library):
                path.write_bytes(b"fixture")
            with self.assertRaises(FileExistsError):
                stage(pulse, tool, library, root)
            self.assertEqual(library.read_bytes(), b"fixture")

    def test_failed_verifier_does_not_mark_verified(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pulse, tool, library = (root / name for name in ("pulse.exe", "tool.py", "pulse_vcs_panel.dll"))
            for path in (pulse, tool, library):
                path.write_bytes(b"fixture")
            result = subprocess.CompletedProcess([], 1, "", "failure")
            with patch("stage_vcs_test.subprocess.run", return_value=result):
                with self.assertRaises(RuntimeError):
                    stage(pulse, tool, library, root / "out")
            self.assertIn('"verified": false', (root / "out/stage-report.json").read_text())

    def test_success_records_hashes_and_does_not_install(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            pulse, tool, library = (root / name for name in ("pulse.exe", "tool.py", "pulse_vcs_panel.dll"))
            for path in (pulse, tool, library):
                path.write_bytes(b"fixture")
            calls = []

            def fake_run(argv, **kwargs):
                action = argv[5]
                calls.append(action)
                if action in ("native-manifest", "pack"):
                    Path(argv[argv.index("--output") + 1]).write_bytes(b"generated")
                return subprocess.CompletedProcess(argv, 0, "{}", "")

            with patch("stage_vcs_test.subprocess.run", side_effect=fake_run):
                package = stage(pulse, tool, library, root / "out")
            self.assertEqual(calls, ["native-manifest", "pack", "verify"])
            self.assertTrue(package.is_file())
            self.assertIn('"verified": true', (root / "out/stage-report.json").read_text())
