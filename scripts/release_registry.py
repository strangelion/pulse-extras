"""Discover explicit release descriptors; never execute commands from metadata."""
from __future__ import annotations

import json
from pathlib import Path
import re
import tomllib

_NATIVE_BUILD = ("zig build -Dtarget=x86_64-windows-msvc -Doptimize=ReleaseSafe",)
_COMPANION_MEMBERS = ("pulse_companion_runtime.dll", "pulse-pet-demo.exe")
_PROFILES = {
    "native": _NATIVE_BUILD,
    "companion": _NATIVE_BUILD + (
        "zig build companion-runtime-bridge -Doptimize=ReleaseSafe",
        "zig build pet-demo -Doptimize=ReleaseSafe",
    ),
}
_FIELDS = {"key", "id", "manifest", "library", "members", "build_profile"}


def flat_name(value: object, suffix: str | tuple[str, ...]) -> bool:
    return (isinstance(value, str)
            and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", value) is not None
            and value.lower().endswith(suffix)
            and ".." not in value)


def discover(root: Path) -> dict:
    root = root.resolve()
    products = {}
    ids = set()
    for descriptor in sorted(root.glob("extensions/*/release.toml")):
        if descriptor.is_symlink() or descriptor.parent.is_symlink() or not descriptor.is_file():
            raise ValueError("invalid release descriptor: " + str(descriptor))
        data = tomllib.loads(descriptor.read_text(encoding="utf-8"))
        if set(data) != _FIELDS:
            raise ValueError("unexpected or missing release descriptor fields: " + str(descriptor))
        key, ident = data["key"], data["id"]
        profile, library, members = data["build_profile"], data["library"], data["members"]
        if (not isinstance(key, str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,63}", key)
                or key == "all" or key in products):
            raise ValueError("invalid or duplicate release key: " + repr(key))
        if (not isinstance(ident, str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]{0,127}", ident)
                or ident in ids or ".." in ident):
            raise ValueError("invalid or duplicate extension id: " + repr(ident))
        if not isinstance(profile, str) or profile not in _PROFILES or not flat_name(library, ".dll"):
            raise ValueError("invalid build profile or library: " + key)
        if (not isinstance(members, list)
                or any(not flat_name(name, (".dll", ".exe")) for name in members)
                or len({name.lower() for name in [library, *members]}) != len(members) + 1):
            raise ValueError("invalid or duplicate package members: " + key)
        if profile == "companion" and (library != "pulse_companion.dll"
                                      or tuple(members) != _COMPANION_MEMBERS):
            raise ValueError("invalid companion profile composition")
        if data["manifest"] != "manifest.release.json":
            raise ValueError("only formal manifest templates may be released")
        manifest = descriptor.parent / data["manifest"]
        if manifest.is_symlink() or not manifest.is_file():
            raise ValueError("missing or invalid manifest: " + str(manifest))
        document = json.loads(manifest.read_text(encoding="utf-8"))
        if document.get("id") != ident or document.get("apiVersion") != 1 or "native" in document:
            raise ValueError("manifest does not match release descriptor: " + key)
        ids.add(ident)
        products[key] = {
            "id": ident, "template": manifest.relative_to(root).as_posix(),
            "descriptor": descriptor.relative_to(root).as_posix(),
            "library": library, "members": tuple(members),
            "build_profile": profile, "build": _PROFILES[profile],
        }
    if not products:
        raise ValueError("no release descriptors found")
    return products
