"""Offline integrity gate for the optional real pet asset."""
import hashlib
import io
import json
from pathlib import Path
import tempfile
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


    def test_hoodie_blob_id_and_no_overwrite(self):
        data = b"abc"
        expected = "f2ba8f84ab5c1bce84a7b441cb1959cfc7093b7f"
        asset.verify_blob(data, 3, expected)
        with self.assertRaises(ValueError):
            asset.verify_blob(b"abd", 3, expected)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp) / "outfits" / "test.webp"
            with patch.object(asset, "urlopen", return_value=io.BytesIO(data)) as fetch:
                asset.fetch_blob("https://example.invalid/test", path, 3, expected)
                asset.fetch_blob("https://example.invalid/test", path, 3, expected)
                fetch.assert_called_once()
            path.write_bytes(b"bad")
            with patch.object(asset, "urlopen") as fetch:
                with self.assertRaises(ValueError):
                    asset.fetch_blob("https://example.invalid/test", path, 3, expected)
                fetch.assert_not_called()
            self.assertEqual(path.read_bytes(), b"bad")

    def test_metadata_matches_every_pinned_outfit(self):
        metadata = json.loads(asset.HOODIE_METADATA.read_text(encoding="utf-8"))
        self.assertEqual(metadata["id"], "hoodie-cat")
        self.assertEqual(metadata["spriteVersionNumber"], 2)
        outfits = metadata["wardrobe"]["outfits"]
        self.assertEqual(len(outfits), 5)
        self.assertEqual({metadata["spritesheetPath"]} |
                         {item["spritesheetPath"] for item in outfits},
                         {item[0] for item in asset.HOODIE_ASSETS})
        self.assertEqual({item["id"] for item in outfits},
                         {rule["outfit"] for rule in metadata["wardrobe"]["schedule"]})

    def test_metadata_published_only_after_verified_atlases(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            with patch.object(asset, "ROOT", root), patch.object(
                asset, "fetch_blob", side_effect=ValueError("bad asset")
            ):
                with self.assertRaises(ValueError):
                    asset.fetch_hoodie_cat()
            self.assertFalse((root / "zig-out/test-assets/hoodie-cat/pet.json").exists())


if __name__ == "__main__":
    unittest.main()
