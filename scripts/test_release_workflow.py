import unittest
from unittest.mock import patch

import release_workflow as release


class ReleaseSelectionTests(unittest.TestCase):
    def test_independent_versions(self):
        items = release.plan("all", {"companion": "0.2.0", "vcs": "1.1.0-rc.1"}, "draft")
        self.assertEqual([item["tag"] for item in items], ["companion/v0.2.0", "vcs/v1.1.0-rc.1"])
        self.assertEqual(items[0]["asset"], "strangelion.companion-0.2.0.pulse-ext")

    def test_single_selection(self):
        self.assertEqual(len(release.plan("vcs", {"companion": "", "vcs": "0.1.0"}, "dry-run")), 1)

    def test_reject_bad_selection_or_version(self):
        for selection, companion, vcs, mode in (
                ("all", "", "0.1.0", "draft"),
                ("vcs", "0.1.0", "0.1.0", "draft"),
                ("vcs,vcs", "", "0.1.0", "draft"),
                ("hello-panel", "", "", "draft"),
                ("vcs", "", "v1.0.0", "draft"),
                ("vcs", "", "1.0.0+build", "draft"),
                ("vcs", "", "1.0.0", "stable")):
            with self.subTest(selection=selection, mode=mode), self.assertRaises(ValueError):
                release.plan(selection, {"companion": companion, "vcs": vcs}, mode)

    @patch.object(release, "repository", return_value="owner/repo")
    @patch.object(release, "gh_pages")
    def test_collision_blocks_batch(self, pages, _repo):
        items = release.plan("all", {"companion": "0.1.0", "vcs": "0.2.0"}, "draft")
        pages.side_effect = [[], [{"name": "vcs/v0.2.0"}]]
        with self.assertRaises(RuntimeError):
            release.preflight(items)


if __name__ == "__main__":
    unittest.main()
