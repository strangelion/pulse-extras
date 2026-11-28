
"""Emit the exact desktop executable digest for the Pulse launcher."""
import hashlib
from pathlib import Path
import sys


with Path(sys.argv[1]).open("rb") as stream:
    digest = hashlib.file_digest(stream, "sha256").hexdigest()
Path(sys.argv[2]).write_text(f'pub const sha256 = "{digest}";\n', encoding="ascii")
