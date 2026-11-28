"""Collect license notices for actual linked non-standard Go packages."""
import json
from pathlib import Path
import subprocess
import sys

raw = subprocess.check_output(["go", "list", "-deps", "-json", "."], text=True,
                              encoding="utf-8", timeout=120)
decoder = json.JSONDecoder()
modules = {}
while raw.strip():
    raw = raw.lstrip()
    pkg, end = decoder.raw_decode(raw)
    raw = raw[end:]
    mod = pkg.get("Module")
    if mod and not mod.get("Main"):
        if mod.get("Replace") or not mod.get("Dir") or not mod.get("Version"):
            raise RuntimeError("Unpinned Go module")
        modules[(mod["Path"], mod["Version"])] = Path(mod["Dir"])
if not any(name == "github.com/quic-go/quic-go" for name, _ in modules):
    raise RuntimeError("QUIC notice inventory missing")
sections = ["Pulse Share Go dependencies — third-party notices\n"]
for (name, version), directory in sorted(modules.items()):
    licenses = sorted(p for p in directory.iterdir() if p.is_file() and
                      p.name.upper().startswith(("LICENSE", "LICENCE", "COPYING", "NOTICE", "COPYRIGHT")))
    if not licenses:
        raise RuntimeError(f"Missing license for {name} {version}")
    sections.append(f"\n{'=' * 72}\n{name} {version}\n")
    for p in licenses:
        if p.stat().st_size > 1024 * 1024:
            raise RuntimeError("Oversized license")
        sections.append(f"\n--- {p.name} ---\n{p.read_text(encoding='utf-8')}\n")
data = "".join(sections)
if len(data.encode("utf-8")) > 4 * 1024 * 1024:
    raise RuntimeError("Notice inventory too large")
Path(sys.argv[1]).write_text(data, encoding="utf-8")
