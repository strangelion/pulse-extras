import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

import sign_release


class SigningBoundaryTests(unittest.TestCase):
    def test_key_must_be_outside_repo(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            key = root / "private.blob"
            key.write_bytes(b"test fixture")
            with patch.object(sign_release.release, "ROOT", root), self.assertRaises(ValueError):
                sign_release.outside_repo(key)

    @unittest.skipUnless(sys.platform == "win32" and os.environ.get("PULSE_SIGNING_TEST_REGISTRY"),
                         "requires pinned official Windows signing CLI")
    def test_official_disposable_key_and_tamper_rejection(self):
        registry = Path(os.environ["PULSE_SIGNING_TEST_REGISTRY"])
        tool = registry / "tools/pulse_sign.py"
        def call(*args, check=True):
            return subprocess.run([sys.executable, str(tool), *map(str, args)],
                                  check=check, capture_output=True, text=True, timeout=60)
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            keys = root / "keys"
            result = json.loads(call("keygen", "--out-dir", keys, "--bits", 3072).stdout)
            private = keys / "publisher.private.blob"
            public = keys / "publisher.public.blob"
            self.assertEqual(result["publisher"], hashlib.sha256(public.read_bytes()).hexdigest())
            manifest = root / "manifest.json"
            manifest.write_bytes(b'{"apiVersion":1,"id":"test.signature"}')
            signature = root / "manifest.sig.json"
            call("sign-manifest", manifest, "--private-key", private, "--output", signature)
            call("verify-manifest", manifest, "--signature", signature, "--public-key", public)
            manifest.write_bytes(manifest.read_bytes() + b" ")
            self.assertNotEqual(call("verify-manifest", manifest, "--signature", signature,
                                     "--public-key", public, check=False).returncode, 0)


if __name__ == "__main__":
    unittest.main()
