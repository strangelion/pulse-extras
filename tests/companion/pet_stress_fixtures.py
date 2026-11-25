"""Original, fully encoded V1/V2 WebP stress fixtures; no dependencies.

Alternating solid color cells exercise actual decoding and atlas ownership,
not realistic artwork complexity. No external downloads.
"""
import base64
import json
from pathlib import Path
import sys

V1 = "UklGRrYAAABXRUJQVlA4TKoAAAAv/8XTAQ9wFK1ruZ1Tdf6jBWTSNvVveu8cJKL/AoIiB+zYXXf8/+Q//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM//uM/JeC/AA=="
V2 = "UklGRtwAAABXRUJQVlA4TM8AAAAv/8U7Ag9wUF2CbBt/r20/1o3I5j/cBDJpm/k3vXcCBonov4CgyAE7Mtc5/n/yH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//xH//x33PgvwIA"


def decode_atlas(encoded, expected_size, width, height):
    data = base64.b64decode(encoded, validate=True)
    if (len(data) != expected_size or data[:4] != b"RIFF"
            or int.from_bytes(data[4:8], "little") + 8 != len(data)
            or data[8:16] != b"WEBPVP8L" or data[20] != 0x2f):
        raise ValueError("Invalid embedded WebP fixture")
    bits = int.from_bytes(data[21:25], "little")
    if ((bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1) != (width, height):
        raise ValueError("Wrong embedded atlas dimensions")
    return data


def main():
    root = Path(sys.argv[1])
    root.mkdir(parents=True, exist_ok=False)
    package = root / "fixture-v1"
    package.mkdir()
    (package / "spritesheet.webp").write_bytes(decode_atlas(V1, 190, 1536, 1872))
    (package / "pet.json").write_text(json.dumps({
        "id": "fixture-v1", "displayName": "Fixture V1",
        "description": "Original stress fixture",
        "spritesheetPath": "spritesheet.webp"
    }), encoding="utf-8")
    (root / "fixture-v2.webp").write_bytes(decode_atlas(V2, 228, 1536, 2288))


if __name__ == "__main__":
    main()
