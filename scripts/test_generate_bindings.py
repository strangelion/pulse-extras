"""Reproducibility tests for generated binding diagnostics."""
import unittest

from generate_bindings import normalize_source_locations


class SourceLocationTests(unittest.TestCase):
    def test_sdk_paths_are_reproducible(self):
        expected = "// pulse/abi.h:5:9\n"
        for path in (
            r"C:\sdk\include\pulse\abi.h",
            r"D:\a\pulse-extras\.sdk-cache\include\pulse\abi.h",
            "/tmp/sdk/include/pulse/abi.h",
        ):
            with self.subTest(path=path):
                self.assertEqual(normalize_source_locations(f"// {path}:5:9\n"), expected)

    def test_compiler_paths_are_reproducible(self):
        expected = "// zig/lib/include/stdint.h:291:9\n"
        for path in (r"C:\zig\lib\include\stdint.h", "/opt/zig/lib/include/stdint.h"):
            self.assertEqual(normalize_source_locations(f"// {path}:291:9\n"), expected)

    def test_other_content_is_preserved(self):
        text = (
            'pub const PULSE_OK: c_int = 0;\n'
            'pub const diagnostic = @compileError("invalid macro");\n'
            '// <builtin>:29:9\n'
            '// unrelated comment\n'
            '// /tmp/unrecognized.h:1:2\n'
            '//! Header digests (sha256):\n'
        )
        self.assertEqual(normalize_source_locations(text), text)

    def test_normalization_is_idempotent(self):
        text = "// pulse/abi.h:5:9\n// zig/lib/include/stdint.h:291:9\n"
        self.assertEqual(normalize_source_locations(text), text)

    def test_line_and_column_remain_significant(self):
        self.assertNotEqual(
            normalize_source_locations("// /a/pulse/abi.h:5:9\n"),
            normalize_source_locations("// /b/pulse/abi.h:6:9\n"),
        )


if __name__ == "__main__":
    unittest.main()
