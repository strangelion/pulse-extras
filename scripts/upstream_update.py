"""Read-only discovery of stable upstream releases and compatible SDK candidates.

Only GitHub's official Pulse repository is consulted. No upstream program is
executed here. A new ABI/preview or changed C-header inventory needs review.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tomllib
from urllib.request import urlopen

from sdk_headers import HEADERS
import upstream_pin as pins

ROOT = pins.ROOT
LIMIT = 1024 * 1024


def gh(*args: str):
    result = subprocess.run(["gh", "api", *args], check=True, capture_output=True,
                            text=True, encoding="utf-8", timeout=120)
    return json.loads(result.stdout)


def releases():
    pages = gh(f"repos/{pins.REPOSITORY}/releases?per_page=100", "--paginate", "--slurp")
    return [row for page in pages for row in page]


def stable_releases(rows: list[dict]) -> dict:
    result = {}
    for row in rows:
        tag = row.get("tag_name", "")
        if (not isinstance(tag, str) or not tag.startswith("v")
                or row.get("draft") is not False or row.get("prerelease") is not False):
            continue
        try:
            version = pins.version_tuple(tag[1:])
        except ValueError:
            continue
        if version in result:
            raise ValueError("duplicate stable upstream release")
        result[version] = row
    if not result:
        raise ValueError("no stable Pulse releases found")
    return result


def release_installer(row: dict) -> dict:
    version = row["tag_name"][1:]
    pins.version_tuple(version)
    filename = f"PulseSetup-{version}.exe"
    matches = [asset for asset in row["assets"] if asset.get("name") == filename]
    if len(matches) != 1:
        raise ValueError("expected exactly one modern Windows installer: " + filename)
    asset = matches[0]
    digest = asset.get("digest")
    size = asset.get("size")
    expected_url = f"{pins.REPOSITORY_URL}/releases/download/v{version}/{filename}"
    if (asset.get("browser_download_url") != expected_url
            or asset.get("state") != "uploaded"
            or not isinstance(digest, str) or not digest.startswith("sha256:")
            or not pins.valid_hex(digest[7:], 64)
            or type(size) is not int or not 0 < size <= pins.MAX_INSTALLER_SIZE):
        raise ValueError("upstream installer lacks trustworthy size/digest metadata")
    return {"filename": filename, "size": size, "sha256": digest[7:]}


def revision(tag: str) -> str:
    pins.version_tuple(tag[1:])
    # Resolves annotated tags to their actual commit, never target_commitish/main.
    sha = gh(f"repos/{pins.REPOSITORY}/commits/{tag}")["sha"]
    if not pins.valid_hex(sha, 40):
        raise ValueError("invalid upstream release commit")
    return sha


def raw(sha: str, path: str) -> bytes:
    if not pins.valid_hex(sha, 40):
        raise ValueError("invalid raw source revision")
    url = f"https://raw.githubusercontent.com/{pins.REPOSITORY}/{sha}/{path}"
    with urlopen(url, timeout=30) as response:
        payload = response.read(LIMIT + 1)
    if len(payload) > LIMIT:
        raise ValueError("upstream SDK file exceeds bound: " + path)
    return payload


def git_blob(data: bytes) -> str:
    return hashlib.sha1(f"blob {len(data)}\0".encode("ascii") + data).hexdigest()


def headers(sha: str, dest: Path) -> tuple[dict, str]:
    prefix = "sdk/native/include/pulse"
    rows = gh(f"repos/{pins.REPOSITORY}/contents/{prefix}?ref={sha}")
    entries = {row["name"]: row for row in rows if row["name"].endswith(".h")}
    expected = {name + ".h" for name in HEADERS}
    if set(entries) != expected:
        raise ValueError(f"C header inventory changed; manual adaptation required; added={sorted(set(entries) - expected)}, removed={sorted(expected - set(entries))}")
    dest.mkdir(parents=True, exist_ok=False)
    digests = {}
    abi_blob = ""
    for name in HEADERS:
        filename = name + ".h"
        entry = entries[filename]
        if (entry.get("type") != "file" or not pins.valid_hex(entry.get("sha"), 40)
                or type(entry.get("size")) is not int or not 0 < entry["size"] <= LIMIT):
            raise ValueError("invalid upstream header metadata: " + filename)
        payload = raw(sha, prefix + "/" + filename)
        blob = git_blob(payload)
        if len(payload) != entry["size"] or blob != entry["sha"]:
            raise ValueError("header bytes differ from exact Git blob: " + filename)
        (dest / filename).write_bytes(payload)
        digests[name] = hashlib.sha256(payload).hexdigest()
        if name == "abi":
            abi_blob = blob
    return digests, abi_blob


def render_pin(text: str, old: dict, version: str, sha: str, installer: dict,
               digests: dict, abi_blob: str) -> str:
    # Preserve historical host snapshot, comments, and every unrelated field.
    def replace(key: str, value) -> None:
        nonlocal text
        pattern = rf"(?m)^{re.escape(key)} = [^\r\n]+$"
        encoded = json.dumps(value)
        text, count = re.subn(pattern, lambda _: f"{key} = {encoded}", text)
        if count != 1:
            raise ValueError("ambiguous or missing pin field: " + key)
    replace("revision", sha)
    replace("pulse_source_version", version)
    replace("abi_header_blob", abi_blob)
    replace("host_verified", False)
    for key, value in installer.items():
        replace(key, value)
    for key, value in digests.items():
        replace(key, value)
    result = pins.validate(tomllib.loads(text))
    if result.get("host") != old.get("host"):
        raise ValueError("historical host snapshot must not be overwritten")
    if (result["revision"] != sha or result["pulse_source_version"] != version
            or result["installer"] != installer or result["headers"] != digests
            or result["abi_header_blob"] != abi_blob or result["host_verified"]):
        raise ValueError("candidate pin failed round-trip verification")
    return text


def discover(out: Path) -> tuple[str, str, dict]:
    old = pins.load()
    versions = stable_releases(releases())
    baseline = pins.version_tuple(old["pulse_source_version"])
    if baseline not in versions:
        raise ValueError("reviewed upstream release no longer listed; investigate before updating")
    row = versions[baseline]
    if release_installer(row) != old["installer"] or revision(row["tag_name"]) != old["revision"]:
        raise ValueError("reviewed upstream asset or tag changed in place; investigate")
    latest = max(versions)
    if latest <= baseline:
        return "unchanged", "", {"current": old["pulse_source_version"], "latest": old["pulse_source_version"]}
    row = versions[latest]
    version = row["tag_name"][1:]
    sha = revision(row["tag_name"])
    installer = release_installer(row)
    catalog = json.loads(raw(sha, "sdk/native/api-catalog.json"))
    if (catalog.get("id") != "pulse.native-sdk" or catalog.get("architecture") != "windows-x64"
            or catalog.get("abiVersion") != old["abi_version"]
            or catalog.get("sdkPreview") != old["sdk_preview"]):
        raise ValueError(f"upstream {version} ABI/SDK preview or architecture changed; manual adaptation required")
    digests, abi_blob = headers(sha, out / "include/pulse")
    text = render_pin((ROOT / "sdk/upstream.toml").read_text(encoding="utf-8"),
                      old, version, sha, installer, digests, abi_blob)
    target = out / "candidate/sdk/upstream.toml"
    target.parent.mkdir(parents=True)
    target.write_text(text, encoding="utf-8", newline="\n")
    report = {"current": old["pulse_source_version"], "latest": version,
              "revision": sha, "installer": installer,
              "changed_headers": sorted(name for name in HEADERS if old["headers"][name] != digests[name]),
              "abi_version": old["abi_version"], "sdk_preview": old["sdk_preview"],
              "real_host_accepted": False}
    return "candidate", "deps/pulse-v" + version, report


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, default=ROOT / ".local/upstream-update")
    args = parser.parse_args()
    args.out.mkdir(parents=True, exist_ok=False)
    try:
        status, branch, report = discover(args.out)
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as exc:
        report = {"status": "blocked", "reason": str(exc)}
        (args.out / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
        print("Upstream update blocked: " + str(exc), file=sys.stderr)
        return 1
    report["status"] = status
    (args.out / "report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(report, indent=2))
    if output := os.environ.get("GITHUB_OUTPUT"):
        with open(output, "a", encoding="utf-8") as stream:
            stream.write(f"status={status}\nbranch={branch}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
