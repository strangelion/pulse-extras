#!/usr/bin/env python3
"""Mechanically compare the pinned SDK headers with a host's own header copy.

The host publishes the headers its binary was built against through
``--extension-api --extension-check`` (``nativeSdk.catalog.headerContract``).
Only headers that changed are shipped, so this script overlays them on the
pinned set and asks the Zig compiler to prove, for every public struct declared
in a host-shipped header, that the host copy:

* still declares the same fields, in the same order;
* keeps every field at the same byte offset;
* recursively keeps nested structs prefix-compatible (the SDK appends fields
  and documents the older size with a ``*_SIZE_V1`` macro);
* keeps function-pointer fields at the same arity.

Structs that live only in pinned headers are reported as not verifiable: the
host did not ship those headers, so they are not independently checked.
"""

from __future__ import annotations

import argparse
import pathlib
import re
import subprocess
import sys
import tempfile

ROOT = pathlib.Path(__file__).resolve().parents[1]
HEADERS = [
    "abi",
    "context",
    "commands",
    "dispatch",
    "preview",
    "ui",
    "ui_model",
    "ui_data",
    "ui_mount",
    "ui_events",
    "dialogs",
    "directories",
    "fileops",
    "files",
    "resources",
    "settings_pages",
    "staging",
    "tasks",
]

STRUCT = re.compile(r"^pub const (?:struct_)?(Pulse[A-Za-z0-9_]+) = extern struct \{", re.MULTILINE)
TYPEDEF = re.compile(r"\}\s*(Pulse[A-Za-z0-9_]+)\s*;")
DECL = re.compile(r"typedef\s+struct\s+(Pulse[A-Za-z0-9_]+)")

CHECKER = """const std = @import("std");
const pinned = @import("pinned_all.zig");
const host = @import("host_all.zig");

fn hasField(comptime T: type, comptime field_name: []const u8) bool {
    inline for (@typeInfo(T).@"struct".field_names) |candidate| {
        if (std.mem.eql(u8, candidate, field_name)) return true;
    }
    return false;
}

/// A nested struct may grow (the SDK appends fields and documents the older
/// size with a `*_SIZE_V1` macro), but every pinned field must keep its offset
/// and its own layout.
fn compareType(comptime P: type, comptime H: type, comptime path: []const u8) void {
    if (@alignOf(H) < @alignOf(P)) @compileError("alignment shrank: " ++ path);
    switch (@typeInfo(P)) {
        .@"struct" => {
            if (@sizeOf(H) < @sizeOf(P)) @compileError("struct shrank: " ++ path);
            const info = @typeInfo(P).@"struct";
            inline for (info.field_names, info.field_types) |field_name, pinned_type| {
                if (!hasField(H, field_name)) @compileError("lost field: " ++ path ++ "." ++ field_name);
                if (@offsetOf(H, field_name) != @offsetOf(P, field_name))
                    @compileError("field moved: " ++ path ++ "." ++ field_name);
                const host_type = @TypeOf(@field(@as(H, undefined), field_name));
                compareType(pinned_type, host_type, path ++ "." ++ field_name);
            }
        },
        .pointer => |pointer| {
            if (@sizeOf(H) != @sizeOf(P)) @compileError("pointer size changed: " ++ path);
            switch (pointer.size) {
                .one => switch (@typeInfo(pointer.child)) {
                    .@"fn" => |pinned_fn| {
                        const host_fn = switch (@typeInfo(H)) {
                            .pointer => |host_pointer| switch (@typeInfo(host_pointer.child)) {
                                .@"fn" => |value| value,
                                else => @compileError("not a function pointer: " ++ path),
                            },
                            else => @compileError("not a pointer: " ++ path),
                        };
                        if (host_fn.params.len != pinned_fn.params.len)
                            @compileError("function arity changed: " ++ path);
                        if (host_fn.is_var_args != pinned_fn.is_var_args)
                            @compileError("function varargs changed: " ++ path);
                    },
                    else => {},
                },
                else => {},
            }
        },
        else => {
            if (@sizeOf(H) != @sizeOf(P)) @compileError("size changed: " ++ path);
        },
    }
}

fn check(comptime name: []const u8) void {
    if (!@hasDecl(host, name)) @compileError("host is missing struct " ++ name);
    compareType(@field(pinned, name), @field(host, name), name);
}

comptime {
    @setEvalBranchQuota(4_000_000);
%s
}

test "prefix compatibility" {
    // Compilation is the assertion; the test exists so `zig test` analyzes it.
}
"""


def zig_executable(explicit: str | None) -> str:
    if explicit:
        return explicit
    found = subprocess.run(
        ["python", str(ROOT / "scripts" / "install_zig.py"), "--print-path"],
        capture_output=True,
        text=True,
    )
    if found.returncode == 0 and found.stdout.strip():
        return found.stdout.strip()
    return "zig"


def header_structs(path: pathlib.Path) -> set[str]:
    text = path.read_text(encoding="utf-8", errors="replace")
    return set(TYPEDEF.findall(text)) | set(DECL.findall(text))


def merge_includes(pinned: pathlib.Path, host: pathlib.Path, work: pathlib.Path) -> tuple[pathlib.Path, list[str], list[str]]:
    merged = work / "merged"
    (merged / "pulse").mkdir(parents=True)
    shipped: list[str] = []
    fallback: list[str] = []
    for header in HEADERS:
        name = f"{header}.h"
        host_file = host / "pulse" / name
        pinned_file = pinned / "pulse" / name
        source = host_file if host_file.is_file() else pinned_file
        if not source.is_file():
            raise SystemExit(f"missing {name} in both header sets")
        (merged / "pulse" / name).write_bytes(source.read_bytes())
        (shipped if host_file.is_file() else fallback).append(name)
    return merged, shipped, fallback


def translate(zig: str, include: pathlib.Path, work: pathlib.Path, name: str) -> pathlib.Path:
    umbrella = work / f"{name}_all.h"
    umbrella.write_text(
        "".join(f'#include "pulse/{header}.h"\n' for header in HEADERS),
        encoding="utf-8",
        newline="\n",
    )
    output = work / f"{name}_all.zig"
    completed = subprocess.run(
        [zig, "translate-c", "-target", "x86_64-windows-msvc", "-I", str(include), str(umbrella)],
        capture_output=True,
        text=True,
    )
    if completed.returncode != 0:
        raise SystemExit(f"translate-c failed for {include}:\n{completed.stderr}")
    output.write_text(completed.stdout, encoding="utf-8", newline="\n")
    return output


def struct_names(text: str) -> list[str]:
    return sorted(set(STRUCT.findall(text)))


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--pinned-include", type=pathlib.Path, default=ROOT / ".sdk-cache" / "include")
    parser.add_argument(
        "--host-include",
        type=pathlib.Path,
        default=ROOT / ".local" / "host-sdk" / "sdk" / "native" / "include",
    )
    parser.add_argument("--zig", default=None)
    args = parser.parse_args()

    pinned_include = args.pinned_include.resolve()
    host_include = args.host_include.resolve()
    missing = [h for h in HEADERS if not (pinned_include / "pulse" / f"{h}.h").is_file()]
    if missing:
        print(f"pinned header set is incomplete under {pinned_include}: {missing}", file=sys.stderr)
        return 2
    if not any((host_include / "pulse" / f"{h}.h").is_file() for h in HEADERS):
        print(f"no host headers found under {host_include}", file=sys.stderr)
        return 2

    zig = zig_executable(args.zig)
    with tempfile.TemporaryDirectory(prefix="pulse-abi-prefix-") as temp:
        work = pathlib.Path(temp)
        merged, shipped, fallback = merge_includes(pinned_include, host_include, work)
        pinned_zig = translate(zig, pinned_include, work, "pinned")
        translate(zig, merged, work, "host")

        pinned_names = struct_names(pinned_zig.read_text(encoding="utf-8"))
        host_names: set[str] = set()
        for name in shipped:
            host_names |= header_structs(host_include / "pulse" / name)
        names = [name for name in pinned_names if name in host_names]
        skipped = [name for name in pinned_names if name not in host_names]
        if not names:
            print("no structs are covered by host-shipped headers", file=sys.stderr)
            return 2

        print(
            f"host headers: {len(shipped)} shipped, {len(fallback)} pinned fallback "
            f"({', '.join(fallback) or 'none'})"
        )
        if skipped:
            print(f"not verifiable (host did not ship that header): {len(skipped)} structs")

        calls = "\n".join(f'    check("{name}");' for name in names)
        (work / "check.zig").write_text(CHECKER % calls, encoding="utf-8", newline="\n")
        completed = subprocess.run(
            [zig, "test", "--cache-dir", str(work / "cache"), str(work / "check.zig")],
            capture_output=True,
            text=True,
        )
        if completed.returncode != 0:
            print(f"prefix mismatch across {len(names)} structs:\n{completed.stderr}", file=sys.stderr)
            return 1
        print(f"prefix compatible: {len(names)} public structs from {len(shipped)} host headers")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
