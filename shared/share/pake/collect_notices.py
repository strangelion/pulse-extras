"""Collect license texts for the locked Windows CPace build.

Fail if a resolved dependency has no bundled license text. Do not write
absolute Cargo cache paths into the redistributable notice.
"""
import json
from pathlib import Path
import subprocess
import sys

root = Path(__file__).resolve().parent
metadata = json.loads(subprocess.check_output(
    ["cargo", "metadata", "--locked", "--format-version", "1",
     "--filter-platform", "x86_64-pc-windows-msvc"],
    cwd=root, text=True, encoding="utf-8", timeout=120,
))
resolved = {node["id"] for node in metadata["resolve"]["nodes"]}
sections = ["Pulse Share CPace helper — third-party license notices\n"]
for package in sorted(metadata["packages"], key=lambda p: (p["name"], p["version"])):
    if package["id"] not in resolved or package["source"] is None:
        continue
    directory = Path(package["manifest_path"]).parent
    candidates = {p for p in directory.iterdir() if p.is_file() and
                  p.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT", "UNLICENSE"))}
    if package.get("license_file"):
        candidates.add(directory / package["license_file"])
    if not candidates:
        raise RuntimeError(f"Missing license text for {package['name']} {package['version']}")
    sections.append(f"\n{'=' * 72}\n{package['name']} {package['version']}\n"
                    f"Declared license: {package.get('license') or 'see license file'}\n"
                    f"Source: {package['source']}\n")
    for path in sorted(candidates):
        if not path.is_file() or path.stat().st_size > 1024 * 1024:
            raise RuntimeError(f"Invalid license text for {package['name']}")
        sections.append(f"\n--- {path.name} ---\n{path.read_text(encoding='utf-8')}\n")
data = "".join(sections)
if len(data.encode("utf-8")) > 4 * 1024 * 1024 or len(sections) < 3:
    raise RuntimeError("Invalid license notice inventory")
Path(sys.argv[1]).write_text(data, encoding="utf-8")
