from pathlib import Path
import contextlib
import io
import tempfile
import unittest

import safety_audit as audit


class SafetyAuditTests(unittest.TestCase):
    def test_runtime_safety_overrides(self):
        # Use actual Zig line comments for the multiline case.
        source = "@setRuntimeSafety(true);\n@setRuntimeSafety(// reason\n false);\n@setRuntimeSafety(flag);"
        findings = audit.scan_text(source)
        self.assertEqual([(f.line, f.rule, f.blocking) for f in findings],
                         [(2, "runtime-safety-override", True),
                          (4, "runtime-safety-override", True)])

    def test_literals_and_comments_are_not_code(self):
        source = (
            '// @setRuntimeSafety(false) value.?\n'
            'const s = "@setRuntimeSafety(false) \\" value.?";\n'
            'const name = @"undefined";\n'
            'const multiline =\n'
            '    \\\\ @setRuntimeSafety(false) catch {}\n'
            ';\n'
            "const c = '\\'';\n"
            'const value = maybe.?;\n'
        )
        self.assertEqual(audit.scan_text(source),
                         [audit.Finding(8, "optional-force-unwrap")])

    def test_pointer_and_error_patterns(self):
        source = ("const p: [*c]u8 = undefined;\n"
                  "const q = @ptrCast(@alignCast(p));\n"
                  "q.* = value . ?;\n"
                  "f() catch { // intentional?\n };\n"
                  "g() catch unreachable;\n")
        rules = {f.rule for f in audit.scan_text(source)}
        self.assertEqual(rules, {"c-pointer", "uninitialized-value", "pointer-cast",
                                 "alignment-cast", "pointer-dereference",
                                 "optional-force-unwrap", "empty-error-handler",
                                 "fatal-error-handler", "unreachable-path"})

    def test_audit_blocks_override_but_not_review_findings(self):
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            (root / "build.zig").write_text("const p = value.?;", encoding="utf-8")
            raw = root / "shared/pulse/raw"
            raw.mkdir(parents=True)
            (raw / "generated.zig").write_text("@setRuntimeSafety(false);", encoding="utf-8")
            with contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(audit.audit(root), 0)
                (root / "build.zig").write_text("@setRuntimeSafety(false);", encoding="utf-8")
                self.assertEqual(audit.audit(root), 1)


if __name__ == "__main__":
    unittest.main()
