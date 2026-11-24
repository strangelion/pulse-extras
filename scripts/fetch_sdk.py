"""Fetch and verify the exact pinned ABI header for C-side checks."""
import hashlib
from pathlib import Path
import tomllib
from urllib.request import urlopen

root = Path(__file__).resolve().parents[1]
pin = tomllib.loads((root / "sdk/upstream.toml").read_text(encoding="utf-8"))
url = f"https://raw.githubusercontent.com/jimmgreen/pulse/{pin['revision']}/sdk/native/include/pulse/abi.h"
with urlopen(url, timeout=30) as response:
    data = response.read(1024 * 1024 + 1)
if len(data) > 1024 * 1024:
    raise SystemExit("Header exceeds size limit")
blob = hashlib.sha1(f"blob {len(data)}\0".encode() + data).hexdigest()
if blob != pin["abi_header_blob"]:
    raise SystemExit(f"Unexpected upstream header hash: {blob}")
dest = root / ".sdk-cache/include/pulse/abi.h"
dest.parent.mkdir(parents=True, exist_ok=True)
dest.write_bytes(data)
print(dest)
