import hashlib
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

import release_workflow as release


class CargoHelperStagingTests(unittest.TestCase):
    def test_compiler_hardlink_is_copied_not_packaged_directly(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            compiler, staging = root / "compiler", root / "staging"
            compiler.mkdir()
            staging.mkdir()
            source = compiler / "pulse-share-pake.exe"
            source.write_bytes(b"synthetic compiler output")
            os.link(source, compiler / "fingerprinted.exe")
            with self.assertRaisesRegex(RuntimeError, "invalid bounded regular file"):
                release.common.sha256(source)
            destination = staging / source.name
            self.assertEqual(release.stage_cargo_helper(source, destination),
                             hashlib.sha256(source.read_bytes()).hexdigest())
            self.assertEqual(destination.stat().st_nlink, 1)
            self.assertEqual(release.common.sha256(destination),
                             hashlib.sha256(source.read_bytes()).hexdigest())
            source.write_bytes(b"modified compiler cache")
            self.assertEqual(destination.read_bytes(), b"synthetic compiler output")
            with self.assertRaises(FileExistsError):
                release.stage_cargo_helper(source, destination)
            self.assertEqual(destination.read_bytes(), b"synthetic compiler output")

    def test_invalid_cargo_output_is_rejected(self):
        with tempfile.TemporaryDirectory() as temp:
            root = Path(temp)
            source = root / "pulse-share-pake.exe"
            destination = root / "staging" / source.name
            destination.parent.mkdir()
            source.touch()
            with self.assertRaisesRegex(RuntimeError, "invalid freshly built Cargo helper"):
                release.stage_cargo_helper(source, destination)
            self.assertFalse(destination.exists())
            source.unlink()
            source.mkdir()
            with self.assertRaisesRegex(RuntimeError, "invalid freshly built Cargo helper"):
                release.stage_cargo_helper(source, destination)
            self.assertFalse(destination.exists())


class ReleaseSelectionTests(unittest.TestCase):
    def test_independent_versions(self):
        items = release.plan("companion=0.2.0-rc.1,vcs=1.1.0-rc.1", "draft")
        self.assertEqual([item["tag"] for item in items], ["companion/v0.2.0-rc.1", "vcs/v1.1.0-rc.1"])
        self.assertEqual(items[0]["asset"], "strangelion.companion-0.2.0-rc.1.pulse-ext")

    def test_single_selection(self):
        self.assertEqual(len(release.plan("vcs=0.1.0", "dry-run")), 1)

    def test_share_selection(self):
        items = release.plan("share=0.1.0-rc.1", "dry-run")
        self.assertEqual(len(items), 1)
        self.assertEqual(items[0]["asset"], "strangelion.share-0.1.0-rc.1.pulse-ext")
        self.assertEqual(release.package.PRODUCTS["share"]["build_profile"], "share")

    def test_all(self):
        items = release.plan("all=0.2.0-rc.1", "draft")
        self.assertEqual({item["product"] for item in items}, set(release.package.PRODUCTS))
        self.assertTrue(all(item["version"] == "0.2.0-rc.1" for item in items))

    def test_new_product_needs_no_input_mapping(self):
        products = dict(release.package.PRODUCTS, convert={"id": "strangelion.convert"})
        with patch.object(release.package, "PRODUCTS", products):
            self.assertEqual(release.plan("convert=1.0.0-rc.1", "draft")[0]["tag"], "convert/v1.0.0-rc.1")

    def test_reject_bad_selection_or_version(self):
        for request, mode in (
                ("", "draft"), ("vcs=", "draft"), ("vcs=1.0.0,", "draft"),
                ("vcs=1.0.0,vcs=1.0.1", "draft"), ("hello-panel=1.0.0", "draft"),
                ("vcs=v1.0.0", "draft"), ("vcs=1.0.0+build", "draft"),
                ("vcs=1.0.0", "stable"), ("all=1.0.0,vcs=1.0.1", "draft"),
                ("vcs=1.0.0=2.0.0", "draft"), ("vcs=1.0.0;companion=1.0.0", "draft")):
            with self.subTest(request=request, mode=mode), self.assertRaises(ValueError):
                release.plan(request, mode)

    def test_preview_cannot_consume_stable_tag(self):
        for mode in ("draft", "publish-preview"):
            with self.assertRaises(ValueError):
                release.plan("vcs=1.0.1", mode)
        self.assertEqual(release.plan("vcs=1.0.1", "dry-run")[0]["tag"], "vcs/v1.0.1")

    def test_unsigned_preview_publication_rejected(self):
        from pathlib import Path
        with self.assertRaises(ValueError):
            release.publish(release.plan("vcs=1.0.1-rc.1", "draft"), "draft", Path("."))

    def test_plan_binding(self):
        items = release.plan("vcs=0.1.0", "dry-run")
        release.check_plan(items, release.plan_json(items))
        with self.assertRaises(RuntimeError):
            release.check_plan(items, release.plan_json(release.plan("vcs=0.2.0", "dry-run")))

    def test_candidate_branch_is_not_publishable(self):
        sha = "a" * 40
        with patch.dict(os.environ, {"GITHUB_REF": "refs/heads/deps/pulse-v1.0.61",
                                     "GITHUB_SHA": sha}), patch.object(
                release.package, "git", side_effect=[sha, ""]):
            self.assertEqual(release.source_revision(candidate=True), sha)
            with self.assertRaisesRegex(RuntimeError, "must run on main"):
                release.source_revision()

    @patch.object(release, "repository", return_value="owner/repo")
    @patch.object(release, "gh_pages")
    def test_collision_blocks_batch(self, pages, _repo):
        items = release.plan("companion=0.1.0-rc.1,vcs=0.2.0-rc.1", "draft")
        pages.side_effect = [[], [{"name": "vcs/v0.2.0-rc.1"}]]
        with self.assertRaises(RuntimeError):
            release.preflight(items)


if __name__ == "__main__":
    unittest.main()
