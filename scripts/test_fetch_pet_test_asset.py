"""Offline integrity gate for the optional real pet asset."""
import hashlib
import unittest
from unittest.mock import patch

import fetch_pet_test_asset as asset


class PetAssetTests(unittest.TestCase):
    def test_reject_bad_size_and_digest(self):
        for data in (b"", b"invalid"):
            with self.assertRaises(ValueError):
                asset.verify(data)

    def test_exact_digest_and_size(self):
        data = b"test fixture"
        with patch.object(asset, "SIZE", len(data)), patch.object(
            asset, "SHA256", hashlib.sha256(data).hexdigest()
        ):
            asset.verify(data)
            with self.assertRaises(ValueError):
                asset.verify(b"x" * len(data))
            with self.assertRaises(ValueError):
                asset.verify(data + b"x")


if __name__ == "__main__":
    unittest.main()
