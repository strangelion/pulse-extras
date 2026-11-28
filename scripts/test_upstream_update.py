import hashlib
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import upstream_pin as pins
import upstream_update as update


def row(version="1.0.60", **overrides):
    filename = f"PulseSetup-{version}.exe"
    data = {"tag_name": "v" + version, "draft": False, "prerelease": False,
            "assets": [{"name": filename, "state": "uploaded", "size": 20,
                        "digest": "sha256:" + "a" * 64,
                        "browser_download_url": f"{pins.REPOSITORY_URL}/releases/download/v{version}/{filename}"}]}
    data.update(overrides)
    return data


class UpstreamUpdateTests(unittest.TestCase):
    def test_stable_selection_is_numeric_and_excludes_packs(self):
        rows = [row("1.0.9"), row("1.0.10"), row("2.0.0", prerelease=True),
                row("3.0.0", draft=True), row(tag_name="pack-images-2.0.0")]
        self.assertEqual(max(update.stable_releases(rows)), (1, 0, 10))

    def test_installer_metadata(self):
        self.assertEqual(update.release_installer(row())["size"], 20)
        for field, value in (("digest", None), ("size", 0), ("state", "new"),
                             ("browser_download_url", "https://example.com/a.exe"),
                             ("name", "PulseSetup-1.0.60-win81.exe")):
            with self.subTest(field=field):
                candidate = row()
                candidate["assets"][0][field] = value
                with self.assertRaises(ValueError):
                    update.release_installer(candidate)

    def test_duplicate_stable_release(self):
        with self.assertRaises(ValueError):
            update.stable_releases([row(), row()])

    def test_candidate_preserves_historical_host_and_resets_acceptance(self):
        path = pins.ROOT / "sdk/upstream.toml"
        old = pins.load(path)
        candidate = update.render_pin(path.read_text(encoding="utf-8"), old,
                                      "1.0.999", "b" * 40, update.release_installer(row("1.0.999")),
                                      old["headers"], "c" * 40)
        import tomllib
        new = pins.validate(tomllib.loads(candidate))
        self.assertEqual(new["host"], old["host"])
        self.assertFalse(new["host_verified"])
        self.assertEqual(new["pulse_source_version"], "1.0.999")

    def test_unchanged_baseline_and_drift(self):
        pin = pins.load()
        baseline = row(pin["pulse_source_version"])
        baseline["assets"][0].update(size=pin["installer"]["size"],
                                     digest="sha256:" + pin["installer"]["sha256"])
        with tempfile.TemporaryDirectory() as temp, patch.object(update, "releases", return_value=[baseline]), \
                patch.object(update, "revision", return_value=pin["revision"]):
            self.assertEqual(update.discover(Path(temp))[0], "unchanged")
            baseline["assets"][0]["digest"] = "sha256:" + "f" * 64
            with self.assertRaisesRegex(ValueError, "changed in place"):
                update.discover(Path(temp))

    def test_candidate_can_add_headers_but_not_remove_them(self):
        old = pins.load()
        names = list(old["headers"])
        new_name = next(name for name in ("future_sdk", "future_sdk_two") if name not in names)
        payload = b"/* fixture */\n"
        entries = [{"name": name + ".h", "type": "file", "size": len(payload),
                    "sha": update.git_blob(payload)} for name in names + [new_name]]
        with tempfile.TemporaryDirectory() as temp, patch.object(update, "gh", return_value=entries), \
                patch.object(update, "raw", return_value=payload):
            root = Path(temp)
            digests, blob = update.headers("a" * 40, root / "headers", names)
            self.assertIn(new_name, digests)
            candidate = update.render_pin((pins.ROOT / "sdk/upstream.toml").read_text(encoding="utf-8"),
                                          old, "1.0.999", "b" * 40,
                                          update.release_installer(row("1.0.999")), digests, blob)
            import tomllib
            self.assertEqual(pins.validate(tomllib.loads(candidate))["headers"], digests)
            entries.pop(0)
            with self.assertRaisesRegex(ValueError, "headers removed"):
                update.headers("a" * 40, root / "removed", names)

    def test_git_blob(self):
        self.assertEqual(update.git_blob(b"hello\n"), hashlib.sha1(b"blob 6\0hello\n").hexdigest())


if __name__ == "__main__":
    unittest.main()
