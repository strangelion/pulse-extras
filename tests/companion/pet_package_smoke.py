"""Header-only package admission fixture; no WIC codec or visible windows."""
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

        def check(expected: bool, id_: str = "cat") -> None:
            result = subprocess.run([str(exe), "--check-package", str(root), id_],
                                    timeout=15, capture_output=True)
            assert (result.returncode == 0) == expected, (result.returncode, result.stderr)

        check(True)
        check(False, "other")
        (actions / "extra.webp").write_bytes(strip)
        check(False)
        (actions / "extra.webp").unlink()
        (actions / "nap.webp").unlink()
        check(False)
        (actions / "nap.webp").write_bytes(b"not webp")
        check(False)
        (actions / "nap.webp").write_bytes(strip)
        check(True)


if __name__ == "__main__":
    main()
