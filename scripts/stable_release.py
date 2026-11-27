"""Promote a successful exact-source candidate; never rebuild tested bytes."""
from __future__ import annotations

import argparse
import json
import os
from pathlib import Path
import re
import sys
import subprocess
import zipfile

import release_workflow as release
import package_common as common
import environment_signing as signing

ROOT = release.ROOT
MODES = {"draft-stable", "publish-stable"}


def validate_run(run: dict, workflow: dict, repo: str, revision: str) -> None:
    if (run.get("workflow_id") != workflow.get("id")
            or workflow.get("path") != ".github/workflows/release.yml"
            or run.get("event") != "workflow_dispatch"
            or run.get("status") != "completed" or run.get("conclusion") != "success"
            or run.get("head_branch") != "main" or run.get("head_sha") != revision
            or (run.get("head_repository") or {}).get("full_name") != repo):
        raise ValueError("candidate must be a successful Extension release run on this exact main SHA")


def tested_hashes(value: str) -> dict:
    result = {}
    for pair in value.split(","):
        key, sep, digest = pair.strip().partition("=")
        if not sep or key not in release.package.PRODUCTS or key in result or not re.fullmatch(r"[0-9a-f]{64}", digest):
            raise ValueError("expected unique product=lowercase-SHA256 entries")
        result[key] = digest
    if not result:
        raise ValueError("no accepted packages")
    return result


def prepare(output: Path, revision: str, run_id: str, hashes: dict,
            host: str, reference: str, actor: str) -> tuple[list[dict], dict]:
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+(?:\.[0-9]+)?", host) or len(host) > 32:
        raise ValueError("record the actual tested Pulse host version")
    if not reference.strip() or len(reference) > 4000 or not actor:
        raise ValueError("record acceptance evidence reference and actor")
    if {path.name for path in output.iterdir()} != set(hashes):
        raise ValueError("tested hashes must cover exactly the candidate products")
    items, receipts = [], {}
    for key, digest in sorted(hashes.items()):
        directory = output / key
        evidence = common.read_evidence(directory / "release-evidence.json")
        version = evidence["version"]
        if not re.fullmatch(r"(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)\.(?:0|[1-9][0-9]*)", version):
            raise ValueError("stable version must be MAJOR.MINOR.PATCH")
        item = release.plan(f"{key}={version}", "dry-run")[0]
        release.verify_candidate(item, directory, revision)
        if evidence["asset_sha256"] != digest:
            raise ValueError("tested package digest differs from candidate: " + key)
        items.append(item)
        receipts[key] = {
            "schema_version": 1, "product": key, "version": version,
            "source_revision": revision, "build_run_id": run_id, "asset_sha256": digest,
            "host_version": host, "reported_by": actor, "evidence_reference": reference,
            "acceptance_kind": "owner-attested-not-automated",
            "attested_scope": "applicable final installed acceptance including lifecycle, settings, coexistence, upgrade/rollback, resource and product-specific checks",
        }
    return items, receipts


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=["prepare", "sign", "publish"])
    args = parser.parse_args()
    # Remove the secret before git, gh or any other child process can inherit it.
    private_encoded = os.environ.pop("PULSE_SIGNING_PRIVATE_KEY", "")
    try:
        revision = release.source_revision()
        repo = release.repository()
        run_id = os.environ["CANDIDATE_RUN"]
        mode = os.environ["STABLE_MODE"]
        if not re.fullmatch(r"[1-9][0-9]{0,19}", run_id) or mode not in MODES:
            raise ValueError("invalid candidate run or stable mode")
        if os.environ.get("ACCEPTANCE_CONFIRMED") != "true":
            raise ValueError("explicit installed acceptance confirmation is required")
        output = ROOT / ".local/stable-candidate"
        signed = ROOT / ".local/stable-signatures"
        if args.action == "prepare":
            workflow = json.loads(release.capture("gh", "api", f"repos/{repo}/actions/workflows/release.yml"))
            run = json.loads(release.capture("gh", "api", f"repos/{repo}/actions/runs/{run_id}"))
            validate_run(run, workflow, repo, revision)
            if output.exists():
                raise ValueError("candidate directory already exists")
            release.run("gh", "run", "download", run_id, "--repo", repo, "--name",
                        "extension-release-candidates", "--dir", str(output), timeout=300)
        items, receipts = prepare(output, revision, run_id, tested_hashes(os.environ["TESTED_HASHES"]),
                                  os.environ["TESTED_HOST"], os.environ["ACCEPTANCE_REFERENCE"],
                                  os.environ["GITHUB_ACTOR"])
        if args.action == "prepare":
            release.preflight(items)
        elif args.action == "sign":
            signing.sign_all(items, output, signed, revision, private_encoded)
        else:
            verified = signing.verify_all(items, output, signed, revision)
            release.publish(items, mode, output, stable_receipts=receipts,
                            build_run_id=run_id, signed_assets=verified)
        return 0
    except (OSError, ValueError, RuntimeError, KeyError, TypeError,
            subprocess.SubprocessError, zipfile.BadZipFile) as exc:
        # Avoid exposing key material or command details from the protected step.
        if args.action == "sign":
            print("Stable signing failed; verify Environment configuration and candidate identity.", file=sys.stderr)
        else:
            print(f"Stable promotion failed: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
