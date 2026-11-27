"""Protected Environment signing and independent verification of exact manifests.

The private key exists only in the signing step and a fresh temporary directory.
No candidate binary is executed; the official pinned Windows CNG CLI is used.
"""
from __future__ import annotations

import base64
import hashlib
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile
import tomllib

import package_common as common
import release_workflow as release

ROOT = release.ROOT
REGISTRY = ROOT / ".local/registry-signing"


def publisher() -> dict:
    data = tomllib.loads((ROOT / "sdk/publisher.toml").read_text(encoding="utf-8"))
    if (set(data) != {"name", "fingerprint", "url", "registry_revision"}
            or not isinstance(data["name"], str) or not data["name"].strip()
            or not re.fullmatch(r"[0-9a-f]{64}", data["fingerprint"])
            or not re.fullmatch(r"[0-9a-f]{40}", data["registry_revision"])
            or data["url"] != "https://github.com/strangelion/pulse-extras"):
        raise ValueError("invalid reviewed publisher configuration")
    return data


def decode_key(value: str) -> bytes:
    if not isinstance(value, str) or not 1 <= len(value) <= 11000:
        raise ValueError("missing or oversized signing key")
    try:
        data = base64.b64decode(value, validate=True)
    except ValueError:
        raise ValueError("invalid Base64 signing key") from None
    if not 1 <= len(data) <= 8192:
        raise ValueError("invalid signing key size")
    return data


def validate_public(data: bytes, pin: dict, supplied: str) -> str:
    digest = hashlib.sha256(data).hexdigest()
    if digest != pin["fingerprint"] or supplied != pin["fingerprint"]:
        raise ValueError("public key does not match reviewed publisher fingerprint")
    return digest


def official_tool() -> Path:
    if sys.platform != "win32":
        raise ValueError("official signing and verification require Windows")
    pin = publisher()
    if (release.capture("git", "-C", str(REGISTRY), "rev-parse", "HEAD") != pin["registry_revision"]
            or release.capture("git", "-C", str(REGISTRY), "status", "--porcelain", "--untracked-files=normal")):
        raise ValueError("official signing tool checkout differs from reviewed revision")
    tool = REGISTRY / "tools/pulse_sign.py"
    common.regular_file(tool, common.FILE_MAX)
    return tool


def cli(tool: Path, *args) -> None:
    # Do not propagate secrets or print upstream output on failure.
    env = {k: v for k, v in os.environ.items()
           if k not in {"PULSE_SIGNING_PRIVATE_KEY", "GH_TOKEN", "GITHUB_TOKEN"}}
    result = subprocess.run([sys.executable, str(tool), *map(str, args)],
                            cwd=REGISTRY, env=env, capture_output=True, timeout=60)
    if result.returncode:
        raise RuntimeError("official signing/verification command failed: " + str(args[0]))


def public_record(pin: dict, public: bytes) -> dict:
    return {"formatVersion": 1, "id": pin["fingerprint"], "name": pin["name"],
            "url": pin["url"], "publicKey": public.hex()}


def signature_name(item: dict) -> str:
    return item["asset"].removesuffix(".pulse-ext") + ".sig.json"


def evidence_for(item: dict, directory: Path, signature: Path, revision: str, pin: dict) -> dict:
    return {"schema_version": 1, "source_revision": revision, "asset": item["asset"],
            "asset_sha256": common.sha256(directory / item["asset"]),
            "manifest_sha256": common.sha256(directory / "manifest.json", common.EVIDENCE_MAX),
            "signature": signature.name, "signature_sha256": common.sha256(signature, 16384),
            "signature_size": signature.stat().st_size, "publisher": pin["fingerprint"],
            "registry_tool_revision": pin["registry_revision"], "signature_verified": True,
            "registry_accepted": False}


def verify_all(items: list[dict], candidate: Path, signed: Path, revision: str) -> dict:
    pin = publisher()
    tool = official_tool()
    if {p.name for p in signed.iterdir()} != {i["product"] for i in items}:
        raise ValueError("signature product inventory differs")
    result = {}
    with tempfile.TemporaryDirectory(prefix="pulse-public-") as temp:
        for item in items:
            key = item["product"]
            directory = candidate / key
            release.verify_candidate(item, directory, revision)
            out = signed / key
            sig = out / signature_name(item)
            names = {sig.name, "publisher.json", "signing-evidence.json"}
            if {p.name for p in out.iterdir()} != names:
                raise ValueError("unexpected signature artifact inventory")
            record = common.read_evidence(out / "publisher.json")
            text = record.get("publicKey")
            if not isinstance(text, str) or not re.fullmatch(r"[0-9a-f]{2,16384}", text) or len(text) % 2:
                raise ValueError("invalid public key record")
            public = bytes.fromhex(text)
            validate_public(public, pin, record.get("id"))
            if record != public_record(pin, public):
                raise ValueError("publisher record differs from reviewed identity")
            pubfile = Path(temp) / (key + ".public.blob")
            pubfile.write_bytes(public)
            common.regular_file(sig, 16384)
            cli(tool, "verify-manifest", directory / "manifest.json",
                "--signature", sig, "--public-key", pubfile)
            if common.read_evidence(sig).get("publisher") != pin["fingerprint"]:
                raise ValueError("unexpected signature publisher")
            expected = evidence_for(item, directory, sig, revision, pin)
            if common.read_evidence(out / "signing-evidence.json") != expected:
                raise ValueError("signature evidence differs from exact verified artifacts")
            result[key] = [sig, out / "publisher.json", out / "signing-evidence.json"]
    return result


def sign_all(items: list[dict], candidate: Path, signed: Path, revision: str,
             private_encoded: str) -> None:
    pin = publisher()
    tool = official_tool()
    # The caller removed the secret before any subprocess started.
    private = decode_key(private_encoded)
    del private_encoded
    public = decode_key(os.environ.get("PULSE_SIGNING_PUBLIC_KEY", ""))
    validate_public(public, pin, os.environ.get("PULSE_PUBLISHER_FINGERPRINT", ""))
    if private == public:
        raise ValueError("private and public keys must differ")
    signed.mkdir(parents=True, exist_ok=False)
    with tempfile.TemporaryDirectory(prefix="pulse-signing-", dir=os.environ.get("RUNNER_TEMP")) as temp:
        keydir = Path(temp)
        private_file = keydir / "publisher.private.blob"
        public_file = keydir / "publisher.public.blob"
        try:
            with private_file.open("xb") as stream:
                stream.write(private)
            del private
            public_file.write_bytes(public)
            for item in items:
                key = item["product"]
                directory = candidate / key
                release.verify_candidate(item, directory, revision)
                out = signed / key
                out.mkdir()
                signature = out / signature_name(item)
                cli(tool, "sign-manifest", directory / "manifest.json",
                    "--private-key", private_file, "--output", signature)
                cli(tool, "verify-manifest", directory / "manifest.json",
                    "--signature", signature, "--public-key", public_file)
                common.write_evidence(out / "publisher.json", public_record(pin, public))
                common.write_evidence(out / "signing-evidence.json",
                                      evidence_for(item, directory, signature, revision, pin))
        finally:
            private_file.unlink(missing_ok=True)
    verify_all(items, candidate, signed, revision)


if __name__ == "__main__":
    # A public-only output, used before checkout of the pinned registry tool.
    with open(os.environ["GITHUB_OUTPUT"], "a", encoding="utf-8") as stream:
        stream.write("revision=" + publisher()["registry_revision"] + "\n")
