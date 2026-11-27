import json
from pathlib import Path
import tempfile
import unittest

import release_registry


class ReleaseRegistryTests(unittest.TestCase):
    def add(self, root, folder="convert", key="convert", ident="strangelion.convert",
            library="pulse_convert.dll", profile="native", members="[]"):
        directory = root / "extensions" / folder
        directory.mkdir(parents=True)
        (directory / "manifest.release.json").write_text(
            json.dumps({"apiVersion": 1, "id": ident}), encoding="utf-8")
        descriptor = directory / "release.toml"
        descriptor.write_text(
            f'key = "{key}"\nid = "{ident}"\nmanifest = "manifest.release.json"\n'
            f'library = "{library}"\nbuild_profile = "{profile}"\nmembers = {members}\n',
            encoding="utf-8")
        return descriptor

    def test_discover_new_product_and_ignore_test_packages(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            self.add(root)
            (root / "extensions" / "abi-probe").mkdir()
            products = release_registry.discover(root)
            self.assertEqual(set(products), {"convert"})
            self.assertEqual(products["convert"]["library"], "pulse_convert.dll")
            self.assertEqual(products["convert"]["build_profile"], "native")

    def test_duplicate_keys_or_ids(self):
        for key, ident in (("convert", "strangelion.other"), ("other", "strangelion.convert")):
            with self.subTest(key=key), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.add(root)
                self.add(root, "other", key, ident)
                with self.assertRaises(ValueError):
                    release_registry.discover(root)

    def test_invalid_descriptors(self):
        for kwargs in ({"key": "all"}, {"library": "../outside.dll"},
                       {"profile": "shell"}, {"members": '["a.dll", "A.dll"]'},
                       {"profile": "companion"}):
            with self.subTest(kwargs=kwargs), tempfile.TemporaryDirectory() as temp:
                root = Path(temp)
                self.add(root, **kwargs)
                with self.assertRaises(ValueError):
                    release_registry.discover(root)

    def test_manifest_mismatch(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            descriptor = self.add(root)
            (descriptor.parent / "manifest.release.json").write_text(
                '{"apiVersion":1,"id":"other.id"}', encoding="utf-8")
            with self.assertRaises(ValueError):
                release_registry.discover(root)


if __name__ == "__main__":
    unittest.main()
