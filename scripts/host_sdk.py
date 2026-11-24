"""Extract and verify the native SDK embedded in an installed Pulse host.

The published Pulse source tree can lag behind the host that is actually
installed. The host exposes its authoritative SDK through the official
`--extension-api --extension-check` discovery call, including the exact text
and SHA-256 of every published interface header. This script snapshots that
surface, validates it fail-closed, and can later prove that the host under
test still matches the snapshot.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path
from typing import NoReturn, cast

EXPECTED_API_VERSION = 1
EXPECTED_ABI_VERSION = 1
EXPECTED_SDK_PREVIEW = 3
HOST_TIMEOUT_SECONDS = 60
MAX_RESPONSE_BYTES = 8 * 1024 * 1024
NAME_PATTERN = re.compile(r"^pulse\.[a-z0-9]+(\.[a-z0-9]+)*$")
SHA256_PATTERN = re.compile(r"^[0-9a-f]{64}$")


def fail(message: str) -> NoReturn:
    raise SystemExit(message)


def sha256_bytes(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def canonical_sha256(value: object) -> str:
    """Hash JSON with the documented sorted-ascii canonicalization."""
    text = json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=True)
    return sha256_bytes(text.encode("ascii"))


def read_host_api(pulse: Path) -> dict:
    if not pulse.is_file():
        fail(f"Pulse host binary not found: {pulse}")
    completed = subprocess.run(
        [str(pulse), "--extension-api", "--extension-check"],
        capture_output=True,
        timeout=HOST_TIMEOUT_SECONDS,
        check=False,
    )
    if completed.returncode != 0:
        fail(
            f"Host discovery failed with exit code {completed.returncode}: "
            f"{completed.stderr.decode('utf-8', 'replace').strip()}"
        )
    if len(completed.stdout) > MAX_RESPONSE_BYTES:
        fail(f"Host discovery response exceeds {MAX_RESPONSE_BYTES} bytes")
    try:
        payload = json.loads(completed.stdout.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError) as exc:
        fail(f"Host discovery returned invalid JSON: {exc}")
    if not isinstance(payload, dict):
        fail("Host discovery returned a non-object payload")
    return cast(dict, payload)


def validate_catalog(api: dict) -> tuple[dict, dict[str, bytes]]:
    if api.get("apiVersion") != EXPECTED_API_VERSION:
        fail(f"Unexpected extension API version: {api.get('apiVersion')!r}")
    native_sdk = api.get("nativeSdk")
    if not isinstance(native_sdk, dict):
        fail("Host does not expose nativeSdk (native packages unsupported)")
    if native_sdk.get("abiVersion") != EXPECTED_ABI_VERSION:
        fail(f"Unexpected host ABI version: {native_sdk.get('abiVersion')!r}")
    catalog = native_sdk.get("catalog")
    if not isinstance(catalog, dict):
        fail("Host does not expose nativeSdk.catalog")
    if catalog.get("abiVersion") != EXPECTED_ABI_VERSION:
        fail(f"Unexpected catalog ABI version: {catalog.get('abiVersion')!r}")
    if catalog.get("sdkPreview") != EXPECTED_SDK_PREVIEW:
        fail(f"Unexpected SDK preview: {catalog.get('sdkPreview')!r}")
    interfaces = catalog.get("interfaces")
    if not isinstance(interfaces, list) or not interfaces:
        fail("Catalog contains no interfaces")

    seen_names: set[str] = set()
    seen_headers: set[str] = set()
    headers: dict[str, bytes] = {}
    for entry in interfaces:
        name = entry.get("name")
        version = entry.get("version")
        header = entry.get("header")
        if not isinstance(name, str) or not NAME_PATTERN.match(name):
            fail(f"Invalid interface name: {name!r}")
        if name in seen_names:
            fail(f"Duplicate interface name: {name}")
        seen_names.add(name)
        if not isinstance(version, int) or version < 1:
            fail(f"Invalid interface version for {name}: {version!r}")
        if not isinstance(header, str) or not header.startswith("include/pulse/"):
            fail(f"Invalid header path for {name}: {header!r}")
        relative = header.removeprefix("include/pulse/")
        if relative.startswith(".") or "/" in relative or "\\" in relative or not relative.endswith(".h"):
            fail(f"Refusing unsafe header path for {name}: {header}")
        if relative in seen_headers:
            fail(f"Duplicate header path: {header}")
        seen_headers.add(relative)

        contract = entry.get("headerContract")
        if contract is None:
            continue
        text = contract.get("text")
        declared = contract.get("sha256")
        if not isinstance(text, str) or not text:
            fail(f"Missing header text for {name}")
        if not isinstance(declared, str) or not SHA256_PATTERN.match(declared):
            fail(f"Invalid header SHA-256 for {name}: {declared!r}")
        data = text.encode("utf-8")
        actual = sha256_bytes(data)
        if actual != declared:
            fail(f"Header text for {name} does not match its declared SHA-256")
        headers[relative] = data

    if not headers:
        fail("Catalog contains no embedded header contracts")
    return catalog, headers


def extract(args: argparse.Namespace) -> int:
    pulse = Path(args.pulse).resolve()
    api = read_host_api(pulse)
    catalog, headers = validate_catalog(api)

    out = Path(args.out).resolve()
    sdk_root = out / "sdk" / "native"
    include = sdk_root / "include" / "pulse"
    include.mkdir(parents=True, exist_ok=True)
    for relative, data in headers.items():
        (include / relative).write_bytes(data)
    catalog_path = sdk_root / "api-catalog.json"
    catalog_path.write_text(
        json.dumps(catalog, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n"
    )

    provenance = {
        "formatVersion": 1,
        "tool": "scripts/host_sdk.py",
        "extractedAt": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "host": {
            "path": str(pulse),
            "size": pulse.stat().st_size,
            "sha256": sha256_file(pulse),
        },
        "discovery": {
            "apiVersion": api["apiVersion"],
            "contractIdentity": api.get("contractIdentity"),
        },
        "sdk": {
            "abiVersion": catalog["abiVersion"],
            "sdkPreview": catalog["sdkPreview"],
            "interfaceCount": len(catalog["interfaces"]),
            "catalogSha256": canonical_sha256(catalog),
        },
        "headers": {path: sha256_bytes(data) for path, data in sorted(headers.items())},
    }
    (out / "provenance.json").write_text(
        json.dumps(provenance, indent=2, ensure_ascii=False) + "\n", encoding="utf-8", newline="\n"
    )

    summary = {
        "out": str(out),
        "host": provenance["host"],
        "sdk": provenance["sdk"],
        "headers": len(headers),
    }
    print(json.dumps(summary, indent=2) if args.json else
          f"Extracted {len(headers)} headers from {pulse}\n"
          f"  SDK preview {catalog['sdkPreview']}, ABI {catalog['abiVersion']}, "
          f"{len(catalog['interfaces'])} interfaces\n"
          f"  catalog sha256 {provenance['sdk']['catalogSha256']}\n  -> {sdk_root}")
    return 0


def load_baseline(path: Path) -> dict:
    provenance_path = path / "provenance.json"
    if not provenance_path.is_file():
        fail(f"Baseline provenance missing: {provenance_path}")
    return json.loads(provenance_path.read_text(encoding="utf-8"))


def comparable(catalog: dict) -> dict[str, tuple[int, str | None]]:
    return {
        entry["name"]: (entry["version"], (entry.get("headerContract") or {}).get("sha256"))
        for entry in catalog["interfaces"]
    }


def verify(args: argparse.Namespace) -> int:
    pulse = Path(args.pulse).resolve()
    baseline_dir = Path(args.baseline).resolve()
    baseline = load_baseline(baseline_dir)
    api = read_host_api(pulse)
    catalog, headers = validate_catalog(api)

    problems: list[str] = []
    expected_sdk = baseline["sdk"]
    if catalog["sdkPreview"] != expected_sdk["sdkPreview"]:
        problems.append(f"sdkPreview {catalog['sdkPreview']} != baseline {expected_sdk['sdkPreview']}")
    if catalog["abiVersion"] != expected_sdk["abiVersion"]:
        problems.append(f"abiVersion {catalog['abiVersion']} != baseline {expected_sdk['abiVersion']}")
    actual_catalog_sha = canonical_sha256(catalog)
    if actual_catalog_sha != expected_sdk["catalogSha256"]:
        problems.append(f"catalog sha256 {actual_catalog_sha[:12]} != baseline {expected_sdk['catalogSha256'][:12]}")

    expected_headers: dict[str, str] = baseline["headers"]
    for relative, expected in sorted(expected_headers.items()):
        actual = headers.get(relative)
        if actual is None:
            problems.append(f"header missing from host: {relative}")
        elif sha256_bytes(actual) != expected:
            problems.append(f"header changed: {relative}")

    baseline_catalog_path = baseline_dir / "sdk" / "native" / "api-catalog.json"
    if baseline_catalog_path.is_file():
        expected_api = comparable(json.loads(baseline_catalog_path.read_text(encoding="utf-8")))
        actual_api = comparable(catalog)
        for name in sorted(set(expected_api) - set(actual_api)):
            problems.append(f"interface removed: {name}")
        for name in sorted(set(actual_api) - set(expected_api)):
            problems.append(f"interface added: {name}")
        for name in sorted(set(expected_api) & set(actual_api)):
            if expected_api[name] != actual_api[name]:
                problems.append(
                    f"interface changed: {name} {expected_api[name]} -> {actual_api[name]}"
                )

    if problems:
        for problem in problems:
            print(f"DRIFT: {problem}", file=sys.stderr)
        return 3
    print(f"Host matches baseline: SDK preview {catalog['sdkPreview']}, "
          f"{len(catalog['interfaces'])} interfaces, catalog {actual_catalog_sha[:12]}")
    return 0


def compare(args: argparse.Namespace) -> int:
    current = Path(args.baseline).resolve()
    other = Path(args.against).resolve()
    current_catalog = json.loads((current / "sdk" / "native" / "api-catalog.json").read_text(encoding="utf-8"))
    other_catalog = json.loads((other / "api-catalog.json").read_text(encoding="utf-8"))
    left = comparable(current_catalog)
    right = comparable(other_catalog)

    added = sorted(set(left) - set(right))
    removed = sorted(set(right) - set(left))
    changed = sorted(name for name in set(left) & set(right) if left[name] != right[name])
    print(f"baseline {len(left)} interfaces vs {other} {len(right)} interfaces")
    for name in added:
        print(f"  host-only interface: {name} v{left[name][0]}")
    for name in removed:
        print(f"  sdk-only interface:  {name} v{right[name][0]}")
    for name in changed:
        print(f"  changed: {name} {right[name]} -> {left[name]}")
    print(f"summary: +{len(added)} -{len(removed)} ~{len(changed)}")
    return 0


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    subparsers = parser.add_subparsers(dest="command", required=True)

    extract_parser = subparsers.add_parser("extract", help="snapshot the SDK embedded in a Pulse host")
    extract_parser.add_argument("--pulse", required=True, help="path to the installed pulse.exe")
    extract_parser.add_argument("--out", required=True, help="output directory")
    extract_parser.add_argument("--json", action="store_true", help="machine-readable summary")
    extract_parser.set_defaults(func=extract)

    verify_parser = subparsers.add_parser("verify", help="prove a host still matches a snapshot")
    verify_parser.add_argument("--pulse", required=True, help="path to the installed pulse.exe")
    verify_parser.add_argument("--baseline", required=True, help="snapshot directory from extract")
    verify_parser.set_defaults(func=verify)

    compare_parser = subparsers.add_parser("compare", help="diff a snapshot against another SDK tree")
    compare_parser.add_argument("--baseline", required=True, help="snapshot directory from extract")
    compare_parser.add_argument("--against", required=True, help="directory containing api-catalog.json")
    compare_parser.set_defaults(func=compare)

    args = parser.parse_args()
    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
