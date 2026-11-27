import base64
import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import environment_signing as signing


class EnvironmentSigningTests(unittest.TestCase):
    def test_reviewed_publisher(self):
        pin = signing.publisher()
        self.assertEqual(len(pin["fingerprint"]), 64)
        self.assertTrue(pin["name"])

    def test_strict_base64(self):
        self.assertEqual(signing.decode_key(base64.b64encode(b"key").decode()), b"key")
        for value in ("", "not base64!", "a" * 12000):
            with self.subTest(value=value), self.assertRaises(ValueError):
                signing.decode_key(value)

    def test_fingerprint_requires_both_pins(self):
        public = b"test public"
        digest = hashlib.sha256(public).hexdigest()
        pin = {"fingerprint": digest}
        self.assertEqual(signing.validate_public(public, pin, digest), digest)
        for data, supplied in ((b"wrong", digest), (public, "a" * 64), (public, "")):
            with self.subTest(supplied=supplied), self.assertRaises(ValueError):
                signing.validate_public(data, pin, supplied)

    @unittest.skipUnless(sys.platform == "win32" and os.environ.get("PULSE_SIGNING_TEST_REGISTRY"),
                         "requires pinned official Windows signing CLI")
    def test_sign_and_reverify_artifact_with_disposable_key(self):
        registry = Path(os.environ["PULSE_SIGNING_TEST_REGISTRY"])
        tool = registry / "tools/pulse_sign.py"
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            keys = root / "keys"
            result = subprocess.run([sys.executable, str(tool), "keygen", "--out-dir", str(keys)],
                                    check=True, capture_output=True, text=True, timeout=60)
            public = (keys / "publisher.public.blob").read_bytes()
            private = (keys / "publisher.private.blob").read_bytes()
            pin = dict(signing.publisher(), fingerprint=hashlib.sha256(public).hexdigest())
            self.assertEqual(json.loads(result.stdout)["publisher"], pin["fingerprint"])
            candidate = root / "candidate"
            directory = candidate / "vcs"
            directory.mkdir(parents=True)
            item = {"product": "vcs", "asset": "strangelion.vcs-1.0.0.pulse-ext"}
            (directory / item["asset"]).write_bytes(b"fixture")
            manifest = directory / "manifest.json"
            manifest.write_bytes(b'{"apiVersion":1,"id":"test.signature"}')
            signed = root / "signed"
            with patch.object(signing, "publisher", return_value=pin), \
                    patch.object(signing, "REGISTRY", registry), \
                    patch.object(signing.release, "verify_candidate"), \
                    patch.dict(os.environ, {
                        "PULSE_SIGNING_PUBLIC_KEY": base64.b64encode(public).decode(),
                        "PULSE_PUBLISHER_FINGERPRINT": pin["fingerprint"],
                    }):
                signing.sign_all([item], candidate, signed, "a" * 40,
                                 base64.b64encode(private).decode())
                result = signing.verify_all([item], candidate, signed, "a" * 40)
                self.assertEqual(len(result["vcs"]), 3)
                self.assertEqual({p.name for p in (signed / "vcs").iterdir()},
                                 {signing.signature_name(item), "publisher.json", "signing-evidence.json"})
                manifest.write_bytes(manifest.read_bytes() + b" ")
                with self.assertRaises(RuntimeError):
                    signing.verify_all([item], candidate, signed, "a" * 40)


if __name__ == "__main__":
    unittest.main()
