"""Inventory fixed x64 PE unwind stack allocations without executing images.

Not a call-graph, dynamic-stack, or leaf-function analysis. Native Zig/C only.
"""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import struct
import subprocess
import sys

REVIEW = 16 * 1024
LARGE = 64 * 1024
LIMIT = 128 * 1024
NATIVE_EXES = {
    "pulse-share-desktop.exe", "pulse-share-local.exe", "pulse-share-worker.exe",
    "pulse-pet.exe", "pulse-pet-crash-capture.exe",
}
SKIPPED = {"pulse-share-lan.exe", "pulse-share-pake.exe"}


class PE:
    def __init__(self, data: bytes):
        self.data = data
        if data[:2] != b"MZ":
            raise ValueError("missing DOS signature")
        pe = self.unpack("<I", 0x3c)[0]
        if self.read(pe, 4) != b"PE\0\0":
            raise ValueError("missing PE signature")
        machine, count = self.unpack("<HH", pe + 4)
        optional_size = self.unpack("<H", pe + 20)[0]
        opt = pe + 24
        if machine != 0x8664 or optional_size < 112 or self.unpack("<H", opt)[0] != 0x20b:
            raise ValueError("expected x64 PE32+")
        if not 0 < count <= 96:
            raise ValueError("invalid section count")
        self.read(opt, optional_size)
        self.image_base = self.unpack("<Q", opt + 24)[0]
        directories = self.unpack("<I", opt + 108)[0]
        if directories > (optional_size - 112) // 8:
            raise ValueError("invalid data directory count")
        self.directories = [
            self.unpack("<II", opt + 112 + 8 * i) for i in range(directories)
        ]
        self.sections = []
        for i in range(count):
            sec = opt + optional_size + i * 40
            self.read(sec, 40)
            virtual_size, rva, size, raw = self.unpack("<IIII", sec + 8)
            if size:
                self.read(raw, size)
                self.sections.append((rva, max(virtual_size, size), raw, size))

    def read(self, offset: int, size: int) -> bytes:
        if offset < 0 or size < 0 or offset + size > len(self.data):
            raise ValueError("truncated PE data")
        return self.data[offset:offset + size]

    def unpack(self, fmt: str, offset: int) -> tuple:
        return struct.unpack(fmt, self.read(offset, struct.calcsize(fmt)))

    def rva(self, rva: int, size: int) -> bytes:
        for start, span, raw, raw_size in self.sections:
            if start <= rva < start + span:
                delta = rva - start
                if delta + size > raw_size:
                    raise ValueError("RVA outside file-backed section")
                return self.read(raw + delta, size)
        raise ValueError(f"unmapped RVA 0x{rva:x}")

    def directory(self, i: int) -> tuple[int, int]:
        return self.directories[i] if i < len(self.directories) else (0, 0)

    def exports(self) -> dict[int, list[str]]:
        base, size = self.directory(0)
        if not base and not size:
            return {}
        if not base or size < 40:
            raise ValueError("invalid export directory")
        fields = struct.unpack("<IIHHIIIIIII", self.rva(base, 40))
        ordinal_base, functions, names, addresses, name_table, ordinals = fields[5:]
        if functions > 65536 or names > 65536:
            raise ValueError("export inventory exceeds limit")
        result: dict[int, list[str]] = {}
        by_ordinal: dict[int, list[str]] = {}
        for i in range(names):
            ordinal = struct.unpack("<H", self.rva(ordinals + i * 2, 2))[0]
            if ordinal >= functions:
                raise ValueError("invalid export ordinal")
            name_rva = struct.unpack("<I", self.rva(name_table + i * 4, 4))[0]
            name = bytearray()
            for j in range(1024):
                char = self.rva(name_rva + j, 1)
                if char == b"\0":
                    break
                name.extend(char)
            else:
                raise ValueError("unterminated export name")
            by_ordinal.setdefault(ordinal, []).append(name.decode("ascii", errors="replace"))
        for i in range(functions):
            address = struct.unpack("<I", self.rva(addresses + 4 * i, 4))[0]
            if address and not base <= address < base + size:
                result.setdefault(address, []).extend(
                    by_ordinal.get(i, [f"ordinal_{ordinal_base + i}"])
                )
        return result

    def unwind(self, address: int, visited: tuple[int, ...] = ()) -> int:
        if address in visited or len(visited) >= 32:
            raise ValueError("invalid unwind chain")
        header, _, count, _ = self.rva(address, 4)
        version, flags = header & 7, header >> 3
        if version != 1:
            raise ValueError(f"unsupported unwind version {version}")
        if flags & ~7 or (flags & 4 and flags & 3):
            raise ValueError("invalid unwind flags")
        codes = self.rva(address + 4, count * 2)
        total, i = 0, 0
        while i < count:
            op = codes[2 * i + 1] & 15
            info = codes[2 * i + 1] >> 4
            slots, added = 1, 0
            if op == 0:  # PUSH_NONVOL
                added = 8
            elif op == 1:  # ALLOC_LARGE
                if info not in (0, 1):
                    raise ValueError("invalid ALLOC_LARGE")
                slots = 2 if info == 0 else 3
                if i + slots > count:
                    raise ValueError("truncated ALLOC_LARGE")
                added = (struct.unpack_from("<H", codes, 2 * (i + 1))[0] * 8
                         if info == 0 else struct.unpack_from("<I", codes, 2 * (i + 1))[0])
            elif op == 2:  # ALLOC_SMALL
                added = info * 8 + 8
            elif op == 3:  # SET_FPREG (no extra stack)
                pass
            elif op in (4, 8):  # SAVE_NONVOL / SAVE_XMM128
                slots = 2
            elif op in (5, 9):  # FAR variants
                slots = 3
            elif op == 10:  # PUSH_MACHFRAME
                if info not in (0, 1):
                    raise ValueError("invalid PUSH_MACHFRAME")
                added = 40 + info * 8
            else:
                raise ValueError(f"unsupported unwind opcode {op}")
            if i + slots > count:
                raise ValueError("truncated unwind operation")
            total += added
            i += slots
        if flags & 4:
            chain = address + 4 + ((count + 1) & ~1) * 2
            begin, end, parent = struct.unpack("<III", self.rva(chain, 12))
            if begin >= end or not parent:
                raise ValueError("invalid chained runtime function")
            total += self.unwind(parent, visited + (address,))
        return total

    def inventory(self) -> dict:
        base, size = self.directory(3)
        if not base or not size or size % 12 or size > 24 * 1024 * 1024:
            raise ValueError("missing or invalid x64 runtime function directory")
        entries = self.rva(base, size)
        exports = self.exports()
        rows = []
        total = 0
        for begin, end, unwind in struct.iter_unpack("<III", entries):
            if begin == end == unwind == 0:
                continue  # linker padding
            if begin >= end or not unwind:
                raise ValueError("invalid runtime function")
            total += 1
            try:
                stack = self.unwind(unwind)
            except ValueError as exc:
                raise ValueError(f"function RVA 0x{begin:x}: {exc}") from exc
            if stack > REVIEW:
                rows.append({"rva": f"0x{begin:08x}", "bytes": stack,
                             "exports": exports.get(begin, [])})
        if not total:
            raise ValueError("empty runtime function inventory")
        rows.sort(key=lambda row: (-row["bytes"], row["rva"]))
        return {"functions": total, "frames": rows,
                "over_limit": [r["bytes"] for r in rows if r["bytes"] > LIMIT]}


def native_image(path: Path) -> bool:
    return ((path.name.startswith("pulse_") and path.suffix.lower() == ".dll")
            or path.name in NATIVE_EXES)


def regressions(current: list[int], baseline: list[int]) -> list[str]:
    if any(type(n) is not int or n <= LIMIT for n in baseline) or baseline != sorted(baseline, reverse=True):
        raise ValueError("baseline must list descending integer frames above 128 KiB")
    return [
        f"rank {i + 1}: {n} bytes exceeds {baseline[i] if i < len(baseline) else LIMIT}"
        for i, n in enumerate(current)
        if n > (baseline[i] if i < len(baseline) else LIMIT)
    ]


def find_symbolizer() -> str | None:
    # No network install or extra compiler invocation. Prefer the existing
    # runner tool, then the standard LLVM installation on Windows.
    found = shutil.which("llvm-symbolizer")
    if found:
        return found
    if os.name == "nt":
        candidate = Path(os.environ.get("ProgramFiles", r"C:\Program Files")) / "LLVM/bin/llvm-symbolizer.exe"
        if candidate.is_file():
            return str(candidate)
    return None


def source_location(name: str, root: Path) -> tuple[str, str]:
    if not name or name == "??":
        return "unknown", ""
    normalized = name.replace("\\", "/")
    root_name = root.resolve().as_posix().rstrip("/") + "/"
    if normalized.lower().startswith(root_name.lower()):
        normalized = normalized[len(root_name):]
    if normalized.startswith(("shared/", "extensions/")):
        return "project", normalized
    if "/lib/std/" in normalized:
        return "zig-stdlib", "std/" + normalized.split("/lib/std/", 1)[1]
    if "/lib/compiler_rt/" in normalized or normalized.endswith("/lib/compiler_rt.zig"):
        return "zig-compiler-rt", normalized.split("/lib/", 1)[-1]
    if normalized.startswith("vendor/") or "/vendor/" in normalized:
        return "dependency", normalized.split("/vendor/", 1)[-1]
    # Do not publish unrelated build-machine absolute paths.
    return "other", normalized.rsplit("/", 1)[-1]


def apply_symbols(rows: list[dict], output: str, image_base: int, root: Path) -> int:
    by_address = {image_base + int(row["rva"], 16): row for row in rows}
    resolved = 0
    for line in output.splitlines():
        if not line.strip():
            continue
        item = json.loads(line)
        address = int(item["Address"], 16)
        row = by_address.get(address)
        if row is None or "symbol" in row:
            continue
        symbols = item.get("Symbol", [])
        if not symbols:
            continue
        symbol = symbols[0]
        function = symbol.get("FunctionName", "")
        if not function or function == "??":
            continue
        origin, filename = source_location(symbol.get("FileName", ""), root)
        row["symbol"] = {"function": function, "source": filename,
                         "line": symbol.get("Line", 0), "origin": origin}
        resolved += 1
    return resolved


def symbolize(path: Path, pe: PE, rows: list[dict], tool: str | None) -> dict:
    if not rows:
        return {"status": "no-large-frames", "resolved": 0, "total": 0}
    if not tool:
        return {"status": "tool-unavailable", "resolved": 0, "total": len(rows)}
    addresses = "".join(f"{pe.image_base + int(row['rva'], 16):#x}\n" for row in rows)
    env = os.environ.copy()
    for key in ("_NT_SYMBOL_PATH", "_NT_ALT_SYMBOL_PATH", "DEBUGINFOD_URLS", "LLVM_SYMBOLIZER_OPTS"):
        env.pop(key, None)
    try:
        result = subprocess.run(
            [tool, "--obj=" + str(path.resolve()), "--output-style=JSON",
             "--no-inlines", "--functions=linkage", "--no-debuginfod"],
            input=addresses, text=True, encoding="utf-8", errors="replace",
            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=30, env=env,
            check=False,
        )
        if result.returncode != 0:
            return {"status": "tool-error", "resolved": 0, "total": len(rows), "exit_code": result.returncode}
        count = apply_symbols(rows, result.stdout, pe.image_base, Path(__file__).resolve().parents[1])
        return {"status": "complete" if count == len(rows) else "partial" if count else "unresolved",
                "resolved": count, "total": len(rows)}
    except (OSError, subprocess.TimeoutExpired, ValueError, KeyError, TypeError, AttributeError):
        count = sum("symbol" in row for row in rows)
        return {"status": "tool-error", "resolved": count, "total": len(rows)}


def audit(directory: Path, baseline: dict, profile: str, symbolizer: str | None = None) -> tuple[dict, list[str]]:
    if not directory.is_dir():
        raise ValueError(f"missing build directory: {directory}")
    report = {"schema": 1, "profile": profile, "images": {}, "excluded": [], "errors": []}
    failures = []
    expected = baseline.get(profile, {})
    for path in sorted(directory.iterdir()):
        if path.name in SKIPPED:
            report["excluded"].append(path.name)
        if not native_image(path):
            continue
        try:
            if not path.is_file() or path.stat().st_size > 256 * 1024 * 1024:
                raise ValueError("invalid image file or size")
            pe = PE(path.read_bytes())
            info = pe.inventory()
            info["sha256"] = hashlib.sha256(pe.data).hexdigest()
            info["symbolization"] = symbolize(path, pe, info["frames"], symbolizer)
            report["images"][path.name] = info
            print(f"{path.name}: {info['functions']} unwind entries; "
                  f"{len(info['frames'])} >16 KiB; {len(info['over_limit'])} >128 KiB")
            coverage = info["symbolization"]
            print(f"  Symbols: {coverage['status']} {coverage['resolved']}/{coverage['total']}")
            for row in info["frames"]:
                if row["bytes"] > LARGE:
                    symbol = row.get("symbol", {})
                    location = f"{symbol.get('function', '')} {symbol.get('source', '')}:{symbol.get('line', 0)}" if symbol else ""
                    location = location.replace("\r", " ").replace("\n", " ").encode("ascii", errors="backslashreplace").decode("ascii")
                    print(f"  REVIEW {row['rva']} {row['bytes']} bytes {' '.join(row['exports'])} {location}".rstrip())
                if path.suffix.lower() == ".dll" and row["exports"] and row["bytes"] > LIMIT:
                    failures.append(f"{path.name}: oversized DLL export {row['exports']} ({row['bytes']} bytes)")
            if path.name in expected:
                failures.extend(f"{path.name}: {msg}" for msg in
                                regressions(info["over_limit"], expected[path.name]))
            elif info["over_limit"]:
                print(f"  BASELINE PENDING: {path.name}; review measured frames before recording")
        except (OSError, ValueError) as exc:
            failures.append(f"{path.name}: {exc}")
    if not report["images"]:
        failures.append("no native images successfully inventoried")
    report["errors"] = failures
    return report, failures


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--baseline", required=True, type=Path)
    parser.add_argument("--profile", default="normal")
    parser.add_argument("--symbolizer", help="local llvm-symbolizer executable; default auto-discovery")
    args = parser.parse_args()
    try:
        baseline = json.loads(args.baseline.read_text(encoding="utf-8"))
        if baseline.get("schema") != 1 or not isinstance(baseline.get("profiles"), dict):
            raise ValueError("invalid baseline schema")
        report, failures = audit(args.directory, baseline["profiles"], args.profile, args.symbolizer or find_symbolizer())
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(report, indent=2, ensure_ascii=True) + "\n", encoding="utf-8")
        for failure in failures:
            print(f"ERROR: {failure}", file=sys.stderr)
        return int(bool(failures))
    except (OSError, ValueError, TypeError, AttributeError) as exc:
        print(f"Stack audit could not complete: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
