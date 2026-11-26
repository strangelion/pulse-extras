"""Explicit Windows VCS approval management; uses the exact candidate DLL.

No PATH search, auto-confirm, package installation, repository changes or
download. The default DLL accepts only the restricted ordinary-Git profile.
The selected installation is executable code trusted by the operator.
"""
from __future__ import annotations

import argparse
import ctypes
import hashlib
import os
from pathlib import Path
import stat
import struct
import sys

MAX_PATH = 2048
MAX_FILES = 512
MAX_PATH_BYTES = 96 * 1024
MAX_BYTES = 256 * 1024 * 1024
MAX_RECORD = 142 + 3 * MAX_PATH
STATUS = {0: "OK", 1: "invalid input", 2: "ABI mismatch", 3: "unavailable",
          4: "initialization failure", 5: "state/resource failure", 8: "permission or audit denied"}


def path_bytes(path: Path) -> bytes:
    value = str(path)
    data = value.encode("utf-8")
    if not path.is_absolute() or len(data) > MAX_PATH or not data or b"\x00" in data:
        raise ValueError(f"Invalid absolute path: {value}")
    return struct.pack("<H", len(data)) + data


def absolute(path: Path) -> Path:
    # Do not resolve symlinks/junctions to a different selected identity.
    return Path(os.path.abspath(path))


def inventory(root: Path) -> list[tuple[Path, bytes]]:
    result = []
    total = 0
    path_total = 0
    visited = 0

    def check(path: Path):
        info = path.lstat()
        if info.st_file_attributes & stat.FILE_ATTRIBUTE_REPARSE_POINT:
            raise ValueError(f"Reparse point denied: {path}")
        return info

    if not stat.S_ISDIR(check(root).st_mode):
        raise ValueError("Installation root is not a directory")
    stack = [(root, 0)]
    while stack:
        folder, depth = stack.pop()
        if depth >= 12:
            raise ValueError("Installation depth limit exceeded")
        for path in folder.iterdir():
            visited += 1
            if visited > 2048:
                raise ValueError("Installation entry limit exceeded")
            info = check(path)
            if stat.S_ISDIR(info.st_mode):
                stack.append((path, depth + 1))
            elif stat.S_ISREG(info.st_mode) and info.st_nlink == 1:
                total += info.st_size
                path_total += len(str(path).encode("utf-8"))
                if len(result) >= MAX_FILES or total > MAX_BYTES or path_total > MAX_PATH_BYTES:
                    raise ValueError("Restricted installation exceeds 512 files / 256 MiB / 96 KiB paths")
                digest = hashlib.sha256()
                size = 0
                with path.open("rb") as stream:
                    while chunk := stream.read(65536):
                        size += len(chunk)
                        if size > info.st_size:
                            raise ValueError(f"File changed during review: {path}")
                        digest.update(chunk)
                if size != info.st_size:
                    raise ValueError(f"File changed during review: {path}")
                result.append((path, digest.digest()))
            else:
                raise ValueError(f"Unsupported installation entry: {path}")
    return sorted(result, key=lambda item: str(item[0]))


def build_input(executable: Path, root: Path, neutral: Path, install: Path):
    entries = inventory(install)
    matches = [digest for path, digest in entries if str(path) == str(executable)]
    if len(matches) != 1:
        raise ValueError("Exact executable spelling must match the installation inventory")
    if executable.name.lower() != "git.exe":
        raise ValueError("Only git.exe is supported")
    body = bytearray(b"PVCSIN01")
    for path in (executable, root, neutral, install):
        body.extend(path_bytes(path))
    body.extend(matches[0])
    body.extend(struct.pack("<H", len(entries)))
    for path, digest in entries:
        body.extend(path_bytes(path))
        body.extend(digest)
    if len(body) > 128 * 1024:
        raise ValueError("Approval input exceeds limit")
    return bytes(body), entries


def check_status(action: str, code: int):
    if code:
        raise RuntimeError(f"{action}: {STATUS.get(code, f'host error {code}')} ({code})")


def load_library(path: Path):
    if path.name != "pulse_vcs_panel.dll" or not path.is_file():
        raise ValueError("Specify the exact built pulse_vcs_panel.dll")
    dll = ctypes.CDLL(str(path), winmode=0x1100)
    dll.PulseVcsInspectV1.argtypes = [ctypes.c_void_p, ctypes.c_uint32,
                                      ctypes.c_void_p, ctypes.c_uint32, ctypes.POINTER(ctypes.c_uint32)]
    dll.PulseVcsInspectV1.restype = ctypes.c_int32
    dll.PulseVcsConfirmV1.argtypes = [ctypes.c_void_p, ctypes.c_uint32, ctypes.c_void_p, ctypes.c_uint32]
    dll.PulseVcsConfirmV1.restype = ctypes.c_int32
    dll.PulseVcsRevokeV1.argtypes = []
    dll.PulseVcsRevokeV1.restype = ctypes.c_int32
    return dll


def approve(dll, args) -> None:
    executable, root, neutral, install = (absolute(getattr(args, name))
                                           for name in ("git", "repo", "neutral", "installation"))
    payload, files = build_input(executable, root, neutral, install)
    output = ctypes.create_string_buffer(MAX_RECORD)
    written = ctypes.c_uint32()
    check_status("Inspect", dll.PulseVcsInspectV1(payload, len(payload), output, len(output), ctypes.byref(written)))
    if not 142 <= written.value <= len(output):
        raise RuntimeError("Invalid review returned by native manager")
    record = output.raw[:written.value]
    if record[:8] != b"PVCSRV01":
        raise RuntimeError("Unexpected review schema")
    print("One saved Windows-user approval will be replaced. Scope: exact repository root, read-only Git.")
    print(f"Executable: {executable}\nRepository: {root}\nNeutral directory: {neutral}\nInstallation: {install}")
    for path, digest in files:
        print(f"  {digest.hex()}  {path}")
    for name, offset in (("Executable", 8), ("Installation evidence", 40), ("Repository evidence", 72), ("Environment", 104)):
        print(f"{name} SHA-256: {record[offset:offset + 32].hex()}")
    token = hashlib.sha256(payload + record).hexdigest()[:16]
    print("Only approve a Git distribution you independently trust. The native checks are not a publisher-signature check.")
    if input(f"Type APPROVE {token} to save, or anything else to cancel: ").strip() != f"APPROVE {token}":
        print("Cancelled; saved approval unchanged.")
        return
    check_status("Confirm", dll.PulseVcsConfirmV1(payload, len(payload), record, len(record)))
    print("Saved. Reopen the extension. Every command will revalidate evidence and the saved approval.")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dll", type=Path, required=True)
    commands = parser.add_subparsers(dest="action", required=True)
    grant = commands.add_parser("approve")
    for name in ("git", "repo", "neutral", "installation"):
        grant.add_argument("--" + name, type=Path, required=True)
    commands.add_parser("revoke")
    args = parser.parse_args()
    if sys.platform != "win32":
        print("Approval manager requires Windows.", file=sys.stderr)
        return 1
    try:
        dll = load_library(absolute(args.dll))
        if args.action == "approve":
            approve(dll, args)
        elif input("Type REVOKE to revoke the saved candidate approval: ").strip() == "REVOKE":
            check_status("Revoke", dll.PulseVcsRevokeV1())
            print("Saved approval revoked. Existing sessions reject further command admissions.")
        else:
            print("Cancelled; saved approval unchanged.")
    except (OSError, ValueError, RuntimeError, EOFError) as exc:
        print(f"Approval failed: {exc}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
