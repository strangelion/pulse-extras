import unittest
from unittest.mock import patch

import release_workflow as release


class ReleaseSelectionTests(unittest.TestCase):
    def test_independent_versions(self):
        items = release.plan("companion=0.2.0,vcs=1.1.0-rc.1", "draft")
        self.assertEqual([item["tag"] for item in items], ["companion/v0.2.0", "vcs/v1.1.0-rc.1"])
        self.assertEqual(items[0]["asset"], "strangelion.companion-0.2.0.pulse-ext")

    def test_single_selection(self):
        self.assertEqual(len(release.plan("vcs=0.1.0", "dry-run")), 1)

    def test_all(self):
        items = release.plan("all=0.2.0", "draft")
        self.assertEqual({item["product"] for item in items}, set(release.package.PRODUCTS))
        self.assertTrue(all(item["version"] == "0.2.0" for item in items))

    def test_new_product_needs_no_input_mapping(self):
        products = dict(release.package.PRODUCTS, convert={"id": "strangelion.convert"})
        with patch.object(release.package, "PRODUCTS", products):
            self.assertEqual(release.plan("convert=1.0.0", "draft")[0]["tag"], "convert/v1.0.0")

    def test_reject_bad_selection_or_version(self):
        for request, mode in (
                ("", "draft"), ("vcs=", "draft"), ("vcs=1.0.0,", "draft"),
                ("vcs=1.0.0,vcs=1.0.1", "draft"), ("hello-panel=1.0.0", "draft"),
                ("vcs=v1.0.0", "draft"), ("vcs=1.0.0+build", "draft"),
                ("vcs=1.0.0", "stable"), ("all=1.0.0,vcs=1.0.1", "draft"),
                ("vcs=1.0.0=2.0.0", "draft"), ("vcs=1.0.0;companion=1.0.0", "draft")):
            with self.subTest(request=request, mode=mode), self.assertRaises(ValueError):
                release.plan(request, mode)

    def test_plan_binding(self):
        items = release.plan("vcs=0.1.0", "dry-run")
        release.check_plan(items, release.plan_json(items))
        with self.assertRaises(RuntimeError):
            release.check_plan(items, release.plan_json(release.plan("vcs=0.2.0", "dry-run")))

    @patch.object(release, "repository", return_value="owner/repo")
    @patch.object(release, "gh_pages")
    def test_collision_blocks_batch(self, pages, _repo):
        items = release.plan("companion=0.1.0,vcs=0.2.0", "draft")
        pages.side_effect = [[], [{"name": "vcs/v0.2.0"}]]
        with self.assertRaises(RuntimeError):
            release.preflight(items)


if __name__ == "__main__":
    unittest.main()
