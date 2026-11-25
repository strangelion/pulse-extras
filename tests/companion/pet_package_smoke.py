"""Header-only package admission fixture; no WIC codec or visible windows."""
import ctypes
import hashlib
import struct
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
            # Expected rejection must not hide a failed cleanup.
            assert b"Companion heap: live=0 allocations=0" in result.stderr, result.stderr
            assert b"Companion resources: files=0 codec=0 dib=0 cleanup_failures=0" in result.stderr, result.stderr
            assert b"Companion native: ipc=0 registry=0 menus=0 argv=0" in result.stderr, result.stderr
            if stage is not None:
                assert stage in result.stderr, result.stderr

        check(True)
        # Independent canonical fingerprint reference, using actual file bytes.
        def reference():
            files = sorted((p.relative_to(root).as_posix(), p.read_bytes())
                           for p in root.rglob("*") if p.is_file())
            digest = hashlib.sha256(b"pulse-classic-package-sha256-v1\\x00")
            digest.update(struct.pack("<Q", len(files)))
            for path, data in files:
                name = path.encode("ascii")
                digest.update(struct.pack("<Q", len(name)))
                digest.update(name)
                digest.update(struct.pack("<Q", len(data)))
                digest.update(hashlib.sha256(data).digest())
            return digest.hexdigest()

        expected_sha = reference()
        result = subprocess.run([str(exe), "--fingerprint-package", str(root), "cat"],
                                timeout=15, capture_output=True)
        assert result.returncode == 0, result.stderr
        assert result.stdout.strip() == f"PULSE_PACKAGE_SHA256_V1 {expected_sha}".encode(), result.stdout
        result = subprocess.run([str(exe), "--check-package", str(root), "cat",
                                 "--expected-sha256", expected_sha], timeout=15, capture_output=True)
        assert result.returncode == 0, result.stderr
        manifest["gazeAnchor"] = {"x": 0.5, "y": 0.25}
        (root / "pet.json").write_text(json.dumps(manifest), encoding="utf-8")
        check(True)  # valid metadata on V1 is inert
        result = subprocess.run([str(exe), "--check-package", str(root), "cat",
                                 "--expected-sha256", expected_sha], timeout=15, capture_output=True)
        assert result.returncode != 0 and b"fingerprint-mismatch" in result.stderr, result.stderr
        assert b"Companion heap: live=0 allocations=0" in result.stderr, result.stderr
        manifest["gazeAnchor"]["x"] = -0.1
        (root / "pet.json").write_text(json.dumps(manifest), encoding="utf-8")
        check(False, stage=b"metadata-parse")
        manifest["gazeAnchor"]["x"] = 0.5
        (root / "pet.json").write_text(json.dumps(manifest), encoding="utf-8")
        check(True, folder=root.resolve(strict=True))
        task = subprocess.run([str(exe), "--check-package-task", str(root), "cat"],
                              timeout=20, capture_output=True)
        # Header-only synthetic base cannot be fully decoded. The actual
        # worker must nevertheless run, notify, join and drain.
        assert task.returncode != 0, task.stderr
        assert b"Companion tasks: queued=0 running=0 peaks=1/1" in task.stderr, task.stderr
        assert b"Companion notification: live=0 peak=1" in task.stderr, task.stderr
        assert b"Companion drawing: windows=0 memory_dc=0 desktop_dc=0" in task.stderr, task.stderr
        assert b"admitted 1" in task.stderr and b"io_failure 1" in task.stderr, task.stderr
        assert b"Companion heap: live=0 allocations=0" in task.stderr, task.stderr
        assert b"Companion resources: files=0 codec=0 dib=0 cleanup_failures=0" in task.stderr, task.stderr
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
                                             "spritesheetPath": "outfits/night.webp"}],
                                "schedule": [{"outfit": "night", "when": {
                                    "time": {"from": "22:00", "to": "07:00"}}}]}
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
