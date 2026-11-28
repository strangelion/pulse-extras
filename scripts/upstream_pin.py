"""Single reviewed source of truth for the public Pulse SDK and installer."""
from __future__ import annotations

import os
from pathlib import Path
import re
import tomllib

from sdk_headers import header_order

ROOT = Path(__file__).resolve().parents[1]
REPOSITORY = "jimmgreen/pulse"
REPOSITORY_URL = "https://github.com/" + REPOSITORY
MAX_INSTALLER_SIZE = 256 * 1024 * 1024
VERSION = re.compile(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)")


def valid_hex(value: object, length: int) -> bool:
    return isinstance(value, str) and re.fullmatch(rf"[0-9a-f]{{{length}}}", value) is not None


def version_tuple(value: str) -> tuple[int, ...]:
    if not isinstance(value, str) or not VERSION.fullmatch(value) or len(value) > 32:
        raise ValueError("invalid stable Pulse version")
    return tuple(map(int, value.split(".")))


def validate(pin: dict) -> dict:
    version_tuple(pin["pulse_source_version"])
    if (pin.get("repository") != REPOSITORY_URL
            or pin.get("target") != "x86_64-windows-msvc"
            or not valid_hex(pin.get("revision"), 40)
            or not valid_hex(pin.get("abi_header_blob"), 40)
            or type(pin.get("abi_version")) is not int or pin["abi_version"] < 1
            or type(pin.get("sdk_preview")) is not int or pin["sdk_preview"] < 1):
        raise ValueError("invalid Pulse SDK pin")
    installer = pin["installer"]
    filename = f"PulseSetup-{pin['pulse_source_version']}.exe"
    if (set(installer) != {"filename", "size", "sha256"} or installer["filename"] != filename
            or type(installer["size"]) is not int or not 0 < installer["size"] <= MAX_INSTALLER_SIZE
            or not valid_hex(installer["sha256"], 64)):
        raise ValueError("invalid pinned Windows installer")
    header_order(pin["headers"])
    if not all(valid_hex(v, 64) for v in pin["headers"].values()):
        raise ValueError("incomplete or invalid SDK header pin")
    if type(pin.get("host_verified")) is not bool:
        raise ValueError("invalid host acceptance flag")
    return pin


def load(path: Path = ROOT / "sdk/upstream.toml") -> dict:
    return validate(tomllib.loads(path.read_text(encoding="utf-8")))


def installer_url(pin: dict) -> str:
    return f"{REPOSITORY_URL}/releases/download/v{pin['pulse_source_version']}/{pin['installer']['filename']}"


def main() -> None:
    pin = load()
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        stream.write(f"repository={REPOSITORY}\nrevision={pin['revision']}\nversion={pin['pulse_source_version']}\n")
    print(f"Pulse {pin['pulse_source_version']}, SDK preview {pin['sdk_preview']}, revision {pin['revision']}")


if __name__ == "__main__":
    main()
