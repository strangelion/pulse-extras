"""Header-only package admission fixture; no WIC codec or visible windows."""
import ctypes
import json
import pathlib
import subprocess
import sys
import tempfile


def main() -> None:
    exe = pathlib.Path(sys.argv[1]).resolve()
    with tempfile.TemporaryDirectory() as tmp:
        root = pathlib.Path(tmp) / "cat"
        root.mkdir()
        actions = root / "activities"
        actions.mkdir()
        manifest = {
            "id": "cat", "displayName": "Cat", "description": "Fixture",
            "spritesheetPath": "spritesheet.webp",
            "activities": [{"id": "nap", "displayName": "Nap",
                            "outfitId": "default", "spritesheetPath": "activities/nap.webp",
                            "frameCount": 4, "fps": 4}],
        }
        (root / "pet.json").write_text(json.dumps(manifest), encoding="utf-8")
        (root / "spritesheet.webp").write_bytes(
            b"RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x2f\xff\xc5\xd3\x01\x00")
        strip = b"RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x2f\xff\xc2\x33\x00\x00"
        (actions / "nap.webp").write_bytes(strip)

        def check(expected: bool, id_: str = "cat", folder: pathlib.Path = root,
                  stage: bytes | None = None) -> None:
            result = subprocess.run([str(exe), "--check-package", str(folder), id_],
                                    timeout=15, capture_output=True)
            assert (result.returncode == 0) == expected, (result.returncode, result.stderr)
            if stage is not None:
                assert stage in result.stderr, result.stderr

        check(True)
        check(True, folder=root.resolve(strict=True))
        # 8.3 aliases may be disabled on this volume. Exercise them if present.
        short_name = ctypes.create_unicode_buffer(1024)
        n = ctypes.windll.kernel32.GetShortPathNameW(str(root), short_name, len(short_name))
        if 0 < n < len(short_name):
            check(True, folder=pathlib.Path(short_name.value))
        check(False, "other", stage=b"metadata-parse")
        (actions / "extra.webp").write_bytes(strip)
        check(False, stage=b"activity-inventory")
        (actions / "extra.webp").unlink()
        (actions / "nap.webp").unlink()
        check(False, stage=b"activity-inventory")
        (actions / "nap.webp").write_bytes(b"not webp")
        check(False, stage=b"activity-header")
        (actions / "nap.webp").write_bytes(strip)
        check(True)
        outfits = root / "outfits"
        outfits.mkdir()
        manifest["wardrobe"] = {"outfits": [{"id": "night", "displayName": "Night",
                                             "spritesheetPath": "outfits/night.webp"}]}
        manifest["activities"][0]["outfitId"] = "night"
        manifest["activities"][0]["outfitVariants"] = [
            {"outfitId": "default", "spritesheetPath": "activities/nap.default.webp",
             "frameCount": 4, "fps": 4}]
        (root / "pet.json").write_text(json.dumps(manifest), encoding="utf-8")
        check(False, stage=b"outfit-inventory")
        (outfits / "night.webp").write_bytes((root / "spritesheet.webp").read_bytes())
        check(False, stage=b"activity-inventory")
        (actions / "nap.default.webp").write_bytes(strip)
        check(True)
        (outfits / "extra.webp").write_bytes(strip)
        check(False, stage=b"outfit-inventory")
        (outfits / "extra.webp").unlink()
        (outfits / "night.webp").write_bytes(strip)
        check(False, stage=b"outfit-header")


if __name__ == "__main__":
    main()
