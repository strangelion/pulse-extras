"""Fetch and verify the pinned native SDK headers used by CI.

Every published `pulse/*.h` of the pinned revision is downloaded and checked
against the sha256 digests recorded in `sdk/upstream.toml`. Nothing is written
when a digest does not match: CI must fail on drift instead of building against
unexpected headers.
"""

from __future__ import annotations

import hashlib
import sys
from pathlib import Path
from urllib.request import urlopen

import upstream_pin

ROOT = Path(__file__).resolve().parents[1]
SOURCE = "https://raw.githubusercontent.com/jimmgreen/pulse"
LIMIT = 1024 * 1024


def header_names() -> list[str]:
    """The shared header list lives next to this script, not on sys.path."""
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from sdk_headers import HEADERS

    return HEADERS


def main() -> int:
    pin = upstream_pin.load()
    expected = pin.get("headers")
    if not expected:
        raise SystemExit("sdk/upstream.toml has no [headers] digests")
    dest = ROOT / ".sdk-cache/include/pulse"
    dest.mkdir(parents=True, exist_ok=True)
    payloads: dict[str, bytes] = {}
    for name in header_names():
        url = (
            f"{SOURCE}/{pin['revision']}/sdk/native/include/pulse/{name}.h"
        )
        if not url.startswith(SOURCE + "/"):
            raise SystemExit(f"refusing unexpected source URL: {url}")
        with urlopen(url, timeout=30) as response:
            data = response.read(LIMIT + 1)
        if len(data) > LIMIT:
            raise SystemExit(f"pulse/{name}.h exceeds size limit")
        digest = hashlib.sha256(data).hexdigest()
        if digest != expected.get(name):
            raise SystemExit(
                f"pulse/{name}.h sha256 mismatch: {digest} != {expected.get(name)}"
            )
        payloads[name] = data
    for name, data in payloads.items():
        (dest / f"{name}.h").write_bytes(data)
    print(f"{dest} ({len(payloads)} headers, digests verified)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
