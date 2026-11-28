"""Reproducibility tests for generated binding diagnostics."""
import unittest

from generate_bindings import normalize_source_locations, public_bindings, upstream_pin


class SourceLocationTests(unittest.TestCase):
    def test_load_reviewed_pin(self):
        self.assertIn("headers", upstream_pin())

    def test_sdk_paths_are_reproducible(self):
        expected = "// pulse/abi.h:5:9\n"
        for path in (
            r"C:\sdk\include\pulse\abi.h",
            r"D:\a\pulse-extras\.sdk-cache\include\pulse\abi.h",
            "/tmp/sdk/include/pulse/abi.h",
        ):
            with self.subTest(path=path):
                self.assertEqual(normalize_source_locations(f"// {path}:5:9\n"), expected)

    def test_new_header_paths_are_reproducible(self):
        names = set(upstream_pin()["headers"]) | {"future_sdk"}
        self.assertEqual(normalize_source_locations("// /tmp/include/pulse/future_sdk.h:5:9\n", names),
                         "// pulse/future_sdk.h:5:9\n")

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


class PublicBindingTests(unittest.TestCase):
    def test_host_runtime_noise_does_not_change_sdk(self):
        sdk = (
            '//! SDK revision: exact\n'
            'const __root = @This();\n'
            'pub const __helpers = @import("std").zig.c_translation.helpers;\n'
        )
        public = (
            'pub const PulseStatus = i32;\n'
            'pub const struct_PulseTest = extern struct {\n'
            '    size: u32 = 0,\n'
            '};\n'
            'pub const PulseTest = struct_PulseTest;\n'
            'pub const PULSE_TEST_SIZE = @compileError("invalid macro");\n'
            '// pulse/test.h:12:9\n'
            'pub inline fn PULSE_TEST_MASK(n: anytype) @TypeOf(n) {\n'
            '    return n;\n'
            '}\n'
        )
        linux = sdk + 'pub const __int64_t = c_long;\n' + public + 'pub const _GLIBC_ = 1;\n'
        windows = sdk + 'pub const __int64_t = i64;\n' + public + 'pub const _WIN32 = 1;\n'
        self.assertEqual(public_bindings(linux), sdk + public)
        self.assertEqual(public_bindings(linux), public_bindings(windows))
        self.assertEqual(public_bindings(sdk + public), sdk + public)
        self.assertNotEqual(public_bindings(linux), public_bindings(windows.replace("size: u32", "size: u64")))

    def test_dependency_on_excluded_declaration_is_rejected(self):
        with self.assertRaisesRegex(ValueError, "needs excluded C declaration"):
            public_bindings("pub const platform_t = c_long;\npub const PulseStatus = platform_t;\n")

    def test_non_namespaced_sdk_diagnostic_is_not_dropped(self):
        with self.assertRaisesRegex(ValueError, "outside Pulse namespace"):
            public_bindings("pub const PulseStatus = i32;\npub const other = 1;\n// pulse/test.h:1:2\n")

    def test_unknown_top_level_syntax_is_not_dropped(self):
        with self.assertRaisesRegex(ValueError, "unsupported top-level syntax"):
            public_bindings("pub const PulseStatus = i32;\npub extern var platform: u32;\n")


if __name__ == "__main__":
    unittest.main()
