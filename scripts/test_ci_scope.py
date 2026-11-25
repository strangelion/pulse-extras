"""Test conservative CI scope classification without network access."""
import unittest

from ci_scope import classify, event_base


SHA = "a" * 40


class ScopeTests(unittest.TestCase):
    def test_docs_only(self):
        self.assertEqual(classify(["README.md", "docs/roadmap.md", "docs/nested/notes.md"]), "docs")

    def test_vcs_only(self):
        self.assertEqual(classify(["shared/vcs/providers/git.zig", "docs/roadmap.md"]), "vcs")

    def test_companion_only(self):
        for path in ("shared/companion/pet_demo.zig", "shared/companion/pet_surface_win32.c",
                     "tests/companion/pet_stress.py", "shared/companion_host.zig"):
            self.assertEqual(classify([path, "docs/openpets-spike.md"]), "companion")

    def test_mixed_or_shared_is_full(self):
        for path in ("shared/runtime/group.zig", "shared/process/trust.zig",
                     "shared/vcs/providers/git.zig", "extensions/hello-panel/main.zig",
                     "build.zig", ".github/workflows/pet-stress.yml", "sdk/upstream.toml"):
            self.assertEqual(classify(["shared/companion/pet_demo.zig", path]), "full")

    def test_full_for_other_paths(self):
        for path in (
            "build.zig", ".zig-version", ".gitattributes", ".gitignore",
            ".github/workflows/zig.yml", "sdk/upstream.toml",
            "scripts/ci_scope.py", "scripts/test_ci_scope.py",
            "shared/pulse/raw/pulse_all.zig", "shared/process/run.zig",
            "extensions/vcs/main.zig", "tests/abi/loader.c",
            "docs/example.py", "shared/vcs/fixture.json", "unknown",
        ):
            with self.subTest(path=path):
                self.assertEqual(classify(["docs/roadmap.md", "shared/vcs/cli.zig", path]), "full")

    def test_empty_is_full(self):
        self.assertEqual(classify([]), "full")

    def test_rename_across_scopes_is_full(self):
        self.assertEqual(classify(["shared/pulse/host.zig", "docs/host.md"]), "full")

    def test_normal_push(self):
        self.assertEqual(event_base("push", "refs/heads/main", {"before": SHA}), SHA)

    def test_pr_base(self):
        self.assertEqual(event_base("pull_request", "refs/pull/1/merge",
                                    {"pull_request": {"base": {"sha": SHA}}}), SHA)

    def test_uncertain_or_explicit_full_events(self):
        for event, ref, payload in (
            ("workflow_dispatch", "refs/heads/main", {}),
            ("push", "refs/tags/v0.1.0", {"before": SHA}),
            ("push", "refs/heads/main", {"before": "0" * 40}),
            ("push", "refs/heads/main", {"before": SHA, "forced": True}),
            ("push", "refs/heads/new", {"before": SHA, "created": True}),
            ("push", "refs/heads/main", {"before": "--help"}),
            ("pull_request", "refs/pull/1/merge", {}),
        ):
            with self.subTest(event=event, ref=ref, payload=payload):
                self.assertIsNone(event_base(event, ref, payload))


if __name__ == "__main__":
    unittest.main()
