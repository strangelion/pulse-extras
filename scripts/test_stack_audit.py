"""Synthetic PE64 and unwind fixtures, independent of Windows or Zig."""
import json
from pathlib import Path
import struct
import unittest

from stack_audit import LIMIT, PE, apply_symbols, regressions, source_location


def image(codes, *, flags=0, count=None):
    data = bytearray(0x800)
    data[:2] = b"MZ"
    struct.pack_into("<I", data, 0x3c, 0x80)
    data[0x80:0x84] = b"PE\0\0"
    struct.pack_into("<HH", data, 0x84, 0x8664, 1)
    struct.pack_into("<H", data, 0x94, 240)
    opt = 0x98
    struct.pack_into("<H", data, opt, 0x20b)
    struct.pack_into("<I", data, opt + 108, 16)
    struct.pack_into("<II", data, opt + 112 + 3 * 8, 0x1000, 12)
    struct.pack_into("<IIII", data, opt + 240 + 8, 0x600, 0x1000, 0x600, 0x200)
    struct.pack_into("<III", data, 0x200, 0x1100, 0x1120, 0x1020)
    data[0x220:0x224] = bytes([1 | (flags << 3), 0, len(codes) // 2 if count is None else count, 0])
    data[0x224:0x224 + len(codes)] = codes
    return data


class StackAudit(unittest.TestCase):
    def test_small_and_saved_register(self):
        pe = PE(image(bytes([0, 0x32, 0, 0x30])))
        self.assertEqual(pe.unwind(0x1020), 40)
        self.assertEqual(pe.inventory()["functions"], 1)

    def test_large_forms(self):
        codes = bytes([0, 1]) + struct.pack("<H", 4096)
        self.assertEqual(PE(image(codes)).unwind(0x1020), 32768)
        codes = bytes([0, 0x11]) + struct.pack("<I", 200000)
        report = PE(image(codes)).inventory()
        self.assertEqual(report["over_limit"], [200000])
        self.assertEqual(report["frames"][0]["rva"], "0x00001100")

    def test_chain_and_cycle(self):
        data = image(bytes([0, 0x12]), flags=4)
        struct.pack_into("<III", data, 0x228, 0x1120, 0x1140, 0x1040)
        data[0x240:0x246] = bytes([1, 0, 1, 0, 0, 0x32])
        self.assertEqual(PE(data).unwind(0x1020), 48)
        struct.pack_into("<I", data, 0x230, 0x1020)
        with self.assertRaisesRegex(ValueError, "chain"):
            PE(data).unwind(0x1020)

    def test_malformed(self):
        with self.assertRaisesRegex(ValueError, "truncated ALLOC_LARGE"):
            PE(image(bytes([0, 0x11]))).unwind(0x1020)
        with self.assertRaisesRegex(ValueError, "opcode"):
            PE(image(bytes([0, 7]))).unwind(0x1020)
        with self.assertRaises(ValueError):
            PE(b"MZ")
        data = image(bytes([0, 2]))
        struct.pack_into("<I", data, 0x208, 0x9000)
        with self.assertRaisesRegex(ValueError, "unmapped"):
            PE(data).inventory()

    def test_exports(self):
        data = image(bytes([0, 0x11]) + struct.pack("<I", 200000))
        opt = 0x98
        struct.pack_into("<II", data, opt + 112, 0x1200, 40)
        struct.pack_into("<IIHHIIIIIII", data, 0x400,
                         0, 0, 0, 0, 0, 1, 1, 1, 0x1240, 0x1244, 0x1248)
        struct.pack_into("<IIH", data, 0x440, 0x1100, 0x1250, 0)
        data[0x450:0x450 + 19] = b"PulsePluginEntryV1\0"
        self.assertEqual(PE(data).inventory()["frames"][0]["exports"], ["PulsePluginEntryV1"])

    def test_symbol_address_and_source_identity(self):
        rows = [{"rva": "0x00001100", "bytes": 200000}, {"rva": "0x00001200", "bytes": 70000}]
        base = 0x180000000
        root = Path.cwd()
        good = {"Address": hex(base + 0x1100), "Symbol": [
            {"FunctionName": "vcs.pump", "FileName": str(root / "shared/vcs/host_query.zig"), "Line": 441}]}
        missing = {"Address": hex(base + 0x1200), "Symbol": [{"FunctionName": "??"}]}
        foreign = {"Address": hex(base + 0x1300), "Symbol": [{"FunctionName": "not ours"}]}
        output = "\n".join(json.dumps(item) for item in (foreign, good, missing, good))
        self.assertEqual(apply_symbols(rows, output, base, root), 1)
        self.assertEqual(rows[0]["symbol"]["origin"], "project")
        self.assertEqual(rows[0]["symbol"]["source"], "shared/vcs/host_query.zig")
        self.assertEqual(rows[0]["symbol"]["line"], 441)
        self.assertNotIn("symbol", rows[1])
        self.assertEqual(source_location("C:/zig/lib/std/Io.zig", root), ("zig-stdlib", "std/Io.zig"))
        self.assertEqual(source_location("C:/private/path/foo.c", root), ("other", "foo.c"))

    def test_rank_baseline(self):
        self.assertEqual(regressions([LIMIT + 8], [LIMIT + 16]), [])
        self.assertEqual(len(regressions([LIMIT + 24, LIMIT + 8], [LIMIT + 16])), 2)
        self.assertEqual(len(regressions([LIMIT + 8], [])), 1)
        with self.assertRaises(ValueError):
            regressions([], [LIMIT])


if __name__ == "__main__":
    unittest.main()
