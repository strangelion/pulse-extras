"""Create or verify a synthetic Share host acceptance tree; never overwrite."""
import argparse
import hashlib
import json
from pathlib import Path
import os
import stat

CHUNK = 1024 * 1024
MAX_ENTRIES = 4096
MAX_FILE = 256 * 1024 * 1024


def digest(path):
    with path.open("rb") as f:
        h = hashlib.sha256()
        for data in iter(lambda: f.read(CHUNK), b""):
            h.update(data)
        return h.hexdigest()


def inventory(root):
    result = []
    for directory, dirs, files in os.walk(root, followlinks=False):
        dirs.sort()
        files.sort()
        for name in dirs + files:
            p = Path(directory) / name
            info = p.lstat()
            if p.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
                raise ValueError("unexpected reparse point or symlink")
            rel = p.relative_to(root).as_posix()
            if stat.S_ISDIR(info.st_mode):
                result.append({"path": rel, "directory": True})
            elif stat.S_ISREG(info.st_mode) and info.st_size <= MAX_FILE:
                result.append({"path": rel, "directory": False, "bytes": info.st_size, "sha256": digest(p)})
            else:
                raise ValueError("unexpected entry type or size")
            if len(result) > MAX_ENTRIES:
                raise ValueError("too many entries")
    return sorted(result, key=lambda e: e["path"])


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group(required=True)
    group.add_argument("--out", type=Path)
    group.add_argument("--verify", type=Path)
    parser.add_argument("--manifest", type=Path)
    args = parser.parse_args()
    if args.out:
        if args.manifest:
            parser.error("--manifest is used only with --verify")
        root = args.out.absolute()
        root.mkdir(parents=False, exist_ok=False)
        tree = root / "share-test-tree"
        tree.mkdir()
        (tree / "empty").mkdir()
        (tree / "子目录").mkdir()
        (tree / "empty.bin").touch(exist_ok=False)
        (tree / "子目录" / "测试文本.txt").write_text("Pulse Share synthetic fixture\n", encoding="utf-8")
        for name, n in (("multi-block.bin", 8 * CHUNK + 123), ("large.bin", 128 * CHUNK + 123)):
            with (tree / name).open("xb") as f:
                while n:
                    data = os.urandom(min(n, CHUNK))
                    f.write(data)
                    n -= len(data)
        manifest = root / "manifest.json"
        with manifest.open("x", encoding="utf-8") as f:
            json.dump({"schema": 1, "entries": inventory(tree)}, f, ensure_ascii=False, indent=2)
        print("Fixture:", tree, "\nManifest:", manifest)
        return
    if not args.manifest:
        parser.error("--verify requires --manifest")
    if args.manifest.stat().st_size > 1024 * 1024:
        raise ValueError("oversized manifest")
    expected = json.loads(args.manifest.read_text(encoding="utf-8"))
    root = args.verify.absolute()
    info = root.lstat()
    if not stat.S_ISDIR(info.st_mode) or root.is_symlink() or getattr(info, "st_file_attributes", 0) & 0x400:
        raise ValueError("expected ordinary received directory")
    if expected.get("schema") != 1 or inventory(root) != expected.get("entries"):
        raise SystemExit("FAIL: tree differs from fixture manifest")
    print("PASS: exact directory structure, size and SHA-256")


if __name__ == "__main__":
    main()
