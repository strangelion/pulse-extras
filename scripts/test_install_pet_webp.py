"""Offline regression tests for pinned optional decoder preparation."""
import hashlib
import io
from pathlib import Path
import tarfile
import tempfile
import unittest
from unittest.mock import patch

import install_pet_webp as webp


class WebpPreparationTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        buffer = io.BytesIO()
        with tarfile.open(fileobj=buffer, mode="w:gz") as archive:
            for name in ("COPYING", "PATENTS", "src/webp/decode.h", "src/dec/alpha_dec.c"):
                data = name.encode()
                member = tarfile.TarInfo(webp.NAME + "/" + name)
                member.size = len(data)
                archive.addfile(member, io.BytesIO(data))
        self.data = buffer.getvalue()
        for key, value in (("SIZE", len(self.data)), ("SHA256", hashlib.sha256(self.data).hexdigest())):
            mock = patch.object(webp, key, value)
            mock.start()
            self.addCleanup(mock.stop)
        self.archive = self.root / (webp.NAME + ".tar.gz")
        self.dest = self.root / webp.NAME

    def test_offline_stage_and_repeat(self):
        self.archive.write_bytes(self.data)
        with patch.object(webp.urllib.request, "urlopen", side_effect=AssertionError("network")):
            webp.prepare(self.root)
            webp.prepare(self.root)
            webp.prepare(self.root, check=True)
            self.assertTrue((self.dest / "src/dec/alpha_dec.c").is_file())

    def test_missing_cache_check_is_offline(self):
        with patch.object(webp.urllib.request, "urlopen", side_effect=AssertionError("network")):
            with self.assertRaises(RuntimeError):
                webp.prepare(self.root, check=True)
        self.assertFalse(self.dest.exists())

    def test_missing_and_modified_source(self):
        self.archive.write_bytes(self.data)
        webp.prepare(self.root)
        source = self.dest / "src/dec/alpha_dec.c"
        source.unlink()
        with self.assertRaises(RuntimeError):
            webp.prepare(self.root, check=True)
        source.write_bytes(b"modified")
        with self.assertRaises(RuntimeError):
            webp.prepare(self.root)
        self.assertEqual(source.read_bytes(), b"modified")

    def test_corrupt_archive(self):
        self.archive.write_bytes(b"x" * len(self.data))
        with self.assertRaises(RuntimeError):
            webp.prepare(self.root, check=True)
        self.assertFalse(self.dest.exists())


if __name__ == "__main__":
    unittest.main()
